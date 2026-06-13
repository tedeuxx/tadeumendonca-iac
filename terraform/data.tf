# Root data sources, declared once. account_id prefixes globally-unique S3 bucket names and is
# never hardcoded (/infrastructure/terraform).
data "aws_caller_identity" "current" {}

# Pre-existing hosted zone for the apex domain — frontend/auth/api records land here.
data "aws_route53_zone" "main" {
  name = var.apex_domain
}

# ACM cert pre-created + DNS-validated out-of-band in us-east-1 (covers apex + *.<apex> + per-env
# wildcards). Resolved by domain — never an ARN in tfvars (/infrastructure/acm). us-east-1 because
# CloudFront, API GW custom domains, and the Cognito custom domain all require it there.
data "aws_acm_certificate" "main" {
  provider    = aws.us_east_1
  domain      = var.apex_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

# Data tier — owned by /infrastructure/dynamodb.
# Per-entity DynamoDB tables, on-demand (PAY_PER_REQUEST, ~$0 idle). Access is pure IAM (no creds,
# no secret, no SG); reached over the DynamoDB Gateway endpoint (vpc.tf), off the NAT path. Shared
# baseline on every table: on-demand billing, SSE with the AWS-managed aws/dynamodb key, PITR on,
# deletion protection in production. Only key/GSI attributes are declared — DynamoDB is schemaless.

locals {
  ddb_deletion_protection = var.environment == "production"
}

# profile — the CV document (effectively one item, profile_id = "me").
module "profile_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-profile-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "profile_id"
  attributes   = [{ name = "profile_id", type = "S" }]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# posts — feed; by-created GSI (constant gsi_pk + created_at) returns newest-first via cursor.
module "posts_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-posts-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "post_id"
  attributes = [
    { name = "post_id", type = "S" },
    { name = "gsi_pk", type = "S" },
    { name = "created_at", type = "S" },
  ]
  global_secondary_indexes = [{
    name            = "by-created"
    hash_key        = "gsi_pk"
    range_key       = "created_at"
    projection_type = "ALL"
  }]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# articles — by-slug (routing) + by-tag (primary tag) + by-created (unified-feed list). Like posts,
# by-created is SPARSE: gsi_pk = "ARTICLE" is set only when published, so the feed/list query
# (gsi_pk = "ARTICLE", created_at desc) returns published articles newest-first WITHOUT a Scan.
module "articles_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-articles-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "article_id"
  attributes = [
    { name = "article_id", type = "S" },
    { name = "slug", type = "S" },
    { name = "tag", type = "S" },
    { name = "gsi_pk", type = "S" },
    { name = "created_at", type = "S" },
  ]
  global_secondary_indexes = [
    {
      name            = "by-slug"
      hash_key        = "slug"
      projection_type = "ALL"
    },
    {
      name            = "by-tag"
      hash_key        = "tag"
      range_key       = "created_at"
      projection_type = "ALL"
    },
    {
      name            = "by-created"
      hash_key        = "gsi_pk"
      range_key       = "created_at"
      projection_type = "ALL"
    },
  ]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# subscriptions — by-status (list active) + by-cognito (lookup by user).
module "subscriptions_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-subscriptions-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"
  attributes = [
    { name = "email", type = "S" },
    { name = "status", type = "S" },
    { name = "cognito_sub", type = "S" },
  ]
  global_secondary_indexes = [
    {
      name            = "by-status"
      hash_key        = "status"
      range_key       = "email"
      projection_type = "ALL"
    },
    {
      name            = "by-cognito"
      hash_key        = "cognito_sub"
      projection_type = "ALL"
    },
  ]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# audits — by-entity + by-actor (admin dashboard); TTL auto-expires old trail entries.
module "audits_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-audits-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "audit_id"
  attributes = [
    { name = "audit_id", type = "S" },
    { name = "entity", type = "S" },
    { name = "actor", type = "S" },
    { name = "created_at", type = "S" },
  ]
  global_secondary_indexes = [
    {
      name            = "by-entity"
      hash_key        = "entity"
      range_key       = "created_at"
      projection_type = "ALL"
    },
    {
      name            = "by-actor"
      hash_key        = "actor"
      range_key       = "created_at"
      projection_type = "ALL"
    },
  ]

  ttl_enabled        = true
  ttl_attribute_name = "ttl" # epoch seconds; the app sets it on write (/backend/audit-middleware)

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# comments — post-moderated comments on posts. by-post GSI lists a post's comments oldest-first.
module "comments_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-comments-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "comment_id"
  attributes = [
    { name = "comment_id", type = "S" },
    { name = "post_id", type = "S" },
    { name = "created_at", type = "S" },
  ]
  global_secondary_indexes = [{
    name            = "by-post"
    hash_key        = "post_id"
    range_key       = "created_at"
    projection_type = "ALL"
  }]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# shortlinks — code → target map for share URLs (tadeumendonca.io/p/<code>). Hash on the opaque code.
module "shortlinks_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-shortlinks-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"
  attributes   = [{ name = "code", type = "S" }]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# polls — enquete surfaced in the aside. by-created is SPARSE (gsi_pk = "POLL" set only when
# published) so the "current poll" query (gsi_pk = "POLL", created_at desc, limit 1) returns the
# newest published poll WITHOUT a Scan, exactly like posts. Vote tallies live as a counter map on the
# poll item, ADDed atomically on each vote — anonymous, 1/browser (localStorage), no votes table.
module "polls_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-polls-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "poll_id"
  attributes = [
    { name = "poll_id", type = "S" },
    { name = "gsi_pk", type = "S" },
    { name = "created_at", type = "S" },
  ]
  global_secondary_indexes = [{
    name            = "by-created"
    hash_key        = "gsi_pk"
    range_key       = "created_at"
    projection_type = "ALL"
  }]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# users — per-account profile + preferences (Phase 3), keyed by the Cognito sub (one item per
# signed-in user): nickname/apelido, avatar key, communication prefs. The SPARSE `by-digest` GSI lets
# the newsletter-digest Lambda Query opted-in users by cadence WITHOUT a Scan — digest_schedule
# (= "daily" | "weekly") is written ONLY while the user is opted in, so opted-out users carry no key
# and never appear in the index. Entity name is English (`users`, not "usuarios"); the UI stays pt-BR.
module "users_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = "${var.project}-users-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cognito_sub"
  attributes = [
    { name = "cognito_sub", type = "S" },
    { name = "digest_schedule", type = "S" },
  ]
  global_secondary_indexes = [{
    name            = "by-digest"
    hash_key        = "digest_schedule"
    range_key       = "cognito_sub"
    projection_type = "ALL"
  }]

  server_side_encryption_enabled = true
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = local.ddb_deletion_protection
}

# SSM config bus — table names (IAM access; no secret/endpoint). app repos read at deploy.
resource "aws_ssm_parameter" "profile_table_name" {
  name  = "/${var.environment}/data/profile-table-name"
  type  = "String"
  value = module.profile_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "posts_table_name" {
  name  = "/${var.environment}/data/posts-table-name"
  type  = "String"
  value = module.posts_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "articles_table_name" {
  name  = "/${var.environment}/data/articles-table-name"
  type  = "String"
  value = module.articles_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "subscriptions_table_name" {
  name  = "/${var.environment}/data/subscriptions-table-name"
  type  = "String"
  value = module.subscriptions_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "audits_table_name" {
  name  = "/${var.environment}/data/audits-table-name"
  type  = "String"
  value = module.audits_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "comments_table_name" {
  name  = "/${var.environment}/data/comments-table-name"
  type  = "String"
  value = module.comments_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "shortlinks_table_name" {
  name  = "/${var.environment}/data/shortlinks-table-name"
  type  = "String"
  value = module.shortlinks_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "polls_table_name" {
  name  = "/${var.environment}/data/polls-table-name"
  type  = "String"
  value = module.polls_table.dynamodb_table_id
}

resource "aws_ssm_parameter" "users_table_name" {
  name  = "/${var.environment}/data/users-table-name"
  type  = "String"
  value = module.users_table.dynamodb_table_id
}
