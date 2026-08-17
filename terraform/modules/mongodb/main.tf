###############################################################################
# terraform/modules/mongodb/main.tf
# MongoDB on EC2 — primary + replica across two AZs
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "mongodb"
    Environment = var.environment
  })

  # MongoDB-specific instance sizing by environment
  mongo_config = {
    dev = {
      instance_type = "t3.medium"
      volume_size   = 50
      volume_type   = "gp3"
      iops          = 3000
    }
    staging = {
      instance_type = "r6i.large"
      volume_size   = 100
      volume_type   = "gp3"
      iops          = 3000
    }
    production = {
      instance_type = "r6i.xlarge"
      volume_size   = 500
      volume_type   = "io2"
      iops          = 10000
    }
  }

  config = lookup(local.mongo_config, var.environment, local.mongo_config["dev"])
}

###############################################################################
# Security Group — MongoDB (only accessible from application tier)
###############################################################################

resource "aws_security_group" "mongodb" {
  name        = "${var.project_name}-${var.environment}-mongodb-sg"
  description = "MongoDB - only reachable from application tier"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MongoDB from app tier only"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [var.app_security_group_id]
  }

  ingress {
    description = "MongoDB replication between nodes"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-mongodb-sg"
  })
}

###############################################################################
# KMS Key — dedicated key for MongoDB EBS volumes
###############################################################################

resource "aws_kms_key" "mongodb" {
  description             = "MongoDB EBS encryption - ${var.project_name} ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-mongodb-kms"
  })
}

resource "aws_kms_alias" "mongodb" {
  name          = "alias/${var.project_name}-${var.environment}-mongodb"
  target_key_id = aws_kms_key.mongodb.key_id
}

###############################################################################
# IAM Role for MongoDB EC2
###############################################################################

resource "aws_iam_role" "mongodb" {
  name = "${var.project_name}-${var.environment}-mongodb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "mongodb_ssm" {
  role       = aws_iam_role.mongodb.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "mongodb_cloudwatch" {
  role       = aws_iam_role.mongodb.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "mongodb_backup" {
  name = "${var.project_name}-${var.environment}-mongodb-backup-policy"
  role = aws_iam_role.mongodb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ]
      Resource = [
        var.backup_bucket_arn,
        "${var.backup_bucket_arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "mongodb" {
  name = "${var.project_name}-${var.environment}-mongodb-profile"
  role = aws_iam_role.mongodb.name

  tags = local.common_tags
}

###############################################################################
# MongoDB Primary Instance (AZ1)
###############################################################################

resource "aws_instance" "mongodb_primary" {
  ami                    = var.mongodb_ami_id
  instance_type          = local.config.instance_type
  subnet_id              = var.db_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.mongodb.id]
  iam_instance_profile   = aws_iam_instance_profile.mongodb.name

  # No key pair — SSH disabled, Session Manager used instead
  associate_public_ip_address = false

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = aws_kms_key.mongodb.arn
    delete_on_termination = true
  }

  ebs_block_device {
    device_name           = "/dev/sdb"
    volume_type           = local.config.volume_type
    volume_size           = local.config.volume_size
    iops                  = local.config.iops
    encrypted             = true
    kms_key_id            = aws_kms_key.mongodb.arn
    delete_on_termination = false  # Persist data volume on termination
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/templates/mongodb-init.sh.tpl", {
    replica_set_name = "${var.project_name}-${var.environment}-rs"
    role             = "primary"
    admin_secret_arn = var.admin_secret_arn
    aws_region       = var.aws_region
    backup_bucket    = var.backup_bucket_name
    backup_schedule  = var.backup_schedule
    log_group        = "/mongodb/${var.project_name}/${var.environment}"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-mongodb-primary"
    Role = "mongodb-primary"
  })
}

###############################################################################
# MongoDB Replica Instance (AZ2) — only in staging/production
###############################################################################

resource "aws_instance" "mongodb_replica" {
  count = var.environment == "production" || var.environment == "staging" ? 1 : 0

  ami                    = var.mongodb_ami_id
  instance_type          = local.config.instance_type
  subnet_id              = var.db_subnet_ids[1]
  vpc_security_group_ids = [aws_security_group.mongodb.id]
  iam_instance_profile   = aws_iam_instance_profile.mongodb.name

  associate_public_ip_address = false

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = aws_kms_key.mongodb.arn
    delete_on_termination = true
  }

  ebs_block_device {
    device_name           = "/dev/sdb"
    volume_type           = local.config.volume_type
    volume_size           = local.config.volume_size
    iops                  = local.config.iops
    encrypted             = true
    kms_key_id            = aws_kms_key.mongodb.arn
    delete_on_termination = false
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/templates/mongodb-init.sh.tpl", {
    replica_set_name = "${var.project_name}-${var.environment}-rs"
    role             = "replica"
    admin_secret_arn = var.admin_secret_arn
    aws_region       = var.aws_region
    backup_bucket    = var.backup_bucket_name
    backup_schedule  = var.backup_schedule
    log_group        = "/mongodb/${var.project_name}/${var.environment}"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-mongodb-replica"
    Role = "mongodb-replica"
  })
}

###############################################################################
# Secrets Manager — MongoDB admin credentials
###############################################################################

resource "aws_secretsmanager_secret" "mongodb_admin" {
  name                    = "${var.project_name}/${var.environment}/mongodb/admin"
  description             = "MongoDB admin credentials"
  kms_key_id              = aws_kms_key.mongodb.arn
  recovery_window_in_days = var.environment == "production" ? 30 : 7

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "mongodb_admin" {
  secret_id = aws_secretsmanager_secret.mongodb_admin.id
  secret_string = jsonencode({
    username         = "admin"
    password         = var.mongodb_admin_password
    host             = aws_instance.mongodb_primary.private_ip
    port             = 27017
    replica_set_name = "${var.project_name}-${var.environment}-rs"
    connection_string = "mongodb://admin:${var.mongodb_admin_password}@${aws_instance.mongodb_primary.private_ip}:27017/?replicaSet=${var.project_name}-${var.environment}-rs&authSource=admin"
  })
}

###############################################################################
# CloudWatch Alarms — MongoDB monitoring
###############################################################################

resource "aws_cloudwatch_metric_alarm" "mongodb_cpu" {
  alarm_name          = "${var.project_name}-${var.environment}-mongodb-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "MongoDB CPU > 80%"
  alarm_actions       = var.alarm_sns_arns

  dimensions = { InstanceId = aws_instance.mongodb_primary.id }
  tags       = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "mongodb_disk" {
  alarm_name          = "${var.project_name}-${var.environment}-mongodb-disk"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "${var.project_name}/${var.environment}/MongoDB"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "MongoDB disk > 80% — expand volume or add node"
  alarm_actions       = var.alarm_sns_arns

  dimensions = { InstanceId = aws_instance.mongodb_primary.id }
  tags       = local.common_tags
}

###############################################################################
# EventBridge Rule — trigger backup validation after backup job completes
###############################################################################

resource "aws_cloudwatch_event_rule" "backup_complete" {
  name                = "${var.project_name}-${var.environment}-mongodb-backup"
  description         = "Trigger after MongoDB backup job completes"
  schedule_expression = var.backup_schedule

  tags = local.common_tags
}
