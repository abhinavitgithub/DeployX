# DeployX — AWS Cloud Infrastructure & Deployment Runbook (Phase 9)

This document provides complete technical specifications, architecture diagrams, step-by-step provisioning guides, security policies, and cost analysis for DeployX's AWS Infrastructure as Code (IaC).

---

## 🏗️ 1. Architecture Overview

DeployX provisions a secure, multi-Availability Zone AWS environment using Terraform:

```
VPC: 10.0.0.0/16 (us-east-1)
├── Public Subnet 1:  10.0.1.0/24 (us-east-1a) -> EC2 Docker Host (AL2023)
├── Public Subnet 2:  10.0.2.0/24 (us-east-1b)
├── Private Subnet 1: 10.0.10.0/24 (us-east-1a)
└── Private Subnet 2: 10.0.20.0/24 (us-east-1b)
```

### Core Subsystems
1. **Compute Layer:** Amazon Linux 2023 EC2 instance (`t3.micro` / `t3.small`) bootstrapped with Docker, Compose, and the Amazon CloudWatch Agent via cloud-init. The application runs as a systemd service (`deployx.service`) with auto-restart on host reboot.
2. **Network Security:** Security groups enforcing Principle of Least Privilege:
   - Ingress HTTP (80) & HTTPS (443) open to allowed CIDRs.
   - Internal backend port (8000) restricted strictly to VPC internal CIDR (`10.0.0.0/16`).
   - SSH (port 22) disabled by default. Terminal access is managed via **AWS Systems Manager (SSM) Session Manager**, requiring zero open ports and zero SSH keys.
3. **Disaster Recovery Storage (S3):** Dedicated S3 bucket with:
   - 4x Public Access Block (complete public isolation).
   - Default AES-256 server-side encryption.
   - S3 Versioning enabled for object rollback protection.
   - Automated lifecycle policy transitioning archives to `STANDARD_IA` after 30 days and expiring after 90 days (staging) or 180 days (production).
   - Enforced TLS-in-transit bucket policy denying unencrypted requests.
4. **Observability (CloudWatch):**
   - CloudWatch Log Group (`/deployx/<env>`) with 14-day retention.
   - Metric Alarms: CPU Utilization > 80% and StatusCheckFailed > 0.
   - Centralized streaming of `/var/log/deployx-init.log` and `/opt/deployx/data/deployx_operations.log`.
5. **Keyless CI/CD (GitHub OIDC):**
   - IAM role trusting GitHub Actions OIDC provider (`token.actions.githubusercontent.com`).
   - Scoped strictly to repository `repo:abhinavitgithub/DeployX:*`.
   - Zero long-lived AWS IAM access keys stored in GitHub Secrets.

---

## 🔒 2. Verification Levels & Distinction Matrix

To maintain absolute technical integrity, DeployX strictly delineates between verification levels:

| Verification Tier | Scope & Tooling | Execution Status |
|---|---|---|
| **Tier 1: Local Static Validation** | `terraform fmt -check`, `terraform validate`, `tflint`, `pytest -v tests/test_aws_terraform.py` (10 tests), `ruff check` | ✅ **VERIFIED (100% Passed)** |
| **Tier 2: Speculative Plan Validation** | `terraform plan -var-file=environments/staging.tfvars.example` against live AWS credentials | ⏳ Ready for Operator Credentials |
| **Tier 3: Actual Cloud Provisioning** | `terraform apply` creating real VPC, EC2, S3, IAM, and CloudWatch resources | 🛑 Controlled: Requires User Approval |
| **Tier 4: Live Cloud Verification** | Live HTTP probe against EC2 Public IP (`http://<public-ip>:80/health/live`) | 🛑 Post-Deployment Only |

---

## 🚀 3. Step-by-Step Operator Runbook

### Prerequisites
- AWS CLI v2 installed and configured (`aws configure` or SSO session).
- Terraform v1.5+ installed (`terraform version`).
- Amazon Linux 2023 AMI access in target region (default `us-east-1`).

### Step 1: Initialize Terraform
```bash
cd infrastructure/aws/terraform

# Initialize with local state backend for testing:
terraform init -backend=false

# Validate syntax:
terraform validate
```

### Step 2: Speculative Infrastructure Plan
```bash
# Review proposed resource additions without creating cloud infrastructure:
terraform plan -var-file=environments/staging.tfvars.example
```

### Step 3: Apply Infrastructure (With Explicit Approval)
```bash
# Apply changes only after human review:
terraform apply -var-file=environments/staging.tfvars.example
```

### Step 4: Validate Live Workloads
```bash
# Get application URL:
APP_URL=$(terraform output -raw application_url)
echo "Access DeployX Dashboard at: $APP_URL"

# Test health probe:
curl -i "$APP_URL/health/live"

# Start secure terminal session via SSM:
$(terraform output -raw ssm_connect_command)
```

### Step 5: Disaster Recovery Replication
Using the Phase 7 automation scripts, sync backup archives directly to the provisioned S3 bucket:
```bash
# Linux Bash:
./scripts/linux/backup.sh --s3-bucket $(terraform output -raw s3_backup_bucket_name)

# Windows PowerShell:
.\scripts\windows\backup.ps1 -S3Bucket $(terraform output -raw s3_backup_bucket_name)
```

### Step 6: Resource Teardown & Cost Elimination
```bash
# Destroy all provisioned resources when testing concludes:
terraform destroy -var-file=environments/staging.tfvars.example
```

---

## 💰 4. Financial Controls & Cost Containment

1. **Free Tier Compatibility:** The default staging configuration uses `t3.micro` (750 hours/month free) and 20 GiB GP3 storage (30 GiB free).
2. **NAT Gateway Avoidance:** By default, `enable_nat_gateway = false`. Deploying an AWS NAT Gateway adds ~$32.40/month per availability zone. Keeping it optional avoids accidental charges while maintaining the option for enterprise private deployments.
3. **Log Retention Limits:** CloudWatch Logs retention is capped at 14 days (staging) or 30 days (production) to prevent unbounded storage accumulation.
4. **S3 Lifecycle Expiration:** Backups transition to Standard-IA after 30 days and permanently expire after 90 days.
