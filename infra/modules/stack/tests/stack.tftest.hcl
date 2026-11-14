# Pruebas sin nube: mock_provider no necesita credenciales, cuentas de servicio ni emulador.

mock_provider "google" {
  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name = "proyecto:us-central1:sql"
    }
  }
  mock_resource "google_service_account" {
    defaults = {
      email  = "run-ledger@proyecto.iam.gserviceaccount.com"
      member = "serviceAccount:run-ledger@proyecto.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_cloud_run_v2_service" {
    defaults = {
      uri = "https://ledger-abc123-uc.a.run.app"
    }
  }
}

mock_provider "random" {}
mock_provider "time" {}

variables {
  project_id           = "ledger-dev-123"
  region               = "us-central1"
  image                = "us-central1-docker.pkg.dev/ops/ghcr/eci/ledger@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  iam_propagation_wait = "1s"
}

run "dev_es_desechable_y_sin_logs" {
  command = apply

  variables {
    environment = "dev"
  }

  assert {
    condition     = module.app.url != "" && startswith(output.app_url, "https://")
    error_message = "La URL publica debe ser HTTPS."
  }
  assert {
    condition     = local.labels["environment"] == "dev"
    error_message = "Las etiquetas deben identificar el ambiente."
  }
  assert {
    condition     = local.is_prod == false
    error_message = "dev no debe activar la configuracion de prod."
  }
  assert {
    condition     = output.service_name == "ledger-dev"
    error_message = "El servicio debe incluir el ambiente."
  }
}

run "prod_se_protege" {
  command = apply

  variables {
    environment  = "prod"
    project_id   = "ledger-prod-123"
    max_replicas = 3
  }

  assert {
    condition     = local.is_prod
    error_message = "prod debe activar respaldos y logs."
  }
  assert {
    condition     = output.project_id == "ledger-prod-123"
    error_message = "prod debe ir en su propio proyecto."
  }
}

run "la_base_puede_ir_en_otra_region" {
  command = apply

  variables {
    environment     = "dev"
    database_region = "us-east1"
  }

  assert {
    condition     = module.database.region == "us-east1"
    error_message = "La base debe crearse en database_region."
  }
}

run "la_imagen_debe_ir_por_digest" {
  command = plan

  variables {
    environment = "dev"
    image       = "ghcr.io/eci/ledger:latest"
  }

  expect_failures = [var.image]
}

run "ambiente_desconocido_se_rechaza" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "el_tope_de_replicas_protege_el_credito" {
  command = plan

  variables {
    environment  = "prod"
    max_replicas = 10
  }

  expect_failures = [var.max_replicas]
}
