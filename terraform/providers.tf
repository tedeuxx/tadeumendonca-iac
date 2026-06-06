# Default provider (var.aws_region) + us_east_1 alias for CloudFront / WAF CLOUDFRONT / ACM /
# Cognito custom domain. Tags applied once via default_tags on BOTH providers — never per resource.
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}
