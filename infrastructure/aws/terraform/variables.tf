# DeployX — AWS Infrastructure Variables
# Defines all customizable parameters for VPC, EC2, S3, IAM, and CloudWatch.

# ------------------------------------------------------------------------------
# 1. General & Project Metadata
# ------------------------------------------------------------------------------
variable "aws_region" {
  description = "Target AWS region for deploying infrastructure"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment tier (staging or production)"
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of: 'dev', 'staging', or 'production'."
  }
}

variable "project_name" {
  description = "Project name identifier used in resource naming prefixes"
  type        = string
  default     = "deployx"
}

variable "owner" {
  description = "Team or individual owner tag for cloud resources"
  type        = string
  default     = "DevOps"
}

# ------------------------------------------------------------------------------
# 2. VPC & Networking
# ------------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "IPv4 CIDR block for the custom DeployX VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "The vpc_cidr value must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of Availability Zones to distribute subnets across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to provision an AWS NAT Gateway for private subnets. Default is false to minimize monthly cloud costs (~$32/mo)."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# 3. Security Groups & Ingress Control
# ------------------------------------------------------------------------------
variable "allowed_ingress_cidrs" {
  description = "List of IPv4 CIDR blocks permitted for HTTP (port 80) and HTTPS (port 443) web access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_ssh_port" {
  description = "Whether to open port 22 in the EC2 security group. Default is false; AWS Systems Manager (SSM) Session Manager is the recommended zero-open-port access method."
  type        = bool
  default     = false
}

variable "ssh_allowed_cidrs" {
  description = "List of IPv4 CIDR blocks allowed to access SSH (port 22) when enable_ssh_port is true"
  type        = list(string)
  default     = []
}

variable "app_port" {
  description = "Public HTTP port routed to the frontend Nginx reverse proxy"
  type        = number
  default     = 80
}

variable "backend_internal_port" {
  description = "Internal port utilized by the FastAPI backend container (restricted from public ingress)"
  type        = number
  default     = 8000
}

# ------------------------------------------------------------------------------
# 4. Compute (EC2)
# ------------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance size for the DeployX Docker host. Default t3.micro is AWS Free Tier eligible."
  type        = string
  default     = "t3.micro"
}

variable "custom_ami_id" {
  description = "Optional custom AMI ID. If empty, the latest Amazon Linux 2023 x86_64 AMI is resolved automatically."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GiB (General Purpose GP3)"
  type        = number
  default     = 20
}

# ------------------------------------------------------------------------------
# 5. Storage (S3 Backups)
# ------------------------------------------------------------------------------
variable "s3_backup_retention_days" {
  description = "Number of days before backup archives in the S3 bucket expire"
  type        = number
  default     = 90
}

variable "s3_glacier_transition_days" {
  description = "Number of days before active backup archives transition to STANDARD_IA storage class"
  type        = number
  default     = 30
}

# ------------------------------------------------------------------------------
# 6. Monitoring & Alarms (CloudWatch)
# ------------------------------------------------------------------------------
variable "cloudwatch_log_retention_days" {
  description = "Number of days to retain application and host logs in CloudWatch Logs"
  type        = number
  default     = 14
}

variable "enable_cloudwatch_alarms" {
  description = "Whether to provision CloudWatch metric alarms for CPU utilization and instance status checks"
  type        = bool
  default     = true
}

variable "cpu_utilization_threshold" {
  description = "CPU utilization percentage threshold that triggers a CloudWatch high-utilization alarm"
  type        = number
  default     = 80
}

variable "alarm_sns_topic_arn" {
  description = "Optional SNS Topic ARN to publish CloudWatch alarm alerts to"
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# 7. CI/CD & IAM Integration (GitHub Actions OIDC)
# ------------------------------------------------------------------------------
variable "enable_github_oidc" {
  description = "Whether to create the GitHub Actions OIDC IAM role for keyless CI/CD authentication"
  type        = bool
  default     = true
}

variable "create_github_oidc_provider" {
  description = "Whether to create the AWS IAM OIDC Provider if one does not already exist in the account"
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC Provider ARN if already provisioned in the AWS account (avoids duplicate provider error)"
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repository (owner/repo) permitted to assume the deployment IAM role via OIDC"
  type        = string
  default     = "abhinavitgithub/DeployX"
}
