# Root outputs (visibility in TFC). Intra-root references use the module/resource directly;
# these surface the network handles other layers compose against.

output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet ids — Lambda ENIs, DocumentDB, and Redis live here."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet ids (NAT gateways)."
  value       = module.vpc.public_subnets
}

output "lambda_security_group_id" {
  description = "Lambda SG id — set as source on the DocumentDB/Redis cluster SGs."
  value       = aws_security_group.lambda.id
}

output "frontend_bucket_name" {
  description = "Private fed SPA origin bucket (CloudFront OAC reads it)."
  value       = module.frontend_bucket.s3_bucket_id
}

output "artifacts_bucket_name" {
  description = "Lambda code artifacts bucket (Pattern B bootstrap + deploy zips)."
  value       = module.artifacts_bucket.s3_bucket_id
}

output "og_images_bucket_name" {
  description = "Generated OG images cache bucket."
  value       = module.og_images_bucket.s3_bucket_id
}

output "dynamodb_table_names" {
  description = "Per-entity DynamoDB table names (also published to SSM /{env}/data/*-table-name)."
  value = {
    profile       = module.profile_table.dynamodb_table_id
    posts         = module.posts_table.dynamodb_table_id
    articles      = module.articles_table.dynamodb_table_id
    subscriptions = module.subscriptions_table.dynamodb_table_id
    audits        = module.audits_table.dynamodb_table_id
  }
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution id (also in SSM /{env}/frontend/cloudfront-distribution-id)."
  value       = module.cloudfront.cloudfront_distribution_id
}

output "frontend_url" {
  description = "Public SPA URL (custom domain fronted by CloudFront)."
  value       = "https://${local.frontend_host}"
}

output "cognito_user_pool_id" {
  description = "Cognito user pool id (also in SSM /{env}/auth/cognito-user-pool-id)."
  value       = module.cognito.id
}

output "cognito_hosted_ui_url" {
  description = "Cognito custom hosted-UI URL."
  value       = "https://${local.auth_domain}"
}

output "waf_regional_arn" {
  description = "REGIONAL WAF web ACL ARN (shared by Cognito + API GW)."
  value       = module.waf_regional.arn
}
