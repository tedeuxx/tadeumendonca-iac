# Network layer — owned by /infrastructure/vpc.
# Topology re-created inline from the decommissioned landing-zone (same shape, no state import):
# 2 AZs, /16 VPC with /24 subnets, NAT (single in staging, per-AZ in production), an S3 Gateway
# endpoint (keeps S3 off the NAT path), and an app-specific Lambda SG.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-${var.environment}"
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  private_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 11)]

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nothing public lives in a subnet — the edge (CloudFront, API GW) is AWS-managed.
  map_public_ip_on_launch = false

  # NAT: single in staging (cost) vs one-per-AZ in production (HA).
  enable_nat_gateway     = true
  single_nat_gateway     = var.environment != "production"
  one_nat_gateway_per_az = var.environment == "production"

  # Lock the default SG to nothing — least privilege, nothing reachable by accident.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # VPC Flow Logs → encrypted CloudWatch log group (/infrastructure/cloudwatch).
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_iam_role             = true
  create_flow_log_cloudwatch_log_group            = true
  flow_log_traffic_type                           = "ALL"
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.environment == "production" ? 90 : 30
}

# S3 Gateway endpoint — keeps S3 traffic on the AWS backbone (free), off NAT. In provider v5 the
# main vpc module no longer accepts endpoints, so this is the standalone submodule. No DynamoDB
# endpoint (data tier is DocumentDB). No interface endpoints — low cross-NAT volume doesn't justify them.
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
  }
}

# Lambda security group — app-specific, out of the VPC module's scope (raw resource, justified glue).
# Egress is HTTPS-only: everything crossing the VPC boundary is TLS. DocumentDB (27017) and Redis
# (6379) inbound is granted by their cluster SGs allowing this SG as source (set in data.tf/cache.tf).
resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda-${var.environment}"
  description = "Lambda ENIs (private subnets) - HTTPS egress only" # ASCII only: EC2 rejects non-ASCII in GroupDescription
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "HTTPS egress (S3 via endpoint; Cognito/Secrets/SES via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-lambda-${var.environment}" }
}
