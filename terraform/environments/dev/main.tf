###############################################################################
# terraform/environments/dev/main.tf
# Dev environment — cost-optimised, single NAT GW, no WAF, no replica
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "athennian-terraform-state-083846066460"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "athennian-terraform-locks"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:083846066460:key/2bb44672-a1ff-46e8-b58c-e971bc5868fd"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "athennian"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  environment = "dev"
  common_tags = { Project = "athennian", Environment = "dev", ManagedBy = "terraform" }
}

module "security" {
  source               = "../../modules/security"
  project_name         = "athennian"
  environment          = local.environment
  create_github_oidc   = false   # OIDC provider already created manually
  tags                 = local.common_tags
}

module "vpc" {
  source       = "../../modules/vpc"
  project_name = "athennian"
  environment  = local.environment
  vpc_cidr     = "10.1.0.0/16"

  public_subnets = {
    az1 = { cidr = "10.1.1.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.1.2.0/24", az = "us-east-1b" }
  }
  app_subnets = {
    az1 = { cidr = "10.1.11.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.1.12.0/24", az = "us-east-1b" }
  }
  db_subnets = {
    az1 = { cidr = "10.1.21.0/24", az = "us-east-1a" }
    az2 = { cidr = "10.1.22.0/24", az = "us-east-1b" }
  }

  # Cost saving: single NAT GW in dev (cross-AZ dependency acceptable)
  enable_nat_gateway      = true
  enable_flow_logs        = false
  tags                    = local.common_tags
}

module "s3" {
  source       = "../../modules/s3"
  project_name = "athennian"
  environment  = local.environment
  account_id   = data.aws_caller_identity.current.account_id
  kms_key_arn  = module.security.kms_key_arns["s3"]
  tags         = local.common_tags
}

module "alb" {
  source              = "../../modules/alb"
  project_name        = "athennian"
  environment         = local.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids_list
  acm_certificate_arn = var.acm_certificate_arn  # empty string = HTTP only in dev
  access_logs_bucket  = module.s3.bucket_ids["alb-logs"]
  tags                = local.common_tags
}

module "ec2" {
  source            = "../../modules/ec2"
  project_name      = "athennian"
  environment       = local.environment
  vpc_id            = module.vpc.vpc_id
  app_subnet_ids    = module.vpc.app_subnet_ids_list
  target_group_arns = [module.alb.target_group_arn]
  ami_id            = var.app_ami_id
  kms_key_arn       = module.security.kms_key_arns["ebs"]
  app_s3_bucket     = module.s3.bucket_ids["app-data"]
  ingress_rules = [{
    description     = "HTTP from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [module.alb.alb_sg_id]
  }]
  tags = local.common_tags
}

output "alb_dns_name" { value = module.alb.alb_dns_name }
output "asg_name"     { value = module.ec2.asg_name }
