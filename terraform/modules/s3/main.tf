###############################################################################
# terraform/modules/s3/main.tf
# S3 buckets with encryption, versioning, lifecycle policies
# Uses for_each to create multiple buckets from a map
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "s3"
    Environment = var.environment
  })
}

###############################################################################
# S3 Buckets — for_each over map of bucket configurations
###############################################################################

resource "aws_s3_bucket" "buckets" {
  for_each = var.buckets

  bucket        = "${var.project_name}-${var.environment}-${each.key}-${var.account_id}"
  force_destroy = var.environment != "production"

  tags = merge(local.common_tags, {
    Name       = "${var.project_name}-${var.environment}-${each.key}"
    BucketType = each.value.type
  })
}

# Block all public access — no S3 bucket should ever be public
resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = var.buckets

  bucket                  = aws_s3_bucket.buckets[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption with KMS
resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = var.buckets

  bucket = aws_s3_bucket.buckets[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true  # Reduces KMS API calls = lower cost
  }
}

# Versioning — enabled for all production buckets
resource "aws_s3_bucket_versioning" "buckets" {
  for_each = var.buckets

  bucket = aws_s3_bucket.buckets[each.key].id

  versioning_configuration {
    status = each.value.versioning ? "Enabled" : "Suspended"
  }
}

# Lifecycle policies — manage storage costs automatically
resource "aws_s3_bucket_lifecycle_configuration" "buckets" {
  for_each = { for k, v in var.buckets : k => v if v.lifecycle_enabled }

  bucket = aws_s3_bucket.buckets[each.key].id

  depends_on = [aws_s3_bucket_versioning.buckets]

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    transition {
      days          = each.value.transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = each.value.transition_to_glacier_days
      storage_class = "GLACIER"
    }

    expiration {
      days = each.value.expiration_days
    }

    dynamic "noncurrent_version_expiration" {
      for_each = each.value.versioning ? [1] : []
      content {
        noncurrent_days = 30
      }
    }
  }
}

# Access logging — who accessed what and when
resource "aws_s3_bucket_logging" "buckets" {
  for_each = { for k, v in var.buckets : k => v if v.enable_access_logging }

  bucket        = aws_s3_bucket.buckets[each.key].id
  target_bucket = aws_s3_bucket.buckets["access-logs"].id
  target_prefix = "${each.key}/"
}

# Enforce HTTPS-only access via bucket policy
# For ALB log buckets, also allow ELB delivery service to put objects
resource "aws_s3_bucket_policy" "enforce_tls" {
  for_each = var.buckets

  bucket = aws_s3_bucket.buckets[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # Allow ELB access log delivery (only for log-type buckets)
      each.value.type == "logs" ? [{
        Sid       = "AllowELBAccessLogs"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.buckets[each.key].arn}/AWSLogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }, {
        Sid       = "AllowELBGetBucketAcl"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.buckets[each.key].arn
      }] : [],
      [{
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.buckets[each.key].arn,
          "${aws_s3_bucket.buckets[each.key].arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }]
    )
  })

  depends_on = [aws_s3_bucket_public_access_block.buckets]
}
