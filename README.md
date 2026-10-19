# koha-upgrade-toolkit

[![CI](https://github.com/joaquinreyes/koha-upgrade-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/joaquinreyes/koha-upgrade-toolkit/actions/workflows/ci.yml)
[![Licencia: GPL v3](https://img.shields.io/badge/licencia-GPLv3-blue.svg)](LICENSE)

Scripts en bash para mantener y actualizar instalaciones de **Koha ILS** hechas con paquetes
(`koha-common`) en Debian/Ubuntu: diagnostico, respaldo verificado, prueba automatica de
restauracion, actualizacion por saltos, mantenimiento de BD, reindexacion de Zebra, revision de
seguridad y chequeo de salud.

Proyecto open source desarrollado por **Plataforma Mozzo SpA** (Chile). Licencia GPL-3.0, igual que Koha.

## Que esta probado

Cada push ejecuta en GitHub Actions (contenedor `debian:bullseye`) esta ruta completa, con datos reales:

1. Instala **Koha 21.05** desde `debian.koha-community.org` sobre Debian 11 con MariaDB y Apache.
2. Crea una instancia, carga el esquema, datos de ejemplo de Koha y **50 registros MARC21 con items**.
3. `10-backup.sh` + `15-restore-test.sh` (y comprueba que un respaldo alterado se rechaza).
4. `20-upgrade.sh --to 22.11` (Koha 21.05 -> 22.11 en Debian 11).
5. `25-os-upgrade.sh --release` (Debian 11 -> Debian 12).
6. `20-upgrade.sh --to stable` (Koha 22.11 -> la serie estable vigente del repositorio).
7. `30`, `40`, `50`, `60`, y verifica que **los conteos de biblio, items, biblio_metadata y
   borrowers no cambian**, que Zebra indexa todos los registros y que la busqueda del OPAC devuelve resultados.

Ver el resultado en la pestana [Actions](https://github.com/joaquinreyes/koha-upgrade-toolkit/actions/workflows/ci.yml).
"stable" es la serie estable del repositorio al momento de cada ejecucion (26.05 en octubre de 2026).

**No probado en CI:** Ubuntu, Debian 10, Elasticsearch, MySQL (solo MariaDB), SSL real,
instalaciones desde codigo fuente (git/tarball), catalogos grandes, plugins y personalizaciones.
La CI corre sin systemd (servicios con `service`); en un servidor real los comandos son los mismos.

## Requisitos

- Debian 11/12/13 o Ubuntu con Koha instalado por paquetes (`koha-common`).
- Acceso root. Herramientas: `curl`, `gpg`, `perl`, `gzip`, `tar`, `sha256sum` (presentes en una instalacion Koha normal).
- Para `--rsync`: `rsync` y acceso SSH al destino.

## Uso rapido

```bash
git clone https://github.com/joaquinreyes/koha-upgrade-toolkit.git /opt/koha-upgrade-toolkit
cd /opt/koha-upgrade-toolkit
sudo scripts/00-preflight.sh biblioteca          # "biblioteca" = nombre de la instancia (koha-list)
```

Todos los scripts reciben el nombre de la instancia y aceptan `--help`.

| Script | Que hace | Modifica el sistema |
|---|---|---|
| `scripts/00-preflight.sh` | SO, versiones de Koha (paquete/codigo/BD), instancias, motor y version de BD, disco, Zebra/ES, conteos | No |
| `scripts/10-backup.sh` | `mysqldump --single-transaction` + `koha-dump` + config y `/var/lib/koha` + conteos + `SHA256SUMS`; `--copy-to`, `--rsync`, `--keep`, `--dry-run` | Solo escribe respaldos |
| `scripts/15-restore-test.sh` | Restaura el respaldo en una BD temporal, compara conteos y version, `CHECK TABLE`, borra la BD temporal | Solo BD temporal |
| `scripts/20-upgrade.sh` | Respaldo, fuente apt de la serie destino, `apt-get -s` de validacion, `koha-common`, `koha-upgrade-schema`, reinicio de servicios, verificacion. Saltos: `--to 22.11,stable`. `--dry-run` | Si |
| `scripts/25-os-upgrade.sh` | Actualiza paquetes del SO, `--security-only`, o `--release` (Debian 11->12->13) | Si |
| `scripts/30-db-maintenance.sh` | `mysqlcheck --check/--analyze`, `--optimize`; reporte de ISBN y titulo+autor duplicados, items sin biblio, biblios sin `biblio_metadata`, etc. **No borra nada** | Solo con `--optimize` |
| `scripts/40-reindex.sh` | `koha-rebuild-zebra -f -v` y comparacion biblios en BD vs registros en Zebra | Reindexa |
| `scripts/50-security-check.sh` | Vigencia SSL, cabeceras HTTP, `ServerTokens`, permisos de `koha-conf.xml`, actualizaciones de seguridad pendientes, usuarios superlibrarian, serie de Koha mantenida | No |
| `scripts/60-healthcheck.sh` | OPAC y login de personal (HTTP 200), busqueda en OPAC y en Zebra con resultados, plack/zebra/memcached/apache | No |

## Ejemplo: Koha 21.05 a la ultima version estable

Caso tipico: Koha 21.05 sobre Debian 11, Apache y MariaDB, unos pocos miles de registros.

```bash
sudo scripts/00-preflight.sh biblioteca
sudo scripts/10-backup.sh biblioteca --copy-to /mnt/respaldo
sudo scripts/15-restore-test.sh biblioteca
sudo scripts/20-upgrade.sh biblioteca --to 22.11      # salto intermedio soportado por Debian 11
sudo scripts/25-os-upgrade.sh biblioteca --release    # Debian 11 -> 12
sudo scripts/20-upgrade.sh biblioteca --to stable     # ultima serie estable
sudo scripts/40-reindex.sh biblioteca
sudo scripts/30-db-maintenance.sh biblioteca --optimize
sudo scripts/50-security-check.sh biblioteca --url https://catalogo.ejemplo.cl
sudo scripts/60-healthcheck.sh biblioteca
```

Por que por saltos: `koha-upgrade-schema` aplica todas las actualizaciones de esquema intermedias,
asi que Koha puede saltar varias versiones de una vez. El limite real es el SO: las series nuevas
requieren paquetes Perl de versiones de Debian nuevas. Por eso se sube Koha hasta donde lo permite
Debian 11, luego se sube el SO, y despues Koha a la serie estable. `20-upgrade.sh` simula la
instalacion con `apt-get -s` antes de tocar nada y se detiene sin cambios si falta alguna dependencia.

Lea [docs/checklist-actualizacion.md](docs/checklist-actualizacion.md) antes de actualizar un servidor real.

## Documentacion

- [docs/checklist-actualizacion.md](docs/checklist-actualizacion.md): pasos antes, durante y despues; vuelta atras.
- [docs/procedimiento-restauracion.md](docs/procedimiento-restauracion.md): restaurar la BD o el servidor completo; cron de respaldos.
- [docs/plan-recuperacion.md](docs/plan-recuperacion.md): plantilla de plan de recuperacion (RPO/RTO, escenarios, pruebas).

## Seguridad y limites

- Los scripts que modifican el sistema piden confirmacion (salvo `--yes`) y respaldan antes.
- Las claves de BD se pasan con archivos temporales `0600`, no por linea de comandos.
- Los respaldos contienen datos personales de usuarios: protejalos (`/var/backups/koha-toolkit` queda con modo `700`).
- `30-db-maintenance.sh` solo reporta. Las correcciones de datos se hacen en Koha, revisando cada caso.
- Pruebe primero en una copia del servidor. Este software se entrega sin garantia (GPL-3.0).

## Contribuir

Issues y pull requests son bienvenidos. La CI ejecuta `shellcheck` y la ruta completa de actualizacion.

---

## English summary

**koha-upgrade-toolkit** is an open-source set of bash scripts, developed by Plataforma Mozzo SpA (Chile),
to maintain and upgrade package-based Koha ILS installs (`koha-common`) on Debian/Ubuntu:
preflight report, verified backups (sha256 manifest, external copy/rsync), automated restore test into a
throwaway database, stepwise upgrades from the Koha community apt repository, Debian release upgrade,
database check/optimize with duplicate and broken-record reports (report only), full Zebra reindex with
an indexed-record count check, security checks (SSL expiry, headers, file permissions, pending security
updates, superlibrarian accounts) and health checks (OPAC/staff HTTP, search results, Plack/Zebra).

The GitHub Actions CI installs **Koha 21.05 on Debian 11** with MariaDB and 50 sample MARC21 records, then
runs backup, restore test, upgrade to **22.11**, Debian 11 -> 12 upgrade, upgrade to the repository's
current **stable** series (26.05 as of October 2026), maintenance, reindex, security and health checks,
and asserts that record counts are unchanged and that search returns results.
Not covered by CI: Ubuntu, Elasticsearch, MySQL, real SSL, source installs, large catalogs.
Documentation is in Spanish. License: GPL-3.0.
