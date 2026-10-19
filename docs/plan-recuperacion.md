# Plan de recuperacion ante desastres (plantilla)

Plantilla para una instancia Koha. Complete los campos entre `< >` con los datos reales.

## 1. Objetivos

| Indicador | Objetivo sugerido | Como se cumple |
|---|---|---|
| RPO (datos que se pueden perder) | 24 horas | Respaldo diario `10-backup.sh` |
| RTO (tiempo para volver a operar) | 4 horas | Procedimiento B de `procedimiento-restauracion.md` |
| Verificacion | Semanal | `15-restore-test.sh` automatico |

## 2. Inventario

| Elemento | Valor |
|---|---|
| Servidor / proveedor | `<host, IP, proveedor>` |
| SO | `<Debian 12>` |
| Koha | `<serie y version, ver 00-preflight.sh>` |
| BD | `<MariaDB 10.11>`, BD `koha_<instancia>` |
| URL OPAC / personal | `<https://...>` / `<https://...>` |
| Certificado SSL | `<Let's Encrypt / proveedor>`, vence `<fecha>` |
| Ubicacion de respaldos | `/var/backups/koha-toolkit` + `<disco externo / servidor remoto>` |
| Responsable tecnico | `<nombre, telefono>` |
| Responsable de la biblioteca | `<nombre, telefono>` |

## 3. Regla 3-2-1 de respaldos

- 3 copias: produccion, respaldo local, respaldo externo.
- 2 medios distintos: disco del servidor y disco externo / almacenamiento remoto.
- 1 copia fuera del edificio o del proveedor (`--rsync` a otro servidor o nube).
- Los respaldos tienen datos personales de usuarios: guardarlos cifrados o en destinos con acceso restringido.

## 4. Escenarios

| Escenario | Accion | Referencia |
|---|---|---|
| Datos borrados por error | Restaurar BD (caso A) o recuperar registros puntuales desde una BD temporal (`15-restore-test.sh --keep-db`) | procedimiento-restauracion.md |
| Actualizacion fallida | Snapshot de VM o caso A con el respaldo previo al salto | checklist-actualizacion.md |
| Disco o servidor perdido | Caso B en servidor nuevo | procedimiento-restauracion.md |
| Indice de busqueda danado | `40-reindex.sh` (no requiere restaurar) | README |
| Certificado SSL vencido | Renovar (`certbot renew`), `50-security-check.sh` lo detecta antes | README |
| Compromiso de seguridad | Aislar servidor, cambiar claves (BD, superlibrarian), restaurar en servidor limpio (caso B), revisar logs | este documento |

## 5. Contactos y escalamiento

1. Personal de biblioteca detecta el problema y avisa a `<responsable tecnico>`.
2. El responsable tecnico evalua con `60-healthcheck.sh` y decide el escenario.
3. Se informa a la biblioteca el tiempo estimado de recuperacion.
4. Al terminar: informe breve con causa, impacto, tiempo y mejoras.

## 6. Pruebas del plan

- Semanal: `15-restore-test.sh` automatico (cron). Revisar el log.
- Semestral: simulacro del caso B en una VM temporal, midiendo el tiempo real (comparar con el RTO).
- Despues de cada actualizacion mayor: respaldo nuevo + prueba de restauracion.

## 7. Registro de pruebas

| Fecha | Tipo de prueba | Resultado | Tiempo | Responsable |
|---|---|---|---|---|
| `<AAAA-MM-DD>` | `<restore-test / simulacro>` | `<OK / falla>` | `<min>` | `<nombre>` |
