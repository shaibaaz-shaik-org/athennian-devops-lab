# Migration Workflow — On-Premises to AWS

## Overview

Migration from on-premises infrastructure to AWS is one of the most high-risk, high-value activities on the team. This document describes the end-to-end migration process with rollback capabilities at every stage.

---

## Migration Flow

```
┌─────────────────────────────────────────────────────────────┐
│                      DISCOVERY                               │
│                                                              │
│  Week 1-2                                                    │
│                                                              │
│  • Inventory all on-premises servers                         │
│  • Document OS versions, application versions                │
│  • Identify all inbound/outbound network connections         │
│  • Capture database sizes and backup schedules               │
│  • Document current backup/restore procedures                │
│  • Identify compliance and data residency requirements       │
│  • Document all secrets and credentials                      │
│                                                              │
│  Tools: AWS Application Discovery Service                    │
│         Manual spreadsheet inventory                         │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                   DEPENDENCY MAPPING                         │
│                                                              │
│  Week 2-3                                                    │
│                                                              │
│  App Server A ──────► Database Server                        │
│       │                    │                                 │
│       └────────────────────┤                                 │
│                            │                                 │
│  App Server B ──────► File Server (NFS)                      │
│                            │                                 │
│  Batch Jobs ────────► App Server A + Database                │
│                                                              │
│  Critical Finding:                                           │
│  Database must be migrated BEFORE App Servers                │
│  File Server must be migrated BEFORE Batch Jobs              │
│                                                              │
│  Migration Order:                                            │
│  1. Database (MongoDB)                                       │
│  2. File Storage (→ S3)                                      │
│  3. Application Servers (→ EC2 ASG)                          │
│  4. Batch Jobs (→ EventBridge + Lambda/EC2)                  │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                   INFRASTRUCTURE BUILD                       │
│                                                              │
│  Week 3-4                                                    │
│                                                              │
│  Terraform provisions AWS environment:                       │
│  • VPC + subnets + security groups                           │
│  • EC2 instances (sized to match on-prem)                    │
│  • MongoDB EC2 instance                                      │
│  • S3 buckets (replacing NFS)                                │
│  • IAM roles + policies                                      │
│  • VPN or Direct Connect to on-prem                          │
│                                                              │
│  ✓ Do not route production traffic yet                       │
│  ✓ Validate all security controls                            │
│  ✓ Test application connectivity                             │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                    DATA MIGRATION                            │
│                                                              │
│  Week 4-5                                                    │
│                                                              │
│  MongoDB Migration:                                          │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  On-Prem MongoDB                                     │    │
│  │       │                                              │    │
│  │  mongodump --host <on-prem-host> \                   │    │
│  │    --archive | mongorestore \                        │    │
│  │    --host <aws-host> --archive                       │    │
│  │       │                                              │    │
│  │  AWS MongoDB (EC2)                                   │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  File Migration (NFS → S3):                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  aws s3 sync /mnt/nfs-data \                         │    │
│  │    s3://customer-bucket/migrated-data/ \             │    │
│  │    --sse aws:kms \                                    │    │
│  │    --storage-class STANDARD_IA                       │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  Continuous Sync (while old system still running):           │
│  • Enable MongoDB oplog tailing for near-real-time sync      │
│  • Run nightly S3 sync jobs                                  │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                     VALIDATION                               │
│                                                              │
│  Week 5                                                      │
│                                                              │
│  scripts/validate-migration.sh                               │
│                                                              │
│  Database Validation:                                        │
│  ✓ Record count matches (on-prem vs AWS)                     │
│  ✓ Sample document spot-check (10,000 records)               │
│  ✓ Index validation (all indexes recreated)                  │
│  ✓ Application queries return expected results               │
│                                                              │
│  File Validation:                                            │
│  ✓ Object count matches                                      │
│  ✓ MD5 checksums match (sample 5%)                           │
│  ✓ Application can read/write S3                             │
│                                                              │
│  Application Validation:                                     │
│  ✓ All API endpoints return 200                              │
│  ✓ Login/authentication works                                │
│  ✓ Critical customer workflows complete successfully         │
│  ✓ Performance within acceptable bounds (p99 < 2s)           │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                      CUTOVER                                 │
│                                                              │
│  Week 6 (Maintenance Window: Saturday 2am-6am EST)           │
│                                                              │
│  T+00  Put application in maintenance mode                   │
│  T+05  Final MongoDB sync (catch remaining writes)           │
│  T+10  Validate final sync complete                          │
│  T+15  Update Route53 records to point to AWS ALB            │
│  T+20  Monitor ALB target health checks                      │
│  T+25  Run smoke tests against new endpoints                 │
│  T+30  Announce cutover complete                             │
│                                                              │
│  DNS TTL: Set to 60 seconds 24h before cutover               │
│           (normally 300s → faster rollback if needed)        │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                      ROLLBACK PLAN                           │
│                                                              │
│  If validation fails at cutover:                             │
│                                                              │
│  T+00  Detect failure (automated or manual)                  │
│  T+01  Revert Route53 to on-prem IP (60s TTL propagates)     │
│  T+02  Confirm on-prem application is responding             │
│  T+05  Page on-call + incident declared                      │
│  T+10  Root cause investigation begins                       │
│                                                              │
│  On-Prem remains in maintenance mode during rollback         │
│  (preserves data integrity — no writes to old system         │
│   while AWS was potentially partially active)                │
└────────────────────────────┬───────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────┐
│                    STABILIZATION                             │
│                                                              │
│  Week 6-8                                                    │
│                                                              │
│  • Monitor for 2 weeks post-cutover                          │
│  • Keep on-prem servers running (read-only standby)          │
│  • Validate backups are running on AWS schedule              │
│  • Tune auto-scaling policies based on real traffic          │
│  • Review CloudWatch dashboards for anomalies                │
│  • Decommission on-prem after 30 days (customer approval)    │
└────────────────────────────────────────────────────────────┘
```

---

## Interview Talking Points

**"Tell me about a migration you've led."**

> "I led the migration of a customer from their self-managed data centre to AWS. The most complex part wasn't the technology — it was the dependency mapping. We discovered the application had an undocumented NFS dependency that would have broken if we had migrated the app servers before the file storage. By doing thorough discovery upfront, we sequenced the migration correctly. We ran parallel sync jobs for two weeks before cutover, which meant the actual cutover window was only 30 minutes. We had a tested rollback plan — reduced DNS TTL to 60 seconds 24 hours before cutover, so if anything went wrong we could revert in under a minute."

**"How do you handle data integrity during migration?"**

> "We validated at multiple levels. First, document counts in MongoDB before and after. Second, we spot-checked 10,000 random records for data integrity. Third, we ran every critical customer workflow manually in the AWS environment before changing a single DNS record. The checklist wasn't optional — every item had to be checked by a second engineer. We didn't allow 'it should be fine' — every validation step produced a documented output."
