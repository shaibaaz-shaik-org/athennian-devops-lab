###############################################################################
# terraform/modules/vpc/main.tf
# Complete VPC module with multi-AZ networking
###############################################################################

locals {
  # Build subnet maps from the input variable — demonstrates `for_each` with maps
  public_subnets  = { for k, v in var.public_subnets : k => v }
  app_subnets     = { for k, v in var.app_subnets : k => v }
  db_subnets      = { for k, v in var.db_subnets : k => v }

  # Common tags applied to every resource this module creates
  common_tags = merge(var.tags, {
    Module      = "vpc"
    Environment = var.environment
  })
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
  })
}

###############################################################################
# Internet Gateway
###############################################################################

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

###############################################################################
# Public Subnets — for_each over map of AZ → CIDR
###############################################################################

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-public-${each.key}"
    Tier = "public"
  })
}

###############################################################################
# Private Application Subnets
###############################################################################

resource "aws_subnet" "app" {
  for_each = local.app_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-app-${each.key}"
    Tier = "application"
  })
}

###############################################################################
# Private Database Subnets
###############################################################################

resource "aws_subnet" "db" {
  for_each = local.db_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-db-${each.key}"
    Tier = "database"
  })
}

###############################################################################
# Elastic IPs for NAT Gateways (one per AZ)
###############################################################################

resource "aws_eip" "nat" {
  # One EIP per public subnet (one per AZ) — conditional to save cost in dev
  for_each = var.enable_nat_gateway ? local.public_subnets : {}

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-eip-${each.key}"
  })

  depends_on = [aws_internet_gateway.main]
}

###############################################################################
# NAT Gateways — one per AZ for HA (avoid cross-AZ dependency)
###############################################################################

resource "aws_nat_gateway" "main" {
  for_each = var.enable_nat_gateway ? local.public_subnets : {}

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-${each.key}"
  })

  depends_on = [aws_internet_gateway.main]
}

###############################################################################
# Route Tables
###############################################################################

# Public route table — routes internet traffic through IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-rt-public"
  })
}

# Private route tables — one per AZ, routes internet traffic through that AZ's NAT GW
resource "aws_route_table" "private" {
  for_each = local.public_subnets

  vpc_id = aws_vpc.main.id

  # Only add NAT route if NAT gateway is enabled
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []

    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[each.key].id
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-rt-private-${each.key}"
  })
}

###############################################################################
# Route Table Associations
###############################################################################

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  for_each = local.app_subnets

  subnet_id      = aws_subnet.app[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "db" {
  for_each = local.db_subnets

  subnet_id      = aws_subnet.db[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

###############################################################################
# VPC Endpoints — keeps S3/SSM traffic off the public internet
###############################################################################

# S3 Gateway endpoint (free — use always)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(
    [aws_route_table.public.id],
    [for rt in aws_route_table.private : rt.id]
  )

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-s3"
  })
}

# SSM Interface endpoints — required for Session Manager (no SSH)
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.app : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-ssm"
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.app : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-ssmmessages"
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.app : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-ec2messages"
  })
}

###############################################################################
# Security Group for VPC Endpoints
###############################################################################

resource "aws_security_group" "vpce" {
  name        = "${var.project_name}-${var.environment}-vpce-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpce-sg"
  })
}

###############################################################################
# VPC Flow Logs — captures all network traffic metadata for security analysis
###############################################################################

resource "aws_flow_log" "main" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-flow-logs"
  })
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/flow-logs/${var.project_name}-${var.environment}"
  retention_in_days = var.flow_log_retention_days

  tags = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.project_name}-${var.environment}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.project_name}-${var.environment}-flow-logs-policy"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}
