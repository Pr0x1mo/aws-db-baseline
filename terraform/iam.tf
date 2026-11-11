# Roles, not access keys. Each role can do exactly one job.

# 1. Lets RDS SQL Server write and read native backups in the backups bucket
#    (used by msdb.dbo.rds_backup_database and rds_restore_database)
resource "aws_iam_role" "rds_s3_backup" {
  name = "${var.name_prefix}-${var.environment}-rds-s3-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_s3_backup" {
  name = "backup-bucket-only"
  role = aws_iam_role.rds_s3_backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.this["backups"].arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.this["backups"].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = aws_kms_key.db.arn
      }
    ]
  })
}

# 2. Enhanced Monitoring (OS-level metrics every 60 seconds)
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name_prefix}-${var.environment}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# 3. AWS Config recorder
resource "aws_iam_role" "config" {
  name = "${var.name_prefix}-${var.environment}-aws-config"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# 4. Systems Manager Automation, used by AWS Config auto-remediation
resource "aws_iam_role" "remediation" {
  name = "${var.name_prefix}-${var.environment}-config-remediation"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "remediation" {
  name = "fix-s3-public-access"
  role = aws_iam_role.remediation.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutBucketPublicAccessBlock", "s3:GetBucketPublicAccessBlock", "s3:PutBucketAcl", "s3:GetBucketAcl"]
      Resource = "*"
    }]
  })
}

# 5. The Lambda that closes a publicly accessible RDS instance
resource "aws_iam_role" "rds_public_fix" {
  name = "${var.name_prefix}-${var.environment}-rds-public-fix"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_public_fix" {
  name = "modify-rds-public-flag"
  role = aws_iam_role.rds_public_fix.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["rds:DescribeDBInstances", "rds:ModifyDBInstance"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}
