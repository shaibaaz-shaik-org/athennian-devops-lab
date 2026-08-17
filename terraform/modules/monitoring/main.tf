###############################################################################
# terraform/modules/monitoring/main.tf
# CloudWatch Dashboards, Alarms, SNS Topics, Log Groups
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "monitoring"
    Environment = var.environment
  })

  # Alarm thresholds by environment — demonstrates map usage
  alarm_thresholds = {
    dev = {
      alb_5xx_threshold    = 50
      alb_latency_threshold = 5
      cpu_threshold         = 90
    }
    staging = {
      alb_5xx_threshold    = 20
      alb_latency_threshold = 3
      cpu_threshold         = 80
    }
    production = {
      alb_5xx_threshold    = 5
      alb_latency_threshold = 2
      cpu_threshold         = 70
    }
  }

  thresholds = lookup(local.alarm_thresholds, var.environment, local.alarm_thresholds["dev"])
}

###############################################################################
# SNS Topics — severity-tiered alerting
###############################################################################

resource "aws_sns_topic" "alerts" {
  for_each = toset(["p0-critical", "p1-high", "p2-medium"])

  name              = "${var.project_name}-${var.environment}-${each.key}"
  kms_master_key_id = var.kms_key_id

  tags = merge(local.common_tags, {
    Name     = "${var.project_name}-${var.environment}-${each.key}"
    Severity = each.key
  })
}

# SNS Subscriptions
resource "aws_sns_topic_subscription" "slack_p0" {
  count = var.slack_webhook_url != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts["p0-critical"].arn
  protocol  = "https"
  endpoint  = var.slack_webhook_url
}

resource "aws_sns_topic_subscription" "email_alerts" {
  for_each = toset(var.alert_email_addresses)

  topic_arn = aws_sns_topic.alerts["p1-high"].arn
  protocol  = "email"
  endpoint  = each.value
}

###############################################################################
# CloudWatch Log Groups
###############################################################################

resource "aws_cloudwatch_log_group" "app_logs" {
  for_each = toset([
    "/app/${var.project_name}/${var.environment}",
    "/mongodb/${var.project_name}/${var.environment}",
    "/aws/vpc/flow-logs/${var.project_name}-${var.environment}"
  ])

  name              = each.key
  retention_in_days = var.environment == "production" ? 90 : 30
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

###############################################################################
# CloudWatch Alarms — ALB
###############################################################################

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = local.thresholds.alb_5xx_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALB 5xx errors > ${local.thresholds.alb_5xx_threshold} — potential application issue"
  alarm_actions       = [aws_sns_topic.alerts["p0-critical"].arn]
  ok_actions          = [aws_sns_topic.alerts["p1-high"].arn]

  dimensions = { LoadBalancer = var.alb_arn_suffix }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"
  threshold           = local.thresholds.alb_latency_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALB p99 latency > ${local.thresholds.alb_latency_threshold}s"
  alarm_actions       = [aws_sns_topic.alerts["p1-high"].arn]

  dimensions = { LoadBalancer = var.alb_arn_suffix }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "alb_healthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-healthy-hosts"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_description   = "CRITICAL: No healthy hosts in ALB target group"
  alarm_actions       = [aws_sns_topic.alerts["p0-critical"].arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = local.common_tags
}

###############################################################################
# CloudWatch Dashboard — main ops dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Request Count & 5xx Errors"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix]
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Target Response Time (p50, p95, p99)"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p99", label = "p99" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ASG Instance Count"
          region = var.aws_region
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", var.asg_name],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", var.asg_name]
          ]
          period = 60
          stat   = "Average"
          view   = "timeSeries"
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Active Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.alb_5xx.arn,
            aws_cloudwatch_metric_alarm.alb_latency.arn,
            aws_cloudwatch_metric_alarm.alb_healthy_hosts.arn
          ]
        }
      }
    ]
  })
}

###############################################################################
# CloudWatch Log Metric Filters — detect application errors in logs
###############################################################################

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${var.project_name}-${var.environment}-app-errors"
  log_group_name = "/app/${var.project_name}/${var.environment}"
  pattern        = "[timestamp, level=ERROR*, ...]"

  metric_transformation {
    name          = "ApplicationErrors"
    namespace     = "${var.project_name}/${var.environment}"
    value         = "1"
    default_value = "0"
  }

  depends_on = [aws_cloudwatch_log_group.app_logs]
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${var.project_name}-${var.environment}-app-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApplicationErrors"
  namespace           = "${var.project_name}/${var.environment}"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Application error rate elevated"
  alarm_actions       = [aws_sns_topic.alerts["p1-high"].arn]
  treat_missing_data  = "notBreaching"

  tags = local.common_tags
}
