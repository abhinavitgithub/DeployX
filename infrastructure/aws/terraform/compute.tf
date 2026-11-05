# DeployX — AWS Compute Architecture (Docker Host on Amazon Linux 2023)
# Provisions a hardened, cost-conscious EC2 instance managed via AWS Systems Manager.

# ------------------------------------------------------------------------------
# 1. Cloud-Init Template Configuration
# ------------------------------------------------------------------------------
data "cloudinit_config" "deployx" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/user_data.sh.tftpl", {
      environment           = var.environment
      aws_region            = var.aws_region
      app_port              = var.app_port
      backend_internal_port = var.backend_internal_port
      s3_backup_bucket      = aws_s3_bucket.backups.id
      cloudwatch_log_group  = aws_cloudwatch_log_group.deployx.name
      backend_image         = "ghcr.io/${lower(split("/", var.github_repository)[0])}/deployx-backend:latest"
      frontend_image        = "ghcr.io/${lower(split("/", var.github_repository)[0])}/deployx-frontend:latest"
    })
  }
}

# ------------------------------------------------------------------------------
# 2. EC2 Host Instance
# ------------------------------------------------------------------------------
resource "aws_instance" "deployx" {
  ami                         = var.custom_ami_id != "" ? var.custom_ami_id : data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true
  user_data_base64            = data.cloudinit_config.deployx.rendered

  # Hardened GP3 Storage Volume with Encryption at Rest
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${local.name_prefix}-root-volume"
    }
  }

  # Enforce IMDSv2 (Session-oriented Instance Metadata Service for SSRF Protection)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [ami]
  }

  tags = {
    Name = "${local.name_prefix}-host"
    Role = "DeployX-Docker-Host"
  }
}
