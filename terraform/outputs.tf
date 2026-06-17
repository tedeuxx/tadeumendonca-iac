# Root outputs (visibility in TFC). This repo owns the SHARED regional WAF only; Cognito/SES + the app
# infra moved to the tadeumendonca-pwa monorepo. Consumers read the value below via the SSM config bus
# (/{env}/auth/waf-regional-arn) — no terraform_remote_state.

output "waf_regional_arn" {
  description = "REGIONAL WAF web ACL ARN (shared baseline; consumed via SSM /{env}/auth/waf-regional-arn)."
  value       = module.waf_regional.arn
}
