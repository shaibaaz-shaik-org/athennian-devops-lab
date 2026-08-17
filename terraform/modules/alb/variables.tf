###############################################################################
# terraform/modules/alb/variables.tf
###############################################################################

variable "project_name" { type = string }
variable "environment"  { type = string }
variable "vpc_id"        { type = string }

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs for the ALB"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for HTTPS"
}

variable "access_logs_bucket" {
  type        = string
  description = "S3 bucket for ALB access logs"
}

variable "app_port" {
  type        = number
  description = "Application port on EC2 instances"
  default     = 8080
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "enable_stickiness" {
  type    = bool
  default = false
}

variable "waf_web_acl_arn" {
  type    = string
  default = ""
}

variable "listener_rules" {
  description = "Additional ALB listener rules"
  type = list(object({
    priority = number
    action = object({
      type             = string
      target_group_arn = optional(string)
    })
    conditions = list(object({
      type   = string
      values = list(string)
    }))
  }))
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
