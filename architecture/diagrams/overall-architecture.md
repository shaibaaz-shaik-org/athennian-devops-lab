# Overall Architecture — Athennian-Style AWS Infrastructure

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                          INTERNET                                    │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │       Route 53        │
                    │  (DNS + Health Checks) │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │       AWS WAF         │
                    │  (Web ACL attached    │
                    │   to ALB)             │
                    │  • OWASP Top 10       │
                    │  • Rate Limiting      │
                    │  • IP Reputation      │
                    │  • Geo Blocking       │
                    └───────────┬───────────┘
                                │
         ┌──────────────────────▼──────────────────────┐
         │         Application Load Balancer            │
         │         (HTTPS :443, HTTP→HTTPS :80)         │
         │         ACM Certificate (TLS 1.2+)           │
         │         Access Logs → S3                     │
         └──────────────┬──────────────┬───────────────┘
                        │              │
           ┌────────────▼─┐          ┌─▼────────────┐
           │   AZ-1 (a)   │          │   AZ-2 (b)   │
           │ Public Subnet│          │ Public Subnet│
           └────────────┬─┘          └─┬────────────┘
                        │              │
         ┌──────────────▼──────────────▼──────────────┐
         │           Auto Scaling Group                │
         │        (min: 2, desired: 2, max: 10)        │
         │         Rolling Update Policy               │
         └──────────────┬──────────────┬──────────────┘
                        │              │
           ┌────────────▼─┐          ┌─▼────────────┐
           │   AZ-1 (a)   │          │   AZ-2 (b)   │
           │ Private App  │          │ Private App  │
           │ Subnet       │          │ Subnet       │
           │ EC2 Instance │          │ EC2 Instance │
           └────────────┬─┘          └─┬────────────┘
                        │              │
         ┌──────────────▼──────────────▼──────────────┐
         │           Private DB Subnets                │
         │  ┌──────────────┐  ┌──────────────────────┐ │
         │  │   MongoDB    │  │    MongoDB Replica   │ │
         │  │   Primary    │  │    (AZ-2)            │ │
         │  │   (AZ-1)     │  │                      │ │
         │  └──────────────┘  └──────────────────────┘ │
         └─────────────────────────────────────────────┘
                        │
         ┌──────────────▼──────────────────────────────┐
         │              Supporting Services             │
         │                                              │
         │  S3 Buckets:          EventBridge:           │
         │  • app-data           • ASG Events           │
         │  • alb-logs           • MongoDB Alerts       │
         │  • terraform-state    • Customer Onboarding  │
         │  • backups                                   │
         │                                              │
         │  KMS Keys:            Secrets Manager:       │
         │  • EBS encryption     • DB credentials       │
         │  • S3 encryption      • API keys             │
         │  • RDS encryption     • Certificates         │
         └──────────────┬──────────────────────────────┘
                        │
         ┌──────────────▼──────────────────────────────┐
         │         Observability Layer                  │
         │                                              │
         │  CloudWatch:          SNS Topics:            │
         │  • Custom dashboards  • P0 (PagerDuty)       │
         │  • Log Insights       • P1 (Slack)           │
         │  • Alarms             • P2 (Email)           │
         │  • Container Insights                        │
         │                                              │
         │  VPC Flow Logs → S3 → Athena                 │
         └─────────────────────────────────────────────┘
```

---

## VPC Network Layout

```
VPC CIDR: 10.0.0.0/16

┌─────────────────────────────────────────────────────┐
│  AZ-1 (us-east-1a)          AZ-2 (us-east-1b)       │
│                                                      │
│  Public:  10.0.1.0/24       Public:  10.0.2.0/24    │
│  App:     10.0.11.0/24      App:     10.0.12.0/24   │
│  DB:      10.0.21.0/24      DB:      10.0.22.0/24   │
│                                                      │
│  NAT GW in each public subnet (HA)                   │
│  Internet GW attached to VPC                         │
└─────────────────────────────────────────────────────┘
```

---

## Security Zones

| Zone | Subnets | Access |
|---|---|---|
| Public | 10.0.1.0/24, 10.0.2.0/24 | ALB, NAT Gateway |
| Application | 10.0.11.0/24, 10.0.12.0/24 | EC2, SSM only (no SSH) |
| Database | 10.0.21.0/24, 10.0.22.0/24 | MongoDB, app tier only |

---

## Interview Talking Points

**Why EC2 over ECS/EKS?**
> "Athennian's environment is EC2-centric. Many legal-tech SaaS platforms rely on EC2 because of predictable pricing, compliance audit requirements that map well to fixed instances, and the complexity of containerising legacy applications. Kubernetes is available but it's not the primary workload platform — that mirrors many real-world mid-size SaaS companies."

**Why two AZs and not three?**
> "Cost vs. resilience trade-off. For a small team, two AZs give 99.99% availability SLA with the ALB. A third AZ adds 50% more NAT Gateway cost and more routing complexity. Most customers don't require three AZs unless they have specific compliance requirements."

**Why NAT Gateway per AZ?**
> "If you share a single NAT Gateway across AZs, you create a cross-AZ dependency. If AZ-1 goes down, your AZ-2 instances lose internet access. Two NAT Gateways eliminates this failure mode. Yes it costs more, but for a production legal-tech SaaS this is non-negotiable."
