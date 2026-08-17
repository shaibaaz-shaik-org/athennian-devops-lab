###############################################################################
# terraform/modules/ec2/variables.tf
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
  type = string
}

variable "app_subnet_ids" {
  description = "List of private application subnet IDs for the ASG"
  type        = list(string)
}

variable "target_group_arns" {
  description = "ALB Target Group ARNs to register instances with"
  type        = list(string)
  default     = []
}

variable "ami_id" {
  description = "AMI ID — typically the latest Packer-built AMI"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (overrides environment default if set)"
  type        = string
  default     = ""
}

variable "min_size" {
  description = "ASG minimum size (overrides environment default if > 0)"
  type        = number
  default     = 0
}

variable "max_size" {
  description = "ASG maximum size (overrides environment default if > 0)"
  type        = number
  default     = 0
}

variable "desired_capacity" {
  description = "ASG desired capacity (overrides environment default if > 0)"
  type        = number
  default     = 0
}

variable "kms_key_arn" {
  description = "KMS key ARN for EBS encryption"
  type        = string
}

variable "app_s3_bucket" {
  description = "S3 bucket name for application data"
  type        = string
}

variable "s3_config_bucket" {
  description = "S3 bucket for application configuration files"
  type        = string
  default     = ""
}

variable "ingress_rules" {
  description = "List of ingress rules for the application security group"
  type = list(object({
    description     = string
    from_port       = number
    to_port         = number
    protocol        = string
    cidr_blocks     = optional(list(string))
    security_groups = optional(list(string))
  }))
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
