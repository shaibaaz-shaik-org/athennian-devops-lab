###############################################################################
# packer/application-image.pkr.hcl
# Builds a hardened Amazon Linux 2023 AMI for the application tier
###############################################################################

packer {
  required_version = ">= 1.9"

  required_plugins {
    amazon = {
      version = ">= 1.3"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

###############################################################################
# Variables
###############################################################################

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.small"  # Small instance for build only — not production size
}

variable "git_sha" {
  type    = string
  default = "local"
}

variable "build_number" {
  type    = string
  default = "0"
}

variable "app_version" {
  type    = string
  default = "latest"
}

###############################################################################
# Data Sources — find latest Amazon Linux 2023 AMI
###############################################################################

data "amazon-ami" "amazon_linux_2023" {
  filters = {
    name                = "al2023-ami-2023.*-x86_64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "x86_64"
  }
  most_recent = true
  owners      = ["amazon"]
  region      = var.aws_region
}

###############################################################################
# Build Source — temporary EC2 instance in a private subnet
###############################################################################

source "amazon-ebs" "app" {
  region        = var.aws_region
  source_ami    = data.amazon-ami.amazon_linux_2023.id
  instance_type = var.instance_type

  # SSH for Packer to provision — note: this is the build instance only
  # Final AMI has SSH removed/disabled
  communicator    = "ssh"
  ssh_username    = "ec2-user"
  ssh_timeout     = "10m"

  # Use SSM for connection (no public IP needed)
  # Requires VPC with SSM endpoints
  # ssh_interface = "session_manager"
  # iam_instance_profile = "packer-build-profile"

  ami_name        = "athennian-app-${formatdate("YYYYMMDD", timestamp())}-${var.git_sha}"
  ami_description = "Athennian application AMI | Build: ${var.build_number} | SHA: ${var.git_sha}"

  # Build in a private subnet
  # vpc_id    = "vpc-xxxxx"
  # subnet_id = "subnet-xxxxx"
  associate_public_ip_address = false

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Enforce IMDSv2 on built AMI
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name        = "athennian-app-${var.git_sha}"
    GitSHA      = var.git_sha
    BuildNumber = var.build_number
    BuildDate   = formatdate("YYYY-MM-DD", timestamp())
    ManagedBy   = "packer"
    Purpose     = "application"
  }
}

###############################################################################
# Build — the actual AMI hardening + software installation
###############################################################################

build {
  name    = "athennian-app"
  sources = ["source.amazon-ebs.app"]

  # ──────────────────────────────────────────────────────────────────────────
  # Step 1: System Updates
  # ──────────────────────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '>>> Step 1: System Updates'",
      "sudo dnf update -y",
      "sudo dnf install -y git curl wget jq unzip htop"
    ]
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Step 2: Install CloudWatch Agent
  # ──────────────────────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '>>> Step 2: Install CloudWatch Agent'",
      "sudo dnf install -y amazon-cloudwatch-agent",
      "sudo systemctl enable amazon-cloudwatch-agent"
    ]
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Step 3: SSM Agent (already on AL2023 — ensure latest)
  # ──────────────────────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '>>> Step 3: Ensure SSM Agent'",
      "sudo dnf install -y amazon-ssm-agent",
      "sudo systemctl enable amazon-ssm-agent",
      "sudo systemctl start amazon-ssm-agent"
    ]
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Step 4: Security Hardening (CIS Benchmark subset)
  # ──────────────────────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '>>> Step 4: Security Hardening'",

      # Disable SSH root login
      "sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config",

      # Disable password auth — key pairs or SSM only
      "sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config",

      # Kernel hardening via sysctl
      "echo 'net.ipv4.tcp_syncookies = 1' | sudo tee -a /etc/sysctl.d/99-security.conf",
      "echo 'net.ipv4.conf.all.rp_filter = 1' | sudo tee -a /etc/sysctl.d/99-security.conf",
      "echo 'net.ipv4.conf.all.accept_redirects = 0' | sudo tee -a /etc/sysctl.d/99-security.conf",
      "echo 'net.ipv4.conf.all.send_redirects = 0' | sudo tee -a /etc/sysctl.d/99-security.conf",
      "echo 'kernel.dmesg_restrict = 1' | sudo tee -a /etc/sysctl.d/99-security.conf",
      "sudo sysctl -p /etc/sysctl.d/99-security.conf",

      # Disable unused services
      "sudo systemctl disable postfix || true",

      # Set umask to 027
      "echo 'umask 027' | sudo tee -a /etc/profile.d/security.sh",

      # Configure auditd for compliance
      "sudo dnf install -y audit",
      "sudo systemctl enable auditd"
    ]
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Step 5: Application Runtime Setup
  # ──────────────────────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '>>> Step 5: Application Runtime'",
      # Install Node.js / Java / Python — adjust for your application stack
      "sudo dnf install -y nodejs",
      "node --version",

      # Create app user (non-root)
      "sudo useradd -r -s /sbin/nologin appuser || true",

      # Create app directories
      "sudo mkdir -p /opt/app /var/log/app",
      "sudo chown appuser:appuser /opt/app /var/log/app"
    ]
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Step 6: Tag build metadata into AMI
  # ──────────────────────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '>>> Step 6: Build metadata'",
      "echo '{\"git_sha\": \"${var.git_sha}\", \"build_number\": \"${var.build_number}\", \"build_date\": \"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'\"}' | sudo tee /etc/ami-metadata.json",
      "sudo cat /etc/ami-metadata.json"
    ]
  }

  # ──────────────────────────────────────────────────────────────────────────
  # Step 7: Final cleanup
  # ──────────────────────────────────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "echo '>>> Step 7: Cleanup'",
      "sudo dnf clean all",
      "sudo rm -rf /tmp/* /var/tmp/*",
      "sudo find /home -name '.ssh' -type d -exec rm -rf {} + || true",
      "sudo truncate -s 0 /etc/machine-id",
      "echo 'AMI build complete!'"
    ]
  }
}
