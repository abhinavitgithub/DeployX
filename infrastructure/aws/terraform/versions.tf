# DeployX — AWS Infrastructure as Code (Terraform Versions)
# Enforces minimum Terraform and cloud provider versions.

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }

  # Remote S3 Backend Configuration (Example for Production Deployments)
  # Uncomment and configure with pre-provisioned state bucket and DynamoDB lock table:
  # backend "s3" {
  #   bucket         = "deployx-terraform-state-<account-id>"
  #   key            = "staging/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "deployx-terraform-locks"
  #   encrypt        = true
  # }
}
