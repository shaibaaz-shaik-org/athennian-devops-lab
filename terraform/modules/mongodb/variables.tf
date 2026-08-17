###############################################################################
# terraform/modules/mongodb/variables.tf
###############################################################################

variable "project_name"          { type = string }
variable "environment"           { type = string }
variable "aws_region"            { type = string; default = "us-east-1" }
variable "vpc_id"                { type = string }
variable "db_subnet_ids"         { type = list(string) }
variable "app_security_group_id" { type = string }
variable "mongodb_ami_id"        { type = string }
variable "backup_bucket_arn"     { type = string }
variable "backup_bucket_name"    { type = string }
variable "admin_secret_arn"      { type = string; default = "" }
variable "alarm_sns_arns"        { type = list(string); default = [] }

variable "mongodb_admin_password" {
  type      = string
  sensitive = true
}

variable "backup_schedule" {
  type    = string
  default = "cron(0 2 * * ? *)"  # 2am UTC daily
}

variable "tags" {
  type    = map(string)
  default = {}
}
