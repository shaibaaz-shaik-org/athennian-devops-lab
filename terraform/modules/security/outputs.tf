###############################################################################
# terraform/modules/security/outputs.tf
###############################################################################

output "kms_key_arns" {
  value = { for k, v in aws_kms_key.keys : k => v.arn }
}

output "kms_key_ids" {
  value = { for k, v in aws_kms_key.keys : k => v.key_id }
}

output "github_actions_role_arn" {
  value = length(aws_iam_role.github_actions) > 0 ? aws_iam_role.github_actions[0].arn : ""
}

output "github_oidc_provider_arn" {
  value = length(aws_iam_openid_connect_provider.github) > 0 ? aws_iam_openid_connect_provider.github[0].arn : ""
}

output "security_group_ids" {
  value = { for k, v in aws_security_group.custom : k => v.id }
}
