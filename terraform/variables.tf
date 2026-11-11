variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "name_prefix" {
  type    = string
  default = "lab"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "One private subnet per Availability Zone; Multi-AZ RDS needs at least two"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "sqlserver_engine_version" {
  description = "Check the current list with: aws rds describe-db-engine-versions --engine sqlserver-se"
  type        = string
  default     = "16.00"
}

variable "db_instance_class" {
  type    = string
  default = "db.m6i.xlarge"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 200
}

variable "backup_retention_days" {
  description = "Automated backup retention; size it to the RPO and audit requirements"
  type        = number
  default     = 14
}

variable "alert_email" {
  description = "Where compliance and security alerts go"
  type        = string
}
