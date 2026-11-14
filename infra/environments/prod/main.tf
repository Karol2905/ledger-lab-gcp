terraform {
  required_version = ">= 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }

  # El bucket y el prefijo se pasan con -backend-config; ver .github/workflows/deploy-env.yml.
  backend "gcs" {}
}

# En GitHub Actions la identidad llega por OIDC (google-github-actions/auth); en tu equipo, de gcloud.
provider "google" {
  project = var.project_id
  region  = var.region

  # La cuenta del pipeline vive en el proyecto ops; sin esto Google cobraria la cuota de las APIs
  # (Cloud SQL Admin, Secret Manager) a ops, donde no estan habilitadas.
  user_project_override = true
  billing_project       = var.project_id
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "database_region" {
  type    = string
  default = null
}

variable "image" {
  type = string
}

module "stack" {
  source = "../../modules/stack"

  environment     = "prod"
  project_id      = var.project_id
  region          = var.region
  database_region = var.database_region
  image           = var.image
  max_replicas    = 3
  jwt_minutes     = 15
}

output "app_url" {
  value = module.stack.app_url
}

output "project_id" {
  value = module.stack.project_id
}
