# Production — paired with TF_WORKSPACE=tadeumendonca-iac-production.
# Differences from stg are driven by var.environment. (BFF is non-VPC — no NAT.)
project     = "tadeumendonca"
environment = "production"
aws_region  = "us-east-1"
