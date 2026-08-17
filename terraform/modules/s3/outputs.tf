###############################################################################
# terraform/modules/s3/outputs.tf
###############################################################################

output "bucket_ids" {
  value = { for k, v in aws_s3_bucket.buckets : k => v.id }
}

output "bucket_arns" {
  value = { for k, v in aws_s3_bucket.buckets : k => v.arn }
}
