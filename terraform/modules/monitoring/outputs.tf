###############################################################################
# terraform/modules/monitoring/outputs.tf
###############################################################################

output "sns_topic_arns" {
  value = { for k, v in aws_sns_topic.alerts : k => v.arn }
}

output "p0_sns_arn" { value = aws_sns_topic.alerts["p0-critical"].arn }
output "p1_sns_arn" { value = aws_sns_topic.alerts["p1-high"].arn }
output "p2_sns_arn" { value = aws_sns_topic.alerts["p2-medium"].arn }
output "dashboard_url" { value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.project_name}-${var.environment}" }
