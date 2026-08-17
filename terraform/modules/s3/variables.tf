###############################################################################
# terraform/modules/s3/variables.tf
###############################################################################

variable "project_name" { type = string }
variable "environment"  { type = string }
variable "account_id"   { type = string }
variable "kms_key_arn"  { type = string }

variable "buckets" {
  description = "Map of S3 buckets to create"
  type = map(object({
    type                   = string
    versioning             = bool
    lifecycle_enabled      = bool
    transition_to_ia_days  = optional(number, 30)
    transition_to_glacier_days = optional(number, 90)
    expiration_days        = optional(number, 365)
    enable_access_logging  = optional(bool, true)
  }))
  default = {
    "app-data" = {
      type                  = "application"
      versioning            = true
      lifecycle_enabled     = true
      transition_to_ia_days = 30
      transition_to_glacier_days = 90
      expiration_days       = 365
      enable_access_logging = true
    }
    "alb-logs" = {
      type                  = "logs"
      versioning            = false
      lifecycle_enabled     = true
      transition_to_ia_days = 30
      transition_to_glacier_days = 90
      expiration_days       = 90
      enable_access_logging = false
    }
    "backups" = {
      type                  = "backup"
      versioning            = true
      lifecycle_enabled     = true
      transition_to_ia_days = 30
      transition_to_glacier_days = 60
      expiration_days       = 730
      enable_access_logging = true
    }
    "access-logs" = {
      type                  = "access-logs"
      versioning            = false
      lifecycle_enabled     = true
      transition_to_ia_days = 30
      transition_to_glacier_days = 90
      expiration_days       = 180
      enable_access_logging = false
    }
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
