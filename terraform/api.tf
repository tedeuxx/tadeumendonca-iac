# API layer (6a) — owned by /infrastructure/api-gateway + /infrastructure/lambda.
# API Gateway REST (v1, REGIONAL) fronts ONLY the BFF: one AWS_PROXY (Lambda proxy) integration,
# routes at root. IaC seeds the shell (GET /health) into the OpenAPI body; the api repo owns the full
# contract via `put-rest-api --mode overwrite` (Pattern B for code). REST chosen over HTTP API because
# it is WAF-associable (per-IP managed rules) + supports usage plans / request validation.
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

# BFF Lambda — Hono modular monolith. Pattern B (placeholder zip; api repo ships code).
# NON-VPC by deliberate cost choice: the BFF reaches DynamoDB/S3/SES/Cognito/SSM over their public AWS
# endpoints (IAM-auth'd, TLS) — no NAT needed. It runs in the VPC ONLY when it has an in-VPC dependency
# (ElastiCache/Redis, deferred); re-add vpc_subnet_ids + a SG + attach_network_policy then. Bonus:
# non-VPC = faster cold starts (no ENI attach). (/infrastructure/lambda, /infrastructure/vpc)
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

  attach_tracing_policy = true # AWSXRayDaemonWriteAccess

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
    SES_FROM_ADDRESS         = local.ses_from_address # notifications sender (ses.tf)
    # REDIS_* / SNS_TOPIC_ARN added later in Phase 2 (cache.tf / sns.tf).
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
    # ListBucket on the bucket itself so a cache-miss HeadObject returns 404 (not 403): without
    # s3:ListBucket, S3 hides existence and returns 403 for absent keys, which the og-image
    # cache-aside would surface as a 500 instead of regenerating (/backend/og-image-generator).
    og_list = {
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = ["arn:aws:s3:::${local.bucket_prefix}-og-images-${var.environment}"]
    }
    # Send notification email via the SES API (no SMTP creds) — scoped to this env's domain identity
    # (ses.tf). The Cc/Bcc-free SendEmail is authorized by the From identity ARN (/backend/notifications).
    ses_send = {
      effect    = "Allow"
      actions   = ["ses:SendEmail"]
      resources = ["arn:aws:ses:${var.aws_region}:${local.account}:identity/${local.frontend_host}"]
    }
  }

  depends_on = [aws_s3_object.bff_bootstrap]
}

# REST API — body is the OpenAPI spec (seed: GET /health → BFF). The api repo owns the body after
# first apply via put-rest-api, so ignore_changes=[body] keeps Terraform from fighting it.
resource "aws_api_gateway_rest_api" "this" {
  name = "${var.project}-${var.environment}"
  endpoint_configuration {
    types = ["REGIONAL"] # REGIONAL (not EDGE): WAF-associable + regional cert
  }
  body = templatefile("${path.module}/bootstrap/openapi-health.json.tftpl", {
    health_integration_uri = module.bff.lambda_function_invoke_arn
  })
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [body]
  }
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  triggers    = { redeploy = sha1(aws_api_gateway_rest_api.this.body) } # redeploy on seed-body change
  lifecycle {
    create_before_destroy = true
  }
}

# Access logs for the stage (/infrastructure/cloudwatch).
resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project}-${var.environment}"
  retention_in_days = var.environment == "production" ? 90 : 30
}

resource "aws_api_gateway_stage" "this" {
  #checkov:skip=CKV_AWS_120:API GW caching is a paid cache cluster — caching is done at CloudFront + the BFF (Redis), not the gateway
  #checkov:skip=CKV2_AWS_51:no mTLS client-cert auth — the API authenticates callers via the Cognito JWT authorizer
  #checkov:skip=CKV2_AWS_77:the REGIONAL WAF includes AWSManagedRulesKnownBadInputsRuleSet (covers Log4j) — checkov can't see it through the cloudposse module
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  stage_name           = "live"
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format          = jsonencode({ requestId = "$context.requestId", ip = "$context.identity.sourceIp", method = "$context.httpMethod", path = "$context.path", status = "$context.status", latency = "$context.responseLatency" })
  }

  # The api repo republishes the contract via put-rest-api + create-deployment, which re-points the
  # stage to a fresh deployment. IaC seeds the initial deployment but must NOT revert that pointer on
  # later applies (Pattern B for the contract) — otherwise /profile etc. drop back to the seed body.
  lifecycle {
    ignore_changes = [deployment_id]
  }
}

# Stage throttling + per-method metrics — the native rate guard (/infrastructure/api-gateway).
resource "aws_api_gateway_method_settings" "this" {
  #checkov:skip=CKV_AWS_225:API GW response caching not used — caching is at CloudFront + the BFF (Redis)
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"
  settings {
    throttling_rate_limit  = 1000
    throttling_burst_limit = 2000
    metrics_enabled        = true
    logging_level          = "ERROR" # execution logs (CKV2_AWS_4)
  }
}

# Custom domain (REGIONAL) — the generated execute-api endpoint is never the public URL.
resource "aws_api_gateway_domain_name" "this" {
  domain_name              = local.api_domain
  regional_certificate_arn = data.aws_acm_certificate.main.arn # us-east-1 regional cert
  endpoint_configuration {
    types = ["REGIONAL"]
  }
  security_policy = "TLS_1_2"
}

resource "aws_api_gateway_base_path_mapping" "this" {
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this.domain_name
}

# Broad invoke permission so reimported routes need no new grant.
resource "aws_lambda_permission" "apigw_bff" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.bff.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

# REGIONAL WAF → the REST API stage (REST stages ARE WAF-associable). Raw glue — no native attr.
resource "aws_wafv2_web_acl_association" "api_gw" {
  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = module.waf_regional.arn
}

# Route53 A-alias for the custom API domain → the REST API regional domain.
resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.api_domain
  type    = "A"
  alias {
    name                   = aws_api_gateway_domain_name.this.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.this.regional_zone_id
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
  value = aws_api_gateway_rest_api.this.id
}

resource "aws_ssm_parameter" "bff_function_name" {
  name  = "/${var.environment}/api/bff-function-name"
  type  = "String"
  value = module.bff.lambda_function_name
}

# --- og-edge Lambda@Edge (#6b) — owned by /infrastructure/lambda + /backend/og-edge-handler ---
# 3-way UA classification at CloudFront Viewer Request (human passthrough / social OG / SEO crawler).
# Lambda@Edge constraints: us-east-1, x86_64 (no arm64), no VPC, NO env vars, ≤128MB / ≤5s, dual-trust.
#
# Pattern-B EXCEPTION: unlike the BFF (app repo ships code, IaC owns config), the edge code lives HERE
# and IaC owns its full lifecycle. CloudFront must reference a SPECIFIC published version (a qualified
# ARN — $LATEST is rejected), so every code change must publish a new version AND atomically repoint the
# distribution. Terraform does both in one apply (source hash → new version → new qualified_arn →
# CloudFront association); a separate CI pipeline mutating the version would fight the CloudFront module's
# state permanently. The handler is zero-dependency CJS deriving the API base from the Host header, so it
# needs no bundling and no env injection — Terraform zips lambda-src/og-edge/ directly.

module "fn_og_edge" {
  source    = "terraform-aws-modules/lambda/aws"
  version   = "~> 7.0"
  providers = { aws = aws.us_east_1 } # Lambda@Edge must be created in us-east-1

  function_name = "${var.project}-og-edge-${var.environment}"
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["x86_64"] # Lambda@Edge does NOT support arm64
  timeout       = 5          # viewer-request ceiling
  memory_size   = 128        # viewer-request ceiling

  lambda_at_edge = true # dual-trust (lambda + edgelambda) + publish a version (qualified ARN)

  create_package = true                                # IaC owns the code: hash change → new version
  source_path    = "${path.module}/lambda-src/og-edge" # single zero-dep index.js (no build step)
  # no VPC, no environment_variables — Lambda@Edge constraints (API base derived from the Host header)

  attach_policy_statements = true
  policy_statements = {
    og_read = {
      effect    = "Allow"
      actions   = ["s3:GetObject"] # serve cached OG images; BFF public routes reached over HTTPS (no IAM)
      resources = ["arn:aws:s3:::${local.bucket_prefix}-og-images-${var.environment}/*"]
    }
  }
}

resource "aws_ssm_parameter" "lambda_edge_og_qualified_arn" {
  name  = "/${var.environment}/api/lambda-edge-og-qualified-arn"
  type  = "String"
  value = module.fn_og_edge.lambda_function_qualified_arn
}
