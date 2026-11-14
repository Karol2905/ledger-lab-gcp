# Se ejecuta una sola vez desde tu equipo, con tu cuenta de gcloud. Crea lo que GitHub Actions
# necesita antes de poder desplegar: los proyectos, el estado remoto de dev y prod, el proxy de
# imagenes y una cuenta de servicio sin claves a la que GitHub entra con OIDC (Workload Identity
# Federation). Su propio estado queda local.

terraform {
  required_version = ">= 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "google" {
  region = var.region
}

variable "region" {
  description = "Region de todos los recursos."
  type        = string
}

variable "billing_account" {
  description = "Cuenta de facturacion a la que se vinculan los tres proyectos (XXXXXX-XXXXXX-XXXXXX)."
  type        = string
}

variable "github_repository" {
  description = "Repositorio que puede desplegar, como usuario/repositorio."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Usa el formato usuario/repositorio."
  }
}

variable "github_repository_ids" {
  description = <<-EOT
    Repositorio con sus ID numericos, como usuario@123/repositorio@456. Obtengalo con:
    gh api repos/usuario/repositorio --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
  EOT
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", var.github_repository_ids))
    error_message = "Usa el formato usuario@123/repositorio@456."
  }
}

locals {
  owner_id = regex("@([0-9]+)/", var.github_repository_ids)[0]
  repo_id  = regex("/[^@]+@([0-9]+)$", var.github_repository_ids)[0]
  owner    = lower(split("/", var.github_repository)[0])
  labels   = { project = "eci-ledger-lab", managed_by = "terraform" }

  # En Azure cada ambiente es un grupo de recursos; en GCP, un proyecto. El sufijo es el ID del
  # repositorio, que es unico, asi que los nombres no chocan con los de otra persona.
  projects = {
    ops  = "ledger-ops-${local.repo_id}"
    dev  = "ledger-dev-${local.repo_id}"
    prod = "ledger-prod-${local.repo_id}"
  }
  environments = ["dev", "prod"]

  ops_apis = [
    "artifactregistry.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
  env_apis = [
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
  ]

  # Lo que el pipeline necesita en cada ambiente: crear el servicio, la base, los secretos y la
  # cuenta de la app. Ninguno de estos roles permite cambiar la politica IAM del proyecto.
  pipeline_env_roles = [
    "roles/cloudsql.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/logging.configWriter",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

# ---------------------------------------------------------------------------------------------
# Proyectos
# ---------------------------------------------------------------------------------------------

resource "google_project" "this" {
  #checkov:skip=CKV2_GCP_5:Los registros de acceso a datos de todos los servicios se cobran; quedan los de administracion
  for_each = local.projects

  project_id      = each.value
  name            = each.value
  billing_account = var.billing_account
  labels          = merge(local.labels, { environment = each.key })
  deletion_policy = "DELETE" # Laboratorio: destroy debe poder borrar los proyectos.
  # La red "default" crea reglas de firewall abiertas que este laboratorio no usa.
  auto_create_network = false
}

resource "google_project_service" "ops" {
  for_each = toset(local.ops_apis)

  project            = google_project.this["ops"].project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service" "env" {
  for_each = { for pair in setproduct(local.environments, local.env_apis) : "${pair[0]}/${pair[1]}" => pair }

  project            = google_project.this[each.value[0]].project_id
  service            = each.value[1]
  disable_on_destroy = false
}

# Las APIs recien habilitadas, y sus agentes de servicio, tardan en propagarse.
resource "time_sleep" "apis" {
  depends_on      = [google_project_service.ops, google_project_service.env]
  create_duration = "60s"
}

# ---------------------------------------------------------------------------------------------
# Estado remoto: un bucket con un prefijo por ambiente
# ---------------------------------------------------------------------------------------------

resource "google_storage_bucket" "state" {
  #checkov:skip=CKV_GCP_62:Los registros de acceso del bucket se cobran; el acceso ya exige IAM
  name                        = "tfstate-ledger-${local.repo_id}"
  project                     = google_project.this["ops"].project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = false      # Solo IAM: sin ACL por objeto.
  public_access_prevention    = "enforced" # El estado contiene secretos.
  force_destroy               = true
  labels                      = local.labels

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 dias
  }

  depends_on = [time_sleep.apis]
}

# ---------------------------------------------------------------------------------------------
# Imagenes: Artifact Registry como proxy de GitHub Container Registry
# ---------------------------------------------------------------------------------------------

# Cloud Run solo descarga imagenes de Artifact Registry o Docker Hub. Un repositorio remoto
# hace de proxy de ghcr.io: la imagen sigue publicandose solo con GITHUB_TOKEN y conserva su digest.
resource "google_artifact_registry_repository" "ghcr" {
  #checkov:skip=CKV_GCP_84:CMEK exige Cloud KMS, con costo mensual; la imagen ademas es publica en GHCR
  project       = google_project.this["ops"].project_id
  location      = var.region
  repository_id = "ghcr"
  description   = "Proxy de solo lectura de ghcr.io"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  labels        = local.labels

  remote_repository_config {
    description = "GitHub Container Registry"
    docker_repository {
      custom_repository {
        uri = "https://ghcr.io"
      }
    }
  }

  # Borra las copias que nadie descarga en 30 dias: el almacenamiento se cobra tras 0,5 GB.
  cleanup_policies {
    id     = "borrar-antiguas"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }

  depends_on = [time_sleep.apis]
}

# El agente de Cloud Run de cada ambiente descarga la imagen; solo puede leer este repositorio.
resource "google_artifact_registry_repository_iam_member" "run_agents" {
  for_each = toset(local.environments)

  project    = google_project.this["ops"].project_id
  location   = google_artifact_registry_repository.ghcr.location
  repository = google_artifact_registry_repository.ghcr.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:service-${google_project.this[each.key].number}@serverless-robot-prod.iam.gserviceaccount.com"
  depends_on = [time_sleep.apis]
}

# Al crear el servicio, Cloud Run tambien comprueba que quien despliega pueda leer la imagen.
resource "google_artifact_registry_repository_iam_member" "pipeline_reader" {
  project    = google_project.this["ops"].project_id
  location   = google_artifact_registry_repository.ghcr.location
  repository = google_artifact_registry_repository.ghcr.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.github.member
}

# ---------------------------------------------------------------------------------------------
# Identidad de GitHub Actions: Workload Identity Federation, sin claves que guardar
# ---------------------------------------------------------------------------------------------

resource "google_service_account" "github" {
  project      = google_project.this["ops"].project_id
  account_id   = "sa-ledger-github"
  display_name = "GitHub Actions de ${var.github_repository}"
  depends_on   = [time_sleep.apis]
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.this["ops"].project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  depends_on                = [time_sleep.apis]
}

# Google solo acepta tokens de este repositorio (por sus ID numericos, que no cambian aunque se
# renombre) y de jobs que declaren el GitHub Environment dev o prod.
resource "google_iam_workload_identity_pool_provider" "github" {
  #checkov:skip=CKV_GCP_125:La condicion usa los ID numericos del dueno y del repositorio, que no cambian ni se reutilizan, en vez del nombre dentro de sub
  project                            = google_project.this["ops"].project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.environment"         = "assertion.environment"
  }

  attribute_condition = join(" && ", [
    "assertion.repository_owner_id == '${local.owner_id}'",
    "assertion.repository_id == '${local.repo_id}'",
    "assertion.environment in ['dev', 'prod']",
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Solo los jobs de los ambientes dev y prod pueden actuar como la cuenta del pipeline.
resource "google_service_account_iam_member" "github_wif" {
  for_each = toset(local.environments)

  service_account_id = google_service_account.github.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/${each.key}"
}

# ---------------------------------------------------------------------------------------------
# Permisos del pipeline
# ---------------------------------------------------------------------------------------------

resource "google_project_iam_member" "pipeline_env" {
  for_each = { for pair in setproduct(local.environments, local.pipeline_env_roles) : "${pair[0]}/${pair[1]}" => pair }

  project    = google_project.this[each.value[0]].project_id
  role       = each.value[1]
  member     = google_service_account.github.member
  depends_on = [time_sleep.apis]
}

# Los roles anteriores no pueden asignar roles. Este lo permite, limitado por la condicion a
# roles/cloudsql.client: el pipeline no puede darse Owner ni Editor a si mismo.
resource "google_project_iam_member" "pipeline_iam_admin" {
  for_each = toset(local.environments)

  project = google_project.this[each.key].project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = google_service_account.github.member

  condition {
    title       = "solo-cloudsql-client"
    description = "Solo puede conceder o quitar roles/cloudsql.client."
    expression  = "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/cloudsql.client'])"
  }
  depends_on = [time_sleep.apis]
}

# Lee y escribe el estado de los dos ambientes.
resource "google_storage_bucket_iam_member" "pipeline_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.github.member
}

# Cuota del proyecto ops para consultar la API de precios desde el control de costos.
resource "google_project_iam_member" "pipeline_ops_usage" {
  project    = google_project.this["ops"].project_id
  role       = "roles/serviceusage.serviceUsageConsumer"
  member     = google_service_account.github.member
  depends_on = [time_sleep.apis]
}

# ---------------------------------------------------------------------------------------------
# Salidas: se copian como variables de GitHub. Ninguna es un secreto.
# ---------------------------------------------------------------------------------------------

output "gcp_wif_provider" {
  description = "Proveedor de Workload Identity. No es un secreto."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "gcp_service_account" {
  description = "Cuenta de servicio del pipeline. No es un secreto."
  value       = google_service_account.github.email
}

output "gcp_region" {
  value = var.region
}

output "gcp_ops_project" {
  value = google_project.this["ops"].project_id
}

output "gcp_dev_project" {
  value = google_project.this["dev"].project_id
}

output "gcp_prod_project" {
  value = google_project.this["prod"].project_id
}

output "tf_state_bucket" {
  value = google_storage_bucket.state.name
}

output "image_registry" {
  description = "Prefijo de las imagenes que descarga Cloud Run."
  value       = "${var.region}-docker.pkg.dev/${google_project.this["ops"].project_id}/${google_artifact_registry_repository.ghcr.repository_id}/${local.owner}"
}
