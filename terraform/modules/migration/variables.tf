variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "migration_id" {
  type = string
}

variable "customer_id" {
  type = string
}

variable "destination_bucket_arn" {
  type    = string
  default = ""
}

variable "datasync_source_location_arn" {
  type    = string
  default = ""
}

variable "notification_sns_arn" {
  type    = string
  default = ""
}

variable "enable_datasync" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
