# Troubleshooting Guide

## Common Issues and Resolutions

---

### 1. Terraform Init Fails — S3 Backend Access Denied

**Symptom**:
```
Error: Failed to get existing workspaces: S3 bucket does not exist.
```

**Cause**: Backend S3 bucket not yet created, or IAM permissions missing.

**Resolution**:
```bash
# First time: deploy the backend module
cd terraform/backend
terraform init -backend=false
terraform apply

# If permissions issue, verify your AWS role has S3 access
aws sts get-caller-identity
aws s3 ls s3://athennian-terraform-state-ACCOUNTID
```

---

### 2. Terraform Apply — Error Creating EC2 Instance (AMI not found)

**Symptom**:
```
Error: InvalidAMIID.NotFound: The image id 'ami-XXXXXXXX' does not exist
```

**Cause**: AMI ID in tfvars points to an AMI that doesn't exist in this region.

**Resolution**:
```bash
# Build a new AMI
cd packer/
packer build application-image.pkr.hcl

# Or find a valid base AMI
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --region us-east-1
```

---

### 3. ALB Health Check Failing

**Symptom**: Target group shows all instances as unhealthy. 503 responses from ALB.

**Diagnostic Steps**:
```bash
# Check what port the app is running on
aws ssm start-session --target <instance-id>
# Inside instance:
sudo ss -tlnp | grep LISTEN
# Should see app listening on port 8080

# Verify security group allows ALB to reach port 8080
aws ec2 describe-security-groups \
  --group-ids <app-sg-id> \
  --region us-east-1 \
  --query 'SecurityGroups[].IpPermissions'

# Test health check endpoint from inside the instance
curl -v http://localhost:8080/health
# Should return: HTTP/1.1 200 OK
```

**Common Causes**:
- Application not started (check `systemctl status app.service`)
- Wrong port in health check configuration
- Security group missing rule for ALB CIDR/SG
- Application returning non-200 on `/health` endpoint

---

### 4. MongoDB Connection Refused

**Symptom**: Application logs show `MongoNetworkError: connect ECONNREFUSED`

**Diagnostic Steps**:
```bash
# Verify MongoDB is running
aws ssm start-session --target <mongodb-instance-id>
sudo systemctl status mongod

# Check MongoDB is listening
sudo ss -tlnp | grep 27017

# Verify security group allows app tier
aws ec2 describe-security-groups \
  --group-ids <mongodb-sg-id> \
  --query 'SecurityGroups[].IpPermissions'

# Test from app instance (need to be on app instance)
aws ssm start-session --target <app-instance-id>
telnet <mongodb-private-ip> 27017
```

---

### 5. GitHub Actions OIDC Authentication Fails

**Symptom**:
```
Error: Could not assume role with OIDC
```

**Cause**: OIDC provider or IAM role trust policy misconfigured.

**Diagnostic Steps**:
```bash
# Verify OIDC provider exists
aws iam list-open-id-connect-providers

# Verify role trust policy
aws iam get-role \
  --role-name athennian-production-github-actions-role \
  --query 'Role.AssumeRolePolicyDocument'

# Check the sub condition matches your repo
# Should contain: repo:<org>/<repo>:*
```

**Resolution**: Run `terraform apply` on the security module to re-create the OIDC provider.

---

### 6. Terraform State Lock

**Symptom**:
```
Error: Error acquiring the state lock
Lock Info: ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Cause**: Previous Terraform run didn't release the lock (killed process, timeout).

**Resolution**:
```bash
# Verify no other terraform process is running
# Check GitHub Actions for running workflows

# If confirmed stale lock:
terraform force-unlock <lock-id>
# Lock ID is shown in the error message
```

---

### 7. WAF Blocking Legitimate Traffic

**Symptom**: Users report blocked requests; WAF CloudWatch showing high block count.

**Diagnostic Steps**:
```bash
# Check WAF logs for blocked requests
aws logs start-query \
  --log-group-name aws-waf-logs-athennian-production \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, terminatingRuleId, httpRequest.clientIp, httpRequest.uri
    | filter action = "BLOCK"
    | stats count(*) by terminatingRuleId, httpRequest.clientIp
    | sort count desc
    | limit 20
  ' \
  --region us-east-1
```

**Resolution Options**:
1. Add IP to allowlist IP set (for known good IPs)
2. Add exception to WAF rule (for false positives)
3. Switch blocking rule to counting mode temporarily (emergency only)

---

### 8. KMS Key Access Denied

**Symptom**: `AccessDenied` when trying to access encrypted S3 object or EBS volume.

**Cause**: IAM role doesn't have `kms:Decrypt` permission on the key.

**Resolution**:
```bash
# Check key policy
aws kms describe-key --key-id alias/athennian-production-s3
aws kms get-key-policy --key-id <key-id> --policy-name default

# Check role has kms:Decrypt in its IAM policy
aws iam get-role-policy \
  --role-name <role-name> \
  --policy-name <policy-name>
```

---

### 9. Drift Detected — Resolving Manual Changes

**Symptom**: Drift detection workflow creates a GitHub issue showing unexpected changes.

**Resolution Options**:

**Option A — Revert the change (restore Terraform-defined state)**:
```bash
terraform apply -var-file="terraform.tfvars"
# Terraform will revert the manual change
```

**Option B — Adopt the change into Terraform config**:
```bash
# First: update Terraform code to match current AWS state
# Then: run plan to confirm no changes
terraform plan -refresh-only -var-file="terraform.tfvars"
# Should show: "No changes. Infrastructure matches configuration."
```

**Option C — If resource was created manually and needs to be managed**:
```bash
# Import the resource into state
terraform import module.vpc.aws_subnet.public["az3"] subnet-0123456789abcdef0
terraform plan -var-file="terraform.tfvars"
```
