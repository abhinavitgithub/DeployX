# DeployX — AWS Identity & Access Management (IAM)
# Provisions least-privilege IAM roles and instance profiles for EC2, S3, and GitHub OIDC.

# ------------------------------------------------------------------------------
# 1. EC2 Instance Role & SSM Access
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name        = "${local.name_prefix}-ec2-role"
  description = "Execution role for the DeployX EC2 Docker host"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-ec2-role"
  }
}

# Attach AWS Systems Manager (SSM) Core Managed Policy for Zero-Open-Port Management
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ------------------------------------------------------------------------------
# 2. Least-Privilege S3 Backup Policy
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "s3_backup" {
  name        = "${local.name_prefix}-s3-backup-policy"
  description = "Allows DeployX host to list, put, and retrieve backup archives in dedicated S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListAndLocationDeployXBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.backups.arn
      },
      {
        Sid    = "ManageBackupObjects"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_backup" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.s3_backup.arn
}

# ------------------------------------------------------------------------------
# 3. Least-Privilege CloudWatch Logs Policy
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "cloudwatch_logs" {
  name        = "${local.name_prefix}-cw-logs-policy"
  description = "Allows DeployX CloudWatch Agent to forward host and application logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PublishDeployXCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.deployx.arn}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

# ------------------------------------------------------------------------------
# 4. EC2 Instance Profile
# ------------------------------------------------------------------------------
resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${local.name_prefix}-ec2-profile"
  }
}

# ------------------------------------------------------------------------------
# 5. GitHub Actions OpenID Connect (OIDC) Role (Keyless CI/CD)
# ------------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc && var.create_github_oidc_provider && var.github_oidc_provider_arn == "" ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c5824a640dd64366b49464a6a3377242d4cf99c"]

  tags = {
    Name = "${var.project_name}-github-oidc-provider"
  }
}

locals {
  github_oidc_arn = var.enable_github_oidc ? (
    var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : (
      length(aws_iam_openid_connect_provider.github) > 0 ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
    )
  ) : ""
}

resource "aws_iam_role" "github_actions" {
  count       = var.enable_github_oidc ? 1 : 0
  name        = "${local.name_prefix}-github-actions-role"
  description = "Role assumed by GitHub Actions via OIDC federation for automated deployments"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.github_oidc_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-github-actions-role"
  }
}

# Scoped Policy for GitHub Actions Deployments
resource "aws_iam_policy" "github_actions_deploy" {
  count       = var.enable_github_oidc ? 1 : 0
  name        = "${local.name_prefix}-github-deploy-policy"
  description = "Least-privilege policy for GitHub Actions CI/CD infrastructure validation and deployment"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DeployXInfrastructureInspection"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ec2:Get*",
          "s3:ListBucket",
          "s3:GetBucket*",
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "logs:Describe*",
          "iam:Get*",
          "iam:List*"
        ]
        Resource = "*"
      },
      {
        Sid    = "DeployXEC2AndS3Management"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:RebootInstances",
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
          "${aws_s3_bucket.backups.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy" {
  count      = var.enable_github_oidc ? 1 : 0
  role       = aws_iam_role.github_actions[0].name
  policy_arn = aws_iam_policy.github_actions_deploy[0].arn
}
