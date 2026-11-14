terraform {
  required_version = ">= 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

locals {
  name = "ledger-${var.environment}"
  labels = {
    project     = "eci-ledger-lab"
    environment = var.environment
    managed_by  = "terraform"
  }
  # Solo prod guarda respaldos y logs propios: dev debe poder borrarse sin residuos.
  is_prod = var.environment == "prod"
}

# Cloud SQL no deja reutilizar el nombre de una instancia hasta una semana despues de borrarla.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

module "database" {
  source = "../database"

  project_id      = var.project_id
  instance_name   = "sql-${local.name}-${random_string.suffix.result}"
  region          = coalesce(var.database_region, var.region)
  backups_enabled = local.is_prod
  labels          = local.labels
}

module "secrets" {
  source = "../secrets"

  project_id = var.project_id
  region     = var.region
  labels     = local.labels

  secrets = {
    "database-url" = module.database.database_url
    "jwt-secret"   = random_password.jwt.result
  }
}

module "app" {
  source = "../cloud_run"

  project_id           = var.project_id
  name                 = local.name
  region               = var.region
  image                = var.image
  sql_connection_name  = module.database.connection_name
  secret_ids           = module.secrets.secret_ids
  max_instances        = var.max_replicas
  logs_enabled         = local.is_prod
  iam_propagation_wait = var.iam_propagation_wait
  labels               = local.labels
  depends_on           = [module.secrets]

  environment_variables = {
    APP_ENV     = var.environment
    JWT_MINUTES = tostring(var.jwt_minutes)
  }
}
