terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Terraform Cloud holds state + locks; execution mode is Local (GitHub Actions runs plan/apply).
  # The cloud{} block is parsed before variables resolve, so org/tags are literal here.
  # CI selects the workspace via TF_WORKSPACE=tadeumendonca-iac-{staging|production}.
  cloud {
    organization = "tadeumendonca-io"
    workspaces {
      tags = ["tadeumendonca-iac"]
    }
  }
}
