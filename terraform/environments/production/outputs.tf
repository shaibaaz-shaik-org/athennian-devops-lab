###############################################################################
# terraform/environments/production/outputs.tf
###############################################################################

output "vpc_id"          { value = module.vpc.vpc_id }
output "alb_dns_name"    { value = module.alb.alb_dns_name }
output "asg_name"        { value = module.ec2.asg_name }
output "mongodb_primary" { value = module.mongodb.mongodb_primary_ip }
output "dashboard_url"   { value = module.monitoring.dashboard_url }

output "github_actions_role_arn" {
  value       = module.security.github_actions_role_arn
  description = "Add this to GitHub repo secrets as AWS_ROLE_ARN"
}

output "customer_resources" {
  value = { for k, v in module.customer_onboarding : k => {
    kms_key  = v.customer_kms_key_arn
    role_arn = v.customer_iam_role_arn
    secret   = v.customer_secret_arn
  }}
  sensitive = true
}
