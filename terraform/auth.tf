# Auth layer — owned by /infrastructure/cognito + /infrastructure/waf.
# Cognito user pool: SOCIAL-ONLY via Google (no native signup); profiles admin + registered (public =
# unauthenticated). MFA OFF (federated → Google 2FA), threat protection ENFORCED, email via the verified
# SES identity. A small trigger (fn-cognito-groups) assigns groups (admin by email allowlist) + injects
# the group claim. Shared REGIONAL WAF fronts the hosted UI; the WAF↔API-GW association is in api.tf.

# Google OAuth client (id + secret) from Secrets Manager — provisioned out-of-band (owner created the
# Google client). Both kept together in the secret; only the secret value is sensitive.
data "aws_secretsmanager_secret_version" "google_oauth" {
  secret_id = "${var.project}/${var.environment}/google-oauth"
}
locals {
  google_oauth = jsondecode(data.aws_secretsmanager_secret_version.google_oauth.secret_string)
}

# Cognito trigger — assigns federated users to 'registered' (+ 'admin' by allowlist) and injects the
# group claim into the token. NO module.cognito references (would create a cycle): the pool id comes
# from the trigger EVENT, and the IAM policy is scoped to userpool/* in this account. Non-VPC, fail-open.
module "fn_cognito_groups" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name = "${var.project}-cognito-groups-${var.environment}"
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  timeout       = 5
  memory_size   = 128

  create_package = true
  source_path    = "${path.module}/lambda-src/cognito-groups"

  environment_variables = { ADMIN_EMAILS = join(",", var.admin_emails) }

  attach_policy_statements = true
  policy_statements = {
    groups = {
      effect    = "Allow"
      actions   = ["cognito-idp:AdminAddUserToGroup", "cognito-idp:AdminListGroupsForUser"]
      resources = ["arn:aws:cognito-idp:${var.aws_region}:${local.account}:userpool/*"] # pool id is post-apply; one pool
    }
  }
}

module "cognito" {
  source  = "lgallard/cognito-user-pool/aws"
  version = "~> 0.31"

  user_pool_name           = "${var.project}-${var.environment}"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF" # social-only → MFA is the IdP's (Google 2FA)

  # Threat protection requires the PLUS tier (the default ESSENTIALS rejects advanced_security ENFORCED
  # with FeatureUnavailableInTierException). PLUS ≈ $0.05/MAU — the owner accepted this for threat prot.
  user_pool_tier    = "PLUS"
  user_pool_add_ons = { advanced_security_mode = "ENFORCED" }

  # No native self-signup — users are provisioned on first Google login (federation).
  admin_create_user_config = { allow_admin_create_user_only = true }

  # Email via the verified SES domain identity (ses.tf) — same account, no extra SES auth policy needed.
  email_configuration = {
    email_sending_account = "DEVELOPER"
    from_email_address    = local.ses_from_address
    source_arn            = "arn:aws:ses:${var.aws_region}:${local.account}:identity/${local.frontend_host}"
  }

  user_groups = [
    { name = "admin", precedence = 1 },
    { name = "registered", precedence = 10 },
  ] # public = no group (unauthenticated)

  # Google as the only identity provider — social-only
  identity_providers = [{
    provider_name = "Google"
    provider_type = "Google"
    provider_details = {
      client_id        = local.google_oauth.client_id
      client_secret    = local.google_oauth.client_secret
      authorize_scopes = "openid email profile"
    }
    attribute_mapping = {
      email    = "email"
      name     = "name"
      username = "sub"
    }
  }]

  # Cognito trigger Lambdas (group assignment + claim injection)
  lambda_config = {
    post_authentication  = module.fn_cognito_groups.lambda_function_arn
    pre_token_generation = module.fn_cognito_groups.lambda_function_arn
  }

  # single PUBLIC SPA client — Authorization Code + PKCE, Google-only (no COGNITO native IdP)
  client_name                                 = "spa"
  client_generate_secret                      = false
  client_allowed_oauth_flows                  = ["code"]
  client_allowed_oauth_flows_user_pool_client = true
  client_allowed_oauth_scopes                 = ["openid", "email", "profile"]
  client_callback_urls                        = local.callback_urls
  client_logout_urls                          = local.logout_urls
  client_default_redirect_uri                 = local.callback_urls[0]
  client_supported_identity_providers         = ["Google"]
  client_explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  # custom hosted-UI domain is the standard — not the Cognito-generated prefix
  domain                 = local.auth_domain
  domain_certificate_arn = data.aws_acm_certificate.main.arn # ISSUED cert in us-east-1
}

# Allow Cognito to invoke the trigger Lambda.
resource "aws_lambda_permission" "cognito_groups" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.fn_cognito_groups.lambda_function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = module.cognito.arn
}

# Hosted-UI branding (classic, managed_login_version=1) — on-brand with the site's look: dark slate
# background + cyan accent (the palette from the OG cards / SPA). CSS uses only the documented
# customizable classes + safe property combos (Cognito validates strictly). The "Continue with Google"
# idpButton keeps Google's standard styling (brand guidelines) on the dark background.
resource "aws_cognito_user_pool_ui_customization" "this" {
  user_pool_id = module.cognito.id
  image_file   = filebase64("${path.module}/assets/cognito-logo.png")
  css          = <<-CSS
    .background-customizable { background-color: #0f172a; }
    .banner-customizable { background-color: #0f172a; }
    .label-customizable { color: #f8fafc; }
    .textDescription-customizable { color: #94a3b8; }
    .idpDescription-customizable { color: #94a3b8; }
    .legalText-customizable { color: #94a3b8; }
    .submitButton-customizable { background-color: #38bdf8; }
    .submitButton-customizable:hover { background-color: #0ea5e9; }
    .logo-customizable { max-width: 380px; max-height: 72px; }
  CSS
}

# WAF log group — name MUST start with aws-waf-logs- (AWS mandate). /infrastructure/cloudwatch
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.project}-${var.environment}"
  retention_in_days = var.environment == "production" ? 90 : 30
}

# REGIONAL WAF — shared by Cognito (here) + API GW (associated in api.tf). Block-list model.
module "waf_regional" {
  source = "cloudposse/waf/aws"
  # Pinned to 1.11.x (not ~> 1.0): cloudposse/waf >= 1.12 requires aws >= 6.2, conflicting with the
  # project-wide aws ~> 5.0 pin. 1.11.0 is the latest aws-5-compatible release. Revisit on aws v6.
  version = "~> 1.11.0"

  name           = "${var.project}-regional-${var.environment}"
  scope          = "REGIONAL"
  default_action = "allow"

  # cloudposse/waf 1.11.x requires a per-rule visibility_config (the AWS web ACL mandates one per
  # rule); newer module lines default it, but the aws-5-compatible pin needs it explicit.
  managed_rule_group_statement_rules = [
    {
      name            = "common"
      priority        = 1
      override_action = "none"
      statement       = { name = "AWSManagedRulesCommonRuleSet", vendor_name = "AWS" }
      visibility_config = {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.project}-regional-common-${var.environment}"
      }
    },
    {
      name            = "known-bad"
      priority        = 2
      override_action = "none"
      statement       = { name = "AWSManagedRulesKnownBadInputsRuleSet", vendor_name = "AWS" }
      visibility_config = {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.project}-regional-known-bad-${var.environment}"
      }
    },
  ]

  rate_based_statement_rules = [
    {
      name      = "rate-limit"
      priority  = 10
      action    = "block"
      statement = { limit = 2000, aggregate_key_type = "IP" }
      visibility_config = {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.project}-regional-rate-limit-${var.environment}"
      }
    },
  ]

  visibility_config = {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "${var.project}-regional-${var.environment}"
  }

  # logging is enabled by a non-empty log_destination_configs (1.11.x has no logging_enabled flag)
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}

# Associate the REGIONAL WAF with the Cognito hosted UI (open self-signup). Raw glue — no native
# WAF attribute on the user pool. The API GW stage association is added in api.tf (#6).
resource "aws_wafv2_web_acl_association" "cognito" {
  resource_arn = module.cognito.arn
  web_acl_arn  = module.waf_regional.arn
}

# Route53 A-alias for the custom auth domain → the Cognito-managed CloudFront distribution.
resource "aws_route53_record" "auth" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.auth_domain
  type    = "A"
  alias {
    name                   = module.cognito.domain_cloudfront_distribution
    zone_id                = module.cognito.domain_cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

# SSM config bus (/infrastructure/ssm) — app repos read at deploy / build.
resource "aws_ssm_parameter" "cognito_user_pool_id" {
  name  = "/${var.environment}/auth/cognito-user-pool-id"
  type  = "String"
  value = module.cognito.id
}

resource "aws_ssm_parameter" "cognito_client_id" {
  name  = "/${var.environment}/auth/cognito-client-id"
  type  = "String"
  value = module.cognito.client_ids[0] # single SPA client
}

resource "aws_ssm_parameter" "cognito_domain" {
  name  = "/${var.environment}/auth/cognito-domain"
  type  = "String"
  value = local.auth_domain
}

resource "aws_ssm_parameter" "cognito_hosted_ui_url" {
  name  = "/${var.environment}/auth/cognito-hosted-ui-url"
  type  = "String"
  value = "https://${local.auth_domain}"
}

resource "aws_ssm_parameter" "waf_regional_arn" {
  name  = "/${var.environment}/auth/waf-regional-arn"
  type  = "String"
  value = module.waf_regional.arn
}
