"""Automated Tests for DeployX AWS Cloud Infrastructure & Terraform (Phase 9).

Validates:
1. Complete Terraform file structure under infrastructure/aws/terraform/.
2. Provider configuration, default tags, and Terraform version constraints.
3. Variable declarations, types, descriptions, and validation rules.
4. S3 storage security: public access block (all 4 flags), versioning, AES256 encryption,
   automated lifecycle transition/expiration, and TLS-in-transit policy.
5. Security group least privilege: port 80/443 web ingress, port 22 disabled by default,
   and backend port 8000 restricted from 0.0.0.0/0 public exposure.
6. IAM least privilege: EC2 instance profile, SSM Session Manager attachment,
   scoped S3 backup policy, scoped CloudWatch policy, and GitHub Actions OIDC trust.
7. Compute hardening: IMDSv2 enforcement, root EBS encryption, and user data bootstrap.
8. CloudWatch monitoring: log group retention, CPU alarms, and status check alarms.
9. Safe, non-sensitive output definitions.
10. S3 backup replication integration in Linux and Windows backup scripts.
"""

import re
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
TF_DIR = ROOT_DIR / "infrastructure" / "aws" / "terraform"


# ------------------------------------------------------------------------------
# 1. Terraform File Structure
# ------------------------------------------------------------------------------
def test_terraform_files_exist() -> None:
    """Verify all required Terraform configuration files exist and are non-empty."""
    required_files = [
        TF_DIR / "providers.tf",
        TF_DIR / "versions.tf",
        TF_DIR / "variables.tf",
        TF_DIR / "outputs.tf",
        TF_DIR / "main.tf",
        TF_DIR / "networking.tf",
        TF_DIR / "security.tf",
        TF_DIR / "compute.tf",
        TF_DIR / "storage.tf",
        TF_DIR / "monitoring.tf",
        TF_DIR / "iam.tf",
        TF_DIR / "templates" / "user_data.sh.tftpl",
        TF_DIR / "environments" / "staging.tfvars.example",
        TF_DIR / "environments" / "production.tfvars.example",
    ]
    for file_path in required_files:
        assert file_path.is_file(), f"Missing required Terraform file: {file_path}"
        assert file_path.stat().st_size > 50, f"Terraform file is unexpectedly empty: {file_path}"


# ------------------------------------------------------------------------------
# 2. Versions & Providers Configuration
# ------------------------------------------------------------------------------
def test_terraform_versions_and_providers() -> None:
    """Verify required Terraform and AWS provider versions and universal tags."""
    versions_content = (TF_DIR / "versions.tf").read_text(encoding="utf-8")
    assert 'required_version = ">= 1.5.0' in versions_content
    assert '"hashicorp/aws"' in versions_content
    assert '"~> 5.0"' in versions_content

    providers_content = (TF_DIR / "providers.tf").read_text(encoding="utf-8")
    assert 'provider "aws"' in providers_content
    assert "default_tags" in providers_content
    assert 'ManagedBy   = "Terraform"' in providers_content
    assert 'Phase       = "9-Cloud-IaC"' in providers_content


# ------------------------------------------------------------------------------
# 3. Variable Definitions & Constraints
# ------------------------------------------------------------------------------
def test_terraform_variables_completeness() -> None:
    """Verify expected variable names, descriptions, and validation blocks."""
    vars_content = (TF_DIR / "variables.tf").read_text(encoding="utf-8")

    expected_vars = [
        "aws_region",
        "environment",
        "project_name",
        "owner",
        "vpc_cidr",
        "availability_zones",
        "public_subnet_cidrs",
        "private_subnet_cidrs",
        "enable_nat_gateway",
        "instance_type",
        "allowed_ingress_cidrs",
        "enable_ssh_port",
        "ssh_allowed_cidrs",
        "app_port",
        "backend_internal_port",
        "s3_backup_retention_days",
        "s3_glacier_transition_days",
        "cloudwatch_log_retention_days",
        "enable_cloudwatch_alarms",
        "cpu_utilization_threshold",
        "enable_github_oidc",
        "github_repository",
    ]
    for var_name in expected_vars:
        assert f'variable "{var_name}"' in vars_content, (
            f"Variable '{var_name}' not defined in variables.tf"
        )

    # Verify cost-conscious default values
    assert 'default     = "t3.micro"' in vars_content  # Free-tier eligible EC2
    assert "default     = false" in vars_content  # NAT Gateway and SSH disabled by default


# ------------------------------------------------------------------------------
# 4. S3 Storage Security & Lifecycle
# ------------------------------------------------------------------------------
def test_s3_storage_security_and_lifecycle() -> None:
    """Verify S3 bucket encryption, public access blocking, versioning, and retention."""
    storage_content = (TF_DIR / "storage.tf").read_text(encoding="utf-8")

    # S3 Public Access Block: All 4 gates must be explicitly enabled
    assert "block_public_acls       = true" in storage_content
    assert "block_public_policy     = true" in storage_content
    assert "ignore_public_acls      = true" in storage_content
    assert "restrict_public_buckets = true" in storage_content

    # Versioning
    assert 'status = "Enabled"' in storage_content

    # Server-Side Encryption
    assert 'sse_algorithm = "AES256"' in storage_content

    # Lifecycle configuration
    assert 'storage_class = "STANDARD_IA"' in storage_content
    assert "var.s3_glacier_transition_days" in storage_content
    assert "days = 90" in storage_content or "var.s3_backup_retention_days" in storage_content
    assert "noncurrent_version_expiration" in storage_content

    # TLS-only bucket policy
    assert '"aws:SecureTransport" = "false"' in storage_content
    assert '"Deny"' in storage_content


# ------------------------------------------------------------------------------
# 5. Security Group Least Privilege
# ------------------------------------------------------------------------------
def test_security_group_least_privilege() -> None:
    """Verify ingress rules enforce PoLP and never expose port 8000 or SSH to 0.0.0.0/0."""
    sec_content = (TF_DIR / "security.tf").read_text(encoding="utf-8")

    # Web access ports
    assert "from_port   = var.app_port" in sec_content
    assert "to_port     = var.app_port" in sec_content
    assert "from_port   = 443" in sec_content

    # SSH must NOT be open to 0.0.0.0/0
    assert "var.enable_ssh_port && length(var.ssh_allowed_cidrs) > 0" in sec_content

    # Internal FastAPI port 8000 must be restricted strictly to VPC CIDR and never 0.0.0.0/0
    match = re.search(r"ingress\s*\{[^}]*?var\.backend_internal_port[^}]*?\}", sec_content)
    assert match is not None, "Could not find ingress block for backend_internal_port"
    backend_ingress_block = match.group(0)
    assert "var.vpc_cidr" in backend_ingress_block
    assert "0.0.0.0/0" not in backend_ingress_block


# ------------------------------------------------------------------------------
# 6. IAM Least Privilege & GitHub OIDC
# ------------------------------------------------------------------------------
def test_iam_least_privilege_and_oidc() -> None:
    """Verify EC2 instance role, SSM attachment, scoped S3/CW policies, and GitHub OIDC."""
    iam_content = (TF_DIR / "iam.tf").read_text(encoding="utf-8")

    # EC2 role & SSM Session Manager
    assert "ec2.amazonaws.com" in iam_content
    assert "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" in iam_content

    # S3 policy strictly scoped to backup bucket
    assert "aws_s3_bucket.backups.arn" in iam_content
    assert "${aws_s3_bucket.backups.arn}/*" in iam_content

    # CloudWatch policy strictly scoped to log group
    assert "${aws_cloudwatch_log_group.deployx.arn}:*" in iam_content

    # GitHub Actions OIDC Trust Policy
    assert "token.actions.githubusercontent.com" in iam_content
    assert "sts:AssumeRoleWithWebIdentity" in iam_content
    assert "token.actions.githubusercontent.com:aud" in iam_content
    assert "repo:${var.github_repository}:*" in iam_content

    # Zero long-lived AWS keys
    assert "AKIA" not in iam_content
    assert "aws_access_key" not in iam_content


# ------------------------------------------------------------------------------
# 7. Compute Hardening & User Data Bootstrap
# ------------------------------------------------------------------------------
def test_compute_hardening_and_user_data() -> None:
    """Verify IMDSv2 enforcement, EBS encryption, and Docker user-data template."""
    compute_content = (TF_DIR / "compute.tf").read_text(encoding="utf-8")

    # IMDSv2 enforced
    assert 'http_tokens                 = "required"' in compute_content

    # Root volume encrypted
    assert "encrypted             = true" in compute_content
    assert 'volume_type           = "gp3"' in compute_content

    # User data bootstrap script
    user_data_path = TF_DIR / "templates" / "user_data.sh.tftpl"
    user_data_content = user_data_path.read_text(encoding="utf-8")
    assert "docker" in user_data_content
    assert "compose.yaml" in user_data_content
    assert "deployx.service" in user_data_content
    assert "amazon-cloudwatch-agent" in user_data_content
    assert "/health/live" in user_data_content


# ------------------------------------------------------------------------------
# 8. Monitoring & CloudWatch Alarms
# ------------------------------------------------------------------------------
def test_monitoring_and_alarms() -> None:
    """Verify CloudWatch Log Group retention and metric alarms."""
    monitoring_content = (TF_DIR / "monitoring.tf").read_text(encoding="utf-8")

    assert "aws_cloudwatch_log_group" in monitoring_content
    assert "var.cloudwatch_log_retention_days" in monitoring_content
    assert "aws_cloudwatch_metric_alarm" in monitoring_content
    assert 'metric_name         = "CPUUtilization"' in monitoring_content
    assert 'metric_name         = "StatusCheckFailed"' in monitoring_content


# ------------------------------------------------------------------------------
# 9. Outputs Completeness & Safety
# ------------------------------------------------------------------------------
def test_outputs_completeness_and_safety() -> None:
    """Verify Terraform outputs expose required resources without leaking secrets."""
    outputs_content = (TF_DIR / "outputs.tf").read_text(encoding="utf-8")

    expected_outputs = [
        "vpc_id",
        "public_subnet_ids",
        "private_subnet_ids",
        "security_group_id",
        "ec2_instance_id",
        "ec2_public_ip",
        "ec2_public_dns",
        "application_url",
        "ssm_connect_command",
        "s3_backup_bucket_name",
        "s3_backup_bucket_arn",
        "cloudwatch_log_group_name",
        "github_actions_role_arn",
    ]
    for out_name in expected_outputs:
        assert f'output "{out_name}"' in outputs_content, (
            f"Output '{out_name}' missing from outputs.tf"
        )

    forbidden_output_terms = ["password", "secret_key", "access_key", "token_value"]
    for term in forbidden_output_terms:
        assert term not in outputs_content.lower()


# ------------------------------------------------------------------------------
# 10. Backup Scripts S3 Integration
# ------------------------------------------------------------------------------
def test_backup_scripts_s3_integration() -> None:
    """Verify Linux and Windows backup scripts support S3 bucket parameter and replication."""
    linux_backup = (ROOT_DIR / "scripts" / "linux" / "backup.sh").read_text(encoding="utf-8")
    assert "--s3-bucket" in linux_backup
    assert "DEPLOYX_S3_BACKUP_BUCKET" in linux_backup
    assert "aws s3 cp" in linux_backup

    win_backup = (ROOT_DIR / "scripts" / "windows" / "backup.ps1").read_text(encoding="utf-8")
    assert "S3Bucket" in win_backup
    assert "DEPLOYX_S3_BACKUP_BUCKET" in win_backup
    assert "aws s3 cp" in win_backup
