###############################################################################
# terraform/modules/security/main.tf
# KMS keys, Secrets Manager, IAM OIDC for GitHub Actions
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "security"
    Environment = var.environment
  })
}

###############################################################################
# KMS Keys — one per domain, demonstrates for_each over map
###############################################################################

locals {
  kms_keys = {
    app = {
      description = "Application data encryption - ${var.project_name} ${var.environment}"
      alias       = "alias/${var.project_name}-${var.environment}-app"
    }
    ebs = {
      description = "EBS volume encryption - ${var.project_name} ${var.environment}"
      alias       = "alias/${var.project_name}-${var.environment}-ebs"
    }
    s3 = {
      description = "S3 bucket encryption - ${var.project_name} ${var.environment}"
      alias       = "alias/${var.project_name}-${var.environment}-s3"
    }
    secrets = {
      description = "Secrets Manager encryption - ${var.project_name} ${var.environment}"
      alias       = "alias/${var.project_name}-${var.environment}-secrets"
    }
  }
}

resource "aws_kms_key" "keys" {
  for_each = local.kms_keys

  description             = each.value.description
  deletion_window_in_days = var.environment == "production" ? 30 : 7
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name    = each.value.alias
    KeyType = each.key
  })
}

resource "aws_kms_alias" "keys" {
  for_each = local.kms_keys

  name          = each.value.alias
  target_key_id = aws_kms_key.keys[each.key].key_id
}

###############################################################################
# GitHub Actions OIDC Provider + IAM Role
# Replaces long-lived AWS access keys with short-lived tokens
###############################################################################

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",  # GitHub OIDC thumbprint
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = local.common_tags
}

resource "aws_iam_role" "github_actions" {
  count = var.create_github_oidc ? 1 : 0

  name = "${var.project_name}-${var.environment}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Restrict to specific repo and branch
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "github_actions_terraform" {
  count = var.create_github_oidc ? 1 : 0

  name = "${var.project_name}-${var.environment}-github-terraform-policy"
  role = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Terraform state backend access
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.terraform_state_bucket}",
          "arn:aws:s3:::${var.terraform_state_bucket}/*"
        ]
      },
      {
        Sid    = "TerraformStateLock"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.terraform_lock_table}"
      },
      {
        # Allow full infra management — scope down per environment in production
        Sid    = "InfrastructureManagement"
        Effect = "Allow"
        Action = [
          "ec2:*", "autoscaling:*", "elasticloadbalancing:*",
          "wafv2:*", "route53:*", "s3:*", "kms:*",
          "iam:*", "secretsmanager:*", "cloudwatch:*",
          "logs:*", "sns:*", "events:*", "ssm:*"
        ]
        Resource = "*"
      }
    ]
  })
}

###############################################################################
# Security Groups — centralised security group rules using for_each
###############################################################################

resource "aws_security_group" "custom" {
  for_each = var.security_groups

  name        = "${var.project_name}-${var.environment}-${each.key}-sg"
  description = each.value.description
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = each.value.ingress_rules
    content {
      description     = ingress.value.description
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      cidr_blocks     = lookup(ingress.value, "cidr_blocks", null)
      security_groups = lookup(ingress.value, "security_groups", null)
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-${each.key}-sg"
  })
}

###############################################################################
# IAM Password Policy — enforce strong passwords for IAM users
###############################################################################

resource "aws_iam_account_password_policy" "strict" {
  count = var.manage_iam_password_policy ? 1 : 0

  minimum_password_length        = 16
  require_lowercase_characters   = true
  require_numbers                = true
  require_uppercase_characters   = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 12
}
