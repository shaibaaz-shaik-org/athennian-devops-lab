output "migration_log_group" { value = aws_cloudwatch_log_group.migration.name }
output "datasync_task_arn"   { value = length(aws_datasync_task.migration) > 0 ? aws_datasync_task.migration[0].arn : "" }
