variable "project_id" {
  description = "Proyecto del ambiente."
  type        = string
}

variable "instance_name" {
  description = "Nombre de la instancia. Google no deja reutilizarlo durante una semana tras borrarla."
  type        = string
}

variable "region" {
  description = "Region de Cloud SQL."
  type        = string
}

variable "tier" {
  description = "Tamano de la instancia."
  type        = string
  default     = "db-f1-micro"

  validation {
    condition     = contains(["db-f1-micro", "db-g1-small"], var.tier)
    error_message = "Solo se permiten instancias compartidas, para proteger el credito."
  }
}

variable "backups_enabled" {
  description = "Respaldos automaticos y recuperacion a un punto en el tiempo."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Impide borrar la instancia desde Terraform."
  type        = bool
  default     = false
}

variable "database_name" {
  type    = string
  default = "ledger"
}

variable "user_name" {
  type    = string
  default = "ledger"
}

variable "labels" {
  type    = map(string)
  default = {}
}
