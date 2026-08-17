###############################################################################
# terraform/modules/onboarding/main.tf
# Customer onboarding module — provisions all per-customer resources
# Called once per customer with customer-specific variables
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "onboarding"
    Environment = var.environment
    CustomerID  = var.customer_id
    CustomerName = var.customer_name
  })
}

###############################################################################
# Customer KMS Key — dedicated encryption key per customer
###############################################################################

resource "aws_kms_key" "customer" {
  description             = "Customer encryption key - ${var.customer_name} (${var.customer_id})"
  deletion_window_in_days = var.environment == "production" ? 30 : 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.customer_id}-kms"
  })
}

resource "aws_kms_alias" "customer" {
  name          = "alias/${var.project_name}-${var.environment}-customer-${var.customer_id}"
  target_key_id = aws_kms_key.customer.key_id
}

###############################################################################
# Customer S3 Buckets — demonstrates for_each over customer-specific buckets
###############################################################################

locals {
  customer_buckets = {
    data = {
      description       = "Primary customer data"
      transition_days   = var.data_retention_days > 90 ? 30 : 999
      expiration_days   = var.data_retention_days
      versioning        = true
    }
    uploads = {
      description     = "Customer file uploads (temp)"
      transition_days = 7
      expiration_days = 30
      versioning      = false
    }
    exports = {
      description     = "Customer data exports"
      transition_days = 1
      expiration_days = 14
      versioning      = false
    }
  }
}

resource "aws_s3_bucket" "customer" {
  for_each = local.customer_buckets

  bucket        = "${var.project_name}-${var.environment}-${var.customer_id}-${each.key}-${var.account_id}"
  force_destroy = var.environment != "production"

  tags = merge(local.common_tags, {
    Name       = "${var.customer_id}-${each.key}"
    BucketType = each.value.description
  })
}

resource "aws_s3_bucket_public_access_block" "customer" {
  for_each = local.customer_buckets

  bucket                  = aws_s3_bucket.customer[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "customer" {
  for_each = local.customer_buckets

  bucket = aws_s3_bucket.customer[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.customer.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "customer" {
  for_each = local.customer_buckets

  bucket = aws_s3_bucket.customer[each.key].id
  versioning_configuration {
    status = each.value.versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "customer" {
  for_each = local.customer_buckets

  bucket     = aws_s3_bucket.customer[each.key].id
  depends_on = [aws_s3_bucket_versioning.customer]

  rule {
    id     = "lifecycle"
    status = "Enabled"

    transition {
      days          = each.value.transition_days
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = each.value.expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

###############################################################################
# Customer IAM Role — scoped strictly to customer resources only
###############################################################################

resource "aws_iam_role" "customer_app" {
  name = "${var.project_name}-${var.environment}-${var.customer_id}-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "customer_s3" {
  name = "${var.customer_id}-s3-policy"
  role = aws_iam_role.customer_app.id

  # Scoped to only this customer's buckets — cross-customer access impossible
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CustomerS3Access"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = flatten([
          for k, v in aws_s3_bucket.customer : [v.arn, "${v.arn}/*"]
        ])
      },
      {
        Sid    = "CustomerKMSAccess"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = aws_kms_key.customer.arn
      },
      {
        Sid    = "CustomerSecretsAccess"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.project_name}/${var.environment}/customers/${var.customer_id}/*"
      }
    ]
  })
}

###############################################################################
# Customer Secrets — database credentials, API keys
###############################################################################

resource "aws_secretsmanager_secret" "customer_db" {
  name                    = "${var.project_name}/${var.environment}/customers/${var.customer_id}/db"
  description             = "Database credentials for customer ${var.customer_name}"
  kms_key_id              = aws_kms_key.customer.arn
  recovery_window_in_days = var.environment == "production" ? 30 : 7

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "customer_db" {
  secret_id = aws_secretsmanager_secret.customer_db.id

  secret_string = jsonencode({
    username        = var.customer_id
    password        = var.customer_db_password
    database        = var.customer_id
    mongodb_host    = var.mongodb_host
    connection_string = "mongodb://${var.customer_id}:${var.customer_db_password}@${var.mongodb_host}:27017/${var.customer_id}?authSource=${var.customer_id}"
  })
}

###############################################################################
# Customer CloudWatch Resources
###############################################################################

resource "aws_cloudwatch_log_group" "customer" {
  name              = "/app/${var.project_name}/${var.environment}/customers/${var.customer_id}"
  retention_in_days = var.data_retention_days < 365 ? var.data_retention_days : 365
  kms_key_id        = aws_kms_key.customer.arn

  tags = local.common_tags
}

resource "aws_cloudwatch_dashboard" "customer" {
  dashboard_name = "${var.project_name}-${var.environment}-customer-${var.customer_id}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "log"
        x      = 0; y = 0; width = 24; height = 6
        properties = {
          title  = "Customer ${var.customer_name} - Application Logs"
          region = var.aws_region
          query  = "SOURCE '/app/${var.project_name}/${var.environment}/customers/${var.customer_id}' | fields @timestamp, @message | sort @timestamp desc | limit 100"
          view   = "table"
        }
      }
    ]
  })
}

###############################################################################
# EventBridge Rule — customer activity monitoring
###############################################################################

resource "aws_cloudwatch_event_rule" "customer_activity" {
  count = var.enable_activity_monitoring ? 1 : 0

  name        = "${var.project_name}-${var.environment}-${var.customer_id}-activity"
  description = "Monitor S3 activity for customer ${var.customer_name}"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created", "Object Deleted"]
    detail = {
      bucket = {
        name = [for k, v in aws_s3_bucket.customer : v.id]
      }
    }
  })

  tags = local.common_tags
}
