#!/usr/bin/env bash
# 60-healthcheck.sh - Chequeo de salud de una instancia Koha.
#
# Uso: sudo scripts/60-healthcheck.sh <instancia> [opciones]
#   --opac-url URL    URL del OPAC (defecto: ServerName de Apache, consultado en 127.0.0.1)
#   --staff-url URL   URL de la interfaz de personal (idem)
#   --search TERM     Termino de busqueda (defecto: una palabra del titulo del primer biblio)
#   --no-local        No forzar la conexion a 127.0.0.1 (usar DNS real)
#
# Revisa: BD, OPAC (HTTP 200), login de personal (HTTP 200), busqueda en OPAC con
# resultados, busqueda directa en Zebra, procesos plack/zebra/memcached y tiempos.
# Sale con codigo 1 si algun control falla.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INSTANCE=""; OPAC_URL=""; STAFF_URL=""; TERM_Q=""; LOCAL=1
while [ $# -gt 0 ]; do
    case "$1" in
        --opac-url) OPAC_URL="$2"; shift 2 ;;
        --staff-url) STAFF_URL="$2"; shift 2 ;;
        --search) TERM_Q="$2"; shift 2 ;;
        --no-local) LOCAL=0; shift ;;
        -h|--help) usage 0 ;;
        -*) die "Opcion desconocida: $1" ;;
        *) INSTANCE="$1"; shift ;;
    esac
done
[ -n "$INSTANCE" ] || usage 1
require_root
require_instance "$INSTANCE"
require_cmd curl

NFAIL=0
F() { fail "$*"; NFAIL=$((NFAIL + 1)); }
USER_K="$(instance_user "$INSTANCE")"

# URL (http://host:puerto) de un VirtualHost de Apache: tipo opac|intranet.
apache_url() {
    local kind="$1" conf="/etc/apache2/sites-available/$INSTANCE.conf"
    [ -f "$conf" ] || return 0
    KIND="$kind" perl -0777 -ne '
        while (m{<VirtualHost\s+[^:>]*:(\d+)>(.*?)</VirtualHost>}sg) {
            my ($port, $b) = ($1, $2);
            next unless $b =~ /apache-shared-\Q$ENV{KIND}\E/;
            my ($name) = $b =~ /^\s*ServerName\s+(\S+)/m or next;
            my $scheme = ($b =~ /SSLEngine\s+on/i) ? "https" : "http";
            print "$scheme://$name:$port";
            last;
        }' "$conf"
}
[ -n "$OPAC_URL" ] || OPAC_URL="$(apache_url opac)"
[ -n "$STAFF_URL" ] || STAFF_URL="$(apache_url intranet)"

# curl con resolucion local opcional.
xcurl() {
    local url="$1"; shift
    local opts=(-sk --max-time 60)
    if [ "$LOCAL" = "1" ]; then
        local hp host port
        hp="$(echo "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
        host="${hp%%:*}"; port="${hp##*:}"
        if [ "$port" = "$hp" ]; then
            if [[ "$url" == https* ]]; then port=443; else port=80; fi
        fi
        opts+=(--resolve "$host:$port:127.0.0.1")
    fi
    curl "${opts[@]}" "$@" "$url"
}

echo "== Healthcheck $INSTANCE - $(date '+%F %T') =="

# --- BD ---
if V="$(koha_db_version "$INSTANCE")" && [ -n "$V" ]; then
    ok "BD responde (Version $V, Koha paquete $(koha_pkg_version))"
else
    F "No hay conexion a la BD"
fi

# --- Procesos ---
if pgrep -u "$USER_K" -f zebrasrv >/dev/null 2>&1; then ok "zebrasrv en ejecucion"; else F "zebrasrv NO esta en ejecucion"; fi
if koha-list --plack 2>/dev/null | grep -qx "$INSTANCE"; then
    if pgrep -u "$USER_K" -f 'starman' >/dev/null 2>&1; then ok "Plack (starman) en ejecucion"; else F "Plack habilitado pero starman NO esta en ejecucion"; fi
else
    warn "Plack no habilitado para $INSTANCE (recomendado: koha-plack --enable $INSTANCE && koha-plack --start $INSTANCE)"
fi
if pgrep -x memcached >/dev/null 2>&1; then ok "memcached en ejecucion"; else warn "memcached no esta en ejecucion"; fi
if pgrep -x apache2 >/dev/null 2>&1 || pgrep -f /usr/sbin/apache2 >/dev/null 2>&1; then ok "apache2 en ejecucion"; else F "apache2 NO esta en ejecucion"; fi

# --- HTTP ---
http_check() {
    local label="$1" url="$2" code t
    [ -n "$url" ] || { F "$label: no se pudo determinar la URL (use --opac-url/--staff-url)"; return 0; }
    read -r code t < <(xcurl "$url" -o /dev/null -w '%{http_code} %{time_total}\n' || echo "000 0") || true
    if [ "$code" = "200" ]; then ok "$label $url -> HTTP $code (${t}s)"; else F "$label $url -> HTTP $code"; fi
}
http_check "OPAC" "${OPAC_URL%/}/"
http_check "Personal (login)" "${STAFF_URL%/}/cgi-bin/koha/mainpage.pl"

if [ -n "$STAFF_URL" ]; then
    if [ "$(xcurl "${STAFF_URL%/}/cgi-bin/koha/mainpage.pl" | grep -ci 'name="password"\|id="password"\|loginform' || true)" != "0" ]; then
        ok "La pagina de login de personal muestra el formulario"
    else
        F "La pagina de personal no muestra el formulario de login"
    fi
fi

# --- Busqueda ---
if [ -z "$TERM_Q" ]; then
    TERM_Q="$(koha_sql "$INSTANCE" "SELECT title FROM biblio WHERE title IS NOT NULL AND title<>'' ORDER BY biblionumber LIMIT 1" | tr -c 'A-Za-z0-9\n' ' ' | tr ' ' '\n' | awk 'length($0)>3' | head -1 || true)"
fi
if [ -z "$TERM_Q" ]; then
    warn "Catalogo vacio: no se prueba la busqueda."
else
    ZOUT="$(koha_perl "$INSTANCE" "$TOOLKIT_LIB_DIR/zebra_count.pl" "$TERM_Q" 2>&1 || true)"
    ZHITS="$(echo "$ZOUT" | sed -n 's/^hits=//p')"
    if [ -n "$ZHITS" ] && [ "$ZHITS" -gt 0 ]; then ok "Zebra: '$TERM_Q' -> $ZHITS resultados"; else F "Zebra: '$TERM_Q' sin resultados ($ZOUT)"; fi

    if [ -n "$OPAC_URL" ]; then
        ENC="$(printf '%s' "$TERM_Q" | sed 's/ /+/g')"
        BODY_FILE="$(make_tmp)"
        EFFECTIVE="$(xcurl "${OPAC_URL%/}/cgi-bin/koha/opac-search.pl?q=$ENC" -L -o "$BODY_FILE" -w '%{url_effective}' || true)"
        NLINKS="$(grep -o 'opac-detail.pl?biblionumber=[0-9]*' "$BODY_FILE" | sort -u | wc -l | tr -d ' ')"
        if [[ "$EFFECTIVE" == *opac-detail.pl* ]] || [ "$NLINKS" -gt 0 ]; then
            ok "OPAC: busqueda '$TERM_Q' devuelve resultados ($NLINKS registros enlazados)"
        else
            F "OPAC: busqueda '$TERM_Q' sin resultados"
        fi
    fi
fi

echo "--------------------------------------------------"
if [ "$NFAIL" -gt 0 ]; then fail "Healthcheck con $NFAIL fallo(s)."; exit 1; fi
ok "Healthcheck OK"
