# Athennian-Style DevOps Demonstration Environment

> **Interview-ready AWS infrastructure project simulating a production legal-tech SaaS platform.**

---

## Overview

This repository demonstrates a complete, production-style AWS infrastructure built with Terraform, secured with AWS WAF + KMS, deployed via GitHub Actions CI/CD, and designed to handle customer onboarding, infrastructure migrations, and production operations at scale.

**This project is optimised for a 90-minute technical interview demonstration.**

---

## Architecture Summary

```
Internet
    │
  Route53  (DNS + Health Checks)
    │
  AWS WAF  (DDoS, OWASP Top 10, Rate Limiting)
    │
Application Load Balancer  (HTTPS, SSL Termination)
    │
Auto Scaling Group  (Multi-AZ, Rolling Deployments)
    │
EC2 Application Tier  (Private Subnets, SSM Access Only)
    │
┌──────────────┬──────────────┐
│              │              │
S3           MongoDB       EventBridge
(Encrypted)  (EC2-based)   (Automation)
│              │              │
└──────────────┴──────────────┘
        │
    CloudWatch + SNS
    (Monitoring + Alerting)
```

---

## Repository Structure

```
athennian-devops-lab/
├── README.md
├── architecture/
│   └── diagrams/
│       ├── overall-architecture.md
│       ├── onboarding-workflow.md
│       └── migration-workflow.md
├── terraform/
│   ├── backend/
│   ├── environments/
│   │   ├── dev/
│   │   ├── staging/
│   │   └── production/
│   └── modules/
│       ├── vpc/
│       ├── ec2/
│       ├── iam/
│       ├── alb/
│       ├── waf/
│       ├── s3/
│       ├── mongodb/
│       ├── monitoring/
│       ├── onboarding/
│       ├── migration/
│       └── security/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml
│       ├── terraform-apply.yml
│       ├── drift-detection.yml
│       ├── security-scan.yml
│       └── ami-build.yml
├── packer/
│   └── application-image.pkr.hcl
├── scripts/
├── docs/
│   ├── interview-guide.md
│   ├── troubleshooting.md
│   └── runbooks.md
└── scenarios/
    └── p0-incident-response.md
```

---

## Quick Start

### Prerequisites

- Terraform >= 1.6
- AWS CLI configured
- Packer >= 1.9
- GitHub repository with Actions enabled

### Deploy Dev Environment

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply
```

### Deploy via GitHub Actions

1. Push to a feature branch → triggers `terraform-plan.yml`
2. Open Pull Request → see plan output as PR comment
3. Merge to `main` → triggers `terraform-apply.yml` with manual approval gate

---

## Key Demonstration Topics

| Topic | Location |
|---|---|
| VPC + Networking | `terraform/modules/vpc/` |
| EC2 + ASG + ALB | `terraform/modules/ec2/`, `terraform/modules/alb/` |
| WAF + Security | `terraform/modules/waf/`, `terraform/modules/security/` |
| MongoDB | `terraform/modules/mongodb/` |
| Customer Onboarding | `terraform/modules/onboarding/` |
| Migration Workflow | `terraform/modules/migration/`, `architecture/diagrams/migration-workflow.md` |
| CI/CD Pipelines | `.github/workflows/` |
| Packer AMI Build | `packer/application-image.pkr.hcl` |
| Incident Response | `scenarios/p0-incident-response.md`, `docs/runbooks.md` |
| Interview Guide | `docs/interview-guide.md` |

---

## 90-Minute Demo Script

See [`docs/interview-guide.md`](docs/interview-guide.md) for the complete demonstration script.
