# Detection: AWS Config rules check every resource continuously against the hardening baseline.
# Fixing: two patterns are shown.
#   A. Config rule -> Systems Manager Automation document (built-in AWS fix), fully automatic
#   B. Config rule -> EventBridge -> Lambda (custom fix you write), plus an alert

locals {
  config_rules = {
    "rds-not-public"             = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
    "rds-storage-encrypted"      = "RDS_STORAGE_ENCRYPTED"
    "rds-multi-az"               = "RDS_MULTI_AZ_SUPPORT"
    "rds-backups-enabled"        = "DB_INSTANCE_BACKUP_ENABLED"
    "rds-deletion-protection"    = "RDS_INSTANCE_DELETION_PROTECTION_ENABLED"
    "rds-snapshots-not-public"   = "RDS_SNAPSHOTS_PUBLIC_PROHIBITED"
    "s3-no-public-read"          = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    "s3-tls-only"                = "S3_BUCKET_SSL_REQUESTS_ONLY"
    "s3-encrypted"               = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
    "sg-no-open-ssh"             = "INCOMING_SSH_DISABLED"
    "cloudtrail-enabled"         = "CLOUD_TRAIL_ENABLED"
    "root-mfa"                   = "ROOT_ACCOUNT_MFA_ENABLED"
    "iam-no-inline-admin-policy" = "IAM_POLICY_NO_STATEMENTS_WITH_ADMIN_ACCESS"
  }
}

resource "aws_config_config_rule" "baseline" {
  for_each = local.config_rules
  name     = each.key

  source {
    owner             = "AWS"
    source_identifier = each.value
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ---------------------------------------------------------------
# Pattern A: a public S3 bucket is fixed automatically within minutes
# ---------------------------------------------------------------
resource "aws_config_remediation_configuration" "s3_public" {
  config_rule_name = aws_config_config_rule.baseline["s3-no-public-read"].name
  target_type      = "SSM_DOCUMENT"
  target_id        = "AWS-DisableS3BucketPublicReadWrite"
  resource_type    = "AWS::S3::Bucket"

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation.arn
  }
  parameter {
    name           = "S3BucketName"
    resource_value = "RESOURCE_ID"
  }

  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60
}

# ---------------------------------------------------------------
# Pattern B: a publicly accessible RDS instance is closed by a Lambda,
# and the team gets an alert saying what was changed and why
# ---------------------------------------------------------------
data "archive_file" "rds_public_fix" {
  type        = "zip"
  source_file = "${path.module}/lambda/rds_public_fix.py"
  output_path = "${path.module}/lambda/rds_public_fix.zip"
}

resource "aws_lambda_function" "rds_public_fix" {
  function_name    = "${var.name_prefix}-${var.environment}-rds-public-fix"
  role             = aws_iam_role.rds_public_fix.arn
  runtime          = "python3.12"
  handler          = "rds_public_fix.handler"
  filename         = data.archive_file.rds_public_fix.output_path
  source_code_hash = data.archive_file.rds_public_fix.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "rds_public_noncompliant" {
  name        = "${var.name_prefix}-${var.environment}-rds-public-noncompliant"
  description = "Fires when AWS Config marks an RDS instance as publicly accessible"
  event_pattern = jsonencode({
    source        = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      configRuleName      = [aws_config_config_rule.baseline["rds-not-public"].name]
      newEvaluationResult = { complianceType = ["NON_COMPLIANT"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "rds_public_fix" {
  rule = aws_cloudwatch_event_rule.rds_public_noncompliant.name
  arn  = aws_lambda_function.rds_public_fix.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_public_fix.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rds_public_noncompliant.arn
}

# ---------------------------------------------------------------
# Everything else: alert only. Any rule going NON_COMPLIANT emails the team.
# Auto-fixing production is a policy decision, so most rules alert and a person decides.
# ---------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "any_noncompliant" {
  name        = "${var.name_prefix}-${var.environment}-config-noncompliant"
  description = "Any baseline rule that goes non-compliant"
  event_pattern = jsonencode({
    source        = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      configRuleName      = [for r in aws_config_config_rule.baseline : r.name]
      newEvaluationResult = { complianceType = ["NON_COMPLIANT"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "any_noncompliant_alert" {
  rule = aws_cloudwatch_event_rule.any_noncompliant.name
  arn  = aws_sns_topic.alerts.arn
}

# High and critical GuardDuty findings also go to the team
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  name = "${var.name_prefix}-${var.environment}-guardduty-high"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 7] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_alert" {
  rule = aws_cloudwatch_event_rule.guardduty_high.name
  arn  = aws_sns_topic.alerts.arn
}
