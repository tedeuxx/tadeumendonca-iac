# Frontend layer — owned by /infrastructure/cloudfront (+ /infrastructure/waf, /infrastructure/s3,
# /infrastructure/route53). CloudFront fronts the private fed bucket (OAC) at the custom domain, with
# a /og/* behavior to the og-images bucket and SPA error routing. The Lambda@Edge (og-edge) viewer
# request is deferred to api.tf (#6) — the SPA serves fine without it (it's bot/SEO only).

# WAF CLOUDFRONT scope — us-east-1 (required). Same block-list model + pin rationale as the REGIONAL
# WAF (auth.tf): cloudposse/waf 1.11.x (>= 1.12 needs aws v6) with a per-rule visibility_config.
resource "aws_cloudwatch_log_group" "waf_cloudfront" {
  provider          = aws.us_east_1 # CLOUDFRONT WAF logs must live in us-east-1
  name              = "aws-waf-logs-${var.project}-cloudfront-${var.environment}"
  retention_in_days = var.environment == "production" ? 90 : 30
}

module "waf_cloudfront" {
  source    = "cloudposse/waf/aws"
  version   = "~> 1.11.0"
  providers = { aws = aws.us_east_1 }

  name           = "${var.project}-cloudfront-${var.environment}"
  scope          = "CLOUDFRONT"
  default_action = "allow"

  managed_rule_group_statement_rules = [
    {
      name            = "common"
      priority        = 1
      override_action = "none"
      statement       = { name = "AWSManagedRulesCommonRuleSet", vendor_name = "AWS" }
      visibility_config = {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.project}-cloudfront-common-${var.environment}"
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
        metric_name                = "${var.project}-cloudfront-rate-limit-${var.environment}"
      }
    },
  ]

  visibility_config = {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "${var.project}-cloudfront-${var.environment}"
  }

  log_destination_configs = [aws_cloudwatch_log_group.waf_cloudfront.arn]
}

module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 3.0"

  aliases             = [local.frontend_host]
  comment             = "${var.project} SPA — ${var.environment}"
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  price_class         = "PriceClass_100" # NA + EU edges (cheapest)
  wait_for_deployment = false
  web_acl_id          = module.waf_cloudfront.arn

  create_origin_access_control = true
  origin_access_control = {
    s3_oac = { description = "${var.project}-${var.environment}", origin_type = "s3", signing_behavior = "always", signing_protocol = "sigv4" }
  }

  origin = {
    s3 = {
      domain_name           = module.frontend_bucket.s3_bucket_bucket_regional_domain_name
      origin_access_control = "s3_oac"
    }
    og = {
      domain_name           = module.og_images_bucket.s3_bucket_bucket_regional_domain_name
      origin_access_control = "s3_oac"
    }
    assets = {
      domain_name           = module.assets_bucket.s3_bucket_bucket_regional_domain_name
      origin_access_control = "s3_oac"
    }
  }

  default_cache_behavior = {
    target_origin_id           = "s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    use_forwarded_values       = false
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # managed CachingOptimized
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03" # managed SecurityHeadersPolicy
    # og-edge Lambda@Edge (#6b): 3-way UA routing (human passthrough / social OG / SEO crawler)
    lambda_function_association = {
      viewer-request = {
        lambda_arn   = module.fn_og_edge.lambda_function_qualified_arn
        include_body = false
      }
    }
  }

  ordered_cache_behavior = [
    {
      path_pattern           = "/og/*"
      target_origin_id       = "og"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true
      use_forwarded_values   = false
      cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    },
    {
      path_pattern           = "/assets/*"
      target_origin_id       = "assets"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true
      use_forwarded_values   = false
      cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    },
  ]

  viewer_certificate = {
    acm_certificate_arn      = data.aws_acm_certificate.main.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # SPA client-side routing: serve index.html (200) on 403/404 from the origin.
  custom_error_response = [
    { error_code = 403, response_code = 200, response_page_path = "/index.html" },
    { error_code = 404, response_code = 200, response_page_path = "/index.html" },
  ]
}

# Combined bucket policy (TLS-deny + CloudFront OAC read) for the private fed + og-images buckets.
# Standalone resource (not the s3 module's attach_policy) to break the storage↔frontend cycle.
data "aws_iam_policy_document" "frontend_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      module.frontend_bucket.s3_bucket_arn,
      "${module.frontend_bucket.s3_bucket_arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.frontend_bucket.s3_bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront.cloudfront_distribution_arn]
    }
  }
}

data "aws_iam_policy_document" "og_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      module.og_images_bucket.s3_bucket_arn,
      "${module.og_images_bucket.s3_bucket_arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.og_images_bucket.s3_bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront.cloudfront_distribution_arn]
    }
  }
}

data "aws_iam_policy_document" "assets_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      module.assets_bucket.s3_bucket_arn,
      "${module.assets_bucket.s3_bucket_arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.assets_bucket.s3_bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront.cloudfront_distribution_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = module.frontend_bucket.s3_bucket_id
  policy = data.aws_iam_policy_document.frontend_bucket.json
}

resource "aws_s3_bucket_policy" "og" {
  bucket = module.og_images_bucket.s3_bucket_id
  policy = data.aws_iam_policy_document.og_bucket.json
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = module.assets_bucket.s3_bucket_id
  policy = data.aws_iam_policy_document.assets_bucket.json
}

# Route53 A-alias for the custom frontend domain → the CloudFront distribution.
resource "aws_route53_record" "frontend" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.frontend_host
  type    = "A"
  alias {
    name                   = module.cloudfront.cloudfront_distribution_domain_name
    zone_id                = "Z2FDTNDATAQYW2" # fixed CloudFront hosted-zone id
    evaluate_target_health = false
  }
}

resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  name  = "/${var.environment}/frontend/cloudfront-distribution-id"
  type  = "String"
  value = module.cloudfront.cloudfront_distribution_id
}
