# Procedimiento de restauracion

Como restaurar una instancia Koha a partir de un respaldo de `scripts/10-backup.sh`.

## Contenido de un respaldo

```
/var/backups/koha-toolkit/<instancia>/<AAAAMMDD-HHMMSS>/
  db.sql.gz        volcado de la BD sin nombre de BD (mysqldump --single-transaction)
  koha-dump/       <instancia>-<fecha>.sql.gz y .tar.gz de koha-dump (formato oficial)
  files.tar.gz     /etc/koha/sites/<inst>, koha-sites.conf, passwd, apache, /var/lib/koha/<inst>
  counts.txt       conteos de registros y version de Koha al momento del respaldo
  SHA256SUMS       manifiesto de integridad
```

Siempre verificar primero:

```bash
cd /var/backups/koha-toolkit/<instancia>/<fecha>
sha256sum -c SHA256SUMS
```

## Caso A: recuperar solo la base de datos (mismo servidor)

Uso: error humano, datos borrados, actualizacion de esquema fallida.

1. Probar el respaldo sin tocar produccion:
   `sudo scripts/15-restore-test.sh <instancia> --backup <ruta-del-respaldo>`
2. Detener servicios de la instancia:
   ```bash
   sudo koha-plack --stop <instancia>
   sudo koha-indexer --stop <instancia>
   sudo koha-zebra --stop <instancia>
   ```
3. Tomar un respaldo del estado actual (aunque este danado): `sudo scripts/10-backup.sh <instancia>`.
4. Recrear la BD y cargar el volcado:
   ```bash
   DB=koha_<instancia>
   sudo mysql -e "DROP DATABASE \`$DB\`; CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
   zcat <ruta-del-respaldo>/db.sql.gz | sudo mysql "$DB"
   ```
5. Si la version del codigo instalado es mas nueva que la del respaldo: `sudo koha-upgrade-schema <instancia>`.
6. Iniciar servicios y reindexar:
   ```bash
   sudo koha-zebra --start <instancia>
   sudo koha-indexer --start <instancia>
   sudo koha-plack --start <instancia>
   sudo service memcached restart
   sudo scripts/40-reindex.sh <instancia>
   sudo scripts/60-healthcheck.sh <instancia>
   ```
7. Comparar conteos con `counts.txt` del respaldo.

## Caso B: servidor nuevo (perdida total)

1. Instalar el mismo SO (o uno compatible) y MariaDB.
2. Agregar el repositorio de Koha con la MISMA serie del respaldo (ver `koha_pkg` en `counts.txt`):
   ```bash
   curl -fsSL https://debian.koha-community.org/koha/gpg.asc | sudo gpg --dearmor -o /usr/share/keyrings/koha-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/koha-keyring.gpg] https://debian.koha-community.org/koha <serie> main" | sudo tee /etc/apt/sources.list.d/koha.list
   sudo apt-get update && sudo apt-get install koha-common
   ```
3. Configurar Apache como en la instalacion original:
   `sudo a2enmod rewrite cgi headers proxy_http && sudo a2dismod mpm_event && sudo a2enmod mpm_itk`.
4. Restaurar con la herramienta oficial a partir de los archivos de `koha-dump/`:
   ```bash
   sudo koha-restore koha-dump/<instancia>-<fecha>.sql.gz koha-dump/<instancia>-<fecha>.tar.gz
   ```
   `koha-restore` crea el usuario de sistema, la BD, el usuario de BD y los archivos de configuracion.
5. Restaurar archivos extra si hace falta (`files.tar.gz` contiene /var/lib/koha/<inst>, plugins y subidas):
   `sudo tar -xzf files.tar.gz -C / var/lib/koha/<instancia>`
6. `sudo koha-plack --enable <instancia> && sudo koha-plack --start <instancia>`, `sudo service apache2 restart`.
7. `sudo scripts/40-reindex.sh <instancia>` y `sudo scripts/60-healthcheck.sh <instancia>`.
8. Actualizar DNS y certificados SSL (Let's Encrypt: `certbot --apache`).

## Respaldo automatico diario

Ejemplo de `/etc/cron.d/koha-toolkit`:

```
# Respaldo diario a las 02:30, conserva 14, copia a disco externo; prueba de restauracion los domingos.
30 2 * * * root /opt/koha-upgrade-toolkit/scripts/10-backup.sh <instancia> --keep 14 --copy-to /mnt/respaldo >> /var/log/koha-toolkit/backup.log 2>&1
30 4 * * 0 root /opt/koha-upgrade-toolkit/scripts/15-restore-test.sh <instancia> >> /var/log/koha-toolkit/restore-test.log 2>&1
```

Revise esos logs cada semana, o envie la salida por correo (`MAILTO=` en el cron).
Un respaldo que nunca se probo no es un respaldo.
