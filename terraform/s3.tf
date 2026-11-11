# Two buckets: one for SQL Server native backups, one for CloudTrail and AWS Config logs.
# Both: public access blocked, versioned, KMS encrypted, TLS required.

locals {
  buckets = {
    backups = "${var.name_prefix}-${var.environment}-sql-backups-${data.aws_caller_identity.current.account_id}"
    logs    = "${var.name_prefix}-${var.environment}-audit-logs-${data.aws_caller_identity.current.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = each.value

  # Object Lock can only be turned on when the bucket is created.
  # It stops anyone (including ransomware with stolen keys) from deleting backups early.
  object_lock_enabled = each.key == "backups"
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.db.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "backups" {
  bucket = aws_s3_bucket.this["backups"].id
  rule {
    default_retention {
      mode = "GOVERNANCE" # COMPLIANCE mode cannot be shortened even by the root user
      days = 30
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.this["backups"].id
  rule {
    id     = "age-out-backups"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Backups bucket: deny anything not over TLS
resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.this["backups"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this["backups"].arn, "${aws_s3_bucket.this["backups"].arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# Logs bucket: deny non-TLS, and let CloudTrail and AWS Config write their files
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.this["logs"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.this["logs"].arn, "${aws_s3_bucket.this["logs"].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "LogServicesAclCheck"
        Effect    = "Allow"
        Principal = { Service = ["cloudtrail.amazonaws.com", "config.amazonaws.com"] }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.this["logs"].arn
      },
      {
        Sid       = "LogServicesWrite"
        Effect    = "Allow"
        Principal = { Service = ["cloudtrail.amazonaws.com", "config.amazonaws.com"] }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this["logs"].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
}
