# AWS database hardening baseline

Hardened RDS for SQL Server plus account-level detection and auto-remediation, built with Terraform.

## Where it lives

A Git repository (GitHub or Azure DevOps). Nothing is built from the AWS console.

```
aws-db-baseline/
  terraform/
    versions.tf        Terraform version, AWS provider, remote state in S3 (locked)
    variables.tf       Inputs
    prod.tfvars        Values for production (one tfvars file per environment)
    network.tf         Private VPC, subnets, security groups, S3 endpoint
    kms.tf             Customer-managed encryption key with rotation
    s3.tf              Backup bucket (Object Lock) and audit log bucket
    iam.tf             One scoped role per job, no access keys
    rds.tf             RDS SQL Server: encrypted, private, Multi-AZ, forced TLS, alarms
    logging.tf         CloudTrail, AWS Config, GuardDuty, Security Hub (CIS), SNS alerts
    detection.tf       AWS Config rules, auto-remediation, EventBridge alerts
    lambda/            Custom remediation code
    outputs.tf
  sql/
    01_compliance_checks.sql   CIS checks inside SQL Server, logged to Admin.dbo.ComplianceResults
    02_schedule_job.sql        Runs them daily with SQL Agent
  .github/workflows/
    terraform.yml      The pipeline that runs Terraform
```

## How it gets executed

1. One time, by hand: create the state bucket named in versions.tf, and the two OIDC (OpenID Connect)
   roles the pipeline assumes (read-only for plan, write for apply).
2. An engineer changes a .tf file on a branch and opens a pull request.
3. The pipeline runs `terraform fmt`, `init`, `validate` and `plan`, and posts the plan on the pull request.
4. A reviewer reads the plan (what will be created, changed or destroyed) and approves the pull request.
5. On merge to main, the apply job waits for an approver on the GitHub "production" environment,
   then runs `terraform apply`.
6. Terraform records what it built in the state file in S3. The next plan compares the code,
   the state and the real AWS resources, and shows any difference.

After the apply, the database layer is set up once from SSMS: run sql/01 then sql/02 against the RDS endpoint.

## What runs on its own after that

- AWS Config evaluates every resource continuously against the rules in detection.tf.
- A public S3 bucket is fixed automatically by a Systems Manager Automation document.
- A publicly accessible RDS instance is set back to private by the Lambda, and the team is emailed.
- Every other non-compliant rule and every high GuardDuty finding emails the team for a decision.
- Secrets Manager rotates the master password.
- SQL Agent runs the database checks daily and the job fails if any check fails.
