#!/bin/sh
# Solo para CI (contenedor sin systemd): el script init de Apache en Debian falla al
# reiniciar dentro de un contenedor (carrera entre stop y start). Este envoltorio
# reemplaza "service apache2 restart|reload" por apache2ctl y espera a que el proceso
# anterior termine. Todo lo demas pasa a /usr/sbin/service sin cambios.
# Se instala como /usr/local/sbin/service, que va antes en el PATH.
if [ "$1" = "apache2" ]; then
    case "$2" in
        restart|force-reload)
            apache2ctl -k stop >/dev/null 2>&1 || true
            i=0
            while pgrep -x apache2 >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
            exec apache2ctl -k start
            ;;
        reload)
            if pgrep -x apache2 >/dev/null 2>&1; then exec apache2ctl -k graceful; else exec apache2ctl -k start; fi
            ;;
        start)
            if pgrep -x apache2 >/dev/null 2>&1; then exit 0; else exec apache2ctl -k start; fi
            ;;
    esac
fi
exec /usr/sbin/service "$@"
