# RDS for SQL Server, hardened at creation.
# Everything that cannot be changed later (encryption, KMS key) is set here.

resource "aws_db_subnet_group" "sql" {
  name       = "${var.name_prefix}-${var.environment}-sql"
  subnet_ids = aws_subnet.private[*].id
}

# Parameter group: force encrypted connections
resource "aws_db_parameter_group" "sql" {
  name   = "${var.name_prefix}-${var.environment}-sqlserver-se-16"
  family = "sqlserver-se-16.0"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot" # static parameter; takes effect at the next reboot
  }
}

# Option group: native backup and restore to S3, using the scoped IAM role
resource "aws_db_option_group" "sql" {
  name                 = "${var.name_prefix}-${var.environment}-sqlserver-se-16"
  engine_name          = "sqlserver-se"
  major_engine_version = "16.00"

  option {
    option_name = "SQLSERVER_BACKUP_RESTORE"
    option_settings {
      name  = "IAM_ROLE_ARN"
      value = aws_iam_role.rds_s3_backup.arn
    }
  }
}

resource "aws_db_instance" "sql" {
  identifier     = "${var.name_prefix}-${var.environment}-sql01"
  engine         = "sqlserver-se"
  engine_version = var.sqlserver_engine_version
  license_model  = "license-included"
  instance_class = var.db_instance_class

  # Storage, encrypted with the customer-managed key (cannot be added after creation)
  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_allocated_storage_gb * 2 # storage autoscaling ceiling
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  # Credentials: RDS creates the master password in Secrets Manager and rotates it.
  # Nobody ever types it, and it never appears in Terraform code or state.
  username                      = "dbadmin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.db.arn

  # Network: private only
  db_subnet_group_name   = aws_db_subnet_group.sql.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  port                   = 1433

  # High availability: synchronous standby in a second Availability Zone
  multi_az = true

  # Configuration
  parameter_group_name = aws_db_parameter_group.sql.name
  option_group_name    = aws_db_option_group.sql.name

  # Backups and protection
  backup_retention_period   = var.backup_retention_days
  backup_window             = "07:00-08:00" # UTC, outside business hours
  copy_tags_to_snapshot     = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-${var.environment}-sql01-final"

  # Patching
  auto_minor_version_upgrade = true
  maintenance_window         = "sun:08:30-sun:09:30"

  # Monitoring
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.db.arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["agent", "error"]
}

# Get an alert for failovers, reboots, low storage and configuration changes
resource "aws_db_event_subscription" "sql" {
  name             = "${var.name_prefix}-${var.environment}-sql-events"
  sns_topic        = aws_sns_topic.alerts.arn
  source_type      = "db-instance"
  source_ids       = [aws_db_instance.sql.identifier]
  event_categories = ["failover", "failure", "low storage", "maintenance", "notification", "configuration change"]
}

resource "aws_cloudwatch_metric_alarm" "sql_cpu" {
  alarm_name          = "${var.name_prefix}-${var.environment}-sql01-cpu-high"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.sql.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "sql_storage" {
  alarm_name          = "${var.name_prefix}-${var.environment}-sql01-free-storage-low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.sql.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20 * 1024 * 1024 * 1024 # 20 GB, in bytes
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
