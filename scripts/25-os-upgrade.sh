#!/usr/bin/env bash
# 25-os-upgrade.sh - Actualiza paquetes del SO o sube Debian a la siguiente version.
#
# Uso: sudo scripts/25-os-upgrade.sh <instancia> [--security-only | --release] [opciones]
#   (sin modo)         apt-get update + upgrade de paquetes del SO (misma version de Debian)
#   --security-only    Solo instala actualizaciones del repositorio de seguridad
#   --release          Sube Debian a la siguiente version (bullseye->bookworm->trixie)
#   --skip-backup      No ejecuta 10-backup.sh antes (NO recomendado)
#   --yes              No pide confirmacion
#   --dry-run          Muestra lo que haria
#
# En modo --release: respalda, cambia /etc/apt/sources.list(.d), hace
# "apt-get upgrade --without-new-pkgs" y luego "full-upgrade", ejecuta mariadb-upgrade,
# koha-upgrade-schema y reinicia servicios. Solo Debian; en Ubuntu use do-release-upgrade.
# Reinicie el servidor al terminar si se actualizo el kernel.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; MODE="upgrade"; SKIP_BACKUP=0; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --security-only) MODE="security"; shift ;;
        --release) MODE="release"; shift ;;
        --skip-backup) SKIP_BACKUP=1; shift ;;
        --yes|-y) YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
require_root
require_instance "$INSTANCE"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CUR="$(os_codename)"
case "$CUR" in
    buster) NEXT=bullseye ;;
    bullseye) NEXT=bookworm ;;
    bookworm) NEXT=trixie ;;
    *) NEXT="" ;;
esac

if [ "$YES" != "1" ] && [ "$DRY_RUN" != "1" ]; then
    read -r -p "Modo '$MODE' en $CUR. Continuar? Escriba 'si': " answer
    [ "$answer" = "si" ] || die "Cancelado por el usuario."
fi

if [ "$SKIP_BACKUP" != "1" ]; then
    for inst in $(koha-list); do
        run "$SCRIPT_DIR/10-backup.sh" "$inst"
    done
fi

case "$MODE" in
    upgrade)
        run apt-get update -q
        run apt-get upgrade "${APT_OPTS[@]}"
        ;;
    security)
        run apt-get update -q
        SEC="$(apt-get -s upgrade 2>/dev/null | awk '/^Inst / && /[Ss]ecurity/ {print $2}' | sort -u | tr '\n' ' ')"
        if [ -z "$SEC" ]; then
            ok "No hay actualizaciones de seguridad pendientes."
        else
            log "Actualizaciones de seguridad: $SEC"
            # shellcheck disable=SC2086
            run apt-get install --only-upgrade "${APT_OPTS[@]}" $SEC
        fi
        ;;
    release)
        [ "$(os_release ID)" = "debian" ] || die "--release solo esta soportado en Debian. En Ubuntu use do-release-upgrade."
        [ -n "$NEXT" ] || die "No hay siguiente version conocida para '$CUR'."
        log "Subiendo Debian $CUR -> $NEXT"
        STAMP="$(date +%Y%m%d-%H%M%S)"
        mapfile -t FILES < <(grep -rl -E "\b$CUR\b" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '\.bak-' || true)
        [ "${#FILES[@]}" -gt 0 ] || die "No se encontraron fuentes apt con '$CUR'."
        for f in "${FILES[@]}"; do
            run cp -p "$f" "$f.bak-$STAMP"
            run sed -i -E "s/\b$CUR\b/$NEXT/g" "$f"
            # Las versiones sin soporte viven en archive.debian.org; la nueva esta en deb.debian.org.
            run sed -i -E 's#archive\.debian\.org/debian-security#deb.debian.org/debian-security#g; s#archive\.debian\.org/debian#deb.debian.org/debian#g' "$f"
            log "Actualizado $f (copia en $f.bak-$STAMP)"
        done
        run apt-get update -q
        run apt-get upgrade --without-new-pkgs "${APT_OPTS[@]}"
        run apt-get full-upgrade "${APT_OPTS[@]}"
        run apt-get autoremove -y
        # MariaDB puede quedar detenido tras el cambio de version.
        run service mariadb restart || run service mysql restart || warn "No se pudo reiniciar MariaDB/MySQL."
        if command -v mariadb-upgrade >/dev/null 2>&1; then
            run mariadb-upgrade || warn "mariadb-upgrade devolvio error (puede ser normal si ya estaba al dia)."
        elif command -v mysql_upgrade >/dev/null 2>&1; then
            run mysql_upgrade || warn "mysql_upgrade devolvio error."
        fi
        for inst in $(koha-list); do
            run koha-upgrade-schema "$inst"
        done
        ;;
esac

# Servicios Koha.
for inst in $(koha-list); do
    if koha-list --plack 2>/dev/null | grep -qx "$inst"; then
        plack_restart "$inst" || warn "No se pudo reiniciar Plack de $inst"
    fi
    run koha-zebra --restart "$inst" || warn "koha-zebra --restart $inst fallo"
done
run service memcached restart || true
run service apache2 restart || warn "No se pudo reiniciar Apache."

if [ -f /var/run/reboot-required ]; then
    warn "El sistema pide reinicio (/var/run/reboot-required)."
fi
ok "SO: $(os_release PRETTY_NAME)"
