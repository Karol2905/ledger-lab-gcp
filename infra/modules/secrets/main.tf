terraform {
  required_version = ">= 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}

# Equivale al Key Vault: guarda la cadena de conexion y la clave JWT. El acceso se concede por
# secreto y por cuenta de servicio, no a todo el almacen.
resource "google_secret_manager_secret" "this" {
  #checkov:skip=CKV_GCP_128:CMEK exige Cloud KMS, con costo mensual por clave; Google cifra igual con sus llaves
  for_each = nonsensitive(toset(keys(var.secrets)))

  project   = var.project_id
  secret_id = each.key
  labels    = var.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "this" {
  for_each = nonsensitive(toset(keys(var.secrets)))

  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = var.secrets[each.key]
}
