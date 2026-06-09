# SES (notifications) — owned by /infrastructure/ses + /backend/notifications. Phase 2 verifies the
# sending domain identity + DKIM; the BFF sends via the SES API with its exec role (ses:SendEmail in
# api.tf) — NO SMTP user/credential (ses_user_enabled=false), so nothing to store or rotate.
#
# Per-env DOMAIN identity (staging.tadeumendonca.io / tadeumendonca.io), NOT a single apex identity:
# the two environments are independent TF workspaces and can't both own the same apex SES identity in
# one account/region without colliding. Per-env identities isolate the envs cleanly. From-address =
# no-reply@<frontend_host>. New accounts are SES-sandboxed (verified recipients only) — production
# access is a manual, out-of-band request.
module "ses" {
  source  = "cloudposse/ses/aws"
  version = "~> 0.25"

  domain        = local.frontend_host
  zone_id       = data.aws_route53_zone.main.zone_id # writes the _amazonses TXT + DKIM CNAMEs here
  verify_domain = true
  verify_dkim   = true

  ses_user_enabled  = false # the BFF role sends via the SES API — no SMTP IAM user
  ses_group_enabled = false

  name    = "ses"
  stage   = var.environment
  enabled = true
}

resource "aws_ssm_parameter" "ses_from_address" {
  name  = "/${var.environment}/notifications/ses-from-address"
  type  = "String"
  value = local.ses_from_address
}
