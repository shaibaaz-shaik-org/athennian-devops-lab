###############################################################################
# terraform/modules/vpc/outputs.tf
###############################################################################

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Map of public subnet IDs keyed by AZ short name"
  value       = { for k, v in aws_subnet.public : k => v.id }
}

output "app_subnet_ids" {
  description = "Map of application private subnet IDs keyed by AZ short name"
  value       = { for k, v in aws_subnet.app : k => v.id }
}

output "db_subnet_ids" {
  description = "Map of database private subnet IDs keyed by AZ short name"
  value       = { for k, v in aws_subnet.db : k => v.id }
}

output "public_subnet_ids_list" {
  description = "List of public subnet IDs"
  value       = [for k, v in aws_subnet.public : v.id]
}

output "app_subnet_ids_list" {
  description = "List of application private subnet IDs"
  value       = [for k, v in aws_subnet.app : v.id]
}

output "db_subnet_ids_list" {
  description = "List of database private subnet IDs"
  value       = [for k, v in aws_subnet.db : v.id]
}

output "nat_gateway_ids" {
  description = "Map of NAT Gateway IDs"
  value       = { for k, v in aws_nat_gateway.main : k => v.id }
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "vpce_sg_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpce.id
}
