#!/usr/bin/env bash
# 00-preflight.sh - Diagnostico previo a una actualizacion de Koha (solo lectura).
#
# Uso: sudo scripts/00-preflight.sh <instancia> [--min-free-gb N]
#
# Muestra: version del SO, version de Koha (paquete, codigo y BD), instancias,
# motor y version de BD, espacio en disco, motor de busqueda (Zebra/Elasticsearch),
# fuente apt de Koha y conteos de registros. No modifica nada.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""
MIN_FREE_GB=5
while [ $# -gt 0 ]; do
    case "$1" in
        --min-free-gb) MIN_FREE_GB="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
require_root
require_instance "$INSTANCE"

PROBLEMS=0
problem() { fail "$*"; PROBLEMS=$((PROBLEMS + 1)); }

echo "=================================================="
echo " Koha preflight - instancia: $INSTANCE - $(hostname) - $(date '+%F %T')"
echo "=================================================="

# --- Sistema operativo ---
OS_ID="$(os_release ID)"
OS_CODENAME="$(os_codename)"
echo "SO:                 $(os_release PRETTY_NAME) (codename: $OS_CODENAME)"
echo "Kernel:             $(uname -r)"
case "$OS_ID" in
    debian|ubuntu) : ;;
    *) problem "SO no soportado por este toolkit (se espera Debian o Ubuntu)." ;;
esac

# --- Koha ---
PKG_VER="$(koha_pkg_version)"
CODE_VER="$(koha_code_version)"
DB_VER="$(koha_db_version "$INSTANCE")"
echo "koha-common:        ${PKG_VER:-NO INSTALADO}"
echo "Version codigo:     ${CODE_VER:-?}"
echo "Version en BD:      ${DB_VER:-?}"
if [ -n "$CODE_VER" ] && [ -n "$DB_VER" ]; then
    if [ "$(code_version_to_db "$CODE_VER")" = "$DB_VER" ]; then
        ok "La BD esta al dia con el codigo instalado."
    else
        warn "La BD ($DB_VER) no coincide con el codigo ($(code_version_to_db "$CODE_VER")). Ejecute koha-upgrade-schema."
    fi
fi
echo "Instancias:         $(koha-list 2>/dev/null | tr '\n' ' ')"
echo "Plack habilitado:   $(koha-list --plack 2>/dev/null | tr '\n' ' ' || true)"

echo "Fuente apt Koha:"
grep -rhs 'koha-community' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sed 's/^/                    /' || echo "                    (no encontrada)"

# --- Base de datos ---
DB_SERVER_VER="$(koha_sql "$INSTANCE" "SELECT VERSION()" 2>/dev/null || true)"
echo "Servidor BD:        ${DB_SERVER_VER:-no se pudo conectar}"
[ -n "$DB_SERVER_VER" ] || problem "No hay conexion a la BD de la instancia."
echo "Base de datos:      $(instance_db_name "$INSTANCE") @ $(koha_conf_value "$INSTANCE" hostname)"
if [ -n "$DB_SERVER_VER" ]; then
    DB_SIZE="$(koha_sql "$INSTANCE" "SELECT ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables WHERE table_schema=DATABASE()")"
    echo "Tamano BD (MB):     $DB_SIZE"
    echo "Conteos:"
    record_counts "$INSTANCE" | sed 's/^/                    /'
fi

# --- Motor de busqueda ---
ENGINE="$(koha_sql "$INSTANCE" "SELECT value FROM systempreferences WHERE variable='SearchEngine'" 2>/dev/null || true)"
echo "SearchEngine:       ${ENGINE:-Zebra (por defecto)}"
if grep -q '<elasticsearch>' "$(koha_conf "$INSTANCE")"; then
    echo "Elasticsearch conf: $(perl -0777 -ne 'print $1 if m{<elasticsearch>.*?<server>(.*?)</server>}s' "$(koha_conf "$INSTANCE")")"
fi
if pgrep -u "$(instance_user "$INSTANCE")" -f zebrasrv >/dev/null 2>&1; then
    ok "zebrasrv en ejecucion."
else
    warn "zebrasrv no esta en ejecucion para $INSTANCE."
fi
PENDING="$(koha_sql "$INSTANCE" "SELECT COUNT(*) FROM zebraqueue WHERE done=0" 2>/dev/null || echo '?')"
echo "zebraqueue pendiente: $PENDING"

# --- Disco ---
echo "Espacio en disco:"
for d in /var/lib/mysql /var/lib/koha /var/spool/koha "$BACKUP_ROOT" /; do
    [ -e "$d" ] || continue
    df -hP "$d" | awk -v d="$d" 'NR==2 {printf "                    %-26s libre %s de %s (uso %s)\n", d, $4, $2, $5}'
done
FREE_KB="$(df -kP /var | awk 'NR==2 {print $4}')"
if [ "$FREE_KB" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
    problem "Menos de ${MIN_FREE_GB} GB libres en /var. Libere espacio antes de actualizar."
else
    ok "Espacio libre en /var >= ${MIN_FREE_GB} GB."
fi

# --- Servicios ---
for svc in apache2 memcached; do
    if pgrep -x "$svc" >/dev/null 2>&1 || pgrep -f "/usr/sbin/$svc" >/dev/null 2>&1; then
        ok "$svc en ejecucion."
    else
        warn "$svc no parece estar en ejecucion."
    fi
done

# --- Recomendacion de ruta ---
SERIES="$(version_series "${CODE_VER:-0.0}")"
echo "Serie actual:       $SERIES"
case "$OS_CODENAME" in
    stretch|buster) warn "Debian $OS_CODENAME esta fuera de soporte. Planifique actualizar el SO (ver docs/checklist-actualizacion.md)." ;;
    bullseye) warn "Debian 11 (bullseye) termino su soporte LTS en 2026. Ruta sugerida: Koha -> 22.11 en bullseye, SO -> bookworm, Koha -> stable." ;;
esac

echo "--------------------------------------------------"
if [ "$PROBLEMS" -gt 0 ]; then
    fail "Preflight con $PROBLEMS problema(s). Corrija antes de continuar."
    exit 1
fi
ok "Preflight sin problemas bloqueantes."
