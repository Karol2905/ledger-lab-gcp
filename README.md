# Ledger en Google Cloud: laboratorio de aplicación transaccional

Versión GCP del Laboratorio 8 (PEMU 2026). La aplicación, sus pruebas, los pipelines y los controles
son los mismos que en la guía de Azure; cambia la plataforma.

| En la guía de Azure | En esta versión |
|---|---|
| Grupo de recursos por ambiente | Proyecto por ambiente: `ledger-dev-<id>` y `ledger-prod-<id>` |
| Container Apps | Cloud Run (escala a cero, facturación por solicitud) |
| Azure SQL con oferta gratuita | Cloud SQL para PostgreSQL `db-f1-micro` |
| Key Vault con RBAC | Secret Manager con IAM por secreto |
| GHCR | GHCR, servido a Cloud Run por un repositorio remoto de Artifact Registry |
| Estado en Blob Storage | Estado en Cloud Storage, un prefijo por ambiente |
| Identidad administrada + OIDC | Workload Identity Federation + cuenta de servicio sin claves |
| Contributor + RBAC Administrator con condición | Roles por servicio + `projectIamAdmin` con condición |
| Azure Retail Prices API | Cloud Billing Catalog API |

| Carpeta | Contenido |
|---|---|
| `app/` | API FastAPI, interfaz web, pruebas y Dockerfile |
| `infra/bootstrap/` | Proyectos, estado remoto, proxy de imágenes e identidad para GitHub Actions |
| `infra/modules/` | Módulos `database`, `secrets`, `cloud_run` y `stack` |
| `infra/environments/` | Raíces de `dev` y `prod` |
| `.github/workflows/` | Pipelines: `ci`, `publish-image`, `deploy`, `deploy-env` y `destroy` |
| `cost/` | Estimador de costos con la API de precios de Google |
| `scripts/` | Consulta de regiones y pruebas contra un ambiente desplegado |
| `docs/` | Riesgos aceptados |
