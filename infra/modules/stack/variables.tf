variable "environment" {
  description = "Ambiente: dev o prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "El ambiente debe ser dev o prod."
  }
}

variable "project_id" {
  description = "Proyecto de Google Cloud del ambiente: cada ambiente tiene el suyo."
  type        = string
}

variable "region" {
  description = "Region de la app y los secretos (ver scripts/check-regions.sh)."
  type        = string
}

variable "database_region" {
  description = "Region de Cloud SQL, si debe ser otra. Con null usa region."
  type        = string
  default     = null
}

variable "image" {
  description = "Imagen fijada por digest, para que prod ejecute exactamente lo probado en dev."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image))
    error_message = "La imagen debe fijarse por digest: registro/imagen@sha256:..."
  }
}

variable "max_replicas" {
  description = "Tope de instancias de Cloud Run."
  type        = number
  default     = 1

  validation {
    condition     = var.max_replicas >= 1 && var.max_replicas <= 3
    error_message = "max_replicas debe estar entre 1 y 3 para proteger el credito."
  }
}

variable "jwt_minutes" {
  description = "Vigencia de los tokens."
  type        = number
  default     = 30
}

variable "iam_propagation_wait" {
  description = "Espera tras conceder permisos IAM."
  type        = string
  default     = "60s"
}
