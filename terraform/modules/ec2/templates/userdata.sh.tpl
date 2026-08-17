#!/bin/bash
# EC2 User Data — bootstraps instance on launch
# Runs on every new instance launched by the ASG
set -euo pipefail

# ---------------------------------------------------------------------------
# Variables injected by Terraform templatefile()
# ---------------------------------------------------------------------------
ENVIRONMENT="${environment}"
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
LOG_GROUP="${log_group_name}"
CONFIG_BUCKET="${s3_config_bucket}"

# ---------------------------------------------------------------------------
# System updates
# ---------------------------------------------------------------------------
yum update -y
yum install -y aws-cli jq

# ---------------------------------------------------------------------------
# Configure CloudWatch Agent
# ---------------------------------------------------------------------------
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json <<EOF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app/*.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}/app",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S"
          },
          {
            "file_path": "/var/log/messages",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}/system"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "$PROJECT_NAME/$ENVIRONMENT",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/"]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json

# ---------------------------------------------------------------------------
# Pull application config from S3 (if bucket set)
# ---------------------------------------------------------------------------
if [ -n "$CONFIG_BUCKET" ]; then
  aws s3 cp "s3://$CONFIG_BUCKET/config/$ENVIRONMENT/app.env" /etc/app.env || true
fi

# ---------------------------------------------------------------------------
# Signal that bootstrapping is complete
# ---------------------------------------------------------------------------
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 create-tags \
  --resources "$INSTANCE_ID" \
  --tags Key=BootstrapStatus,Value=complete \
  --region "$AWS_REGION" || true
