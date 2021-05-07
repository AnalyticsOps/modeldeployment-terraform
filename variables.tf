variable "project_name" {
  type = string
}

variable "environment_name" {
  type = string
}

variable "resource_number" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "alert_emails" {
  type        = list(string)
  default     = []
  description = "E-mail to receive alerts"
}

variable "alert_frequency" {
  type        = number
  default     = 60
  description = "Alert frequency (in minutes)"
}
