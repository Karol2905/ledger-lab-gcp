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
  }
}

resource "random_password" "app" {
  length  = 32
  special = false
}

# Cloud SQL no tiene una oferta gratuita como Azure SQL: se usa la instancia compartida mas pequena
# y se cobra cada hora que exista. Por eso el laboratorio la destruye al terminar.
resource "google_sql_database_instance" "this" {
  #checkov:skip=CKV_GCP_60:Sin VPC de pago no hay IP privada; no hay redes autorizadas y se entra solo por el conector de Cloud SQL
  #checkov:skip=CKV_GCP_14:dev no guarda respaldos para no pagar almacenamiento; prod si los activa (var.backups_enabled)
  #checkov:skip=CKV2_GCP_20:PITR exige respaldos; se activa junto con ellos en prod
  #checkov:skip=CKV_GCP_79:Se fija la version mayor para que un plan no cambie de motor sin revisarlo
  #checkov:skip=CKV_GCP_110:pgaudit genera mucho volumen de logs; la auditoria fina queda como extension
  #checkov:skip=CKV_GCP_109:Depende de pgaudit
  #checkov:skip=CKV_GCP_111:Registrar cada sentencia expondria datos y llenaria los logs
  name                = var.instance_name
  project             = var.project_id
  region              = var.region
  database_version    = "POSTGRES_17"
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL" # La alta disponibilidad duplica el costo de computo.
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = false
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled = true
      # Sin redes autorizadas y con certificado de cliente obligatorio: solo entra el conector de
      # Cloud SQL que usa Cloud Run, que negocia TLS mutuo y exige roles/cloudsql.client.
      ssl_mode = "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
    }

    backup_configuration {
      enabled                        = var.backups_enabled
      point_in_time_recovery_enabled = var.backups_enabled
      backup_retention_settings {
        retained_backups = 7
      }
    }

    # Registro de conexiones y bloqueos: no tiene costo propio y ayuda a auditar.
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_duration"
      value = "on"
    }
    database_flags {
      name  = "log_hostname"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_min_messages"
      value = "error"
    }
    database_flags {
      name  = "log_min_error_statement"
      value = "error"
    }
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "-1"
    }
    database_flags {
      name  = "log_statement"
      value = "ddl"
    }
  }
}

resource "google_sql_database" "this" {
  name     = var.database_name
  project  = var.project_id
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "app" {
  name     = var.user_name
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  password = random_password.app.result
  # En PostgreSQL el usuario es dueno de las tablas y Cloud SQL se niega a borrarlo ("role cannot be
  # dropped because some objects depend on it"). Al destruir se abandona: desaparece con la instancia.
  deletion_policy = "ABANDON"
}
