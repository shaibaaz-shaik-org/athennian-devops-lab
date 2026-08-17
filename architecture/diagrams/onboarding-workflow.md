# Customer Onboarding Workflow

## Overview

Customer onboarding is the most critical operational process. Every new customer requires isolated AWS resources, encryption keys, IAM policies, and monitoring — all provisioned automatically via Terraform.

---

## Onboarding Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    CUSTOMER REQUEST                          │
│                                                              │
│  Sales → tickets Jira/Linear story                          │
│  • Customer name                                             │
│  • Data residency requirement (region)                       │
│  • Expected data volume                                      │
│  • Compliance requirements (SOC2, HIPAA, etc.)               │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                  REQUIREMENT ANALYSIS                        │
│                                                              │
│  Platform Engineer reviews:                                  │
│  • Storage requirements → S3 bucket sizing                  │
│  • MongoDB storage → instance type selection                 │
│  • Expected concurrent users → ASG sizing                    │
│  • Backup retention requirements                             │
│  • Network isolation level needed                            │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│              TERRAFORM ONBOARDING MODULE                     │
│                                                              │
│  Engineer creates:                                           │
│  terraform/environments/production/customers/               │
│    customer-acme.tfvars                                      │
│                                                              │
│  customer_id        = "acme"                                 │
│  customer_name      = "Acme Corp"                            │
│  environment        = "production"                           │
│  data_retention_days = 365                                   │
│  enable_backups     = true                                   │
│  backup_schedule    = "0 2 * * *"                            │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │   STORAGE    │ │     IAM      │ │  MONITORING  │
    │              │ │              │ │              │
    │ S3 Bucket:   │ │ IAM Role:    │ │ CloudWatch   │
    │ acme-data    │ │ acme-app-role│ │ Dashboard    │
    │              │ │              │ │              │
    │ KMS Key:     │ │ IAM Policy:  │ │ Log Group:   │
    │ acme-kms-key │ │ acme-s3-     │ │ /app/acme    │
    │              │ │ policy       │ │              │
    │ Lifecycle:   │ │              │ │ Alarms:      │
    │ 365-day      │ │ Secrets Mgr: │ │ error rate   │
    │ retention    │ │ acme-db-creds│ │ latency      │
    └──────────────┘ └──────────────┘ └──────────────┘
              │              │              │
              └──────────────┼──────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                     MIGRATION                                │
│                                                              │
│  If migrating existing data:                                 │
│  1. Enable AWS DataSync or S3 Transfer Acceleration         │
│  2. MongoDB mongodump → mongorestore                         │
│  3. Validate record counts                                   │
│  4. Validate checksums                                       │
│  5. Run application smoke tests                              │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                     VALIDATION                               │
│                                                              │
│  Automated validation script:                                │
│  scripts/validate-customer-onboarding.sh acme               │
│                                                              │
│  ✓ S3 bucket exists and encrypted                           │
│  ✓ KMS key active                                           │
│  ✓ IAM role assumable                                       │
│  ✓ Secrets Manager secrets populated                         │
│  ✓ CloudWatch dashboard created                              │
│  ✓ SNS alerts configured                                     │
│  ✓ Application smoke tests pass                              │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                     PRODUCTION                               │
│                                                              │
│  • Customer is live                                          │
│  • Monitoring active                                         │
│  • Runbook created in docs/runbooks/                         │
│  • Customer ID tagged on all resources                       │
│  • Billing tagged for cost allocation                        │
└────────────────────────────────────────────────────────────┘
```

---

## Interview Talking Points

**"Walk me through how you onboard a new customer."**

> "When a new customer was signed, I owned the entire infrastructure provisioning process end-to-end. I built a Terraform onboarding module that took a single `.tfvars` file and provisioned everything — dedicated S3 buckets with customer-specific KMS encryption keys, IAM roles scoped only to that customer's resources, CloudWatch dashboards and log groups, Secrets Manager entries for database credentials, and SNS alert topics. The entire onboarding could be done in under 30 minutes with a single `terraform apply`. Before I built this module, onboarding was a multi-day manual process. I reduced it to a PR + pipeline run."

**"How did you handle customer data isolation?"**

> "Every customer gets a dedicated KMS key. All S3 objects, EBS volumes, and MongoDB backups are encrypted with that key. IAM policies use resource-level conditions scoped to the customer's specific S3 prefix and KMS key ARN. A bug in customer A's application can never accidentally write to customer B's S3 bucket because the IAM policy simply doesn't allow it. I also tag every resource with `customer_id` for cost allocation and audit purposes."
