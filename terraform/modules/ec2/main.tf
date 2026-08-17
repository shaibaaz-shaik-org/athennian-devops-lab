###############################################################################
# terraform/modules/ec2/main.tf
# EC2 Launch Template + Auto Scaling Group
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "ec2"
    Environment = var.environment
  })

  # Demonstrates map usage — environment-specific instance sizing
  environment_config = {
    dev = {
      instance_type     = "t3.small"
      min_size          = 1
      max_size          = 2
      desired_capacity  = 1
      volume_size       = 20
    }
    staging = {
      instance_type     = "t3.medium"
      min_size          = 1
      max_size          = 4
      desired_capacity  = 2
      volume_size       = 30
    }
    production = {
      instance_type     = "t3.large"
      min_size          = 2
      max_size          = 10
      desired_capacity  = 2
      volume_size       = 50
    }
  }

  # Select config for this environment, fall back to dev if unknown
  env_config = lookup(local.environment_config, var.environment, local.environment_config["dev"])

  # Allow overrides from variables
  instance_type    = var.instance_type != "" ? var.instance_type : local.env_config.instance_type
  min_size         = var.min_size > 0 ? var.min_size : local.env_config.min_size
  max_size         = var.max_size > 0 ? var.max_size : local.env_config.max_size
  desired_capacity = var.desired_capacity > 0 ? var.desired_capacity : local.env_config.desired_capacity
}

###############################################################################
# Security Group — EC2 Application Tier
###############################################################################

resource "aws_security_group" "app" {
  name        = "${var.project_name}-${var.environment}-app-sg"
  description = "Security group for application EC2 instances"
  vpc_id      = var.vpc_id

  # Demonstrates dynamic blocks for security group rules
  dynamic "ingress" {
    for_each = var.ingress_rules
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
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-app-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Launch Template
###############################################################################

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-${var.environment}-"
  image_id      = var.ami_id
  instance_type = local.instance_type

  # No key pair — SSH disabled, Session Manager used instead
  # key_name = "" # Intentionally omitted

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = local.env_config.volume_size
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 enforced — security hardening
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true  # Detailed CloudWatch monitoring
  }

  user_data = base64encode(templatefile("${path.module}/templates/userdata.sh.tpl", {
    environment      = var.environment
    project_name     = var.project_name
    aws_region       = var.aws_region
    log_group_name   = "/app/${var.project_name}/${var.environment}"
    s3_config_bucket = var.s3_config_bucket
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${var.environment}-app"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${var.environment}-app-volume"
    })
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

###############################################################################
# Auto Scaling Group
###############################################################################

resource "aws_autoscaling_group" "app" {
  name = "${var.project_name}-${var.environment}-asg"

  vpc_zone_identifier = var.app_subnet_ids
  target_group_arns   = var.target_group_arns

  min_size         = local.min_size
  max_size         = local.max_size
  desired_capacity = local.desired_capacity

  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_cooldown          = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Rolling update strategy — zero-downtime deployments
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 300
    }
  }

  # Demonstrates conditional — more aggressive termination in prod
  termination_policies = var.environment == "production" ? ["OldestInstance"] : ["Default"]

  dynamic "tag" {
    for_each = merge(local.common_tags, {
      Name = "${var.project_name}-${var.environment}-app"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]  # Don't fight with autoscaling
  }
}

###############################################################################
# Auto Scaling Policies
###############################################################################

# Scale out on high CPU
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.project_name}-${var.environment}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.app.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

# Scale in on low CPU
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.project_name}-${var.environment}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.app.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 600  # Longer cooldown to avoid thrashing
}

###############################################################################
# CloudWatch CPU Alarms for Scaling
###############################################################################

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale out when CPU exceeds 70% for 4 minutes"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.project_name}-${var.environment}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 20
  alarm_description   = "Scale in when CPU below 20% for 10 minutes"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  tags = local.common_tags
}

###############################################################################
# IAM Instance Profile (for SSM + CloudWatch access)
###############################################################################

resource "aws_iam_role" "app" {
  name = "${var.project_name}-${var.environment}-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "app_custom" {
  name = "${var.project_name}-${var.environment}-app-policy"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.app_s3_bucket}",
          "arn:aws:s3:::${var.app_s3_bucket}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.project_name}/${var.environment}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-${var.environment}-app-profile"
  role = aws_iam_role.app.name

  tags = local.common_tags
}
