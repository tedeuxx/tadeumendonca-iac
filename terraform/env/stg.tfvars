# Staging — paired with TF_WORKSPACE=tadeumendonca-iac-staging.
# Single NAT gateway (cost). Differences from prd are driven by var.environment, not extra vars.
project     = "tadeumendonca"
environment = "staging"
aws_region  = "us-east-1"
vpc_cidr    = "10.0.0.0/16"
azs         = ["us-east-1a", "us-east-1b"]
