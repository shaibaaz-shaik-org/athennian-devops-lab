#!/bin/bash
# MongoDB EC2 Initialisation Script
# Runs on first boot — sets up MongoDB replica set member
set -euo pipefail

REPLICA_SET="${replica_set_name}"
ROLE="${role}"
ADMIN_SECRET_ARN="${admin_secret_arn}"
AWS_REGION="${aws_region}"
BACKUP_BUCKET="${backup_bucket}"
LOG_GROUP="${log_group}"

# ---------------------------------------------------------------------------
# Install MongoDB 7.0
# ---------------------------------------------------------------------------
cat > /etc/yum.repos.d/mongodb-org-7.0.repo <<'EOF'
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/7.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-7.0.asc
EOF

yum install -y mongodb-org aws-cli jq amazon-cloudwatch-agent

# ---------------------------------------------------------------------------
# Mount data volume (/dev/sdb → /data/mongodb)
# ---------------------------------------------------------------------------
if ! blkid /dev/sdb; then
  mkfs.xfs /dev/sdb
fi

mkdir -p /data/mongodb
mount /dev/sdb /data/mongodb
echo "/dev/sdb /data/mongodb xfs defaults,noatime 0 0" >> /etc/fstab
chown -R mongod:mongod /data/mongodb

# ---------------------------------------------------------------------------
# Retrieve admin credentials from Secrets Manager
# ---------------------------------------------------------------------------
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$ADMIN_SECRET_ARN" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text | jq -r '.password' 2>/dev/null || echo "changeme")

# ---------------------------------------------------------------------------
# Configure MongoDB
# ---------------------------------------------------------------------------
cat > /etc/mongod.conf <<EOF
storage:
  dbPath: /data/mongodb
  wiredTiger:
    engineConfig:
      cacheSizeGB: 1

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 0.0.0.0

security:
  authorization: enabled
  keyFile: /etc/mongodb-keyfile

replication:
  replSetName: "$REPLICA_SET"
EOF

# Create keyfile for replica set auth
openssl rand -base64 756 > /etc/mongodb-keyfile
chmod 400 /etc/mongodb-keyfile
chown mongod:mongod /etc/mongodb-keyfile

# ---------------------------------------------------------------------------
# Start MongoDB
# ---------------------------------------------------------------------------
systemctl enable mongod
systemctl start mongod
sleep 10

# ---------------------------------------------------------------------------
# Initialise replica set (primary only)
# ---------------------------------------------------------------------------
if [ "$ROLE" = "primary" ]; then
  INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
  mongosh --eval "
    rs.initiate({
      _id: '$REPLICA_SET',
      members: [{ _id: 0, host: '$INSTANCE_IP:27017', priority: 2 }]
    })
  " || true
  sleep 5

  # Create admin user
  mongosh admin --eval "
    db.createUser({
      user: 'admin',
      pwd: '$ADMIN_PASSWORD',
      roles: ['root']
    })
  " || true
fi

# ---------------------------------------------------------------------------
# Configure automated backups via cron
# ---------------------------------------------------------------------------
cat > /usr/local/bin/mongodb-backup.sh <<BACKUP
#!/bin/bash
set -euo pipefail
DATE=\$(date +%Y/%m/%d/%H%M)
BACKUP_PATH="/tmp/mongodb-backup-\$DATE"
mkdir -p "\$BACKUP_PATH"

mongodump \
  --host localhost:27017 \
  --username admin \
  --password "$ADMIN_PASSWORD" \
  --authenticationDatabase admin \
  --oplog \
  --out "\$BACKUP_PATH"

tar -czf "\$BACKUP_PATH.tar.gz" -C "\$BACKUP_PATH" .

aws s3 cp "\$BACKUP_PATH.tar.gz" \
  "s3://$BACKUP_BUCKET/mongodb/\$DATE.tar.gz" \
  --sse aws:kms \
  --region "$AWS_REGION"

rm -rf "\$BACKUP_PATH" "\$BACKUP_PATH.tar.gz"

echo "Backup completed: \$DATE" | logger -t mongodb-backup
BACKUP

chmod +x /usr/local/bin/mongodb-backup.sh
echo "${backup_schedule} root /usr/local/bin/mongodb-backup.sh" >> /etc/crontab

# ---------------------------------------------------------------------------
# Configure CloudWatch agent
# ---------------------------------------------------------------------------
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/mongodb/mongod.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}/mongod",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "MongoDB/Custom",
    "metrics_collected": {
      "disk": {
        "measurement": ["disk_used_percent"],
        "resources": ["/data/mongodb"]
      },
      "mem": { "measurement": ["mem_used_percent"] }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json
