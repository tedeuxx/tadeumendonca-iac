# Staging — paired with TF_WORKSPACE=tadeumendonca-iac-staging.
# Differences from prd are driven by var.environment, not extra vars. (BFF is non-VPC — no NAT.)
project     = "tadeumendonca"
environment = "staging"
aws_region  = "us-east-1"
