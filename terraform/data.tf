# Root data sources, declared once. account_id prefixes globally-unique S3 bucket names and is
# never hardcoded (/infrastructure/terraform). Route53 zone + ACM cert are added by the layers
# that need them (auth.tf / frontend.tf).
data "aws_caller_identity" "current" {}
