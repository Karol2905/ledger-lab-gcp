# Seguridad y excepciones de Checkov

Checkov termina sin fallos porque 50 controles pasan y 18 se omiten explícitamente (los módulos se
evalúan por cada uso, así que un mismo control puede contar más de una vez). **Eso no significa que
esta configuración esté lista para producción real.** Cada omisión es un riesgo aceptado para no
consumir crédito, y su razón está junto al recurso, en un comentario `#checkov:skip`.

## Lo que sí está protegido

- Solo HTTPS en Cloud Run. Cloud SQL exige TLS con certificado de cliente
  (`TRUSTED_CLIENT_CERTIFICATE_REQUIRED`) y no tiene redes autorizadas: solo entra el conector.
- Secretos en Secret Manager; la cuenta de la app solo puede leer sus dos secretos.
- La app corre con su propia cuenta de servicio, no con la cuenta por defecto de Compute (Editor).
- Estado de Terraform en un bucket con acceso uniforme, prevención de acceso público y versionado.
- GitHub entra sin claves: Workload Identity Federation, limitado por ID de repositorio y ambiente.
- El pipeline no puede asignarse roles: `projectIamAdmin` solo con la condición `roles/cloudsql.client`.
- Contraseñas con scrypt y sal por usuario. JWT con algoritmo fijo y expiración obligatoria.
- Imagen fijada por digest y ejecutada con un usuario sin privilegios.
- Montos enteros, restricción `CHECK` de saldo y claves de idempotencia únicas.

## Riesgos aceptados

| Riesgo | Controles | Para producción real |
|---|---|---|
| Cloud SQL con IP pública (sin redes autorizadas) | `CKV_GCP_60` | VPC, IP privada y Cloud Run con salida directa a la VPC |
| dev sin respaldos ni recuperación a un punto | `CKV_GCP_14`, `CKV2_GCP_20` | Respaldos en todo ambiente con datos reales |
| Sin pgaudit ni registro de sentencias | `CKV_GCP_109`, `CKV_GCP_110`, `CKV_GCP_111` | pgaudit hacia un bucket de logs con retención |
| Llaves administradas por Google | `CKV_GCP_128`, `CKV_GCP_84` | CMEK con Cloud KMS si la norma lo exige |
| Sin registros de acceso a datos ni del bucket del estado | `CKV2_GCP_5`, `CKV_GCP_62` | Data Access audit logs y registros del bucket |
| La condición de WIF no usa `sub` | `CKV_GCP_125` | Se acepta: los ID numéricos son más estrictos que el nombre |
| Versión mayor de PostgreSQL fija | `CKV_GCP_79` | Actualizar con una ventana de mantenimiento planificada |

## Otros límites de la aplicación

- La app entra a la base con usuario y contraseña (guardada en Secret Manager). La alternativa sin
  contraseña es la autenticación IAM de Cloud SQL con la cuenta de servicio de la app.
- No hay límite de intentos de login ni de registros: agrégalo antes de exponer la app a usuarios reales.
- El bono de bienvenida crea dinero al registrarse: es solo una ayuda para la demostración.
- La cuenta del pipeline tiene `iam.serviceAccountAdmin` y `secretmanager.admin` en dev y prod: puede
  crear cuentas y leer cualquier secreto de esos proyectos.

## Ejecutar el análisis

```bash
uvx --python 3.12 checkov --config-file .checkov.yaml
```
