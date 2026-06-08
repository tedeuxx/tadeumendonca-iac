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

variable "vpc_cidr" {
  type        = string
  description = "VPC IPv4 CIDR block (/16). Subnets are carved as /24 (8-bit) within it."
  default     = "10.0.0.0/16"
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "azs" {
  type        = list(string)
  description = "Availability Zones for subnets. Exactly 2 AZs (cost/resilience trade-off)."
  validation {
    condition     = length(var.azs) == 2
    error_message = "azs must contain exactly 2 Availability Zones."
  }
  validation {
    condition     = alltrue([for az in var.azs : can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", az))])
    error_message = "each az must be a valid Availability Zone id (e.g. us-east-1a)."
  }
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
