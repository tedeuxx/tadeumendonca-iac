locals {
  # Workload boundary in a shared account. Project = workload, Environment = isolation/cost split,
  # ManagedBy = provenance. Activated as cost-allocation tags in Billing. (/infrastructure/terraform)
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
