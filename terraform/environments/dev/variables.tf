variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "app_ami_id" {
  type    = string
  default = "ami-0c02fb55956c7d316" # Amazon Linux 2023
}
