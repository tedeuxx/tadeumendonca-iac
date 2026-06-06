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
