###############################################################################
# terraform/modules/mongodb/outputs.tf
###############################################################################

output "mongodb_primary_ip"          { value = aws_instance.mongodb_primary.private_ip }
output "mongodb_primary_instance_id" { value = aws_instance.mongodb_primary.id }
output "mongodb_replica_ip"          { value = length(aws_instance.mongodb_replica) > 0 ? aws_instance.mongodb_replica[0].private_ip : "" }
output "mongodb_security_group_id"   { value = aws_security_group.mongodb.id }
output "mongodb_kms_key_arn"         { value = aws_kms_key.mongodb.arn }
output "mongodb_secret_arn"          { value = aws_secretsmanager_secret.mongodb_admin.arn }
