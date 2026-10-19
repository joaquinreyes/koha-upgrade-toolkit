#!/usr/bin/env bash
# 10-backup.sh - Respaldo completo y verificable de una instancia Koha.
#
# Uso: sudo scripts/10-backup.sh <instancia> [opciones]
#   --dest DIR          Directorio raiz de respaldos (defecto: /var/backups/koha-toolkit)
#   --copy-to DIR       Copia el respaldo a otra ruta (disco externo, NFS) y verifica sha256
#   --rsync DESTINO     Envia el respaldo con rsync (ej. usuario@host:/respaldos/koha)
#   --exclude-indexes   No incluye los indices Zebra (se regeneran con 40-reindex.sh)
#   --keep N            Conserva solo los N respaldos mas recientes en --dest (defecto: no borra)
#   --dry-run           Muestra lo que haria sin hacerlo
#
# Genera en DEST/<instancia>/<fecha>/:
#   db.sql.gz        mysqldump --single-transaction SIN nombre de BD (seguro para restaurar en otra BD)
#   koha-dump/       salida estandar de koha-dump (BD + configuracion), compatible con koha-restore
#   files.tar.gz     /etc/koha/sites/<inst>, koha-sites.conf, passwd, apache y /var/lib/koha/<inst>
#   counts.txt       conteos de registros y version (para la prueba de restauracion)
#   SHA256SUMS       manifiesto de integridad
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; DEST="$BACKUP_ROOT"; COPY_TO=""; RSYNC_TARGET=""; EXCLUDE_INDEXES=0; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        --copy-to) COPY_TO="$2"; shift 2 ;;
        --rsync) RSYNC_TARGET="$2"; shift 2 ;;
        --exclude-indexes) EXCLUDE_INDEXES=1; shift ;;
        --keep) KEEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
require_root
require_instance "$INSTANCE"
require_cmd koha-dump gzip tar sha256sum "$(db_dump)"
[[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep debe ser un numero"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/$INSTANCE/$STAMP"
DB="$(instance_db_name "$INSTANCE")"

log "Respaldo de '$INSTANCE' en $OUT"
if [ "$DRY_RUN" = "1" ]; then
    run koha-dump "$INSTANCE"
    run "$(db_dump)" --single-transaction --routines --triggers --events "$DB" "| gzip > $OUT/db.sql.gz"
    run tar -czf "$OUT/files.tar.gz" "/etc/koha/sites/$INSTANCE" "/var/lib/koha/$INSTANCE"
    [ -n "$COPY_TO" ] && run cp -a "$OUT" "$COPY_TO/"
    [ -n "$RSYNC_TARGET" ] && run rsync -a "$OUT" "$RSYNC_TARGET/"
    exit 0
fi

umask 077
mkdir -p "$OUT/koha-dump"

# 1) Volcado propio, consistente y sin "CREATE DATABASE/USE".
log "Volcando base de datos $DB (single-transaction)..."
DEFAULTS="$(instance_db_defaults "$INSTANCE")"
"$(db_dump)" --defaults-extra-file="$DEFAULTS" --single-transaction --quick \
    --routines --triggers --events --hex-blob "$DB" | gzip -6 > "$OUT/db.sql.gz"
gzip -t "$OUT/db.sql.gz"
zcat "$OUT/db.sql.gz" | tail -n 1 | grep -q 'Dump completed' || die "El volcado de la BD parece incompleto."
ok "db.sql.gz ($(du -h "$OUT/db.sql.gz" | cut -f1))"

# 2) koha-dump estandar (para usar con koha-restore si se reconstruye el servidor).
log "Ejecutando koha-dump..."
SPOOL="$(koha_conf_value "$INSTANCE" backupdir)"; SPOOL="${SPOOL:-/var/spool/koha/$INSTANCE}"
KD_OPTS=(--quiet)
[ "$EXCLUDE_INDEXES" = "1" ] && KD_OPTS+=(--exclude-indexes)
koha-dump "${KD_OPTS[@]}" "$INSTANCE"
newest() { find "$SPOOL" -maxdepth 1 -type f -name "$1" ! -name '*schema*' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-; }
KD_SQL="$(newest "$INSTANCE-*.sql.gz")"
KD_TAR="$(newest "$INSTANCE-*.tar.gz")"
[ -n "$KD_SQL" ] && [ -n "$KD_TAR" ] || die "No se encontraron los archivos de koha-dump en $SPOOL"
cp -p "$KD_SQL" "$KD_TAR" "$OUT/koha-dump/"
ok "koha-dump: $(basename "$KD_SQL"), $(basename "$KD_TAR")"

# 3) Archivos de configuracion y datos.
log "Empaquetando configuracion y archivos..."
PATHS=("etc/koha/sites/$INSTANCE" "var/lib/koha/$INSTANCE")
for p in etc/koha/koha-sites.conf etc/koha/passwd "etc/apache2/sites-available/$INSTANCE.conf" \
         etc/mysql/koha-common.cnf etc/apt/sources.list.d/koha.list "var/log/koha/$INSTANCE"; do
    [ -e "/$p" ] && PATHS+=("$p")
done
TAR_EXCL=()
if [ "$EXCLUDE_INDEXES" = "1" ]; then
    TAR_EXCL=(--exclude="var/lib/koha/$INSTANCE/biblios" --exclude="var/lib/koha/$INSTANCE/authorities")
fi
tar -czf "$OUT/files.tar.gz" -C / "${TAR_EXCL[@]}" "${PATHS[@]}"
tar -tzf "$OUT/files.tar.gz" >/dev/null
ok "files.tar.gz ($(du -h "$OUT/files.tar.gz" | cut -f1))"

# 4) Conteos y metadatos para la verificacion.
{
    echo "instance=$INSTANCE"
    echo "date=$STAMP"
    echo "host=$(hostname)"
    echo "koha_pkg=$(koha_pkg_version)"
    echo "koha_db_version=$(koha_db_version "$INSTANCE")"
    echo "db_name=$DB"
    record_counts "$INSTANCE"
} > "$OUT/counts.txt"

# 5) Manifiesto sha256.
MANIFEST_TMP="$(make_tmp)"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) > "$MANIFEST_TMP"
cp "$MANIFEST_TMP" "$OUT/SHA256SUMS"
( cd "$OUT" && sha256sum --quiet -c SHA256SUMS ) || die "Fallo la verificacion sha256 local."
ok "Manifiesto SHA256SUMS verificado."

# 6) Copias externas.
if [ -n "$COPY_TO" ]; then
    log "Copiando a $COPY_TO ..."
    mkdir -p "$COPY_TO/$INSTANCE"
    cp -a "$OUT" "$COPY_TO/$INSTANCE/"
    ( cd "$COPY_TO/$INSTANCE/$STAMP" && sha256sum --quiet -c SHA256SUMS ) || die "La copia en $COPY_TO no coincide con el manifiesto."
    ok "Copia externa verificada: $COPY_TO/$INSTANCE/$STAMP"
fi
if [ -n "$RSYNC_TARGET" ]; then
    require_cmd rsync
    log "Enviando con rsync a $RSYNC_TARGET ..."
    rsync -a --checksum "$OUT" "$RSYNC_TARGET/"
    ok "rsync completado (verifique en destino con: sha256sum -c SHA256SUMS)."
fi

# 7) Retencion.
if [ "$KEEP" -gt 0 ]; then
    mapfile -t OLD < <(find "$DEST/$INSTANCE" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r | tail -n +"$((KEEP + 1))")
    for d in "${OLD[@]}"; do
        log "Retencion: eliminando respaldo antiguo $d"
        rm -rf -- "$d"
    done
fi

echo "$OUT" > "$DEST/$INSTANCE/LATEST"
ok "Respaldo completo: $OUT"
