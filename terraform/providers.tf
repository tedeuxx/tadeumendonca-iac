# Single AWS provider (var.aws_region). Tags applied once via default_tags — never per resource.
# (The us-east-1 alias used by CloudFront / WAF CLOUDFRONT / ACM / the Cognito custom domain left with
# the app infra when it moved to the tadeumendonca-pwa monorepo; this repo owns only the regional WAF.)
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.tags
  }
}
