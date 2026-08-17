# Runbooks — Athennian Platform Operations

## Table of Contents

1. [Deploy a New Application Version](#deploy-new-version)
2. [Onboard a New Customer](#onboard-customer)
3. [Scale the ASG Manually](#scale-asg)
4. [Rotate MongoDB Credentials](#rotate-mongodb-credentials)
5. [Restore from Backup](#restore-backup)
6. [Investigate High Latency](#investigate-latency)
7. [Terraform State Recovery](#terraform-state-recovery)
8. [Add a Customer SSH Debug Session](#ssm-debug)

---

## 1. Deploy a New Application Version {#deploy-new-version}

**When**: New application code ready to ship
**Expected duration**: 15–30 minutes
**Risk**: Low (rolling deployment, no downtime)

```bash
# Step 1: Build new AMI (or trigger GitHub Actions workflow)
cd packer/
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  application-image.pkr.hcl

# Note the AMI ID from output: ami-XXXXXXXXXXXXXXXXX

# Step 2: Update the AMI in Terraform
# Edit terraform/environments/production/terraform.tfvars
# app_ami_id = "ami-XXXXXXXXXXXXXXXXX"

# Step 3: Plan the change
cd terraform/environments/production
terraform plan -var-file="terraform.tfvars"

# Step 4: Apply — this triggers ASG instance refresh
terraform apply -var-file="terraform.tfvars"

# Step 5: Monitor the instance refresh
watch -n 10 aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name athennian-production-asg \
  --region us-east-1 \
  --query 'InstanceRefreshes[0].{Status:Status,Progress:PercentageComplete}'

# Step 6: Verify health
aws elbv2 describe-target-health \
  --target-group-arn <tg-arn> \
  --region us-east-1 \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,Status:TargetHealth.State}'
```

**Rollback**: Revert `app_ami_id` to previous value and run `terraform apply`

---

## 2. Onboard a New Customer {#onboard-customer}

**When**: Sales confirms new customer
**Expected duration**: 30 minutes
**Risk**: Low (creates new resources, no existing ones modified)

```bash
# Step 1: Gather customer details
# - customer_id: short slug e.g. "acme" (lowercase, no spaces)
# - customer_name: full name e.g. "Acme Corp"
# - data_retention_days: usually 365 or 730
# - db_password: generate with: openssl rand -base64 32

# Step 2: Add customer to tfvars
# Edit terraform/environments/production/terraform.tfvars
# Add to customers = { ... }:
#
# acme = {
#   name                = "Acme Corp"
#   db_password         = "<generated-password>"
#   data_retention_days = 365
#   enable_backups      = true
# }

# Step 3: Store password securely BEFORE committing
aws secretsmanager create-secret \
  --name "athennian/production/customers/acme/db-password" \
  --secret-string "<generated-password>" \
  --region us-east-1

# Step 4: Plan and review
cd terraform/environments/production
terraform plan -var-file="terraform.tfvars" | grep -A 5 "acme"

# Step 5: Apply
terraform apply -var-file="terraform.tfvars" -target='module.customer_onboarding["acme"]'

# Step 6: Validate
bash scripts/validate-customer-onboarding.sh acme production

# Step 7: Create MongoDB user for customer
aws ssm start-session --target <mongodb-instance-id> --region us-east-1
# On the MongoDB instance:
# mongosh -u admin -p <admin-password>
# use acme
# db.createUser({ user: "acme", pwd: "<customer-db-password>", roles: ["readWrite"] })
```

---

## 3. Scale the ASG Manually {#scale-asg}

**When**: Anticipated traffic spike (product launches, marketing campaigns)
**Expected duration**: 5 minutes

```bash
# Pre-scale BEFORE the event
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name athennian-production-asg \
  --desired-capacity 6 \
  --region us-east-1

# Monitor scale-out
watch -n 15 aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-name athennian-production-asg \
  --query 'AutoScalingGroups[0].Instances[].{ID:InstanceId,State:LifecycleState}'

# After event — return to normal (or let auto-scaling handle it)
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name athennian-production-asg \
  --desired-capacity 2 \
  --region us-east-1
```

---

## 4. Rotate MongoDB Credentials {#rotate-mongodb-credentials}

**When**: Security policy (every 90 days), or suspected compromise
**Expected duration**: 20 minutes
**Risk**: Medium — application restart required

```bash
# Step 1: Generate new password
NEW_PASSWORD=$(openssl rand -base64 32)

# Step 2: Connect to MongoDB via SSM and add new password
aws ssm start-session --target <mongodb-primary-instance-id>
# On MongoDB:
# mongosh -u admin -p <old-password>
# db.updateUser("admin", { pwd: "<new-password>" })

# Step 3: Update Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id athennian/production/mongodb/admin \
  --secret-string "{\"password\":\"$NEW_PASSWORD\", ...other-fields...}" \
  --region us-east-1

# Step 4: Trigger application restart via SSM Run Command
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets '[{"Key":"tag:aws:autoscaling:groupName","Values":["athennian-production-asg"]}]' \
  --parameters '{"commands":["systemctl restart app.service"]}' \
  --region us-east-1

# Step 5: Verify health
aws elbv2 describe-target-health \
  --target-group-arn <tg-arn> \
  --region us-east-1
```

---

## 5. Restore from Backup {#restore-backup}

**When**: Data loss event, corruption, accidental deletion
**Expected duration**: 1–4 hours depending on data size
**Risk**: High — test procedure first in staging

### MongoDB Restore

```bash
# Step 1: Identify backup to restore
aws s3 ls s3://athennian-production-backups-ACCOUNTID/mongodb/ | sort -r | head -10

# Step 2: Download backup
aws s3 cp \
  s3://athennian-production-backups-ACCOUNTID/mongodb/2026/08/17/020000.tar.gz \
  /tmp/mongodb-restore.tar.gz

# Step 3: Connect to MongoDB via SSM
aws ssm start-session --target <mongodb-primary-instance-id>

# Step 4: Extract and restore
tar -xzf /tmp/mongodb-restore.tar.gz -C /tmp/restore/

mongorestore \
  --host localhost:27017 \
  --username admin \
  --password <password> \
  --authenticationDatabase admin \
  --oplogReplay \
  /tmp/restore/

# Step 5: Validate record counts
mongosh -u admin -p <password> --eval "
  db.getSiblingDB('<customer-db>').runCommand({dbStats: 1})
"
```

### S3 Object Restore

```bash
# S3 versioning is enabled — recover deleted object
aws s3api list-object-versions \
  --bucket athennian-production-app-data-ACCOUNTID \
  --prefix customer/acme/important-file.json

# Restore specific version
aws s3api copy-object \
  --bucket athennian-production-app-data-ACCOUNTID \
  --copy-source "athennian-production-app-data-ACCOUNTID/customer/acme/important-file.json?versionId=<version-id>" \
  --key "customer/acme/important-file.json"
```

---

## 6. Terraform State Recovery {#terraform-state-recovery}

**When**: State corruption, manual changes, `terraform import` needed

```bash
# List all resources in state
terraform state list

# Inspect a specific resource
terraform state show module.vpc.aws_vpc.main

# Remove a resource from state (without destroying it)
# Use when: resource was deleted manually, need to re-import
terraform state rm module.ec2.aws_instance.old_instance

# Import an existing resource into state
# Use when: resource exists in AWS but not in Terraform state
terraform import module.vpc.aws_vpc.main vpc-0123456789abcdef0

# Refresh state from actual AWS resources (drift check without planning changes)
terraform plan -refresh-only -var-file="terraform.tfvars"

# Unlock state if locked by failed run
terraform force-unlock <lock-id>

# Restore state from S3 versioning (if state file corrupted)
aws s3api list-object-versions \
  --bucket athennian-terraform-state-ACCOUNTID \
  --prefix production/terraform.tfstate

aws s3api copy-object \
  --bucket athennian-terraform-state-ACCOUNTID \
  --copy-source "athennian-terraform-state-ACCOUNTID/production/terraform.tfstate?versionId=<version-id>" \
  --key production/terraform.tfstate
```

---

## 7. SSM Debug Session {#ssm-debug}

**When**: Need to debug an EC2 instance (SSH is disabled)

```bash
# Start Session Manager session
aws ssm start-session \
  --target <instance-id> \
  --region us-east-1

# Port forwarding to remote service (e.g. MongoDB)
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["27017"],"localPortNumber":["27017"]}' \
  --region us-east-1

# Then connect locally:
mongosh "mongodb://localhost:27017"

# Run command across all ASG instances
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets '[{"Key":"tag:aws:autoscaling:groupName","Values":["athennian-production-asg"]}]' \
  --parameters '{"commands":["uptime && free -h && df -h"]}' \
  --output-s3-bucket-name athennian-production-backups-ACCOUNTID \
  --region us-east-1
```
