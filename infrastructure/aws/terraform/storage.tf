# DeployX — AWS S3 Storage Architecture (Disaster Recovery Backups)
# Provisions an encrypted, versioned, public-blocked S3 bucket with automated lifecycle management.

# ------------------------------------------------------------------------------
# 1. S3 Backup Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "backups" {
  bucket        = "${local.name_prefix}-backups-${random_id.bucket_suffix.hex}"
  force_destroy = false

  tags = {
    Name        = "${local.name_prefix}-backups"
    Purpose     = "Disaster-Recovery-Backups"
    Sensitivity = "Confidential"
  }
}

# ------------------------------------------------------------------------------
# 2. Strict Public Access Blocking (All 4 Gates Enabled)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# 3. Object Versioning (State History & Accidental Deletion Protection)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ------------------------------------------------------------------------------
# 4. Server-Side Encryption (AES-256 Default)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ------------------------------------------------------------------------------
# 5. Lifecycle Rules (Cost Optimization: IA Transition & Retention Pruning)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "backup-lifecycle-retention"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    # Transition active backups to Standard-IA after 30 days
    transition {
      days          = var.s3_glacier_transition_days
      storage_class = "STANDARD_IA"
    }

    # Expire active backups after 90 days
    expiration {
      days = 90
    }

    # Retain non-current versions for 90 days
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Clean up incomplete multipart uploads after 7 days
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ------------------------------------------------------------------------------
# 6. Bucket Policy Enforcing TLS Encryption in Transit
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "enforce_tls" {
  bucket = aws_s3_bucket.backups.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLSRequestsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
