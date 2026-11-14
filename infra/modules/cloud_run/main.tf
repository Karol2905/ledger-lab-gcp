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

# Cuenta de servicio propia de la app: existe, y tiene permisos, antes de crear el servicio.
# Con la cuenta por defecto de Compute la app tendria rol Editor sobre todo el proyecto.
resource "google_service_account" "app" {
  project      = var.project_id
  account_id   = "run-${var.name}"
  display_name = "Ledger ${var.name} (Cloud Run)"
}

# Solo puede leer sus dos secretos, uno por uno.
resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = var.secret_ids

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.app.member
}

# Permite abrir el tunel del conector de Cloud SQL. El pipeline solo puede conceder este rol.
resource "google_project_iam_member" "sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.app.member
}

# IAM tarda en propagarse; sin esta espera la primera revision falla al leer los secretos.
resource "time_sleep" "iam_propagation" {
  depends_on      = [google_secret_manager_secret_iam_member.reader, google_project_iam_member.sql_client]
  create_duration = var.iam_propagation_wait
}

resource "google_logging_project_bucket_config" "this" {
  count = var.logs_enabled ? 1 : 0

  project        = var.project_id
  location       = var.region
  bucket_id      = "ledger-${var.name}"
  retention_days = 30
  description    = "Registros de la app con retencion propia, el equivalente a Log Analytics."
}

resource "google_logging_project_sink" "this" {
  count = var.logs_enabled ? 1 : 0

  project     = var.project_id
  name        = "ledger-${var.name}"
  destination = "logging.googleapis.com/${google_logging_project_bucket_config.this[0].id}"
  filter      = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.name}\""
}

resource "google_cloud_run_v2_service" "this" {
  name                 = var.name
  project              = var.project_id
  location             = var.region
  ingress              = "INGRESS_TRAFFIC_ALL"
  deletion_protection  = false
  invoker_iam_disabled = true # API publica: la autenticacion la hace la app con JWT.
  labels               = var.labels
  depends_on           = [time_sleep.iam_propagation]

  template {
    service_account                  = google_service_account.app.email
    max_instance_request_concurrency = 20
    timeout                          = "120s"
    labels                           = var.labels

    scaling {
      min_instance_count = 0 # Escala a cero: sin trafico no se cobra computo.
      max_instance_count = var.max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [var.sql_connection_name]
      }
    }

    containers {
      name  = "ledger"
      image = var.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true # Facturacion por solicitud: la CPU solo se cobra mientras atiende.
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = var.environment_variables
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = var.secret_ids["database-url"]
            version = "latest"
          }
        }
      }

      env {
        name = "JWT_SECRET"
        value_source {
          secret_key_ref {
            secret  = var.secret_ids["jwt-secret"]
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # Tolera el arranque en frio y la primera conexion a Cloud SQL.
      startup_probe {
        period_seconds    = 10
        failure_threshold = 12
        http_get {
          path = "/healthz"
        }
      }

      liveness_probe {
        http_get {
          path = "/healthz"
        }
      }
    }
  }
}
