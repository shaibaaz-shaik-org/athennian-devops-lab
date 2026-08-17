###############################################################################
# terraform/environments/production/variables.tf
###############################################################################

variable "project_name" {
  type    = string
  default = "athennian"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "github_org" {
  type    = string
  default = ""
}

variable "github_repo" {
  type    = string
  default = "athennian-devops-lab"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for ALB HTTPS"
}

variable "app_ami_id" {
  type        = string
  description = "Latest Packer-built application AMI"
}

variable "mongodb_ami_id" {
  type        = string
  description = "Base AMI for MongoDB instances"
}

variable "mongodb_admin_password" {
  type      = string
  sensitive = true
}

variable "slack_webhook_url" {
  type    = string
  default = ""
}

variable "alert_email_addresses" {
  type    = list(string)
  default = []
}

# Demonstrates for_each over a customer map
variable "customers" {
  description = "Map of customer configurations"
  type = map(object({
    name                = string
    db_password         = string
    data_retention_days = number
    enable_backups      = bool
  }))
  default = {}

  sensitive = true
}
