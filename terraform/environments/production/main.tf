###############################################################################
# terraform/environments/production/main.tf
# Production environment — assembles all modules
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "athennian-terraform-state-ACCOUNT_ID"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "athennian-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "production"
      ManagedBy   = "terraform"
      Repository  = "athennian-devops-lab"
    }
  }
}

data "aws_caller_identity" "current" {}

###############################################################################
# Local environment config — demonstrates maps and conditionals
###############################################################################

locals {
  environment = "production"

  # Environment sizing map
  environments = {
    dev = {
      instance_type    = "t3.small"
      min_asg_size     = 1
      max_asg_size     = 2
      enable_waf       = false
      enable_backups   = false
      nat_per_az       = false
      mongo_replica    = false
    }
    staging = {
      instance_type    = "t3.medium"
      min_asg_size     = 1
      max_asg_size     = 4
      enable_waf       = true
      enable_backups   = true
      nat_per_az       = false
      mongo_replica    = true
    }
    production = {
      instance_type    = "t3.large"
      min_asg_size     = 2
      max_asg_size     = 10
      enable_waf       = true
      enable_backups   = true
      nat_per_az       = true
      mongo_replica    = true
    }
  }

  config = local.environments[local.environment]

  common_tags = {
    Project     = var.project_name
    Environment = local.environment
    ManagedBy   = "terraform"
    CostCenter  = "platform-engineering"
  }
}

###############################################################################
# Security Module — KMS keys, OIDC, security groups
###############################################################################

module "security" {
  source = "../../modules/security"

  project_name = var.project_name
  environment  = local.environment
  aws_region   = var.aws_region

  create_github_oidc     = true
  github_org             = var.github_org
  github_repo            = var.github_repo
  terraform_state_bucket = "athennian-terraform-state-${data.aws_caller_identity.current.account_id}"
  terraform_lock_table   = "athennian-terraform-locks"

  tags = local.common_tags
}

###############################################################################
# VPC Module
###############################################################################

module "vpc" {
  source = "../../modules/vpc"

  project_name = var.project_name
  environment  = local.environment
  aws_region   = var.aws_region
  vpc_cidr     = "10.0.0.0/16"

  public_subnets = {
    az1 = { cidr = "10.0.1.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.0.2.0/24", az = "us-east-1b" }
  }

  app_subnets = {
    az1 = { cidr = "10.0.11.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.0.12.0/24", az = "us-east-1b" }
  }

  db_subnets = {
    az1 = { cidr = "10.0.21.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.0.22.0/24", az = "us-east-1b" }
  }

  enable_nat_gateway      = true  # Always true in production
  enable_flow_logs        = true
  flow_log_retention_days = 90

  tags = local.common_tags
}

###############################################################################
# S3 Module
###############################################################################

module "s3" {
  source = "../../modules/s3"

  project_name = var.project_name
  environment  = local.environment
  account_id   = data.aws_caller_identity.current.account_id
  kms_key_arn  = module.security.kms_key_arns["s3"]

  tags = local.common_tags
}

###############################################################################
# WAF Module — only in staging and production
###############################################################################

module "waf" {
  count  = local.config.enable_waf ? 1 : 0
  source = "../../modules/waf"

  project_name = var.project_name
  environment  = local.environment

  rate_limit_requests_per_5min = 2000
  blocked_country_codes        = []
  log_retention_days           = 90

  tags = local.common_tags
}

###############################################################################
# ALB Module
###############################################################################

module "alb" {
  source = "../../modules/alb"

  project_name        = var.project_name
  environment         = local.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids_list
  acm_certificate_arn = var.acm_certificate_arn
  access_logs_bucket  = module.s3.bucket_ids["alb-logs"]
  waf_web_acl_arn     = local.config.enable_waf ? module.waf[0].web_acl_arn : ""

  tags = local.common_tags
}

###############################################################################
# EC2 / ASG Module
###############################################################################

module "ec2" {
  source = "../../modules/ec2"

  project_name      = var.project_name
  environment       = local.environment
  aws_region        = var.aws_region
  vpc_id            = module.vpc.vpc_id
  app_subnet_ids    = module.vpc.app_subnet_ids_list
  target_group_arns = [module.alb.target_group_arn]
  ami_id            = var.app_ami_id
  kms_key_arn       = module.security.kms_key_arns["ebs"]
  app_s3_bucket     = module.s3.bucket_ids["app-data"]

  # ALB SG can reach app tier on app port
  ingress_rules = [
    {
      description     = "HTTP from ALB"
      from_port       = 8080
      to_port         = 8080
      protocol        = "tcp"
      security_groups = [module.alb.alb_sg_id]
    }
  ]

  tags = local.common_tags
}

###############################################################################
# MongoDB Module
###############################################################################

module "mongodb" {
  source = "../../modules/mongodb"

  project_name          = var.project_name
  environment           = local.environment
  aws_region            = var.aws_region
  vpc_id                = module.vpc.vpc_id
  db_subnet_ids         = module.vpc.db_subnet_ids_list
  app_security_group_id = module.ec2.app_security_group_id
  mongodb_ami_id        = var.mongodb_ami_id
  backup_bucket_arn     = module.s3.bucket_arns["backups"]
  backup_bucket_name    = module.s3.bucket_ids["backups"]
  alarm_sns_arns        = [module.monitoring.p0_sns_arn]

  mongodb_admin_password = var.mongodb_admin_password

  tags = local.common_tags
}

###############################################################################
# Monitoring Module
###############################################################################

module "monitoring" {
  source = "../../modules/monitoring"

  project_name           = var.project_name
  environment            = local.environment
  aws_region             = var.aws_region
  kms_key_id             = module.security.kms_key_ids["app"]
  kms_key_arn            = module.security.kms_key_arns["app"]
  alb_arn_suffix         = module.alb.alb_arn
  target_group_arn_suffix = module.alb.target_group_arn
  asg_name               = module.ec2.asg_name
  slack_webhook_url      = var.slack_webhook_url
  alert_email_addresses  = var.alert_email_addresses

  tags = local.common_tags
}

###############################################################################
# Customer Onboarding — for_each over customer map
###############################################################################

module "customer_onboarding" {
  for_each = var.customers
  source   = "../../modules/onboarding"

  project_name = var.project_name
  environment  = local.environment
  aws_region   = var.aws_region
  account_id   = data.aws_caller_identity.current.account_id

  customer_id   = each.key
  customer_name = each.value.name
  mongodb_host  = module.mongodb.mongodb_primary_ip

  customer_db_password = each.value.db_password
  data_retention_days  = each.value.data_retention_days
  enable_backups       = each.value.enable_backups

  tags = merge(local.common_tags, {
    CustomerID = each.key
  })
}
