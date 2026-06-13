# Staging — paired with TF_WORKSPACE=tadeumendonca-iac-staging.
# Differences from prd are driven by var.environment, not extra vars. (BFF is non-VPC — no NAT.)
project     = "tadeumendonca"
environment = "staging"
aws_region  = "us-east-1"
# e2e-test@... is the native test user for authed/admin regression (USER_PASSWORD_AUTH test client).
# Staging-only — prd keeps just the owner. The cognito-groups trigger reads ADMIN_EMAILS to grant admin.
admin_emails = ["tadeu.tyf@gmail.com", "e2e-test@tadeumendonca.io"]
