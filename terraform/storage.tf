# Storage layer — owned by /infrastructure/s3.
# Three buckets via terraform-aws-modules/s3-bucket/aws ~> 4.0, all sharing one hardened baseline
# (ACLs off, public access fully blocked, SSE-KMS at rest, TLS-only in transit); only versioning,
# lifecycle, and purpose differ. Names are account-id-prefixed for global uniqueness.
#
# Bucket NAMES are created here; the OAC read policies for the private fed + og-images buckets are
# wired in frontend.tf (#7) once the CloudFront distribution exists — its SourceArn is the principal.

locals {
  bucket_prefix = "${data.aws_caller_identity.current.account_id}-${var.project}"

  # Shared hardened baseline applied to every bucket.
  s3_force_destroy = var.environment != "production" # stg can be torn down; prod protected

  # Default: SSE-KMS with the AWS-managed aws/s3 key (the not-publicly-served buckets — artifacts).
  s3_encryption = {
    rule = {
      apply_server_side_encryption_by_default = { sse_algorithm = "aws:kms" }
      bucket_key_enabled                      = true # S3 Bucket Keys — fewer KMS calls (cost)
    }
  }

  # CloudFront-served public buckets (fed, og-images) use SSE-S3 (AES256): CloudFront OAC can't
  # decrypt objects under the AWS-managed aws/s3 KMS key (its key policy can't grant the CloudFront
  # service principal kms:Decrypt), which 403s the SPA. The content is public, so AES256 at rest is
  # the right stance here (/infrastructure/s3, /infrastructure/kms). A CMK would be the KMS alternative.
  s3_encryption_public = {
    rule = {
      apply_server_side_encryption_by_default = { sse_algorithm = "AES256" }
    }
  }
}

# 1. Frontend (fed) SPA origin — private, reached only via CloudFront OAC (policy wired in #7).
module "frontend_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket        = "${local.bucket_prefix}-fed-${var.environment}"
  force_destroy = local.s3_force_destroy

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = local.s3_encryption_public # AES256 — CloudFront OAC can't decrypt aws/s3 KMS
  # TLS-deny is folded into the combined OAC bucket policy in frontend.tf (a single policy per
  # bucket; the OAC allow needs the CloudFront ARN, so the policy can't live in this module call —
  # that would create a storage↔frontend cycle).
  attach_deny_insecure_transport_policy = false

  versioning = { enabled = true } # rollback safety for the site
}

# 2. Lambda code artifacts — Pattern B bootstrap zip + deploy bundles (bff/og-edge).
module "artifacts_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket        = "${local.bucket_prefix}-artifacts-${var.environment}"
  force_destroy = local.s3_force_destroy

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration  = local.s3_encryption
  attach_deny_insecure_transport_policy = true

  versioning = { enabled = true } # keep prior bundles for rollback

  lifecycle_rule = [{
    id                            = "expire-old-versions"
    enabled                       = true
    noncurrent_version_expiration = { days = 30 }
  }]
}

# 3. Generated OG images cache — private, read via the main CloudFront /og/* behavior (OAC in #7).
module "og_images_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket        = "${local.bucket_prefix}-og-images-${var.environment}"
  force_destroy = local.s3_force_destroy

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = local.s3_encryption_public # AES256 — CloudFront OAC can't decrypt aws/s3 KMS
  # TLS-deny folded into the combined OAC bucket policy in frontend.tf (see frontend_bucket).
  attach_deny_insecure_transport_policy = false

  versioning = { enabled = false } # regenerable cache — no versioning

  lifecycle_rule = [{
    id         = "expire"
    enabled    = true
    expiration = { days = 90 } # purge stale OG PNGs
  }]
}

# 4. Assets — ONE generic object store for any feature that needs one (Phase 3: user avatars under
# avatars/), with per-feature isolation via root subfolders. Private, read publicly via the main
# CloudFront /assets/* behavior (OAC in frontend.tf). AES256 like og-images (CloudFront OAC can't
# decrypt the aws/s3 KMS key). No lifecycle expiry — avatars persist; versioning off (each key is
# overwritten in place by the uploader).
module "assets_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket        = "${local.bucket_prefix}-assets-${var.environment}"
  force_destroy = local.s3_force_destroy

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration  = local.s3_encryption_public # AES256 — CloudFront OAC can't decrypt aws/s3 KMS
  attach_deny_insecure_transport_policy = false                      # folded into the combined OAC policy in frontend.tf

  versioning = { enabled = false }
}

# SSM config bus (/infrastructure/ssm) — IaC writes, app repos read at deploy. Non-sensitive names.
resource "aws_ssm_parameter" "frontend_bucket_name" {
  name  = "/${var.environment}/frontend/s3-bucket-name"
  type  = "String"
  value = module.frontend_bucket.s3_bucket_id
}

resource "aws_ssm_parameter" "artifacts_bucket_name" {
  name  = "/${var.environment}/storage/artifacts-bucket-name"
  type  = "String"
  value = module.artifacts_bucket.s3_bucket_id
}

resource "aws_ssm_parameter" "og_images_bucket_name" {
  name  = "/${var.environment}/storage/og-images-bucket-name"
  type  = "String"
  value = module.og_images_bucket.s3_bucket_id
}

resource "aws_ssm_parameter" "assets_bucket_name" {
  name  = "/${var.environment}/storage/assets-bucket-name"
  type  = "String"
  value = module.assets_bucket.s3_bucket_id
}
