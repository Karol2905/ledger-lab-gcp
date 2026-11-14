output "connection_name" {
  description = "proyecto:region:instancia, lo que Cloud Run monta en /cloudsql."
  value       = google_sql_database_instance.this.connection_name
}

output "region" {
  value = google_sql_database_instance.this.region
}

output "database_url" {
  description = "Cadena de conexion por el socket del conector de Cloud SQL."
  sensitive   = true
  value = format(
    "postgresql+psycopg://%s:%s@/%s?host=/cloudsql/%s",
    google_sql_user.app.name,
    random_password.app.result,
    google_sql_database.this.name,
    google_sql_database_instance.this.connection_name,
  )
}
