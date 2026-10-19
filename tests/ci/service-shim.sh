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
# El script init de memcached tambien falla al reiniciar dentro del contenedor.
if [ "$1" = "memcached" ] && [ "$2" = "restart" ]; then
    /usr/sbin/service memcached stop >/dev/null 2>&1 || true
    pkill -x memcached 2>/dev/null || true
    sleep 1
    exec /usr/sbin/service memcached start
fi
# RabbitMQ: tras subir Debian, el script init nuevo no puede detener el nodo Erlang
# viejo. Se detiene a la fuerza y se inicia de nuevo; si no inicia se avisa (Koha
# funciona sin RabbitMQ: las tareas en segundo plano usan la BD).
if [ "$1" = "rabbitmq-server" ] && [ "$2" = "restart" ]; then
    /usr/sbin/service rabbitmq-server stop >/dev/null 2>&1 || true
    pkill -f beam.smp 2>/dev/null || true
    pkill -x epmd 2>/dev/null || true
    sleep 3
    if /usr/sbin/service rabbitmq-server start; then exit 0; fi
    echo "AVISO (CI): rabbitmq-server no inicio en el contenedor" >&2
    exit 0
fi
exec /usr/sbin/service "$@"
