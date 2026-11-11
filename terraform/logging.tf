# Account-level visibility: who did what (CloudTrail), what changed (AWS Config),
# threats (GuardDuty), and one compliance scorecard (Security Hub with CIS).

# Left unencrypted on purpose: EventBridge cannot publish to a topic encrypted with the
# AWS-managed SNS key. To encrypt it, use a customer-managed key whose policy allows
# events.amazonaws.com, and keep sensitive data out of alert messages either way.
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-${var.environment}-db-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # the recipient must click the confirmation email once
}

# Let EventBridge, RDS and CloudWatch publish to the alert topic
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "rds.amazonaws.com", "cloudwatch.amazonaws.com"] }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
    }]
  })
}

# CloudTrail: every API call in every Region, with tamper-evident log files
resource "aws_cloudtrail" "main" {
  name                          = "${var.name_prefix}-${var.environment}-trail"
  s3_bucket_name                = aws_s3_bucket.this["logs"].id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.db.arn

  depends_on = [aws_s3_bucket_policy.logs]
}

# AWS Config: records the configuration of every resource and every change to it
resource "aws_config_configuration_recorder" "main" {
  name     = "default"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.this["logs"].id

  depends_on = [aws_config_configuration_recorder.main, aws_s3_bucket_policy.logs]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# GuardDuty: threat detection from CloudTrail, VPC flow logs and DNS logs
resource "aws_guardduty_detector" "main" {
  enable = true
}

# Security Hub with the CIS AWS Foundations Benchmark: the cloud version of the CimTrak score
resource "aws_securityhub_account" "main" {}

resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${var.region}::standards/cis-aws-foundations-benchmark/v/3.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}
