variable "project_id" {
  type = string
}

variable "region" {
  description = "Los secretos se replican solo en la region del ambiente."
  type        = string
}

variable "secrets" {
  description = "Nombre y valor de cada secreto."
  type        = map(string)
  sensitive   = true
}

variable "labels" {
  type    = map(string)
  default = {}
}
