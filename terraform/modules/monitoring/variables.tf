###############################################################################
# terraform/modules/monitoring/variables.tf
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

variable "kms_key_id" {
  type    = string
  default = ""
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "alb_arn_suffix" {
  type    = string
  default = ""
}

variable "target_group_arn_suffix" {
  type    = string
  default = ""
}

variable "asg_name" {
  type    = string
  default = ""
}

variable "slack_webhook_url" {
  type    = string
  default = ""
}

variable "alert_email_addresses" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
