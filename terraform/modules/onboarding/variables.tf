###############################################################################
# terraform/modules/onboarding/variables.tf
###############################################################################

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  type = string
}

variable "customer_id" {
  type        = string
  description = "Unique short identifier e.g. acme"
}

variable "customer_name" {
  type        = string
  description = "Full customer name e.g. Acme Corp"
}

variable "mongodb_host" {
  type = string
}

variable "customer_db_password" {
  type      = string
  sensitive = true
}

variable "data_retention_days" {
  type    = number
  default = 365
}

variable "enable_backups" {
  type    = bool
  default = true
}

variable "enable_activity_monitoring" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
