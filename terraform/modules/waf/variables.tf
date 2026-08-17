###############################################################################
# terraform/modules/waf/variables.tf
###############################################################################

variable "project_name"  { type = string }
variable "environment"   { type = string }

variable "rate_limit_requests_per_5min" {
  type    = number
  default = 2000
}

variable "blocked_country_codes" {
  description = "ISO 3166 country codes to block"
  type        = list(string)
  default     = []
}

variable "allowed_ip_set_arns" {
  description = "WAFv2 IP set ARNs to always allow (ops, office)"
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
