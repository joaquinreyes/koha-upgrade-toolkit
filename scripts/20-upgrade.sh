#!/usr/bin/env bash
# 20-upgrade.sh - Actualizacion segura de Koha (instalacion por paquetes koha-common).
#
# Uso: sudo scripts/20-upgrade.sh <instancia> --to SERIE[,SERIE...] [opciones]
#   --to SERIES       Serie(s) destino del repositorio de la comunidad, en orden.
#                     Ej.: --to 26.05   |   --to 22.11,stable   |   --to oldstable
#   --skip-backup     No ejecuta 10-backup.sh antes (NO recomendado)
#   --backup-dest DIR Raiz de respaldos (defecto: /var/backups/koha-toolkit)
#   --repo URL        Repositorio apt (defecto: https://debian.koha-community.org/koha)
#   --yes             No pide confirmacion
#   --dry-run         Muestra lo que haria sin hacerlo
#
# Para cada serie (salto) hace:
#   1. Respaldo verificado de TODAS las instancias (10-backup.sh) + conteos.
#   2. Escribe /etc/apt/sources.list.d/koha.list con la serie destino (guarda copia del anterior).
#   3. apt-get update + apt-get install koha-common (mantiene los archivos de config locales).
#      Si apt no puede resolver dependencias, restaura koha.list y se detiene sin cambios.
#   4. koha-upgrade-schema para todas las instancias.
#   5. Reinicia plack, zebra, indexer, worker, memcached y recarga Apache.
#   6. Verifica: version BD == version codigo y conteos iguales a los del respaldo.
#
# Koha actualiza el esquema de forma acumulativa (updatedatabase.pl incluye todos
# los pasos intermedios), por lo que un salto directo es posible. Se usan saltos
# intermedios cuando el SO actual no soporta la serie destino (ej. Debian 11 ->
# Koha 22.11, luego subir el SO con 25-os-upgrade.sh, y luego Koha stable).
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; TARGETS=""; SKIP_BACKUP=0; YES=0; BACKUP_DEST="$BACKUP_ROOT"
while [ $# -gt 0 ]; do
    case "$1" in
        --to) TARGETS="$2"; shift 2 ;;
        --skip-backup) SKIP_BACKUP=1; shift ;;
        --backup-dest) BACKUP_DEST="$2"; shift 2 ;;
        --repo) KOHA_REPO_URL="$2"; shift 2 ;;
        --yes|-y) YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] && [ -n "$TARGETS" ] || usage 1
require_root
require_instance "$INSTANCE"
require_cmd apt-get dpkg-query curl koha-upgrade-schema koha-list

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KOHA_LIST_FILE=/etc/apt/sources.list.d/koha.list
LOG_DIR=/var/log/koha-toolkit
mkdir -p "$LOG_DIR"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Serie real (ej. 26.05) de un nombre de suite (stable, oldstable, 26.05...).
resolve_series() {
    local suite="$1" codename
    codename="$(curl -fsSL --max-time 30 "$KOHA_REPO_URL/dists/$suite/Release" 2>/dev/null | sed -n 's/^Codename: *//p' | head -1)"
    [ -n "$codename" ] || return 1
    # Para suites numericas el Codename es la misma serie.
    printf '%s' "$codename"
}

# Compara series "AA.MM": devuelve 0 si $1 < $2.
series_lt() {
    local a b
    a="$(echo "$1" | awk -F. '{printf "%d%02d", $1, $2}')"
    b="$(echo "$2" | awk -F. '{printf "%d%02d", $1, $2}')"
    [ "$a" -lt "$b" ]
}

ensure_keyring() {
    if [ -s "$KOHA_KEYRING" ]; then return 0; fi
    require_cmd gpg
    log "Instalando llave del repositorio Koha en $KOHA_KEYRING"
    run sh -c "curl -fsSL '$KOHA_REPO_URL/gpg.asc' | gpg --dearmor > '$KOHA_KEYRING'"
}

restart_services() {
    local inst
    for inst in $(koha-list); do
        if koha-list --plack 2>/dev/null | grep -qx "$inst"; then
            run koha-plack --restart "$inst" || warn "koha-plack --restart $inst fallo"
        fi
        run koha-zebra --restart "$inst" 2>/dev/null || run koha-zebra --start "$inst" || warn "zebra $inst no inicio"
        if command -v koha-indexer >/dev/null 2>&1; then
            run koha-indexer --restart "$inst" 2>/dev/null || run koha-indexer --start "$inst" || warn "koha-indexer $inst no inicio"
        fi
        if command -v koha-worker >/dev/null 2>&1; then
            run koha-worker --restart "$inst" 2>/dev/null || run koha-worker --start "$inst" || warn "koha-worker $inst no inicio"
        fi
    done
    if command -v memcached >/dev/null 2>&1; then
        run service memcached restart || warn "No se pudo reiniciar memcached (cache de Koha)."
    fi
    run service apache2 reload || run apache2ctl graceful || warn "No se pudo recargar Apache."
}

compare_counts() {
    local inst="$1" counts_file="$2" bad=0 key expected got
    while IFS='=' read -r key expected; do
        case "$key" in
            biblio|biblioitems|biblio_metadata|items|borrowers)
                got="$(koha_sql "$inst" "SELECT COUNT(*) FROM $key")"
                if [ "$got" = "$expected" ]; then
                    ok "$inst: $key = $got (sin cambios)"
                else
                    fail "$inst: $key cambio de $expected a $got"
                    bad=1
                fi
                ;;
        esac
    done < "$counts_file"
    return "$bad"
}

upgrade_hop() {
    local suite="$1" target cur_series prev_list stamp backup_dirs=() inst counts
    target="$(resolve_series "$suite")" || die "La serie '$suite' no existe en $KOHA_REPO_URL"
    cur_series="$(version_series "$(koha_code_version)")"
    stamp="$(date +%Y%m%d-%H%M%S)"

    echo "=================================================="
    log "Salto de Koha $cur_series -> $target (suite '$suite') en $(os_codename)"
    echo "=================================================="
    if [ "$cur_series" = "$target" ]; then
        ok "Ya esta en la serie $target. Se aplicaran solo actualizaciones menores."
    elif series_lt "$target" "$cur_series"; then
        die "La serie destino $target es anterior a la instalada $cur_series. Este script no hace downgrade."
    fi

    if [ "$YES" != "1" ] && [ "$DRY_RUN" != "1" ]; then
        read -r -p "Continuar con la actualizacion a $target? Escriba 'si': " answer
        [ "$answer" = "si" ] || die "Cancelado por el usuario."
    fi

    # 1) Respaldo de todas las instancias.
    if [ "$SKIP_BACKUP" = "1" ]; then
        warn "Respaldo omitido por --skip-backup."
    else
        for inst in $(koha-list); do
            if [ "$DRY_RUN" = "1" ]; then
                run "$SCRIPT_DIR/10-backup.sh" "$inst" --dest "$BACKUP_DEST"
            else
                "$SCRIPT_DIR/10-backup.sh" "$inst" --dest "$BACKUP_DEST"
                backup_dirs+=("$(cat "$BACKUP_DEST/$inst/LATEST")")
            fi
        done
    fi

    # 2) Fuente apt.
    ensure_keyring
    prev_list=""
    if [ -f "$KOHA_LIST_FILE" ]; then
        prev_list="$KOHA_LIST_FILE.bak-$stamp"
        run cp -p "$KOHA_LIST_FILE" "$prev_list"
    fi
    local others
    others="$(grep -rls 'koha-community.org' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v -e "^$KOHA_LIST_FILE" -e '\.bak-' || true)"
    if [ -n "$others" ]; then
        fail "Otras fuentes apt de Koha: $others"
        die "Hay otras fuentes apt de Koha fuera de $KOHA_LIST_FILE. Dejelas en un solo archivo antes de seguir."
    fi
    log "Escribiendo $KOHA_LIST_FILE -> serie $suite"
    if [ "$DRY_RUN" = "1" ]; then
        run "echo 'deb [signed-by=$KOHA_KEYRING] $KOHA_REPO_URL $suite main' > $KOHA_LIST_FILE"
    else
        echo "deb [signed-by=$KOHA_KEYRING] $KOHA_REPO_URL $suite main" > "$KOHA_LIST_FILE"
    fi

    # 3) Paquetes.
    run apt-get update -q
    if [ "$DRY_RUN" = "1" ]; then
        run apt-get install "${APT_OPTS[@]}" koha-common
        return 0
    fi
    log "Simulando instalacion (apt-get -s) para validar dependencias..."
    if ! apt-get -s install koha-common > "$LOG_DIR/apt-sim-$stamp.log" 2>&1; then
        fail "apt no puede instalar koha-common $target en $(os_codename). Ver $LOG_DIR/apt-sim-$stamp.log"
        tail -n 20 "$LOG_DIR/apt-sim-$stamp.log" >&2 || true
        if [ -n "$prev_list" ]; then cp -p "$prev_list" "$KOHA_LIST_FILE"; else rm -f "$KOHA_LIST_FILE"; fi
        apt-get update -q || true
        die "Sin cambios en Koha. Probablemente esta serie requiere una version de SO mas nueva (ver 25-os-upgrade.sh)."
    fi
    log "Instalando koha-common de la serie $target (log: $LOG_DIR/apt-$stamp.log)..."
    apt-get install "${APT_OPTS[@]}" koha-common 2>&1 | tee "$LOG_DIR/apt-$stamp.log"
    ok "koha-common instalado: $(koha_pkg_version)"

    # 4) Esquema.
    for inst in $(koha-list); do
        log "koha-upgrade-schema $inst (log: $LOG_DIR/schema-$inst-$stamp.log)"
        koha-upgrade-schema "$inst" 2>&1 | tee "$LOG_DIR/schema-$inst-$stamp.log"
        if grep -Eq '(^|[^A-Za-z])ERROR' "$LOG_DIR/schema-$inst-$stamp.log"; then
            warn "koha-upgrade-schema reporto lineas ERROR para $inst. Reviselas:"
            grep -E '(^|[^A-Za-z])ERROR' "$LOG_DIR/schema-$inst-$stamp.log" | head -20 >&2 || true
        fi
    done

    # 5) Servicios.
    restart_services

    # 6) Verificaciones.
    local code_db bad=0
    code_db="$(code_version_to_db "$(koha_code_version)")"
    for inst in $(koha-list); do
        if [ "$(koha_db_version "$inst")" = "$code_db" ]; then
            ok "$inst: version de BD $code_db coincide con el codigo."
        else
            fail "$inst: version de BD $(koha_db_version "$inst") distinta del codigo $code_db"
            bad=1
        fi
    done
    for counts in "${backup_dirs[@]}"; do
        inst="$(sed -n 's/^instance=//p' "$counts/counts.txt")"
        compare_counts "$inst" "$counts/counts.txt" || bad=1
    done
    [ "$bad" = "0" ] || die "Verificacion posterior al salto a $target FALLIDA. Respaldos: ${backup_dirs[*]:-ninguno}"
    ok "Salto a Koha $target completado: $(koha_pkg_version)"
}

IFS=',' read -r -a HOPS <<< "$TARGETS"
for hop in "${HOPS[@]}"; do
    upgrade_hop "$hop"
done
ok "Actualizacion terminada. Ejecute 40-reindex.sh y 60-healthcheck.sh."
