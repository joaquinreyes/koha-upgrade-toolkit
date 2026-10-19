#!/usr/bin/env bash
# Guarda o compara conteos de registros de una instancia.
# Uso: tests/ci/assert-counts.sh save <instancia> <archivo>
#      tests/ci/assert-counts.sh compare <instancia> <archivo>
set -euo pipefail
# shellcheck source=../../scripts/lib/common.sh
. "$(dirname "$0")/../../scripts/lib/common.sh"
MODE="$1"; INST="$2"; FILE="$3"

current() {
    for t in biblio biblioitems biblio_metadata items borrowers; do
        printf '%s=%s\n' "$t" "$(koha_sql "$INST" "SELECT COUNT(*) FROM $t")"
    done
}

case "$MODE" in
    save)
        current > "$FILE"
        cat "$FILE"
        [ "$(sed -n 's/^biblio=//p' "$FILE")" -gt 0 ] || die "No hay biblios cargados."
        [ "$(sed -n 's/^items=//p' "$FILE")" -gt 0 ] || die "No hay items cargados."
        ;;
    compare)
        NOW="$(current)"
        echo "Base:   $(tr '\n' ' ' < "$FILE")"
        echo "Actual: $(echo "$NOW" | tr '\n' ' ')"
        [ "$NOW" = "$(cat "$FILE")" ] || die "Los conteos cambiaron."
        ok "Conteos identicos a la linea base."
        ;;
    *) die "Modo desconocido: $MODE" ;;
esac
