# Terraform and provider versions, plus where Terraform keeps its state.
# State lives in a locked, encrypted S3 bucket so the whole team (and the pipeline)
# works from one copy and two applies can never run at the same time.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket       = "lab-terraform-state-CHANGE-ME" # created once, by hand, before the first init
    key          = "db-baseline/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3 native state locking (Terraform 1.10 and later)
  }
}

provider "aws" {
  region = var.region

  # Every resource gets these tags automatically, which auditors and cost reports rely on
  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "dba-team"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
