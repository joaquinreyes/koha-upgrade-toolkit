#!/usr/bin/env bash
# 15-restore-test.sh - Prueba automatica de restauracion de un respaldo.
#
# Uso: sudo scripts/15-restore-test.sh <instancia> [opciones]
#   --backup DIR    Respaldo a probar (defecto: el ultimo de 10-backup.sh, ver LATEST)
#   --dest DIR      Raiz de respaldos (defecto: /var/backups/koha-toolkit)
#   --keep-db       No borra la BD temporal al terminar (para inspeccion manual)
#
# Pasos:
#   1. Verifica SHA256SUMS y la integridad de gzip/tar.
#   2. Crea una BD temporal "koha_restoretest_<fecha>" en el mismo servidor.
#   3. Carga db.sql.gz en esa BD (el volcado no contiene CREATE DATABASE/USE).
#   4. Compara conteos (biblio, items, borrowers, ...) y version con counts.txt.
#   5. Ejecuta CHECK TABLE sobre tablas clave.
#   6. Borra la BD temporal. La BD de produccion no se toca.
# Sale con codigo 1 si algun control falla.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; BACKUP=""; DEST="$BACKUP_ROOT"; KEEP_DB=0
while [ $# -gt 0 ]; do
    case "$1" in
        --backup) BACKUP="$2"; shift 2 ;;
        --dest) DEST="$2"; shift 2 ;;
        --keep-db) KEEP_DB=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
validate_instance_name "$INSTANCE"
require_root
require_cmd sha256sum gzip tar "$(db_client)"

if [ -z "$BACKUP" ]; then
    [ -f "$DEST/$INSTANCE/LATEST" ] || die "No hay respaldo registrado en $DEST/$INSTANCE/LATEST. Use --backup."
    BACKUP="$(cat "$DEST/$INSTANCE/LATEST")"
fi
[ -d "$BACKUP" ] || die "No existe el respaldo $BACKUP"
for f in db.sql.gz counts.txt SHA256SUMS files.tar.gz; do
    [ -f "$BACKUP/$f" ] || die "Falta $f en $BACKUP"
done

FAILS=0
check_fail() { fail "$*"; FAILS=$((FAILS + 1)); }

log "Probando respaldo: $BACKUP"

# 1) Integridad de archivos.
if ( cd "$BACKUP" && sha256sum --quiet -c SHA256SUMS ); then ok "SHA256SUMS correcto."; else check_fail "SHA256SUMS no coincide."; fi
if gzip -t "$BACKUP/db.sql.gz"; then ok "db.sql.gz es un gzip valido."; else check_fail "db.sql.gz corrupto."; fi
if tar -tzf "$BACKUP/files.tar.gz" >/dev/null; then ok "files.tar.gz es un tar valido."; else check_fail "files.tar.gz corrupto."; fi
# (grep -c lee todo: evita SIGPIPE con pipefail)
if [ "$(tar -tzf "$BACKUP/files.tar.gz" | grep -c "etc/koha/sites/.*/koha-conf.xml" || true)" != "0" ]; then
    ok "files.tar.gz contiene koha-conf.xml."
else
    check_fail "files.tar.gz no contiene koha-conf.xml."
fi
[ "$FAILS" -eq 0 ] || die "El respaldo no pasa los controles de integridad."

# Proteccion: el volcado no debe cambiar de base de datos.
if [ "$(zcat "$BACKUP/db.sql.gz" | grep -Eic '^(USE |CREATE DATABASE)' || true)" != "0" ]; then
    die "db.sql.gz contiene USE/CREATE DATABASE; no es seguro restaurarlo en una BD temporal."
fi

# 2) BD temporal.
TESTDB="koha_restoretest_$(date +%Y%m%d%H%M%S)"
PROD_DB="$(sed -n 's/^db_name=//p' "$BACKUP/counts.txt")"
[ "$TESTDB" != "$PROD_DB" ] || die "Nombre de BD temporal igual a produccion (no deberia ocurrir)."

drop_testdb() {
    if [ "$KEEP_DB" = "1" ]; then
        warn "Se conserva la BD temporal $TESTDB (--keep-db). Borrela con: DROP DATABASE \`$TESTDB\`;"
    else
        db_admin -e "DROP DATABASE IF EXISTS \`$TESTDB\`" && log "BD temporal $TESTDB eliminada."
    fi
    cleanup_tmpfiles
}
trap drop_testdb EXIT

log "Creando BD temporal $TESTDB ..."
db_admin -e "CREATE DATABASE \`$TESTDB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"

# 3) Carga.
START=$(date +%s)
log "Restaurando db.sql.gz en $TESTDB ..."
zcat "$BACKUP/db.sql.gz" | db_admin "$TESTDB"
ok "Restauracion completada en $(( $(date +%s) - START )) s."

q() { db_admin -N -B -e "$1" "$TESTDB"; }

# 4) Conteos.
printf '%-20s %12s %12s\n' "tabla" "respaldo" "restaurado"
while IFS='=' read -r key expected; do
    case "$key" in
        biblio|biblioitems|biblio_metadata|items|borrowers|authorised_values)
            got="$(q "SELECT COUNT(*) FROM $key")"
            printf '%-20s %12s %12s\n' "$key" "$expected" "$got"
            [ "$got" = "$expected" ] || check_fail "Conteo distinto en $key: esperado $expected, obtenido $got"
            ;;
    esac
done < "$BACKUP/counts.txt"

EXP_VER="$(sed -n 's/^koha_db_version=//p' "$BACKUP/counts.txt")"
GOT_VER="$(q "SELECT value FROM systempreferences WHERE variable='Version'")"
if [ "$EXP_VER" = "$GOT_VER" ]; then ok "Version de BD restaurada: $GOT_VER"; else check_fail "Version distinta: $EXP_VER vs $GOT_VER"; fi

# Cada biblio debe tener su registro MARC.
ORPHANS="$(q "SELECT COUNT(*) FROM biblio b LEFT JOIN biblio_metadata m ON m.biblionumber=b.biblionumber WHERE m.id IS NULL")"
if [ "$ORPHANS" = "0" ]; then ok "Todos los biblios tienen biblio_metadata."; else warn "$ORPHANS biblios sin biblio_metadata (tambien estaban en el origen; ver 30-db-maintenance.sh)."; fi

# 5) CHECK TABLE.
for t in biblio biblioitems biblio_metadata items borrowers issues reserves; do
    res="$(q "CHECK TABLE \`$t\`" 2>/dev/null | awk -F'\t' '$3=="status"{print $4}' | tail -1 || true)"
    [ -z "$res" ] && continue
    if [ "$res" = "OK" ]; then ok "CHECK TABLE $t: OK"; else check_fail "CHECK TABLE $t: $res"; fi
done

echo "--------------------------------------------------"
if [ "$FAILS" -gt 0 ]; then
    fail "Prueba de restauracion FALLIDA ($FAILS error(es))."
    exit 1
fi
ok "Prueba de restauracion EXITOSA: $BACKUP"
