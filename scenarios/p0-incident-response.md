# P0 Incident Response — ALB 503 Errors

## Scenario

**Alert**: CloudWatch alarm fires: `ALB 5xx errors > 5 in 60 seconds`
**Impact**: All customers unable to access the application
**Severity**: P0 — Critical

---

## Incident Response Timeline

```
T+00  CloudWatch alarm fires
      SNS → PagerDuty → on-call engineer paged

T+03  On-call acknowledges page
      Joins #incident-response Slack channel
      Declares P0 incident

T+05  Initial triage begins
      Open CloudWatch dashboard
      Open ALB metrics

T+10  Root cause investigation

T+30  Root cause identified

T+35  Remediation begins

T+45  Service restored

T+60  Post-incident monitoring

T+120 Incident closed

T+24h Post-mortem scheduled
```

---

## Triage Runbook

### Step 1 — Confirm the Problem (T+05)

```bash
# Check ALB target group health
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --region us-east-1

# Expected: all targets HealthStatus = "healthy"
# Problem: targets HealthStatus = "unhealthy" or count = 0
```

```bash
# Check ALB 5xx metrics for the last 30 minutes
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_ELB_5XX_Count \
  --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> \
  --start-time $(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum \
  --region us-east-1
```

---

### Step 2 — Log Analysis (T+08)

```bash
# CloudWatch Logs Insights — find error patterns
aws logs start-query \
  --log-group-name /app/athennian/production \
  --start-time $(date -d '30 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, @message
    | filter @message like /ERROR/
    | stats count(*) as errorCount by bin(1m)
    | sort @timestamp desc
    | limit 100
  ' \
  --region us-east-1

# Check ALB access logs in S3
aws s3 ls s3://athennian-production-alb-logs-ACCOUNTID/athennian/production/alb/ \
  --recursive | tail -20
```

---

### Step 3 — Networking Investigation (T+12)

```bash
# Check ASG instance count
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names athennian-production-asg \
  --query 'AutoScalingGroups[0].{
    Desired:DesiredCapacity,
    Min:MinSize,
    Max:MaxSize,
    InService:Instances[?LifecycleState==`InService`]|length(@)
  }' \
  --region us-east-1

# Check EC2 instance status
aws ec2 describe-instance-status \
  --filters "Name=instance-state-name,Values=running" \
  --region us-east-1 \
  --query 'InstanceStatuses[].{ID:InstanceId,Status:SystemStatus.Status}'

# Connect via Session Manager (no SSH needed)
aws ssm start-session \
  --target <instance-id> \
  --region us-east-1
```

---

### Step 4 — Common Root Causes and Fixes

#### Cause A: All EC2 instances terminated / unhealthy

```bash
# Check recent ASG activity
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name athennian-production-asg \
  --max-items 10 \
  --region us-east-1

# Check why instances are unhealthy
# → Look for: "Launch template version changed", "AMI not found", "Instance refresh"
```

**Fix**: If bad AMI deployed:
```bash
# Roll back to previous launch template version
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name athennian-production-asg \
  --launch-template LaunchTemplateId=<id>,Version='<previous-version>' \
  --region us-east-1

# Trigger instance refresh with previous version
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name athennian-production-asg \
  --preferences '{"MinHealthyPercentage": 50, "InstanceWarmup": 300}' \
  --region us-east-1
```

---

#### Cause B: Application crashed (OOM / unhandled exception)

```bash
# Connect to a running instance
aws ssm start-session --target <instance-id> --region us-east-1

# Check application logs on instance
sudo journalctl -u app.service -n 100 --no-pager

# Check memory
free -h
# Check disk
df -h
# Check for OOM kills
sudo dmesg | grep -i "out of memory"
```

**Fix**: Restart application service
```bash
sudo systemctl restart app.service
sudo systemctl status app.service
```

---

#### Cause C: Security group or WAF blocking traffic

```bash
# Check WAF blocked requests
aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 \
  --metric-name BlockedRequests \
  --dimensions Name=WebACL,Value=athennian-production-waf Name=Region,Value=us-east-1 Name=Rule,Value=ALL \
  --start-time $(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum \
  --region us-east-1

# Check WAF logs (CloudWatch Log Insights)
aws logs start-query \
  --log-group-name aws-waf-logs-athennian-production \
  --start-time $(date -d '30 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, action, httpRequest.clientIp, httpRequest.uri
    | filter action = "BLOCK"
    | stats count(*) by httpRequest.uri
    | sort count desc
  ' \
  --region us-east-1
```

**Fix**: Temporarily put WAF in count mode (NOT block) while investigating
```bash
# WARNING: Only do this if WAF is confirmed to be the cause
# This should be a short-term mitigation, not a long-term fix
aws wafv2 update-web-acl \
  --name athennian-production-waf \
  --scope REGIONAL \
  --default-action Allow={} \
  --region us-east-1
# ... update rules to count mode ...
```

---

#### Cause D: MongoDB connection failure

```bash
# Connect to app instance via SSM
aws ssm start-session --target <instance-id>

# Test MongoDB connectivity
mongosh "mongodb://<mongodb-private-ip>:27017" --eval "db.adminCommand('ping')"

# Check Secrets Manager for correct credentials
aws secretsmanager get-secret-value \
  --secret-id athennian/production/mongodb/admin \
  --region us-east-1 \
  --query 'SecretString'
```

---

### Step 5 — Rollback Procedure

```bash
# Option 1: Terraform rollback — revert to previous state
git log --oneline -10  # Find previous known-good commit
git checkout <previous-sha> -- terraform/environments/production/

# Re-apply previous configuration
cd terraform/environments/production
terraform init
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars" -auto-approve
```

```bash
# Option 2: ASG instance refresh with previous AMI
# Find previous AMI ID from git history or AWS console
PREVIOUS_AMI="ami-0previousgoodami"

# Update launch template
aws ec2 create-launch-template-version \
  --launch-template-id <lt-id> \
  --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"$PREVIOUS_AMI\"}" \
  --region us-east-1

# Trigger instance refresh
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name athennian-production-asg \
  --preferences '{"MinHealthyPercentage": 50}' \
  --region us-east-1
```

---

## Post-Incident Checklist

- [ ] Service restored and stable for 30 minutes
- [ ] All CloudWatch alarms back to OK state
- [ ] ALB target group showing all instances healthy
- [ ] Incident Slack channel updated with resolution
- [ ] Timeline documented in incident ticket
- [ ] Immediate mitigations documented
- [ ] Post-mortem meeting scheduled (within 48h)
- [ ] Action items created in backlog

---

## Interview Talking Points

**"Tell me about a P0 incident you handled."**

> "We had an incident where the ALB was returning 503s for all customers. My first action was to confirm the scope — I checked the ALB target group health and immediately saw zero healthy instances. The ASG had attempted to launch new instances but they were all failing health checks. I used CloudWatch Logs Insights to find that the application was crashing on startup with a MongoDB connection error. Tracing back further, I found a Secrets Manager rotation had changed the MongoDB credentials but the application hadn't been restarted. I restarted the application service via SSM Session Manager across all instances, verified health checks passed, and service was restored within 18 minutes of the alert. The post-mortem identified that we needed to add a rotation Lambda that also restarts the application when secrets rotate."

**"How do you handle incidents on a small team?"**

> "On a small team, you need to be very systematic because there's no-one to hand off to. My approach is: confirm the scope, log your actions as you go (even just in Slack), work through the most likely causes first, and never make a change without knowing how to revert it. The runbook exists because the worst time to figure out the commands is at 2am during an incident."
