locals {
  # Workload boundary in a shared account. Project = workload, Environment = isolation/cost split,
  # ManagedBy = provenance. Activated as cost-allocation tags in Billing. (/infrastructure/terraform)
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Per-env domain model (/infrastructure/route53): production sits on the apex; staging on a
  # `staging.` subdomain. auth/api hosts derive from the frontend host.
  frontend_host = var.environment == "production" ? var.apex_domain : "staging.${var.apex_domain}"
  auth_domain   = "auth.${local.frontend_host}"
  api_domain    = "api.${local.frontend_host}"
  callback_urls = ["https://${local.frontend_host}/callback"]
  logout_urls   = ["https://${local.frontend_host}/"]
}
