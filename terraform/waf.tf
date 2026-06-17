# Shared REGIONAL WAF — the only thing this repo owns. It is a workload-agnostic security baseline:
# any workload's regional resources (API Gateway stages, Cognito hosted UIs, ALBs) can associate with
# it. The associations themselves live in the consuming workloads (e.g. tadeumendonca-pwa's api.tf +
# auth.tf read the ARN below via the SSM config bus and create their own aws_wafv2_web_acl_association).
# Block-list model. Pinned to the aws-5-compatible module line.

# WAF log group — name MUST start with aws-waf-logs- (AWS mandate).
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.project}-${var.environment}"
  retention_in_days = var.environment == "production" ? 90 : 30
}

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

# SSM config bus — consuming workloads read this to associate their regional resources with the WAF.
resource "aws_ssm_parameter" "waf_regional_arn" {
  name  = "/${var.environment}/auth/waf-regional-arn"
  type  = "String"
  value = module.waf_regional.arn
}
