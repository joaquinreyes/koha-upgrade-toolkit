# Checklist de actualizacion de Koha

Lista para una actualizacion de Koha instalado con paquetes (`koha-common`) en Debian/Ubuntu.
Ejemplo: Koha 21.05 sobre Debian 11 a la ultima version estable.

## 1. Antes (dias previos)

- [ ] Acordar una ventana de mantenimiento fuera del horario de atencion. Avisar a los usuarios.
- [ ] Tener acceso root (sudo) y acceso a la consola del proveedor (por si falla SSH o la red).
- [ ] Ejecutar `sudo scripts/00-preflight.sh <instancia>` y guardar la salida.
- [ ] Anotar: version de Koha, version del SO, version de MariaDB/MySQL, conteos de registros.
- [ ] Revisar personalizaciones: CSS/JS en sysprefs (`OPACUserCSS`, `IntranetUserJS`...), plugins,
      reportes SQL guardados, plantillas de avisos, cron propios. Pueden fallar en la version nueva.
- [ ] Leer las notas de version de cada serie intermedia (https://koha-community.org/category/releases/).
- [ ] Confirmar espacio libre: al menos 3 veces el tamano de la BD en `/var`.
- [ ] Confirmar que el SO soporta la serie destino (ver tabla abajo).
- [ ] Debian 10 y 11 ya no tienen soporte: sus paquetes se movieron a `archive.debian.org`.
      Si `apt-get update` o `apt-get install` dan error 404, cambie `/etc/apt/sources.list` a
      `http://archive.debian.org/debian` y `http://archive.debian.org/debian-security`
      (la CI de este proyecto lo hace asi). `25-os-upgrade.sh --release` vuelve a `deb.debian.org` al subir de version.
- [ ] Ideal: probar todo el proceso primero en una copia del servidor (snapshot o VM).

## 2. Respaldo (el mismo dia)

- [ ] `sudo scripts/10-backup.sh <instancia> --copy-to /ruta/disco-externo` (o `--rsync usuario@host:/ruta`).
- [ ] `sudo scripts/15-restore-test.sh <instancia>` debe terminar en "Prueba de restauracion EXITOSA".
- [ ] Si el servidor es una VM: tomar tambien un snapshot de la VM.

## 3. Actualizacion

Ruta usada en la CI de este proyecto para Debian 11:

```bash
sudo scripts/20-upgrade.sh <instancia> --to 22.11          # Koha 21.05 -> 22.11 en Debian 11
sudo scripts/25-os-upgrade.sh <instancia> --release        # Debian 11 -> Debian 12
sudo scripts/20-upgrade.sh <instancia> --to stable         # Koha 22.11 -> serie estable actual
```

Si el SO ya es Debian 12 o 13, basta con un salto:

```bash
sudo scripts/20-upgrade.sh <instancia> --to stable
```

- [ ] Cada salto respalda primero, valida dependencias con `apt-get -s` y verifica conteos al final.
- [ ] Revisar los logs en `/var/log/koha-toolkit/` (lineas `ERROR` de `koha-upgrade-schema`).
- [ ] Reiniciar el servidor si el SO lo pide (`/var/run/reboot-required`).

## 4. Despues

- [ ] `sudo scripts/40-reindex.sh <instancia>`: todos los biblios deben estar indexados.
- [ ] `sudo scripts/30-db-maintenance.sh <instancia> --optimize`: revisar el reporte de duplicados.
- [ ] `sudo scripts/50-security-check.sh <instancia> --url https://<opac>`: corregir los FAIL.
- [ ] `sudo scripts/60-healthcheck.sh <instancia>`: todo en OK.
- [ ] Pruebas manuales: login de personal, busqueda en OPAC, prestamo y devolucion de prueba,
      catalogacion de un registro, un reporte guardado, envio de un aviso por correo.
- [ ] Revisar `Acerca de Koha > Informacion del sistema` en la interfaz de personal.
- [ ] Nuevo respaldo y prueba de restauracion sobre la version nueva.
- [ ] Programar respaldos diarios (ver `docs/procedimiento-restauracion.md`).

## Tabla orientativa de compatibilidad

Comprobado por la CI de este repositorio (ver el badge en el README):

| Serie Koha | Debian 11 (bullseye) | Debian 12 (bookworm) |
|---|---|---|
| 21.05 | instalada y probada en CI | no probado |
| 22.11 | actualizacion probada en CI | probado en CI (tras subir el SO) |
| stable (26.05 en oct-2026) | no probado | actualizacion probada en CI |

Para otras combinaciones, `20-upgrade.sh` hace una simulacion con `apt-get -s` y se detiene
sin cambios si las dependencias no se pueden resolver.

## Plan de vuelta atras

Si la verificacion falla y no se puede corregir en la ventana:

1. Snapshot de la VM: restaurarlo (lo mas rapido).
2. Sin snapshot: volver a la serie anterior en `/etc/apt/sources.list.d/koha.list` (hay una copia
   `.bak-<fecha>`), instalar la version anterior de `koha-common` con
   `apt-get install koha-common=<version>` y restaurar la BD del respaldo previo
   (ver `docs/procedimiento-restauracion.md`). La BD no se puede "bajar" de version: hay que restaurarla.
