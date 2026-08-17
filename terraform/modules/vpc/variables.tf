###############################################################################
# terraform/modules/vpc/variables.tf
###############################################################################

variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Deployment environment: dev, staging, production"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Map of public subnets keyed by AZ short name"
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    az1 = { cidr = "10.0.1.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.0.2.0/24", az = "us-east-1b" }
  }
}

variable "app_subnets" {
  description = "Map of private application subnets keyed by AZ short name"
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    az1 = { cidr = "10.0.11.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.0.12.0/24", az = "us-east-1b" }
  }
}

variable "db_subnets" {
  description = "Map of private database subnets keyed by AZ short name"
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    az1 = { cidr = "10.0.21.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.0.22.0/24", az = "us-east-1b" }
  }
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway (disable in dev to reduce cost)"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch log retention for VPC flow logs (days)"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
