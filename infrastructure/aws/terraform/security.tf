# DeployX — AWS Security Groups & Network Access Control
# Enforces the Principle of Least Privilege across ingress and egress rules.

resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "Security group for DeployX Docker EC2 host with strict ingress isolation"
  vpc_id      = aws_vpc.main.id

  # ----------------------------------------------------------------------------
  # Ingress Rules
  # ----------------------------------------------------------------------------

  # Ingress HTTP (Port 80) — Routes to Nginx Reverse Proxy
  ingress {
    description = "Allow inbound HTTP web traffic to Nginx reverse proxy"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  # Ingress HTTPS (Port 443) — TLS Web Access
  ingress {
    description = "Allow inbound HTTPS web traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  # Ingress SSH (Port 22) — Conditionally enabled only for specified CIDR blocks
  dynamic "ingress" {
    for_each = var.enable_ssh_port && length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      description = "Restricted SSH ingress (SSM Session Manager preferred)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_allowed_cidrs
    }
  }

  # Internal Ingress — Backend API (Port 8000) restricted strictly to VPC internal CIDR
  ingress {
    description = "Allow internal FastAPI backend access strictly within VPC CIDR"
    from_port   = var.backend_internal_port
    to_port     = var.backend_internal_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Internal Ingress — Self Security Group communication
  ingress {
    description = "Allow intra-security-group communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # ----------------------------------------------------------------------------
  # Egress Rules
  # ----------------------------------------------------------------------------
  egress {
    description = "Allow all outbound traffic for container images, OS updates, and AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ec2-sg"
  }
}
