#!/usr/bin/env bash
# Funciones comunes para koha-upgrade-toolkit.
# Este archivo se carga con "source" desde los scripts; no se ejecuta solo.
# shellcheck shell=bash

TOOLKIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd "$TOOLKIT_LIB_DIR/../.." && pwd)"
export TOOLKIT_LIB_DIR TOOLKIT_DIR

DRY_RUN="${DRY_RUN:-0}"
KOHA_LIB="${KOHA_LIB:-/usr/share/koha/lib}"
KOHA_REPO_URL="${KOHA_REPO_URL:-https://debian.koha-community.org/koha}"
KOHA_KEYRING="${KOHA_KEYRING:-/usr/share/keyrings/koha-keyring.gpg}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/koha-toolkit}"

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_OFF=""
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(date '+%F %T')" "$C_OFF" "$*"; }
ok()   { printf '%s[OK]%s    %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s  %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '%s[FAIL]%s  %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { fail "$*"; exit 1; }

# Ejecuta un comando, o solo lo muestra si DRY_RUN=1.
run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Este script debe ejecutarse como root (sudo)."
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Falta el comando requerido: $c"
    done
}

# Nombre de instancia: solo letras, numeros, guion y guion bajo.
validate_instance_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]] || die "Nombre de instancia invalido: '${1:-}'"
}

require_instance() {
    local inst="$1"
    validate_instance_name "$inst"
    [ -f "/etc/koha/sites/$inst/koha-conf.xml" ] || die "La instancia '$inst' no existe (/etc/koha/sites/$inst/koha-conf.xml)."
}

koha_conf() { printf '/etc/koha/sites/%s/koha-conf.xml' "$1"; }

# Lee un valor del bloque <config> de koha-conf.xml (database, hostname, port, user, pass...).
koha_conf_value() {
    local inst="$1" key="$2"
    KEY="$key" perl -0777 -ne '
        my $k = $ENV{KEY};
        # El bloque principal es <config> solo en su linea (hay otros <config>x</config> en serverinfo).
        if (m{^\s*<config>\s*$(.*?)^\s*</config>}ms) {
            my $c = $1;
            if ($c =~ m{<\Q$k\E>\s*(.*?)\s*</\Q$k\E>}s) {
                my $v = $1;
                $v =~ s/&lt;/</g; $v =~ s/&gt;/>/g; $v =~ s/&quot;/"/g; $v =~ s/&apos;/\x27/g; $v =~ s/&amp;/&/g;
                print $v;
            }
        }' "$(koha_conf "$inst")" 2>/dev/null || true
}

# Binarios cliente de MariaDB/MySQL (MariaDB >= 10.5 trae nombres mariadb-*).
db_client()  { if command -v mariadb >/dev/null 2>&1; then echo mariadb; else echo mysql; fi; }
db_dump()    { if command -v mariadb-dump >/dev/null 2>&1; then echo mariadb-dump; else echo mysqldump; fi; }
db_check()   { if command -v mariadb-check >/dev/null 2>&1; then echo mariadb-check; else echo mysqlcheck; fi; }

# Crea un archivo de opciones temporal (0600) con las credenciales de la instancia.
# Evita poner la clave en la linea de comandos (visible en ps).
# Todos los temporales van a un directorio propio que se borra al salir.
# (make_tmp se llama dentro de $(...), por eso no se usa un arreglo.)
TOOLKIT_TMPDIR="$(mktemp -d /tmp/koha-toolkit.XXXXXX)"
chmod 711 "$TOOLKIT_TMPDIR"
cleanup_tmpfiles() { rm -rf -- "$TOOLKIT_TMPDIR"; }
trap cleanup_tmpfiles EXIT

# make_tmp [-d]: crea un archivo (o directorio con -d) temporal.
make_tmp() {
    if [ "${1:-}" = "-d" ]; then
        mktemp -d "$TOOLKIT_TMPDIR/d.XXXXXX"
    else
        mktemp "$TOOLKIT_TMPDIR/f.XXXXXX"
    fi
}

instance_db_defaults() {
    local inst="$1" f host port user pass
    host="$(koha_conf_value "$inst" hostname)"
    port="$(koha_conf_value "$inst" port)"
    user="$(koha_conf_value "$inst" user)"
    pass="$(koha_conf_value "$inst" pass)"
    [ -n "$user" ] || die "No se pudo leer el usuario de BD desde $(koha_conf "$inst")"
    f="$(make_tmp)"
    chmod 600 "$f"
    {
        echo "[client]"
        echo "host=${host:-localhost}"
        [ -n "$port" ] && echo "port=$port"
        echo "user=$user"
        # Entre comillas para admitir caracteres como # o espacios.
        pass="${pass//\\/\\\\}"; pass="${pass//\"/\\\"}"
        echo "password=\"$pass\""
    } > "$f"
    printf '%s' "$f"
}

instance_db_name() { koha_conf_value "$1" database; }

# Ejecuta SQL en la BD de la instancia. Salida sin cabeceras, separada por tabs.
koha_sql() {
    local inst="$1" sql="$2" defaults db
    defaults="$(instance_db_defaults "$inst")" || return 1
    db="$(instance_db_name "$inst")"
    [ -n "$db" ] || { fail "No se pudo leer el nombre de la BD de $inst"; return 1; }
    "$(db_client)" --defaults-extra-file="$defaults" -N -B -e "$sql" "$db"
}

# Opciones para conectarse como administrador de BD (para crear BD temporales).
# Se puede forzar con DB_ADMIN_DEFAULTS=/ruta/archivo.cnf
db_admin() {
    if [ -n "${DB_ADMIN_DEFAULTS:-}" ]; then
        "$(db_client)" --defaults-extra-file="$DB_ADMIN_DEFAULTS" "$@"
    elif [ -r /etc/mysql/koha-common.cnf ] && [ -e /etc/mysql/koha-common.cnf ]; then
        "$(db_client)" --defaults-extra-file=/etc/mysql/koha-common.cnf "$@"
    else
        # root con autenticacion unix_socket (por defecto en Debian).
        "$(db_client)" "$@"
    fi
}

# Version de Koha instalada por paquete (ej. 21.05.21-1).
koha_pkg_version() { dpkg-query -W -f='${Version}' koha-common 2>/dev/null || true; }

# Version de Koha del codigo instalado (ej. 26.05.04.000).
koha_code_version() {
    sed -n 's/.*VERSION *= *"\([0-9.]*\)".*/\1/p' "$KOHA_LIB/Koha.pm" 2>/dev/null | head -1
}

# Version guardada en la BD (syspref Version, ej. 26.0504000).
koha_db_version() { koha_sql "$1" "SELECT value FROM systempreferences WHERE variable='Version'" 2>/dev/null || true; }

# 26.05.04.000 -> 26.0504000 (formato de la syspref Version).
code_version_to_db() {
    local v="$1" major rest
    major="${v%%.*}"
    rest="${v#*.}"
    printf '%s.%s' "$major" "${rest//./}"
}

# Serie (ej. 21.05) a partir de una version.
version_series() { echo "$1" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p'; }

# Lee un campo de /etc/os-release sin ejecutar el archivo.
os_release() { sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | tr -d '"' | head -1; }
os_codename() { local c; c="$(os_release VERSION_CODENAME)"; echo "${c:-unknown}"; }

# Conteos clave de una instancia, formato clave=valor.
record_counts() {
    local inst="$1" t
    local n
    for t in biblio biblioitems biblio_metadata items borrowers authorised_values; do
        n="$(koha_sql "$inst" "SELECT COUNT(*) FROM $t")" || return 1
        printf '%s=%s\n' "$t" "$n"
    done
}

# Ejecuta un script perl como el usuario de la instancia (koha-shell).
# Copia el script a un directorio temporal legible por la instancia.
koha_perl() {
    local inst="$1" script="$2"; shift 2
    local d args="" a
    d="$(make_tmp -d)"
    chmod 755 "$d"
    cp "$script" "$d/"
    chmod 644 "$d/$(basename "$script")"
    for a in "$@"; do args="$args $(printf '%q' "$a")"; done
    koha-shell -c "perl $d/$(basename "$script")$args" "$inst"
}

instance_user() { printf '%s-koha' "$1"; }
