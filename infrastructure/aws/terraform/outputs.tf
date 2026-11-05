# DeployX — AWS Terraform Outputs
# Exposes operational endpoints, resource IDs, and connection strings without leaking secrets.

# ------------------------------------------------------------------------------
# 1. Networking Outputs
# ------------------------------------------------------------------------------
output "vpc_id" {
  description = "ID of the custom DeployX VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets across availability zones"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets across availability zones"
  value       = aws_subnet.private[*].id
}

output "security_group_id" {
  description = "ID of the EC2 security group"
  value       = aws_security_group.ec2.id
}

# ------------------------------------------------------------------------------
# 2. Compute Outputs
# ------------------------------------------------------------------------------
output "ec2_instance_id" {
  description = "Instance ID of the DeployX Docker host"
  value       = aws_instance.deployx.id
}

output "ec2_public_ip" {
  description = "Public IPv4 address assigned to the DeployX host"
  value       = aws_instance.deployx.public_ip
}

output "ec2_public_dns" {
  description = "Public DNS hostname of the DeployX host"
  value       = aws_instance.deployx.public_dns
}

output "application_url" {
  description = "Public URL to access the DeployX Operations Center Dashboard"
  value       = "http://${aws_instance.deployx.public_ip}:${var.app_port}"
}

output "ssm_connect_command" {
  description = "AWS Systems Manager CLI command to connect to host with zero open inbound ports"
  value       = "aws ssm start-session --target ${aws_instance.deployx.id}"
}

# ------------------------------------------------------------------------------
# 3. Storage Outputs (S3)
# ------------------------------------------------------------------------------
output "s3_backup_bucket_name" {
  description = "Name of the dedicated S3 backup bucket"
  value       = aws_s3_bucket.backups.id
}

output "s3_backup_bucket_arn" {
  description = "Amazon Resource Name (ARN) of the S3 backup bucket"
  value       = aws_s3_bucket.backups.arn
}

# ------------------------------------------------------------------------------
# 4. Monitoring Outputs (CloudWatch & SNS)
# ------------------------------------------------------------------------------
output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch Log Group streaming system and application logs"
  value       = aws_cloudwatch_log_group.deployx.name
}

output "sns_alerts_topic_arn" {
  description = "ARN of the SNS topic receiving CloudWatch alarm notifications"
  value       = length(aws_sns_topic.alerts) > 0 ? aws_sns_topic.alerts[0].arn : var.alarm_sns_topic_arn
}

# ------------------------------------------------------------------------------
# 5. IAM & CI/CD Outputs (GitHub OIDC)
# ------------------------------------------------------------------------------
output "github_actions_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions via OIDC"
  value       = var.enable_github_oidc && length(aws_iam_role.github_actions) > 0 ? aws_iam_role.github_actions[0].arn : ""
}
