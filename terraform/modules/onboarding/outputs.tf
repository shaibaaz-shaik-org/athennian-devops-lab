###############################################################################
# terraform/modules/onboarding/outputs.tf
###############################################################################

output "customer_kms_key_arn"   { value = aws_kms_key.customer.arn }
output "customer_s3_bucket_ids" { value = { for k, v in aws_s3_bucket.customer : k => v.id } }
output "customer_iam_role_arn"  { value = aws_iam_role.customer_app.arn }
output "customer_secret_arn"    { value = aws_secretsmanager_secret.customer_db.arn }
output "customer_log_group"     { value = aws_cloudwatch_log_group.customer.name }
