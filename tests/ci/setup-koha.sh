#!/usr/bin/env bash
# Instala Koha <serie> desde el repositorio de la comunidad en un contenedor Debian
# (sin systemd), crea la instancia y la deja lista con datos de ejemplo.
# Uso: tests/ci/setup-koha.sh <instancia> <serie> [n_registros]
set -euo pipefail
INST="$1"; SERIES="$2"; NREC="${3:-50}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

echo "::group::Paquetes base"
# Debian 11 ya no tiene soporte: sus paquetes estan en archive.debian.org (igual que en un servidor real).
if grep -q 'VERSION_CODENAME=bullseye' /etc/os-release; then
    cat > /etc/apt/sources.list <<'SRC'
deb http://archive.debian.org/debian bullseye main
deb http://archive.debian.org/debian bullseye-updates main
deb http://archive.debian.org/debian-security bullseye-security main
SRC
    rm -f /etc/apt/sources.list.d/debian.sources
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive
fi
apt-get update -q
apt-get install -y -q curl gnupg ca-certificates procps rsync openssl sudo
curl -fsSL https://debian.koha-community.org/koha/gpg.asc | gpg --dearmor > /usr/share/keyrings/koha-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/koha-keyring.gpg] https://debian.koha-community.org/koha $SERIES main" > /etc/apt/sources.list.d/koha.list
apt-get update -q
apt-get install -y -q mariadb-server memcached
service mariadb start
echo "::endgroup::"

echo "::group::koha-common $SERIES"
apt-get install -y -q koha-common
dpkg-query -W koha-common
echo "::endgroup::"

echo "::group::Apache e instancia"
a2dismod mpm_event >/dev/null 2>&1 || true
a2enmod mpm_itk rewrite cgi headers proxy_http >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true
sed -i -e 's/^DOMAIN=.*/DOMAIN=".koha.test"/' -e 's/^INTRAPORT=.*/INTRAPORT="80"/' -e 's/^OPACPORT=.*/OPACPORT="80"/' /etc/koha/koha-sites.conf
# Nombres de los sitios de Apache para pruebas locales.
echo "127.0.0.1 $INST.koha.test $INST-intra.koha.test" >> /etc/hosts
service memcached start || true
service apache2 start
koha-create --create-db "$INST"
koha-plack --enable "$INST"
koha-plack --start "$INST" || true
service apache2 restart
echo "::endgroup::"

echo "::group::Esquema y datos de ejemplo"
cp "$HERE/install_db.pl" "$HERE/generate_marc.pl" /tmp/
chmod 644 /tmp/install_db.pl /tmp/generate_marc.pl
koha-shell -c "perl /tmp/install_db.pl" "$INST"
perl /tmp/generate_marc.pl /tmp/sample.mrc "$NREC"
chmod 644 /tmp/sample.mrc
BULK="$(find /usr/share/koha -name bulkmarcimport.pl | head -1)"
SUPER="$(find /usr/share/koha -name create_superlibrarian.pl | head -1)"
echo "bulkmarcimport: $BULK / create_superlibrarian: ${SUPER:-no incluido}"
koha-shell -c "perl $BULK -b -m ISO2709 -file /tmp/sample.mrc -commit 50" "$INST"
if [ -n "$SUPER" ]; then
    koha-shell -c "perl $SUPER --userid ciadmin --password 'Ci-Toolkit-2026-x' --branchcode CPL --categorycode S --cardnumber 99999" "$INST"
else
    koha-mysql "$INST" -e "UPDATE borrowers SET flags=1, userid='ciadmin' WHERE borrowernumber=(SELECT b FROM (SELECT MIN(borrowernumber) b FROM borrowers) x)"
fi
koha-rebuild-zebra -f -v "$INST"
koha-zebra --restart "$INST" || koha-zebra --start "$INST" || true
echo "::endgroup::"
