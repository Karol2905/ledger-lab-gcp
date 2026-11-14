output "secret_ids" {
  description = "Nombre del secreto => id completo, para referenciarlo desde Cloud Run."
  value       = { for name, secret in google_secret_manager_secret.this : name => secret.secret_id }
}

# La version depende de la escritura: Cloud Run no debe arrancar antes de que exista el valor.
output "versions" {
  value = { for name, version in google_secret_manager_secret_version.this : name => version.version }
}
