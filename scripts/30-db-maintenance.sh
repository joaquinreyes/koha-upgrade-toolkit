#!/usr/bin/env bash
# 30-db-maintenance.sh - Revision y optimizacion de la BD de Koha. Solo reporta: no borra nada.
#
# Uso: sudo scripts/30-db-maintenance.sh <instancia> [opciones]
#   --optimize        Ejecuta OPTIMIZE (mysqlcheck --optimize). Bloquea tablas: hagalo fuera de horario.
#   --report FILE     Guarda el reporte en FILE (defecto: /var/log/koha-toolkit/db-report-<inst>-<fecha>.txt)
#   --fail-on-issues  Sale con codigo 2 si encuentra problemas de datos
#   --dry-run         Muestra lo que haria
#
# Controles:
#   - mysqlcheck --check y --analyze de todas las tablas
#   - ISBN duplicados, titulo+autor duplicados
#   - items sin biblio, biblio sin biblio_metadata, biblio sin biblioitems
#   - biblio_metadata cuyo biblio no existe
#   - items con biblioitemnumber inconsistente, con sucursal o tipo inexistente
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; OPTIMIZE=0; REPORT=""; FAIL_ON_ISSUES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --optimize) OPTIMIZE=1; shift ;;
        --report) REPORT="$2"; shift 2 ;;
        --fail-on-issues) FAIL_ON_ISSUES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
require_root
require_instance "$INSTANCE"
mkdir -p /var/log/koha-toolkit
REPORT="${REPORT:-/var/log/koha-toolkit/db-report-$INSTANCE-$(date +%Y%m%d-%H%M%S).txt}"

DB="$(instance_db_name "$INSTANCE")"
DEFAULTS="$(instance_db_defaults "$INSTANCE")"
ISSUES=0

{
echo "Reporte de mantenimiento BD - instancia $INSTANCE - BD $DB - $(date '+%F %T')"
echo "======================================================================"

echo
echo "## mysqlcheck --check"
if [ "$DRY_RUN" = "1" ]; then
    run "$(db_check)" --check "$DB"
else
    CHECK_OUT="$("$(db_check)" --defaults-extra-file="$DEFAULTS" --check "$DB" 2>&1 || true)"
    BAD="$(echo "$CHECK_OUT" | grep -v -E '\s(OK|Table is already up to date)$' | grep -v -E '^(note|status)\s*:' | grep -c . || true)"
    if [ "$BAD" = "0" ]; then echo "Todas las tablas OK ($(echo "$CHECK_OUT" | grep -c ' OK$' || true) tablas)."; else echo "$CHECK_OUT" | grep -v ' OK$'; ISSUES=$((ISSUES + 1)); fi
fi

echo
echo "## mysqlcheck --analyze (actualiza estadisticas del optimizador)"
if [ "$DRY_RUN" = "1" ]; then
    run "$(db_check)" --analyze "$DB"
else
    if "$(db_check)" --defaults-extra-file="$DEFAULTS" --analyze "$DB" >/dev/null 2>&1; then echo "ANALYZE completado."; else echo "ANALYZE con advertencias."; fi
fi

if [ "$OPTIMIZE" = "1" ]; then
    echo
    echo "## mysqlcheck --optimize"
    if [ "$DRY_RUN" = "1" ]; then
        run "$(db_check)" --optimize "$DB"
    else
        BEFORE="$(koha_sql "$INSTANCE" "SELECT ROUND(SUM(data_length+index_length+data_free)/1024/1024,1) FROM information_schema.tables WHERE table_schema=DATABASE()")"
        "$(db_check)" --defaults-extra-file="$DEFAULTS" --optimize "$DB" >/dev/null 2>&1 || echo "OPTIMIZE con advertencias (InnoDB hace recreate + analyze, es normal)."
        AFTER="$(koha_sql "$INSTANCE" "SELECT ROUND(SUM(data_length+index_length+data_free)/1024/1024,1) FROM information_schema.tables WHERE table_schema=DATABASE()")"
        echo "Tamano en disco (MB): antes $BEFORE, despues $AFTER"
    fi
fi

[ "$DRY_RUN" = "1" ] && exit 0

# check_query "titulo" "SQL que cuenta" "SQL de detalle (max 50 filas)"
check_query() {
    local title="$1" count_sql="$2" detail_sql="$3" n
    n="$(koha_sql "$INSTANCE" "$count_sql")"
    echo
    echo "## $title: $n"
    if [ "$n" != "0" ]; then
        ISSUES=$((ISSUES + 1))
        koha_sql "$INSTANCE" "$detail_sql LIMIT 50" | sed 's/^/   /'
        [ "$n" -gt 50 ] && echo "   ... (mostrando 50 de $n)"
    fi
    return 0
}

echo
echo "## Conteos"
record_counts "$INSTANCE" | sed 's/^/   /'

check_query "ISBN duplicados (grupos)" \
  "SELECT COUNT(*) FROM (SELECT isbn FROM biblioitems WHERE isbn IS NOT NULL AND isbn<>'' GROUP BY isbn HAVING COUNT(*)>1) d" \
  "SELECT isbn, COUNT(*) AS n, GROUP_CONCAT(biblionumber ORDER BY biblionumber) AS biblios FROM biblioitems WHERE isbn IS NOT NULL AND isbn<>'' GROUP BY isbn HAVING COUNT(*)>1 ORDER BY n DESC"

check_query "Titulo+autor duplicados (grupos)" \
  "SELECT COUNT(*) FROM (SELECT 1 FROM biblio WHERE title IS NOT NULL AND title<>'' GROUP BY LOWER(TRIM(title)), LOWER(TRIM(COALESCE(author,''))) HAVING COUNT(*)>1) d" \
  "SELECT LEFT(title,60), LEFT(COALESCE(author,''),30), COUNT(*) AS n, GROUP_CONCAT(biblionumber ORDER BY biblionumber) FROM biblio WHERE title IS NOT NULL AND title<>'' GROUP BY LOWER(TRIM(title)), LOWER(TRIM(COALESCE(author,''))) HAVING COUNT(*)>1 ORDER BY n DESC"

check_query "Items sin biblio" \
  "SELECT COUNT(*) FROM items i LEFT JOIN biblio b ON b.biblionumber=i.biblionumber WHERE b.biblionumber IS NULL" \
  "SELECT i.itemnumber, i.biblionumber, i.barcode FROM items i LEFT JOIN biblio b ON b.biblionumber=i.biblionumber WHERE b.biblionumber IS NULL"

check_query "Biblios sin biblio_metadata (registro MARC)" \
  "SELECT COUNT(*) FROM biblio b LEFT JOIN biblio_metadata m ON m.biblionumber=b.biblionumber WHERE m.id IS NULL" \
  "SELECT b.biblionumber, LEFT(b.title,60) FROM biblio b LEFT JOIN biblio_metadata m ON m.biblionumber=b.biblionumber WHERE m.id IS NULL"

check_query "Biblios sin biblioitems" \
  "SELECT COUNT(*) FROM biblio b LEFT JOIN biblioitems bi ON bi.biblionumber=b.biblionumber WHERE bi.biblioitemnumber IS NULL" \
  "SELECT b.biblionumber, LEFT(b.title,60) FROM biblio b LEFT JOIN biblioitems bi ON bi.biblionumber=b.biblionumber WHERE bi.biblioitemnumber IS NULL"

check_query "biblio_metadata sin biblio" \
  "SELECT COUNT(*) FROM biblio_metadata m LEFT JOIN biblio b ON b.biblionumber=m.biblionumber WHERE b.biblionumber IS NULL" \
  "SELECT m.id, m.biblionumber FROM biblio_metadata m LEFT JOIN biblio b ON b.biblionumber=m.biblionumber WHERE b.biblionumber IS NULL"

check_query "biblio_metadata vacio o sin <record>" \
  "SELECT COUNT(*) FROM biblio_metadata WHERE metadata IS NULL OR metadata NOT LIKE '%<record%'" \
  "SELECT id, biblionumber FROM biblio_metadata WHERE metadata IS NULL OR metadata NOT LIKE '%<record%'"

check_query "Items con biblioitemnumber de otro biblio" \
  "SELECT COUNT(*) FROM items i JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE bi.biblionumber<>i.biblionumber" \
  "SELECT i.itemnumber, i.biblionumber, bi.biblionumber FROM items i JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE bi.biblionumber<>i.biblionumber"

check_query "Items con sucursal inexistente" \
  "SELECT COUNT(*) FROM items i LEFT JOIN branches br ON br.branchcode=i.homebranch WHERE br.branchcode IS NULL" \
  "SELECT i.itemnumber, i.homebranch FROM items i LEFT JOIN branches br ON br.branchcode=i.homebranch WHERE br.branchcode IS NULL"

check_query "Items con tipo de item inexistente" \
  "SELECT COUNT(*) FROM items i LEFT JOIN itemtypes it ON it.itemtype=i.itype WHERE i.itype IS NOT NULL AND it.itemtype IS NULL" \
  "SELECT i.itemnumber, i.itype FROM items i LEFT JOIN itemtypes it ON it.itemtype=i.itype WHERE i.itype IS NOT NULL AND it.itemtype IS NULL"

check_query "Codigos de barra duplicados" \
  "SELECT COUNT(*) FROM (SELECT barcode FROM items WHERE barcode IS NOT NULL AND barcode<>'' GROUP BY barcode HAVING COUNT(*)>1) d" \
  "SELECT barcode, COUNT(*) FROM items WHERE barcode IS NOT NULL AND barcode<>'' GROUP BY barcode HAVING COUNT(*)>1"

echo
echo "## Tablas mas grandes (MB)"
koha_sql "$INSTANCE" "SELECT table_name, ROUND((data_length+index_length)/1024/1024,2) FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY (data_length+index_length) DESC LIMIT 10" | sed 's/^/   /'

echo
echo "======================================================================"
echo "Grupos de problemas encontrados: $ISSUES"
echo "Este script NO modifica datos. Revise cada caso en la interfaz de Koha"
echo "(Herramientas > Fusion de registros, o catalogacion) antes de corregir."
echo "ISSUES=$ISSUES"
} | tee "$REPORT"

ISSUES_FOUND="$(sed -n 's/^ISSUES=//p' "$REPORT" | tail -1)"
ok "Reporte guardado en $REPORT"
if [ "$FAIL_ON_ISSUES" = "1" ] && [ "${ISSUES_FOUND:-0}" != "0" ]; then
    exit 2
fi
exit 0
