# API layer (6a) — owned by /infrastructure/api-gateway + /infrastructure/lambda.
# API GW v2 (HTTP) fronts ONLY the BFF: a single AWS_PROXY integration, routes at root. IaC seeds
# the shell (GET /health); the api repo owns the full contract via reimport-api (Pattern B for code).
# og-edge Lambda@Edge + its CloudFront association are #6b (#22). Redis/SNS env+policy → Phase 2.

# Pattern B bootstrap: a minimal placeholder zip so the Lambda provisions with config only; the api
# repo ships real code via update-function-code (ignore_source_code_hash keeps the two from colliding).
data "archive_file" "bootstrap" {
  type                    = "zip"
  output_path             = "${path.module}/bootstrap/placeholder.zip"
  source_content_filename = "index.js"
  source_content          = "exports.handler = async () => ({ statusCode: 200, body: JSON.stringify({ status: 'bootstrap' }) });"
}

resource "aws_s3_object" "bff_bootstrap" {
  bucket = module.artifacts_bucket.s3_bucket_id
  key    = "bff/bootstrap.zip"
  source = data.archive_file.bootstrap.output_path
  etag   = data.archive_file.bootstrap.output_md5
}

# BFF Lambda — in-VPC Hono modular monolith. Pattern B (placeholder zip; api repo ships code).
module "bff" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name = "${var.project}-bff-${var.environment}"
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"] # Graviton
  timeout       = 29        # API GW ceiling
  memory_size   = 256       # bundles satori/resvg (OG image module)
  tracing_mode  = "Active"

  create_package          = false
  ignore_source_code_hash = true
  s3_existing_package     = { bucket = module.artifacts_bucket.s3_bucket_id, key = "bff/bootstrap.zip" }

  # in-VPC (private subnets) — DynamoDB via the Gateway endpoint, AWS APIs via NAT
  vpc_subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.lambda.id]
  attach_network_policy  = true
  attach_tracing_policy  = true # AWSXRayDaemonWriteAccess

  environment_variables = {
    ENVIRONMENT              = var.environment
    LOG_LEVEL                = "INFO"
    POWERTOOLS_SERVICE_NAME  = "bff"
    PROFILE_TABLE_NAME       = module.profile_table.dynamodb_table_id
    POSTS_TABLE_NAME         = module.posts_table.dynamodb_table_id
    ARTICLES_TABLE_NAME      = module.articles_table.dynamodb_table_id
    SUBSCRIPTIONS_TABLE_NAME = module.subscriptions_table.dynamodb_table_id
    AUDITS_TABLE_NAME        = module.audits_table.dynamodb_table_id
    OG_IMAGES_BUCKET         = module.og_images_bucket.s3_bucket_id
    # REDIS_* / SNS_TOPIC_ARN added in Phase 2 (cache.tf / sns.tf).
  }

  # least-privilege exec role (/infrastructure/iam). Redis secret + SNS publish → Phase 2.
  attach_policy_statements = true
  policy_statements = {
    data_tables = {
      effect = "Allow"
      actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
      "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:BatchGetItem"] # no Scan
      resources = [
        "arn:aws:dynamodb:${var.aws_region}:${local.account}:table/${var.project}-*-${var.environment}",
        "arn:aws:dynamodb:${var.aws_region}:${local.account}:table/${var.project}-*-${var.environment}/index/*",
      ]
    }
    read_ssm = {
      effect    = "Allow"
      actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      resources = [local.ssm_env_arn]
    }
    og_cache = {
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject"]
      resources = ["arn:aws:s3:::${local.bucket_prefix}-og-images-${var.environment}/*"]
    }
  }

  depends_on = [aws_s3_object.bff_bootstrap]
}

# API GW v2 (HTTP) — fronts only the BFF; custom domain; seed body (GET /health). The api repo owns
# the full contract (reimport-api) — create_routes_and_integrations=false so Terraform won't manage routes.
module "apigw" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "~> 5.0"

  name          = "${var.project}-${var.environment}"
  protocol_type = "HTTP"

  domain_name                 = local.api_domain
  domain_name_certificate_arn = data.aws_acm_certificate.main.arn
  create_certificate          = false
  create_domain_records       = false # we manage the Route53 alias below (module derives the wrong zone)

  cors_configuration = {
    allow_origins = ["https://${local.frontend_host}"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 300
  }

  create_routes_and_integrations = false
  body = templatefile("${path.module}/bootstrap/openapi-health.json.tftpl", {
    health_integration_uri = module.bff.lambda_function_invoke_arn
  })
}

# Broad invoke permission so reimported routes need no new grant.
resource "aws_lambda_permission" "apigw_bff" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.bff.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.apigw.api_execution_arn}/*/*"
}

# REGIONAL WAF → API GW stage (deferred from auth.tf #5). Raw glue — no native WAF arg on the stage.
resource "aws_wafv2_web_acl_association" "api_gw" {
  resource_arn = module.apigw.stage_arn
  web_acl_arn  = module.waf_regional.arn
}

# Route53 A-alias for the custom API domain → API GW.
resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.api_domain
  type    = "A"
  alias {
    name                   = module.apigw.domain_name_target_domain_name
    zone_id                = module.apigw.domain_name_hosted_zone_id
    evaluate_target_health = false
  }
}

# SSM config bus.
resource "aws_ssm_parameter" "gateway_url" {
  name  = "/${var.environment}/api/gateway-url"
  type  = "String"
  value = "https://${local.api_domain}"
}

resource "aws_ssm_parameter" "gateway_id" {
  name  = "/${var.environment}/api/gateway-id"
  type  = "String"
  value = module.apigw.api_id
}

resource "aws_ssm_parameter" "bff_function_name" {
  name  = "/${var.environment}/api/bff-function-name"
  type  = "String"
  value = module.bff.lambda_function_name
}
