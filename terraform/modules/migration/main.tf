###############################################################################
# terraform/modules/migration/main.tf
# Resources to support on-premises to AWS migrations
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "migration"
    Environment = var.environment
    MigrationID = var.migration_id
  })
}

###############################################################################
# DataSync — managed file transfer service for large data volumes
###############################################################################

resource "aws_datasync_location_s3" "destination" {
  count = var.enable_datasync ? 1 : 0

  s3_bucket_arn    = var.destination_bucket_arn
  subdirectory     = "/${var.customer_id}/migration"

  s3_config {
    bucket_access_role_arn = aws_iam_role.datasync[0].arn
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.migration_id}-datasync-dest"
  })
}

resource "aws_datasync_task" "migration" {
  count = var.enable_datasync ? 1 : 0

  name                     = "${var.project_name}-${var.migration_id}-transfer"
  destination_location_arn = aws_datasync_location_s3.destination[0].arn
  source_location_arn      = var.datasync_source_location_arn

  options {
    bytes_per_second       = -1  # No throttle during off-peak
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    overwrite_mode         = "ALWAYS"
    preserve_deleted_files = "PRESERVE"
    log_level              = "TRANSFER"
  }

  cloudwatch_log_group_arn = aws_cloudwatch_log_group.migration.arn

  tags = local.common_tags
}

resource "aws_iam_role" "datasync" {
  count = var.enable_datasync ? 1 : 0

  name = "${var.project_name}-${var.environment}-${var.migration_id}-datasync-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "datasync.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "datasync" {
  count = var.enable_datasync ? 1 : 0

  name = "datasync-s3-access"
  role = aws_iam_role.datasync[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                "s3:GetObjectTagging", "s3:PutObjectTagging",
                "s3:GetBucketLocation", "s3:ListBucket"]
      Resource = [var.destination_bucket_arn, "${var.destination_bucket_arn}/*"]
    }]
  })
}

###############################################################################
# CloudWatch Log Group — migration audit trail
###############################################################################

resource "aws_cloudwatch_log_group" "migration" {
  name              = "/migration/${var.project_name}/${var.migration_id}"
  retention_in_days = 90

  tags = local.common_tags
}

###############################################################################
# EventBridge Rule — migration status notifications
###############################################################################

resource "aws_cloudwatch_event_rule" "datasync_complete" {
  count = var.enable_datasync ? 1 : 0

  name        = "${var.project_name}-${var.migration_id}-sync-complete"
  description = "DataSync task execution completed"

  event_pattern = jsonencode({
    source      = ["aws.datasync"]
    detail-type = ["DataSync Task Execution State Change"]
    detail = {
      State = ["SUCCESS", "ERROR"]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "datasync_sns" {
  count = var.enable_datasync && var.notification_sns_arn != "" ? 1 : 0

  rule      = aws_cloudwatch_event_rule.datasync_complete[0].name
  target_id = "migration-sns"
  arn       = var.notification_sns_arn
}
