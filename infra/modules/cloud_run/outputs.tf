output "url" {
  value = google_cloud_run_v2_service.this.uri
}

output "service_account" {
  value = google_service_account.app.email
}
