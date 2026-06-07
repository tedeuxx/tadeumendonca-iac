# Auth layer — owned by /infrastructure/cognito + /infrastructure/waf.
# Cognito user pool (3 profiles: public / registered self-signup / admin) with a public PKCE client
# and a custom hosted-UI domain; a shared REGIONAL WAF fronting the open signup surface. SES is
# deferred to Phase 2 (#17). The WAF↔API-GW association lives in api.tf (#6).

module "cognito" {
  source  = "lgallard/cognito-user-pool/aws"
  version = "~> 0.31"

  user_pool_name           = "${var.project}-${var.environment}"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"

  password_policy = {
    minimum_length                   = 12
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
    password_history_size            = 24
  }

  admin_create_user_config = { allow_admin_create_user_only = false } # registered users self-signup

  user_groups = [
    { name = "admin", precedence = 1 },
    { name = "registered", precedence = 10 },
  ] # public = no group

  # single public app client (the SPA) — Authorization Code + PKCE, no secret
  client_name                                 = "spa"
  client_generate_secret                      = false
  client_allowed_oauth_flows                  = ["code"]
  client_allowed_oauth_flows_user_pool_client = true
  client_allowed_oauth_scopes                 = ["openid", "email", "profile"]
  client_callback_urls                        = local.callback_urls
  client_logout_urls                          = local.logout_urls
  client_default_redirect_uri                 = local.callback_urls[0] # must be one of the callback URLs
  client_supported_identity_providers         = ["COGNITO"]
  client_explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]

  # custom hosted-UI domain is the standard — not the Cognito-generated prefix
  domain                 = local.auth_domain
  domain_certificate_arn = data.aws_acm_certificate.main.arn # ISSUED cert in us-east-1
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
