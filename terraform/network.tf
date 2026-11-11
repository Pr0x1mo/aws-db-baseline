# Private network for the databases: no internet gateway, no public subnets.
# Only the application tier's security group can reach SQL Server on 1433.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-${var.environment}-vpc" }
}

resource "aws_subnet" "private" {
  count                   = length(var.private_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-${var.environment}-private-${count.index + 1}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-${var.environment}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# S3 traffic (backups, audit files) stays on the AWS network instead of the internet
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# Locks the VPC's default security group to no rules at all (a CIS AWS Foundations control)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

# The application tier attaches this group; it is the only thing allowed into the database
resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-${var.environment}-app"
  description = "Application servers that are allowed to reach SQL Server"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-${var.environment}-sqlserver"
  description = "RDS SQL Server, reachable only from the app security group"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
  description                  = "SQL Server from the app tier only"
}

resource "aws_vpc_security_group_egress_rule" "db_out_vpc" {
  security_group_id = aws_security_group.db.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
  description       = "Outbound inside the VPC only"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
}
