# Canonical input variables. Every variable is typed and domain-validated so a bad value fails at
# `plan`, never at `apply`. Later layers (storage/data/auth/api/frontend/iam) extend this file.

variable "project" {
  type        = string
  description = "Workload name — used in every resource name, SSM path, and the Project tag."
  default     = "tadeumendonca"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project))
    error_message = "project must be lowercase kebab-case (a-z, 0-9, -), 3–32 chars."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment. Drives per-env conditionals (NAT topology, retention)."
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be 'staging' or 'production'."
  }
}

variable "aws_region" {
  type        = string
  description = "Primary AWS region for the default provider."
  default     = "us-east-1"
  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region id (e.g. us-east-1)."
  }
}

# vpc_cidr / azs removed — the BFF is non-VPC (no NAT, see api.tf). Reintroduce with the VPC when an
# in-VPC dependency (Redis) lands.

variable "admin_emails" {
  type        = list(string)
  description = "Emails granted the Cognito 'admin' group by the fn-cognito-groups trigger (allowlist)."
  default     = []
}

variable "apex_domain" {
  type        = string
  description = "Registrable apex domain. Hosted zone name + base for per-env hosts (auth/api/frontend)."
  default     = "tadeumendonca.io"
  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.apex_domain))
    error_message = "apex_domain must be a valid domain name (e.g. example.com)."
  }
}

variable "github_org" {
  type        = string
  description = "GitHub org owning the api/fed repos — OIDC trust subjects repo:<org>/<repo>:*."
  default     = "tedeuxx"
  validation {
    condition     = can(regex("^[a-zA-Z0-9](-?[a-zA-Z0-9]){0,38}$", var.github_org))
    error_message = "github_org must be a valid GitHub org/user handle."
  }
}
