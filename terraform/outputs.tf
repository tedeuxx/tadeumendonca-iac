# Root outputs (visibility in TFC). This repo owns the SHARED foundation only; the app-infra outputs
# (buckets, dynamodb_table_names, cloudfront_distribution_id, frontend_url, github_actions_role_arns)
# moved with the app .tf to the tadeumendonca-pwa monorepo (iac/ split). The app reads the values below
# via the SSM config bus (no terraform_remote_state).

output "cognito_user_pool_id" {
  description = "Cognito user pool id (also in SSM /{env}/auth/cognito-user-pool-id)."
  value       = module.cognito.id
}

output "cognito_hosted_ui_url" {
  description = "Cognito custom hosted-UI URL."
  value       = "https://${local.auth_domain}"
}

output "waf_regional_arn" {
  description = "REGIONAL WAF web ACL ARN (protects the Cognito hosted UI + the app's API GW; consumed via SSM /{env}/auth/waf-regional-arn)."
  value       = module.waf_regional.arn
}
