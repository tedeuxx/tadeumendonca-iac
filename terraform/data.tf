# Root data sources, declared once. account_id is never hardcoded (/infrastructure/terraform).
data "aws_caller_identity" "current" {}

# Pre-existing hosted zone for the apex domain — auth + ses (SES DKIM/verification) records land here.
data "aws_route53_zone" "main" {
  name = var.apex_domain
}

# ACM cert pre-created + DNS-validated out-of-band in us-east-1. Resolved by domain — never an ARN in
# tfvars (/infrastructure/acm). us-east-1 because the Cognito custom domain requires it there (auth.tf).
data "aws_acm_certificate" "main" {
  provider    = aws.us_east_1
  domain      = var.apex_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  # account_id — consumed by auth.tf (Cognito/SES ARNs) and ses.tf. Defined here because iam.tf, which
  # used to own this local, moved to the tadeumendonca-pwa monorepo (app-infra split). The data tier
  # (DynamoDB tables) + its SSM params also moved there; this repo keeps only the shared foundation
  # (Cognito/auth, SES, WAF regional).
  account = data.aws_caller_identity.current.account_id
}
