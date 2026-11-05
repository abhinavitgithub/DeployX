# DeployX — AWS Cloud Infrastructure as Code (Terraform)

This directory contains the production-grade, modular Terraform architecture for deploying the **DeployX Intelligent Cloud Deployment Platform** onto Amazon Web Services (AWS).

---

## 🏗️ AWS Cloud Architecture

```mermaid
flowchart TD
    Internet([Internet / Public Users]) -->|HTTP Port 80 / HTTPS Port 443| IGW[AWS Internet Gateway]
    Operator([DevOps Operator]) -->|AWS SSM Session Manager<br/>(Zero Open Ports)| SSM[AWS Systems Manager]

    subgraph AWS["AWS Cloud (Region: us-east-1)"]
        subgraph VPC["Custom VPC: deployx-staging-vpc (10.0.0.0/16)"]
            IGW --> PubSubnet1["Public Subnet 1 (10.0.1.0/24)<br/>AZ: us-east-1a"]
            IGW --> PubSubnet2["Public Subnet 2 (10.0.2.0/24)<br/>AZ: us-east-1b"]

            subgraph PublicCompute["Public Compute Tier"]
                PubSubnet1 --> EC2["EC2 Instance (Amazon Linux 2023)<br/>t3.micro (Free Tier) | IMDSv2<br/>GP3 Encrypted (20 GiB)"]

                subgraph Containers["Docker & Compose Stack"]
                    EC2 --> FE_CTR["Nginx Frontend Container<br/>Port 80 (Reverse Proxy & Dashboard)"]
                    FE_CTR -->|Internal Network: deployx-network<br/>http://backend:8000| BE_CTR["FastAPI Backend Container<br/>Port 8000 (Metrics, Probes, State)"]
                end
            end

            PrivSubnet1["Private Subnet 1 (10.0.10.0/24)<br/>AZ: us-east-1a"]
            PrivSubnet2["Private Subnet 2 (10.0.20.0/24)<br/>AZ: us-east-1b"]
        end

        subgraph IAM_Security["IAM & Security Controls"]
            EC2_ROLE["IAM Role & Instance Profile<br/>• AmazonSSMManagedInstanceCore<br/>• Scoped S3 Backup Access<br/>• Scoped CloudWatch Logs"]
            EC2 --> EC2_ROLE
            SSM -.->|Secure Tunnel| EC2
        end

        subgraph Storage["Disaster Recovery Storage"]
            S3["S3 Backup Bucket: deployx-staging-backups-xxxx<br/>• Public Access Blocked (All 4)<br/>• AES-256 Encryption at Rest<br/>• Object Versioning Enabled<br/>• Lifecycle: IA @ 30d, Expire @ 90d<br/>• Enforced TLS in Transit"]
            EC2 -.->|Replicate Backups<br/>aws s3 cp| S3
        end

        subgraph Monitoring["Observability & Alarms"]
            CW_LOGS["CloudWatch Log Group: /deployx/staging<br/>Retention: 14 Days<br/>Streams: cloud-init, operations, messages"]
            CW_ALARM1["CloudWatch Metric Alarm: CPU > 80%"]
            CW_ALARM2["CloudWatch Metric Alarm: StatusCheckFailed"]
            SNS["SNS Topic: deployx-staging-alerts-topic"]

            EC2 -.->|Stream Logs via CW Agent| CW_LOGS
            EC2 -.->|Host Metrics| CW_ALARM1 & CW_ALARM2
            CW_ALARM1 & CW_ALARM2 --> SNS
        end
    end

    subgraph CICD["GitHub Actions CI/CD"]
        GHA[GitHub Actions Runner] -->|OIDC Token Exchange<br/>sts:AssumeRoleWithWebIdentity| GHA_ROLE["IAM Role: deployx-staging-github-actions-role<br/>Trust: repo:abhinavitgithub/DeployX:*"]
        GHA_ROLE -.->|Speculative Plan / Apply| AWS
    end
```

---

## 📂 Terraform File Catalog

| File | Purpose | Key Resources Provisioned |
|---|---|---|
| [`versions.tf`](terraform/versions.tf) | Provider & Terraform version constraints | Terraform `>= 1.5.0, < 2.0.0`, AWS provider `~> 5.0`, Random `~> 3.6`, CloudInit `~> 2.3`. |
| [`providers.tf`](terraform/providers.tf) | AWS Provider configuration | Sets AWS region and universal tags (`Project`, `Environment`, `ManagedBy`, `Phase`). |
| [`variables.tf`](terraform/variables.tf) | Input variable definitions | Strongly typed variables with validation blocks, documentation, and cost-conscious defaults. |
| [`main.tf`](terraform/main.tf) | Core module locals & data sources | Computes naming prefixes, queries latest Amazon Linux 2023 AMI, generates random bucket suffix. |
| [`networking.tf`](terraform/networking.tf) | Custom VPC & Subnets | VPC (`10.0.0.0/16`), 2 public subnets, 2 private subnets, IGW, route tables, and optional NAT Gateway. |
| [`security.tf`](terraform/security.tf) | Security groups & network isolation | Ingress HTTP 80 & HTTPS 443; internal port 8000 restricted to VPC CIDR; zero public SSH ports. |
| [`compute.tf`](terraform/compute.tf) | EC2 Docker host & cloud-init | `aws_instance` with Amazon Linux 2023, IMDSv2, encrypted GP3 volume, cloud-init configuration. |
| [`storage.tf`](terraform/storage.tf) | S3 Disaster Recovery bucket | S3 bucket with 4x public access block, AES-256 encryption, versioning, automated lifecycle pruning. |
| [`monitoring.tf`](terraform/monitoring.tf) | CloudWatch Logs & Alarms | Log group (`/deployx/<env>`), CPU utilization alarm, instance status alarm, SNS alert topic. |
| [`iam.tf`](terraform/iam.tf) | Least-privilege IAM roles | EC2 role, SSM Managed Instance Core attachment, scoped S3/CW policies, GitHub Actions OIDC trust. |
| [`outputs.tf`](terraform/outputs.tf) | Safe operational outputs | VPC ID, public IP/DNS, application URL, S3 bucket ARN, SSM connection command (zero secrets). |
| [`templates/user_data.sh.tftpl`](terraform/templates/user_data.sh.tftpl) | Cloud-init host bootstrap script | Installs Docker, Compose, CloudWatch Agent, systemd unit `deployx.service`, runs health probe. |
| [`environments/staging.tfvars.example`](terraform/environments/staging.tfvars.example) | Staging configuration template | Cost-optimized defaults (t3.micro, NAT Gateway disabled, 30-day retention). |
| [`environments/production.tfvars.example`](terraform/environments/production.tfvars.example) | Production configuration template | Production sizing (t3.small, 180-day retention, 30-day log retention). |

---

## 🔒 Security Posture & Compliance

1. **Zero Open SSH Ports (SSM Session Manager):**
   Port 22 is disabled by default (`enable_ssh_port = false`). Operators securely connect to the instance via AWS Systems Manager Session Manager using TLS encryption:
   ```bash
   aws ssm start-session --target <instance-id>
   ```
2. **Internal Network Isolation:**
   The backend API port (`8000`) is restricted strictly to the VPC CIDR (`10.0.0.0/16`) in `security.tf`. Only the Nginx reverse proxy on port 80 can route external requests to the backend.
3. **IMDSv2 Mandatory:**
   EC2 instance metadata requires session tokens (`http_tokens = "required"`, hop limit 2) to eliminate SSRF attack vectors.
4. **Encrypted Storage at Rest & in Transit:**
   - EC2 root volume is encrypted with AWS-managed EBS encryption (`encrypted = true`).
   - S3 backup bucket enforces default `AES256` server-side encryption and includes an explicit bucket policy denying non-TLS (`aws:SecureTransport = false`) requests.
   - S3 public access block enforces all four gates (`block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`).
5. **Keyless CI/CD Authentication (GitHub OIDC):**
   The IAM deployment role trusts the GitHub Actions OpenID Connect provider (`token.actions.githubusercontent.com`) scoped strictly to `repo:abhinavitgithub/DeployX:*`. No long-lived AWS Access Keys are created or stored.

---

## 💰 Estimated Running Costs & Financial Controls

DeployX is deliberately engineered for **cost containment**:

| Resource Category | Configuration | Estimated Monthly Cost | Notes |
|---|---|---|---|
| **Compute (EC2)** | `t3.micro` (1 vCPU, 1 GiB RAM) | **$0.00** (Free Tier) or ~$7.50 | 750 hours/month free under AWS Free Tier. |
| **Storage (EBS)** | 20 GiB GP3 Volume | **$0.00** (Free Tier) or ~$1.60 | 30 GiB EBS free under AWS Free Tier. |
| **Storage (S3)** | Versioned Backup Bucket | **<$0.10** | Pennies per GB. Automatic Standard-IA transition at 30 days and expiration at 90 days. |
| **Networking (NAT Gateway)** | `enable_nat_gateway = false` | **$0.00** | **Disabled by default**. Saves ~$32.40/month. |
| **Observability (CloudWatch)** | 1 Log Group, 2 Metric Alarms | **$0.00** (Free Tier) or <$0.50 | 5 GB log ingestion and 10 alarms included in AWS Free Tier. |
| **Systems Manager (SSM)** | Core Instance Management | **$0.00** | Free standard capability. |
| **Total Estimated Cost:** | | **~$0.00 (Free Tier) / ~$9.20/month** | |

---

## 🚀 Step-by-Step Operator Runbook

### Step 1: Pre-Flight Linting & Validation
```bash
cd infrastructure/aws/terraform

# Format validation
terraform fmt -check

# Configuration validation
terraform init -backend=false
terraform validate

# Static linting
tflint
```

### Step 2: Speculative Infrastructure Plan
```bash
# Copy example tfvars to active tfvars
cp environments/staging.tfvars.example staging.tfvars

# Run speculative plan
terraform plan -var-file=staging.tfvars
```

### Step 3: Provision Infrastructure (Requires Explicit Operator Approval)
```bash
terraform apply -var-file=staging.tfvars
```

### Step 4: Access the Live Application & Connect via SSM
```bash
# Capture outputs
terraform output application_url
terraform output ssm_connect_command

# Connect to EC2 instance via AWS SSM (Zero SSH keys required)
aws ssm start-session --target $(terraform output -raw ec2_instance_id)

# Inside the instance, verify container status:
docker compose -f /opt/deployx/compose.yaml ps
curl -i http://localhost:80/health/live
```

### Step 5: Teardown & Resource Destruction
```bash
# Destroy all provisioned cloud resources to prevent ongoing charges:
terraform destroy -var-file=staging.tfvars
```
