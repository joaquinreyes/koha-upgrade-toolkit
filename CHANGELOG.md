# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).

## [0.1.0] - 2026-10-19

### Agregado
- `00-preflight.sh`: diagnostico de SO, Koha, BD, disco, motor de busqueda.
- `10-backup.sh`: respaldo con mysqldump consistente, koha-dump, archivos, conteos y SHA256SUMS; copia externa o rsync.
- `15-restore-test.sh`: restauracion en BD temporal con comparacion de conteos y CHECK TABLE.
- `20-upgrade.sh`: actualizacion por saltos desde el repositorio de la comunidad, con validacion de dependencias y verificacion posterior.
- `25-os-upgrade.sh`: actualizaciones del SO, solo seguridad, o subida de version de Debian.
- `30-db-maintenance.sh`: mysqlcheck/optimize y reporte de duplicados y registros inconsistentes.
- `40-reindex.sh`: reindexacion completa de Zebra y control de registros no indexados.
- `50-security-check.sh`: SSL, cabeceras, permisos, actualizaciones pendientes, superlibrarians.
- `60-healthcheck.sh`: OPAC, login de personal, busqueda, procesos.
- Documentacion: plan de recuperacion, procedimiento de restauracion, checklist de actualizacion.
- CI en GitHub Actions: Koha 21.05 en Debian 11 actualizado hasta la serie estable en Debian 12.
