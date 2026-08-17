###############################################################################
# terraform/modules/ec2/outputs.tf
###############################################################################

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "asg_arn" {
  value = aws_autoscaling_group.app.arn
}

output "launch_template_id" {
  value = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  value = aws_launch_template.app.latest_version
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "app_iam_role_arn" {
  value = aws_iam_role.app.arn
}

output "app_iam_role_name" {
  value = aws_iam_role.app.name
}
