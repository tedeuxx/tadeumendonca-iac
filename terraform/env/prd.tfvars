# Production — paired with TF_WORKSPACE=tadeumendonca-iac-production.
# NAT gateway per AZ (HA) — driven by var.environment == "production".
project     = "tadeumendonca"
environment = "production"
aws_region  = "us-east-1"
vpc_cidr    = "10.1.0.0/16"
azs         = ["us-east-1a", "us-east-1b"]
