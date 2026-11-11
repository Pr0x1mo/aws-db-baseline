output "sql_endpoint" {
  description = "Connect SSMS here (from inside the VPC)"
  value       = aws_db_instance.sql.address
}

output "master_password_secret_arn" {
  description = "Secrets Manager secret holding the rotated master password"
  value       = aws_db_instance.sql.master_user_secret[0].secret_arn
}

output "backup_bucket" {
  value = aws_s3_bucket.this["backups"].id
}

output "app_security_group_id" {
  description = "Attach this to the application servers so they can reach SQL Server"
  value       = aws_security_group.app.id
}
