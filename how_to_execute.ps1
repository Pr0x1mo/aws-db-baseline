# how_to_execute.ps1
# Run from the repository root:  .\how_to_execute.ps1
# Prerequisites (one time): winget install Hashicorp.Terraform ; winget install Amazon.AWSCLI ; aws configure

$ErrorActionPreference = "Stop"
$stateBucket = "lab-terraform-state-CHANGE-ME"   # must match the bucket name in terraform/versions.tf
$region      = "us-east-1"

# One time: create the state bucket if it does not exist yet
aws s3api head-bucket --bucket $stateBucket 2>$null
if ($LASTEXITCODE -ne 0) {
    aws s3api create-bucket --bucket $stateBucket --region $region
    aws s3api put-bucket-versioning --bucket $stateBucket --versioning-configuration Status=Enabled
}

Set-Location (Join-Path $PSScriptRoot "terraform")

terraform init
terraform plan -var-file=prod.tfvars -out=tfplan

# Stop here and read the plan before anything is built
$answer = Read-Host "Apply this plan? Type yes to continue"
if ($answer -eq "yes") {
    terraform apply tfplan
} else {
    Write-Host "Nothing was changed."
}

# To tear everything down later, run this by hand (not part of this script):
#   terraform destroy -var-file=prod.tfvars
