###############################################################################
# terraform/modules/alb/main.tf
# Application Load Balancer with HTTPS, access logs, and dynamic listeners
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = "alb"
    Environment = var.environment
  })
}

###############################################################################
# Security Group — ALB
###############################################################################

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Security group for ALB — public HTTPS/HTTP ingress only"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from internet (redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound to application tier"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  })
}

###############################################################################
# Application Load Balancer
###############################################################################

resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "production" ? true : false
  drop_invalid_header_fields = true  # Security: reject malformed headers

  access_logs {
    bucket  = var.access_logs_bucket
    prefix  = "${var.project_name}/${var.environment}/alb"
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-alb"
  })
}

###############################################################################
# Target Group
###############################################################################

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-${var.environment}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = var.health_check_path
    matcher             = "200"
    protocol            = "HTTP"
  }

  deregistration_delay = 30  # Drain connections for 30s before removing instance

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = var.enable_stickiness
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-tg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# ALB Listeners — demonstrates dynamic blocks
###############################################################################

# HTTP → HTTPS redirect
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.common_tags
}

# HTTPS listener with ACM certificate
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"  # TLS 1.3 preferred
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = local.common_tags
}

# Additional listener rules — demonstrates dynamic blocks
resource "aws_lb_listener_rule" "rules" {
  for_each = { for idx, rule in var.listener_rules : tostring(idx) => rule }

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  dynamic "action" {
    for_each = [each.value.action]
    content {
      type             = action.value.type
      target_group_arn = lookup(action.value, "target_group_arn", aws_lb_target_group.app.arn)
    }
  }

  dynamic "condition" {
    for_each = each.value.conditions
    content {
      dynamic "path_pattern" {
        for_each = condition.value.type == "path-pattern" ? [condition.value] : []
        content {
          values = path_pattern.value.values
        }
      }
      dynamic "host_header" {
        for_each = condition.value.type == "host-header" ? [condition.value] : []
        content {
          values = host_header.value.values
        }
      }
    }
  }

  tags = local.common_tags
}

###############################################################################
# WAF Association
###############################################################################

resource "aws_wafv2_web_acl_association" "alb" {
  count = var.waf_web_acl_arn != "" ? 1 : 0

  resource_arn = aws_lb.main.arn
  web_acl_arn  = var.waf_web_acl_arn
}
