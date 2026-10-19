#!/usr/bin/env bash
# 40-reindex.sh - Reindexacion completa de Zebra y control de registros no indexados.
#
# Uso: sudo scripts/40-reindex.sh <instancia> [opciones]
#   --check-only     No reindexa; solo compara biblios en BD vs registros en Zebra
#   --dry-run        Muestra lo que haria
#
# Ejecuta "koha-rebuild-zebra -f -v <instancia>" (biblios y autoridades) y luego
# compara el numero de biblios en la BD con el numero de registros en el indice.
# Sale con codigo 1 si hay biblios sin indexar.
# Si la instancia usa Elasticsearch (syspref SearchEngine), indica el comando
# equivalente (koha-elasticsearch --rebuild) y lo ejecuta.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check-only) CHECK_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
require_root
require_instance "$INSTANCE"

ENGINE="$(koha_sql "$INSTANCE" "SELECT value FROM systempreferences WHERE variable='SearchEngine'" || true)"
if [ "$ENGINE" = "Elasticsearch" ]; then
    warn "La instancia usa Elasticsearch."
    [ "$CHECK_ONLY" = "1" ] && exit 0
    run koha-elasticsearch --rebuild -d -v "$INSTANCE"
    exit 0
fi

if [ "$CHECK_ONLY" != "1" ]; then
    START=$(date +%s)
    log "Reindexacion completa Zebra de $INSTANCE (koha-rebuild-zebra -f -v)..."
    run koha-rebuild-zebra -f -v "$INSTANCE"
    ok "Reindexacion terminada en $(( $(date +%s) - START )) s."
fi
[ "$DRY_RUN" = "1" ] && exit 0

# zebrasrv debe estar en ejecucion para contar.
if ! pgrep -u "$(instance_user "$INSTANCE")" -f zebrasrv >/dev/null 2>&1; then
    warn "zebrasrv no esta en ejecucion; iniciando..."
    koha-zebra --start "$INSTANCE" || true
    sleep 3
fi

DB_BIBLIOS="$(koha_sql "$INSTANCE" "SELECT COUNT(*) FROM biblio")"
ZOUT="$(koha_perl "$INSTANCE" "$TOOLKIT_LIB_DIR/zebra_count.pl")"
INDEXED="$(echo "$ZOUT" | sed -n 's/^total=//p')"
PENDING="$(koha_sql "$INSTANCE" "SELECT COUNT(*) FROM zebraqueue WHERE done=0")"

echo "Biblios en BD:          $DB_BIBLIOS"
echo "Registros en Zebra:     ${INDEXED:-?}"
echo "zebraqueue pendiente:   $PENDING"

[ -n "$INDEXED" ] || die "No se pudo consultar Zebra. Salida: $ZOUT"
if [ "$INDEXED" -lt "$DB_BIBLIOS" ]; then
    fail "Hay $((DB_BIBLIOS - INDEXED)) biblios sin indexar."
    exit 1
elif [ "$INDEXED" -gt "$DB_BIBLIOS" ]; then
    warn "Zebra tiene $((INDEXED - DB_BIBLIOS)) registros de mas (biblios borrados aun indexados). Ejecute una reindexacion completa."
else
    ok "Todos los biblios estan indexados ($INDEXED)."
fi
