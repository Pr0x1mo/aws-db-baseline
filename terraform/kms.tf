# One customer-managed key for the database tier, with yearly automatic rotation.
# A customer-managed key (instead of the AWS default key) lets you control and audit
# who can decrypt, and lets you share encrypted snapshots across accounts for DR.

resource "aws_kms_key" "db" {
  description             = "${var.name_prefix}-${var.environment} database encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudTrailAndConfig"
        Effect    = "Allow"
        Principal = { Service = ["cloudtrail.amazonaws.com", "config.amazonaws.com"] }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.name_prefix}-${var.environment}-db"
  target_key_id = aws_kms_key.db.key_id
}
