# Root data sources, declared once. account_id prefixes globally-unique S3 bucket names and is
# never hardcoded (/infrastructure/terraform). Route53 zone + ACM cert are added by the layers
# that need them (auth.tf / frontend.tf).
data "aws_caller_identity" "current" {}

# Data tier — owned by /infrastructure/documentdb.
# DocumentDB cluster (cloudposse), VPC-only and SG-gated (inbound 27017 from the Lambda SG only),
# TLS enforced, audit logs on. Credentials live in Secrets Manager; SSM gets references only.

resource "random_password" "docdb" {
  length  = 32
  special = false
}

module "docdb" {
  source = "cloudposse/documentdb-cluster/aws"
  # Pinned to 0.30.x (not the skill's ~> 1.0): the 1.x line pulls a submodule requiring aws >= 6.8.0,
  # which conflicts with the project-wide aws ~> 5.0 pin (/infrastructure/terraform). 0.30.x is the
  # latest line compatible with aws 5.x. Revisit when the platform moves to the aws v6 provider.
  version = "~> 0.30.0"

  # identity / engine
  name           = var.project
  stage          = var.environment
  engine         = "docdb"
  engine_version = "5.0.0" # DocumentDB 5.0 (parameter family docdb5.0)
  cluster_family = "docdb5.0"
  db_port        = 27017

  # sizing
  instance_class = "db.t4g.medium"                         # Graviton; floor class for DocumentDB
  cluster_size   = var.environment == "production" ? 2 : 1 # 1 primary + N-1 replicas (HA in prod)

  # network (VPC-only, private)
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnets
  allowed_security_groups = [aws_security_group.lambda.id] # inbound 27017 only from the Lambda SG
  allowed_cidr_blocks     = []                             # none — SG-gated only

  # credentials (32-char random; stored in Secrets Manager below)
  master_username = "admin"
  master_password = random_password.docdb.result

  # encryption at rest — AWS-managed aws/rds key ("" = managed; CMK per /infrastructure/kms)
  storage_encrypted = true
  kms_key_id        = ""

  # backup / maintenance
  retention_period             = var.environment == "production" ? 7 : 1
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:30-sun:05:30"
  skip_final_snapshot          = var.environment != "production"
  apply_immediately            = var.environment != "production" # prod waits for the window
  auto_minor_version_upgrade   = true
  deletion_protection          = var.environment == "production"

  # parameter group — TLS enforced, audit logs on
  cluster_parameters = [
    { name = "tls", value = "enabled", apply_method = "pending-reboot" },
    { name = "audit_logs", value = "enabled", apply_method = "pending-reboot" },
    { name = "ttl_monitor", value = "enabled", apply_method = "pending-reboot" },
  ]
  enabled_cloudwatch_logs_exports = ["audit", "profiler"] # → /infrastructure/cloudwatch
}

# Credentials → Secrets Manager (never SSM plaintext). Lambdas read this at runtime (api.tf env).
resource "aws_secretsmanager_secret" "docdb" {
  #checkov:skip=CKV2_AWS_57:Static master credential — rotation deferred (would need a rotation Lambda); revisit post-Phase 3
  name                    = "${var.project}/${var.environment}/docdb"
  recovery_window_in_days = var.environment == "production" ? 7 : 0
}

resource "aws_secretsmanager_secret_version" "docdb" {
  secret_id = aws_secretsmanager_secret.docdb.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.docdb.result
    host     = module.docdb.endpoint
    port     = 27017
    dbname   = var.project
  })
}

# SSM config bus — references only (the secret ARN + the endpoint, never the secret material).
resource "aws_ssm_parameter" "docdb_secret_arn" {
  name  = "/${var.environment}/data/docdb-secret-arn"
  type  = "String"
  value = aws_secretsmanager_secret.docdb.arn
}

resource "aws_ssm_parameter" "docdb_cluster_endpoint" {
  name  = "/${var.environment}/data/docdb-cluster-endpoint"
  type  = "String"
  value = module.docdb.endpoint
}
