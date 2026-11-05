# DeployX — Main Module Configuration & Data Sources
# Computes shared naming prefixes, tags, and resolves dynamic cloud data.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ------------------------------------------------------------------------------
# Data Sources
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Fetch the latest official Amazon Linux 2023 x86_64 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Generate a random 4-byte hex suffix for globally unique S3 bucket naming
resource "random_id" "bucket_suffix" {
  byte_length = 4
}
