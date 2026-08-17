###############################################################################
# terraform/modules/waf/main.tf
# AWS WAF v2 Web ACL — OWASP Top 10 + Rate Limiting + Geo Rules
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "waf"
    Environment = var.environment
  })

  # WAF rules defined as a map — demonstrates for_each + dynamic blocks
  managed_rule_groups = {
    AWSManagedRulesCommonRuleSet = {
      priority            = 10
      vendor_name         = "AWS"
      name                = "AWSManagedRulesCommonRuleSet"
      metric_name         = "AWSManagedRulesCommonRuleSetMetric"
      override_to_count   = false
    }
    AWSManagedRulesKnownBadInputsRuleSet = {
      priority            = 20
      vendor_name         = "AWS"
      name                = "AWSManagedRulesKnownBadInputsRuleSet"
      metric_name         = "AWSManagedRulesKnownBadInputsMetric"
      override_to_count   = false
    }
    AWSManagedRulesSQLiRuleSet = {
      priority            = 30
      vendor_name         = "AWS"
      name                = "AWSManagedRulesSQLiRuleSet"
      metric_name         = "AWSManagedRulesSQLiMetric"
      override_to_count   = false
    }
    AWSManagedRulesAmazonIpReputationList = {
      priority            = 40
      vendor_name         = "AWS"
      name                = "AWSManagedRulesAmazonIpReputationList"
      metric_name         = "AWSManagedRulesAmazonIpReputationMetric"
      override_to_count   = false
    }
  }
}

###############################################################################
# WAF Web ACL — demonstrates dynamic blocks
###############################################################################

resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project_name}-${var.environment}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Rate limiting rule — protect against brute force and DDoS
  rule {
    name     = "RateLimitRule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_requests_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${var.environment}-RateLimitMetric"
      sampled_requests_enabled   = true
    }
  }

  # Geo restriction — block traffic from high-risk countries (configurable)
  dynamic "rule" {
    for_each = length(var.blocked_country_codes) > 0 ? [1] : []
    content {
      name     = "GeoBlockRule"
      priority = 2

      action {
        block {}
      }

      statement {
        geo_match_statement {
          country_codes = var.blocked_country_codes
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.project_name}-${var.environment}-GeoBlockMetric"
        sampled_requests_enabled   = true
      }
    }
  }

  # IP allowlist — bypass all rules for trusted IPs (ops team, office)
  dynamic "rule" {
    for_each = length(var.allowed_ip_set_arns) > 0 ? [1] : []
    content {
      name     = "IPAllowlistRule"
      priority = 3

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = var.allowed_ip_set_arns[0]
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.project_name}-${var.environment}-IPAllowlistMetric"
        sampled_requests_enabled   = false
      }
    }
  }

  # AWS Managed Rule Groups — demonstrates dynamic blocks over a map
  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.key
      priority = rule.value.priority

      dynamic "override_action" {
        for_each = rule.value.override_to_count ? [1] : []
        content {
          count {}
        }
      }

      dynamic "override_action" {
        for_each = rule.value.override_to_count ? [] : [1]
        content {
          none {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = rule.value.vendor_name
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.metric_name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-WAFMetric"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

###############################################################################
# WAF Logging — captures blocked requests for security analysis
###############################################################################

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.project_name}-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name = "${var.project_name}-${var.environment}-waf-log-policy"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.waf.arn}:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

data "aws_caller_identity" "current" {}
