output "app_url" {
  description = "URL publica de la aplicacion."
  value       = module.app.url
}

output "project_id" {
  description = "Proyecto del ambiente."
  value       = var.project_id
}

output "service_name" {
  value = local.name
}
