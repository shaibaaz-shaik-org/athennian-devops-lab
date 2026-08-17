###############################################################################
# terraform/modules/security/variables.tf
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

variable "vpc_id" {
  type    = string
  default = ""
}

variable "create_github_oidc" {
  type    = bool
  default = true
}

variable "github_org" {
  type    = string
  default = ""
}

variable "github_repo" {
  type    = string
  default = ""
}

variable "terraform_state_bucket" {
  type    = string
  default = ""
}

variable "terraform_lock_table" {
  type    = string
  default = ""
}

variable "manage_iam_password_policy" {
  type    = bool
  default = false  # Only set once per account
}

variable "security_groups" {
  description = "Map of security groups to create"
  type = map(object({
    description = string
    ingress_rules = list(object({
      description     = string
      from_port       = number
      to_port         = number
      protocol        = string
      cidr_blocks     = optional(list(string))
      security_groups = optional(list(string))
    }))
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
