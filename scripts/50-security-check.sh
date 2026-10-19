#!/usr/bin/env bash
# 50-security-check.sh - Revision de seguridad de una instancia Koha (solo lectura).
#
# Uso: sudo scripts/50-security-check.sh <instancia> [opciones]
#   --url URL          URL publica del OPAC para revisar certificado y cabeceras (ej. https://biblioteca.cl)
#   --staff-url URL    URL publica de la interfaz de personal
#   --cert-days N      Dias minimos de vigencia del certificado (defecto: 21)
#   --apt-update       Ejecuta apt-get update antes de contar actualizaciones de seguridad
#   --strict           Sale con codigo 1 tambien si hay advertencias
#
# Revisa: certificados SSL (Apache y URL), cabeceras HTTP, permisos de koha-conf.xml
# y otros archivos sensibles, actualizaciones de seguridad pendientes del SO,
# usuarios superlibrarian, version de Koha soportada y exposicion del instalador web.
# Resultado: lineas OK/WARN/FAIL. Sale con codigo 1 si hay algun FAIL.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; URL=""; STAFF_URL=""; CERT_DAYS=21; APT_UPDATE=0; STRICT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --url) URL="$2"; shift 2 ;;
        --staff-url) STAFF_URL="$2"; shift 2 ;;
        --cert-days) CERT_DAYS="$2"; shift 2 ;;
        --apt-update) APT_UPDATE=1; shift ;;
        --strict) STRICT=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
require_root
require_instance "$INSTANCE"
require_cmd openssl curl stat

NFAIL=0; NWARN=0
F() { fail "$*"; NFAIL=$((NFAIL + 1)); }
W() { warn "$*"; NWARN=$((NWARN + 1)); }

echo "== Seguridad: instancia $INSTANCE en $(hostname) =="

# --- 1. Certificados SSL configurados en Apache ---
echo "-- Certificados SSL (Apache)"
mapfile -t CERTS < <(grep -rhoE '^\s*SSLCertificateFile\s+\S+' /etc/apache2/sites-enabled/ 2>/dev/null | awk '{print $2}' | sort -u || true)
if [ "${#CERTS[@]}" -eq 0 ]; then
    W "Apache no tiene sitios con SSL habilitado. El OPAC y el login de personal viajan sin cifrar (HTTP)."
else
    for c in "${CERTS[@]}"; do
        if [ ! -r "$c" ]; then F "No se puede leer el certificado $c"; continue; fi
        END="$(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)"
        if openssl x509 -checkend $((CERT_DAYS * 86400)) -noout -in "$c" >/dev/null; then
            ok "$c vence el $END"
        elif openssl x509 -checkend 0 -noout -in "$c" >/dev/null; then
            W "$c vence pronto ($END, menos de $CERT_DAYS dias)"
        else
            F "$c VENCIDO ($END)"
        fi
    done
fi

# --- 2. Certificado y cabeceras de las URLs publicas ---
check_url() {
    local u="$1" host port hdrs end
    echo "-- URL $u"
    if [[ "$u" == https://* ]]; then
        host="$(echo "$u" | sed -E 's#https://([^/:]+).*#\1#')"
        port="$(echo "$u" | sed -nE 's#https://[^/:]+:([0-9]+).*#\1#p')"; port="${port:-443}"
        end="$(echo | timeout 15 openssl s_client -servername "$host" -connect "$host:$port" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
        if [ -z "$end" ]; then
            F "No se pudo obtener el certificado de $host:$port"
        else
            local exp_s now_s days
            exp_s="$(date -d "$end" +%s)"; now_s="$(date +%s)"; days=$(( (exp_s - now_s) / 86400 ))
            if [ "$days" -lt 0 ]; then F "Certificado de $host VENCIDO ($end)"
            elif [ "$days" -lt "$CERT_DAYS" ]; then W "Certificado de $host vence en $days dias ($end)"
            else ok "Certificado de $host valido por $days dias ($end)"; fi
        fi
    else
        W "$u no usa HTTPS."
        local https_hdr
        https_hdr="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${u/http:/https:}" || true)"
        [ "$https_hdr" != "000" ] && echo "   (responde por HTTPS con codigo $https_hdr)"
    fi
    hdrs="$(curl -skI -L --max-time 20 "$u" || true)"
    [ -n "$hdrs" ] || { F "Sin respuesta HTTP de $u"; return 0; }
    local h
    for h in X-Frame-Options X-Content-Type-Options; do
        if echo "$hdrs" | grep -qi "^$h:"; then ok "Cabecera $h presente"; else W "Falta cabecera $h"; fi
    done
    if [[ "$u" == https://* ]]; then
        if echo "$hdrs" | grep -qi '^Strict-Transport-Security:'; then ok "HSTS presente"; else W "Falta Strict-Transport-Security (HSTS)"; fi
    fi
    if echo "$hdrs" | grep -qiE '^Server: .*Apache/[0-9]'; then
        W "Apache expone su version (Server: $(echo "$hdrs" | grep -i '^Server:' | head -1 | cut -d' ' -f2- | tr -d '\r')). Use ServerTokens Prod."
    fi
    if echo "$hdrs" | grep -qiE '^X-Powered-By:'; then W "Cabecera X-Powered-By expuesta"; fi
}
[ -n "$URL" ] && check_url "$URL"
[ -n "$STAFF_URL" ] && check_url "$STAFF_URL"

# --- 3. Configuracion de Apache ---
echo "-- Apache"
if command -v apache2ctl >/dev/null 2>&1; then
    TOKENS="$(grep -rhE '^\s*ServerTokens' /etc/apache2/ 2>/dev/null | tail -1 | awk '{print $2}' || true)"
    if [ "${TOKENS,,}" = "prod" ]; then ok "ServerTokens Prod"; else W "ServerTokens es '${TOKENS:-OS (defecto)}'; recomendado: Prod"; fi
    SIG="$(grep -rhE '^\s*ServerSignature' /etc/apache2/ 2>/dev/null | tail -1 | awk '{print $2}' || true)"
    if [ "${SIG,,}" = "off" ]; then ok "ServerSignature Off"; else W "ServerSignature es '${SIG:-On}'; recomendado: Off"; fi
    if apache2ctl -M 2>/dev/null | grep -q headers_module; then ok "mod_headers habilitado"; else W "mod_headers no habilitado (necesario para cabeceras de seguridad)"; fi
fi

# --- 4. Permisos de archivos sensibles ---
echo "-- Permisos"
check_perm() {
    local f="$1" max="$2" mode owner
    [ -e "$f" ] || return 0
    mode="$(stat -L -c '%a' "$f")"; owner="$(stat -L -c '%U:%G' "$f")"
    if [ $(( 8#$mode & 8#007 )) -ne 0 ]; then
        F "$f es legible/escribible por todos (modo $mode, $owner). Recomendado: $max"
    elif [ $(( 8#$mode & ~8#$max & 8#777 )) -ne 0 ]; then
        W "$f tiene modo $mode ($owner); recomendado $max o menos"
    else
        ok "$f modo $mode ($owner)"
    fi
}
check_perm "$(koha_conf "$INSTANCE")" 640
check_perm /etc/koha/passwd 640
check_perm /etc/mysql/debian.cnf 600
check_perm "/etc/koha/sites/$INSTANCE/log4perl.conf" 644
for d in "/var/lib/koha/$INSTANCE" "/var/log/koha/$INSTANCE" "/var/spool/koha/$INSTANCE"; do
    [ -d "$d" ] || continue
    mode="$(stat -c '%a' "$d")"
    if [ $(( 8#$mode & 8#002 )) -ne 0 ]; then F "$d escribible por todos ($mode)"; else ok "$d modo $mode"; fi
done
if [ -d "$BACKUP_ROOT" ]; then
    mode="$(stat -c '%a' "$BACKUP_ROOT")"
    if [ $(( 8#$mode & 8#007 )) -ne 0 ]; then F "$BACKUP_ROOT accesible por todos ($mode); contiene datos personales"; else ok "$BACKUP_ROOT modo $mode"; fi
fi

# --- 5. Actualizaciones de seguridad pendientes ---
echo "-- Actualizaciones del SO"
if [ "$APT_UPDATE" = "1" ]; then apt-get update -q >/dev/null 2>&1 || warn "apt-get update fallo"; fi
SEC_COUNT="$(apt-get -s upgrade 2>/dev/null | awk '/^Inst / && /[Ss]ecurity/' | wc -l | tr -d ' ')"
ALL_COUNT="$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /' | wc -l | tr -d ' ')"
if [ "$SEC_COUNT" -gt 0 ]; then
    W "$SEC_COUNT actualizaciones de seguridad pendientes ($ALL_COUNT en total). Use 25-os-upgrade.sh --security-only"
else
    ok "Sin actualizaciones de seguridad pendientes ($ALL_COUNT actualizaciones normales pendientes)"
fi
CODENAME="$(os_codename)"
case "$CODENAME" in
    stretch|buster|bullseye) F "Debian $CODENAME ya no recibe actualizaciones de seguridad regulares. Planifique subir de version." ;;
esac

# --- 6. Usuarios superlibrarian ---
echo "-- Usuarios con permiso superlibrarian"
SUPERS="$(koha_sql "$INSTANCE" "SELECT CONCAT(borrowernumber,' ',COALESCE(userid,'(sin userid)'),' ',COALESCE(surname,''),' ultimo acceso: ',COALESCE(lastseen,'nunca')) FROM borrowers WHERE flags IS NOT NULL AND (flags & 1)=1")"
NSUP="$(printf '%s' "$SUPERS" | grep -c . || true)"
echo "$SUPERS" | sed '/^$/d; s/^/   /'
if [ "$NSUP" -gt 3 ]; then W "$NSUP usuarios superlibrarian. Revise si todos lo necesitan."; else ok "$NSUP usuario(s) superlibrarian"; fi

# --- 7. Version de Koha soportada ---
echo "-- Version de Koha"
SERIES="$(version_series "$(koha_code_version)")"
SUPPORTED="$(for s in stable oldstable oldoldstable; do curl -fsSL --max-time 15 "$KOHA_REPO_URL/dists/$s/Release" 2>/dev/null | sed -n 's/^Codename: *//p'; done | tr '\n' ' ')"
if [ -z "$SUPPORTED" ]; then
    W "No se pudo consultar el repositorio de Koha para ver las series mantenidas."
elif echo " $SUPPORTED " | grep -q " $SERIES "; then
    ok "Koha $SERIES esta entre las series mantenidas ($SUPPORTED)"
else
    F "Koha $SERIES ya no recibe correcciones de seguridad. Series mantenidas: $SUPPORTED"
fi

# --- 8. Instalador web y otros ---
echo "-- Otros"
if koha_sql "$INSTANCE" "SELECT value FROM systempreferences WHERE variable='SessionStorage'" | grep -qi tmp; then
    W "SessionStorage=tmp: use 'mysql' o 'memcached'."
fi
DBPASS="$(koha_conf_value "$INSTANCE" pass)"
if [ -n "$DBPASS" ] && [ "${#DBPASS}" -lt 12 ]; then
    W "La clave de BD de la instancia tiene menos de 12 caracteres."
fi

echo "--------------------------------------------------"
echo "Resultado: $NFAIL FAIL, $NWARN WARN"
if [ "$NFAIL" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = "1" ] && [ "$NWARN" -gt 0 ]; then exit 1; fi
exit 0
