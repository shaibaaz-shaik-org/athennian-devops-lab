# Interview Guide — Athennian DevOps Demonstration

> **This is your complete preparation guide for a 90-minute technical interview.**
> Read this document before every practice session.

---

## About This Environment

This project simulates the Athennian platform engineering environment:

- AWS as primary cloud (EC2-centric)
- Terraform as the primary IaC tool
- MongoDB on EC2
- GitHub Actions CI/CD (replacing Bitbucket Pipelines)
- Small team, high autonomy
- Customer onboarding + migrations = majority of work
- Sensitive legal data = security is non-negotiable

---

### Segment 1: Introduction and Architecture (0:00 – 0:10)

**Open**: `architecture/diagrams/overall-architecture.md`

**Say**:

> "Let me start by walking you through the architecture I've built.
>
> This represents a production-style AWS infrastructure for a legal-tech SaaS platform.
> The design is intentionally EC2-centric because that maps to how many mid-size SaaS companies actually run — not everyone is on Kubernetes.
>
> Traffic flows: Route53 → WAF → ALB → Auto Scaling Group across two AZs → Private EC2 instances.
> Storage tier: encrypted S3, MongoDB on EC2 with a replica in the second AZ.
> Observability: CloudWatch dashboards, log groups, SNS alerting by severity.
>
> Every decision here I can defend. Let me show you the code."

**Interview question you'll get**: _"Why EC2 and not ECS or EKS?"_
**Answer**: "For a small team, EC2 with a well-configured ASG is simpler to operate than Kubernetes. The team knows it, the tooling is mature, and the compliance audit trail maps cleanly to individual instances. Kubernetes is available when the complexity is justified — but on a small team it adds operational overhead without proportional benefit."

---

### Segment 2: Terraform Architecture (0:10 – 0:30)

**Open**: `terraform/` directory structure

**Say**:

> "Let me walk you through how I've structured the Terraform."

**Open**: `terraform/modules/vpc/main.tf`

**Point to**: `for_each` on subnets

> "Here's how I use `for_each` to create subnets from a map. The key insight is that the subnet map is an input variable, so the same module creates 2 AZs in dev and can be extended to 3 without touching the module code."

**Point to**: Dynamic blocks in route tables

> "Dynamic blocks on route tables — in dev I don't create a NAT Gateway to save cost. The dynamic block means no code duplication between dev and production."

**Open**: `terraform/environments/production/main.tf`

**Point to**: locals `environments` map

> "This is how I handle environment-specific sizing. The local map defines instance types, ASG sizes, whether WAF is enabled. Each environment picks its config from the map. This means a junior engineer can add a new environment without understanding the module internals — they just add an entry to the map."

**Point to**: `for_each` on customers

> "This is probably the most important architectural decision I made. Each customer is a map entry. When sales onboards a new customer, an engineer adds a single block to the tfvars file, pushes a PR, and the pipeline provisions a dedicated KMS key, three S3 buckets, an IAM role scoped to only that customer's resources, Secrets Manager entries, and a CloudWatch dashboard. Zero manual steps."

**Interview question you'll get**: _"How do you manage state?"_

**Open**: `terraform/backend/main.tf`

**Say**: "S3 backend with versioning enabled — this is the safety net. If state gets corrupted, I can restore from any point-in-time version via S3 versioning. DynamoDB for state locking — prevents two engineers or two pipeline runs from applying simultaneously and corrupting state. KMS encryption on both."

**Demo commands** (have these ready in a terminal):

```bash
terraform state list
terraform state show module.vpc.aws_vpc.main
terraform plan -refresh-only -var-file="terraform.tfvars"
```

---

### Segment 3: Security (0:30 – 0:45)

**Open**: `terraform/modules/security/main.tf`

**Point to**: OIDC section

**Say**:

> "GitHub Actions authenticates to AWS using OIDC — no long-lived access keys anywhere. When the pipeline runs, GitHub gets a short-lived JWT token, exchanges it with AWS STS for temporary credentials, and those credentials expire when the pipeline job finishes. If someone's GitHub account is compromised, there are no AWS keys to steal."

**Open**: `terraform/modules/waf/main.tf`

**Point to**: Dynamic blocks for managed rules

**Say**:

> "WAF protects the ALB with four AWS managed rule sets — OWASP Top 10, known bad inputs, SQL injection, and IP reputation list. Rate limiting blocks brute force at 2000 requests per 5 minutes. All of this is defined as code, not clicked through the console. The dynamic block means I can enable or disable rule groups per environment without changing the module."

**Open**: `terraform/modules/ec2/main.tf`

**Point to**: `http_tokens = "required"`

**Say**:

> "IMDSv2 enforced on all instances. This prevents a category of SSRF attacks where a compromised application could call the instance metadata service and steal the EC2 IAM role credentials. Enforcing IMDSv2 requires a session token, breaking that attack vector."

**Point to**: No `key_name` in launch template

**Say**:

> "SSH is disabled. There's no key pair on the launch template. Engineers access instances via AWS Session Manager — authenticated through IAM, fully audited, no inbound port 22 open anywhere. This also means we don't have to manage, rotate, or revoke SSH keys."

**Interview question you'll get**: _"What security controls do you consider non-negotiable?"_
**Answer**:

> "Four things I always implement regardless of timeline pressure: encryption at rest with KMS for all storage, IMDSv2 enforced, no public SSH, and no long-lived IAM access keys — everything authenticates via roles and OIDC. These are hygiene, not optional extras."

---

### Segment 4: Customer Onboarding (0:45 – 1:00)

**Open**: `architecture/diagrams/onboarding-workflow.md`

**Say**:

> "Customer onboarding was more than 50% of the team's work. I built a repeatable, automated process because manual onboarding doesn't scale and introduces errors."

**Open**: `terraform/modules/onboarding/main.tf`

**Walk through**:

1. Customer KMS key — dedicated per customer, separate from platform keys
2. S3 buckets via `for_each` — data, uploads, exports with different lifecycle policies
3. IAM policy — scoped to `Resource = customer's bucket ARN` only
4. Secrets Manager — connection string stored, encrypted with customer's key
5. CloudWatch log group + dashboard — customer-specific observability

**Say**:

> "The IAM policy deserves emphasis. The resource ARN in the policy is hardcoded to that customer's specific bucket. A bug in customer A's application — even if running under a misconfigured role — cannot access customer B's data. That's enforced at the AWS API level, not at the application level."

**Open**: `terraform/environments/production/terraform.tfvars.example`

**Show**: The `customers` block

**Say**:

> "To onboard a new customer, an engineer adds this block, opens a PR. The pipeline runs a plan showing exactly what will be created. After approval, the pipeline creates all resources. I reduced onboarding time from multi-day manual process to under 30 minutes."

---

### Segment 5: CI/CD Pipeline (1:00 – 1:10)

**Open**: `.github/workflows/terraform-plan.yml`

**Walk through the jobs**:

1. `terraform-fmt` — "catches formatting issues before they reach code review"
2. `terraform-validate` — "syntax check without AWS credentials — catches typos"
3. `tflint` — "catches AWS-specific mistakes, deprecated arguments, missing required fields"
4. `checkov` — "security scanning against 1000+ policies. Stops the pipeline if we're about to deploy an unencrypted S3 bucket"
5. `terraform-plan` — "runs against real AWS, posts the exact plan as a PR comment — reviewers see what will change before they approve"

**Open**: `.github/workflows/terraform-apply.yml`

**Point to**: `environment: production` on the deploy job

**Say**:

> "Production deploy requires a manual approval. In GitHub, I configure the `production` environment with required reviewers — a PR can't deploy to production without a second engineer approving. This is enforced by GitHub's environment protection rules, not by convention."

**Open**: `.github/workflows/drift-detection.yml`

**Say**:

> "This runs daily at 6am. `terraform plan -refresh-only -detailed-exitcode` — exit code 2 means drift detected. If it detects drift, it automatically creates a GitHub issue with the details and pings the Slack channel. On a small team, we can't afford undocumented changes silently accumulating in production."

---

### Segment 6: MongoDB (1:10 – 1:18)

**Open**: `terraform/modules/mongodb/main.tf`

**Say**:

> "MongoDB on EC2 rather than Atlas or DocumentDB — this is a deliberate choice reflecting real-world constraints. Many customers have compliance requirements around data residency that are easier to satisfy with self-managed instances. The team has existing MongoDB expertise. And for the data volumes we're dealing with, the per-GB cost of Atlas at scale is significantly higher."

**Point to**: Instance sizing map

**Say**:

> "Production uses io2 volumes with 10,000 IOPS — MongoDB is I/O intensive and the application's p99 latency SLA requires fast storage. Dev uses gp3 to keep costs down."

**Point to**: Backup script in template

**Say**:

> "Nightly `mongodump` to S3, encrypted with the customer's KMS key. The backup includes `--oplog` for point-in-time recovery — you can replay the oplog to recover to any specific timestamp within the backup window, not just the midnight snapshot."

**Interview question**: _"How does MongoDB differ from RDS in your operations?"_
**Answer**: "MongoDB means I own the patching, the replication setup, the backup testing, the query performance tuning. RDS offloads that to AWS. The trade-off: MongoDB gives more control and lower cost at scale; RDS gives less operational burden. For a small team, either is defensible — the key is being intentional about the choice."

---

### Segment 7: Incident Response Demo (1:18 – 1:28)

**Open**: `scenarios/p0-incident-response.md`

**Say**:

> "Let me walk through how I'd handle a P0. The scenario: ALB returning 503s, all customers affected."

**Walk through the timeline** — T+00 through T+45.

**Show the diagnostic commands** — especially:

```bash
aws elbv2 describe-target-health --target-group-arn <arn>
aws ssm start-session --target <instance-id>
```

**Say**:

> "The Session Manager command is important — we don't have SSH. I can still get a shell on any instance within seconds, fully audited by CloudTrail. When I need to debug at 2am, I don't want to be hunting for the right SSH key."

**Point to rollback section**

**Say**:

> "Every incident response starts by identifying the revert action before touching anything. If the fix makes things worse, how do I undo it? For a deployment gone wrong, I know which previous AMI to roll back to. For a config change, I revert the commit and trigger the pipeline. Rollback is always planned, never improvised."

---

### Segment 8: Migration Story (1:28 – 1:35)

**Open**: `architecture/diagrams/migration-workflow.md`

**Say**:

> "Migrations were a significant part of the work. Let me walk through the process."

**Hit the key points**:

1. **Discovery** — "the most underestimated phase. You cannot migrate what you don't fully understand."
2. **Dependency mapping** — "we found an undocumented NFS dependency that would have broken the migration had we not discovered it"
3. **Cutover window** — "DNS TTL reduced to 60 seconds 24h before. Rollback is a DNS change, not an application change — propagates in under a minute."
4. **Validation** — "every validation step required sign-off from a second engineer. No 'it should be fine.'"

---

### Segment 9: Wrap Up (1:35 – 1:40)

**Say**:

> "To summarise what I've built here:
>
> - Production-style AWS infrastructure across two AZs
> - Terraform modules with `for_each`, dynamic blocks, conditionals — everything you'd expect in a mature codebase
> - GitHub Actions CI/CD with security scanning, plan comments, and manual approval gates
> - Customer onboarding automation that scales
> - Operational tooling: drift detection, runbooks, incident response procedures
>
> What I haven't built that would exist in a real environment: a proper test harness for Terraform modules (Terratest), service mesh for east-west traffic, and a more sophisticated observability stack. But this represents the core platform that everything else builds on."

---

## Common Interview Questions and Answers

### "How do you handle a situation where Terraform state doesn't match reality?"

> "I run `terraform plan -refresh-only` to see exactly what drifted. If the drift represents an intentional change that should be kept, I update the Terraform code and import the resource. If it's an unauthorised change, I document it in a GitHub issue, investigate how it happened, and apply Terraform to revert. The daily drift detection pipeline means we catch these within 24 hours rather than discovering them during the next deployment."

### "How do you manage secrets in Terraform?"

> "Secrets never live in Terraform state if I can help it. Database passwords are passed as variables marked `sensitive = true` and stored in GitHub environment secrets. The Secrets Manager resources themselves are managed by Terraform, but the secret values are populated via AWS CLI or the console — not through `terraform apply`. For customer credentials, I generate them separately and store in Secrets Manager before running the Terraform onboarding."

### "How do you handle a change that requires downtime?"

> "First question: does it actually require downtime? Most changes can be done with blue-green or rolling deployment. If downtime is unavoidable, I schedule a maintenance window, communicate it to customers with 48 hours notice, prepare the rollback procedure in writing, and have a second engineer available. The actual maintenance window is usually under an hour because everything has been tested in staging first."

### "What's your approach to cost management?"

> "Tag everything with Environment and Project. Use AWS Cost Explorer to track spend by tag. Dev environment: single NAT Gateway, no WAF, smaller instances, no replicas — probably 20% of production cost. Auto Scaling ensures we're not paying for idle capacity. S3 lifecycle policies move old data to cheaper storage tiers automatically. Monthly cost review is a standing agenda item."

### "How do you approach infrastructure security reviews?"

> "Security is in the pipeline, not in a periodic review. Checkov runs on every PR and will fail the build if an unencrypted resource is being created. TruffleHog scans for secrets in every commit. The security scan workflow checks for open ports and missing IMDSv2 enforcement. Security controls aren't a checkpoint at the end — they're gates throughout the development process."

### "Tell me about a time you reduced toil."

> "Customer onboarding was a 2-day manual process — spin up resources in the console, configure permissions by hand, set up monitoring by hand. I built the Terraform onboarding module, which takes a single tfvars entry and provisions everything automatically. I also wrote a validation script that checks every resource was created correctly and the application can connect. What took two days now takes 30 minutes, and the error rate dropped to near zero because computers don't make copy-paste mistakes."

---

## Pre-Interview Checklist

- [ ] Read through this guide the morning of the interview
- [ ] Have VS Code open with this project
- [ ] Have a terminal ready with AWS CLI configured (or mocked outputs)
- [ ] Know the architecture diagram from memory
- [ ] Practice the onboarding story out loud (3 minutes)
- [ ] Practice the incident response story out loud (3 minutes)
- [ ] Have `terraform state list` output ready to show
- [ ] Know the answer to "why MongoDB instead of RDS"
- [ ] Know the answer to "how do you handle state"

---

## Architecture Decision Records

| Decision        | Choice                    | Rationale                                                              |
| --------------- | ------------------------- | ---------------------------------------------------------------------- |
| IaC tool        | Terraform                 | Industry standard, strong AWS provider, HCL readable                   |
| CI/CD           | GitHub Actions            | Replaces Bitbucket, native OIDC, environment protection gates          |
| Compute         | EC2 + ASG                 | EC2-centric environment, compliance, team expertise                    |
| Database        | MongoDB on EC2            | Existing expertise, data residency, cost at scale                      |
| Instance access | SSM Session Manager       | No SSH keys, full audit trail, works in private subnets                |
| Encryption      | KMS per customer          | Customer data isolation, compliance, key revocation possible           |
| NAT Gateway     | One per AZ in prod        | Eliminate cross-AZ failure dependency                                  |
| State backend   | S3 + DynamoDB             | Standard pattern, versioning for recovery, locking prevents corruption |
| WAF             | AWS WAFv2 + managed rules | OWASP Top 10 without maintaining rule signatures                       |
