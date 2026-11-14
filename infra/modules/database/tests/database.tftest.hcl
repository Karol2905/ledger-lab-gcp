mock_provider "google" {
  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name = "proyecto:us-central1:sql-prueba"
    }
  }
}

mock_provider "random" {}

variables {
  project_id    = "proyecto"
  instance_name = "sql-prueba"
  region        = "us-central1"
}

run "por_defecto_es_la_instancia_mas_pequena" {
  command = apply

  assert {
    condition     = google_sql_database_instance.this.settings[0].tier == "db-f1-micro"
    error_message = "Por defecto debe usarse db-f1-micro."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].availability_type == "ZONAL"
    error_message = "La alta disponibilidad duplica el costo."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ssl_mode == "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
    error_message = "La base debe exigir TLS con certificado de cliente."
  }
  assert {
    condition     = length(google_sql_database_instance.this.settings[0].ip_configuration[0].authorized_networks) == 0
    error_message = "No debe haber redes autorizadas: solo se entra por el conector."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].enabled == false
    error_message = "dev no guarda respaldos."
  }
  assert {
    condition     = strcontains(nonsensitive(output.database_url), "host=/cloudsql/proyecto:us-central1:sql-prueba")
    error_message = "La app debe conectarse por el socket del conector."
  }
}

run "prod_activa_respaldos" {
  command = apply

  variables {
    backups_enabled = true
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].point_in_time_recovery_enabled
    error_message = "Con respaldos tambien debe activarse PITR."
  }
}

run "el_tier_se_valida" {
  command = plan

  variables {
    tier = "db-custom-4-16384"
  }

  expect_failures = [var.tier]
}
