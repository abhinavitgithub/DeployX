# DeployX — AWS Provider Configuration
# Configures default provider region and universal resource tags.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
      Phase       = "9-Cloud-IaC"
    }
  }
}
