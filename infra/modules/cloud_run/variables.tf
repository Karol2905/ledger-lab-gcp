variable "project_id" {
  type = string
}

variable "name" {
  description = "Nombre del servicio, p. ej. ledger-dev."
  type        = string
}

variable "region" {
  type = string
}

variable "image" {
  description = "Imagen fijada por digest."
  type        = string
}

variable "sql_connection_name" {
  type = string
}

variable "secret_ids" {
  description = "Debe incluir database-url y jwt-secret."
  type        = map(string)
}

variable "max_instances" {
  type    = number
  default = 1
}

variable "logs_enabled" {
  description = "Crea un bucket de logs con retencion propia y lo alimenta con un sink."
  type        = bool
  default     = false
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "iam_propagation_wait" {
  type    = string
  default = "60s"
}

variable "labels" {
  type    = map(string)
  default = {}
}
