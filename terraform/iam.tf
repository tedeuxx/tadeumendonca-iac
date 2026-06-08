# IAM layer — owned by /infrastructure/iam.
# GitHub OIDC deploy roles for the api + fed repos: a scoped deploy policy (iam-policy submodule)
# + an OIDC-assumable role (iam-assumable-role-with-oidc) each, with the role ARNs published to SSM.
# Trust = the pre-existing GitHub OIDC provider (landing zone), scoped to repo:<org>/<repo>:*.
# The iac repo's own deploy role is bootstrapped out-of-band (not here).

locals {
  account = data.aws_caller_identity.current.account_id
  # ARN fragments — scope every statement to specific resources (least privilege).
  artifacts_bucket_arn = "arn:aws:s3:::${local.account}-${var.project}-artifacts-${var.environment}"
  fed_bucket_arn       = "arn:aws:s3:::${local.account}-${var.project}-fed-${var.environment}"
  ssm_env_arn          = "arn:aws:ssm:${var.aws_region}:${local.account}:parameter/${var.environment}/*"
}

# api deploy policy — BFF/og-edge code update, API GW contract reimport, artifacts, SSM read.
module "policy_api_deploy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 5.0"

  name        = "${var.project}-api-deploy-${var.environment}"
  description = "GitHub Actions deploy policy for ${var.project}-api (${var.environment})."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaCodeDeploy"
        Effect = "Allow"
        Action = ["lambda:UpdateFunctionCode", "lambda:PublishVersion", "lambda:GetFunction"]
        # BFF + og-edge, by name pattern (<project>-<fn>-<env>) — never lambda:* on *.
        Resource = "arn:aws:lambda:${var.aws_region}:${local.account}:function:${var.project}-*-${var.environment}"
      },
      {
        Sid      = "ApiGatewayReimport"
        Effect   = "Allow"
        Action   = ["apigateway:PUT", "apigateway:POST", "apigateway:GET"]
        Resource = "arn:aws:apigateway:${var.aws_region}::/apis/*"
      },
      {
        Sid      = "ArtifactsBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${local.artifacts_bucket_arn}/*"
      },
      {
        Sid      = "ReadConfigBus"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = local.ssm_env_arn
      },
    ]
  })
}

# fed deploy policy — site sync to the fed bucket, CloudFront invalidation, SSM read.
module "policy_fed_deploy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 5.0"

  name        = "${var.project}-fed-deploy-${var.environment}"
  description = "GitHub Actions deploy policy for ${var.project}-fed (${var.environment})."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SiteObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.fed_bucket_arn}/*"
      },
      {
        Sid      = "SiteList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.fed_bucket_arn
      },
      {
        Sid      = "CloudFrontInvalidation"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = "arn:aws:cloudfront::${local.account}:distribution/*"
      },
      {
        Sid      = "ReadConfigBus"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = local.ssm_env_arn
      },
    ]
  })
}

module "oidc_api" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                    = true
  role_name                      = "github-actions-api-${var.environment}"
  provider_url                   = "token.actions.githubusercontent.com" # pre-existing provider
  oidc_fully_qualified_audiences = ["sts.amazonaws.com"]
  oidc_subjects_with_wildcards   = ["repo:${var.github_org}/${var.project}-api:*"]
  role_policy_arns               = [module.policy_api_deploy.arn]
}

module "oidc_fed" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                    = true
  role_name                      = "github-actions-fed-${var.environment}"
  provider_url                   = "token.actions.githubusercontent.com"
  oidc_fully_qualified_audiences = ["sts.amazonaws.com"]
  oidc_subjects_with_wildcards   = ["repo:${var.github_org}/${var.project}-fed:*"]
  role_policy_arns               = [module.policy_fed_deploy.arn]
}

# SSM config bus — app repos read AWS_OIDC_ROLE_ARN at deploy (never a rotatable secret).
resource "aws_ssm_parameter" "api_role_arn" {
  name  = "/${var.environment}/iam/github-actions-api-role-arn"
  type  = "String"
  value = module.oidc_api.iam_role_arn
}

resource "aws_ssm_parameter" "fed_role_arn" {
  name  = "/${var.environment}/iam/github-actions-fed-role-arn"
  type  = "String"
  value = module.oidc_fed.iam_role_arn
}
