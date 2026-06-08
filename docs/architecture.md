# tadeumendonca-iac — Architecture

Infrastructure for the **tadeumendonca.io** platform, provisioned by a single Terraform root
(`terraform/`), one `.tf` per layer, applied per environment via Terraform Cloud workspaces
(`tadeumendonca-iac-{staging,production}`). Diagrams are Mermaid only (`/workflow/documentation-standard`).

## Runtime network topology

```mermaid
flowchart TD
  user([User / Browser])
  bot([Bot / Crawler])

  subgraph edge[AWS Edge - global]
    cfwaf[WAF CLOUDFRONT]
    cf[CloudFront distribution]
  end

  subgraph regional[us-east-1 - regional, AWS-managed]
    rwaf[WAF REGIONAL]
    cognito[Cognito User Pool + custom hosted UI]
    apigw[API GW v2 HTTP - custom domain, stage throttling]
  end

  subgraph vpc[VPC 10.x/16 - 2 AZs]
    subgraph public[Public subnets]
      nat[NAT Gateway]
    end
    subgraph private[Private subnets]
      bff[BFF Lambda - Hono, arm64, in-VPC]
    end
    s3gw[S3 Gateway endpoint]
    ddbgw[DynamoDB Gateway endpoint]
  end

  subgraph data[Regional services - IAM auth, off-NAT]
    ddb[(DynamoDB - 5 per-entity tables)]
    s3fed[(S3 fed - SPA, private/OAC)]
    s3og[(S3 og-images - private/OAC)]
    s3art[(S3 artifacts - Lambda zips)]
  end

  sm[Secrets Manager]
  ses[SES - Phase 2]

  user -->|https SPA| cfwaf --> cf
  cf -->|OAC| s3fed
  cf -->|/og/*| s3og
  user -->|https API Bearer JWT| apigw
  bot -->|SEO/OG| cf
  user -->|login PKCE| rwaf --> cognito

  apigw -->|AWS_PROXY| bff
  bff -->|TLS, off-NAT| ddbgw --> ddb
  bff -->|TLS, off-NAT| s3gw --> s3og
  bff -->|HTTPS via NAT| nat --> sm
  nat --> ses
  rwaf -.protects.-> cognito

  classDef phase2 stroke-dasharray: 4 3;
  class ses phase2;
```

**Key paths.** The SPA loads from S3 via CloudFront + OAC (origin stays private). The API is an HTTP
API on a custom domain fronting only the BFF Lambda; JWT is validated by the API GW Cognito authorizer
(not in the BFF). The BFF runs in private subnets and reaches **DynamoDB and S3 over Gateway endpoints**
(AWS backbone, off the NAT path) and Secrets Manager / SES over **NAT**. WAF: CLOUDFRONT scope on the
distribution, REGIONAL scope on the **Cognito hosted UI only** — an HTTP API can't be WAF-fronted, so it
relies on **stage throttling** instead (`/infrastructure/api-gateway`).

## Terraform module / layer dependency graph

```mermaid
flowchart LR
  data_src[data.tf - caller_identity, route53 zone, ACM cert]

  vpc[vpc.tf - VPC, subnets, NAT, S3+DynamoDB endpoints, lambda SG]
  storage[storage.tf - S3 fed/artifacts/og-images]
  ddb[data.tf - DynamoDB x5 + SSM]
  auth[auth.tf - Cognito + WAF REGIONAL]
  frontend[frontend.tf - WAF CLOUDFRONT + CloudFront + OAC policies + Route53]
  api[api.tf - API GW v2 + BFF Lambda Pattern B + Route53]
  iam[iam.tf - OIDC roles api/fed]
  ssm[(SSM config bus - /env/...)]

  vpc --> ddb
  vpc --> api
  storage --> frontend
  storage --> api
  data_src --> auth
  data_src --> frontend
  data_src --> api
  auth --> api
  frontend --> api

  vpc --> ssm
  storage --> ssm
  ddb --> ssm
  auth --> ssm
  frontend --> ssm
  api --> ssm
  iam --> ssm
```

**Cross-layer notes.**
- `api.tf` depends on the lambda SG + private subnets (vpc), the artifacts + og-images buckets (storage),
  the DynamoDB tables (data), and the REGIONAL WAF (auth, for reference). It seeds the API GW with a
  `GET /health` body; the **api repo** owns the full contract (reimport-api, Pattern B for code).
- `auth.tf`'s Cognito **custom domain** requires the frontend host's DNS A record (`frontend.tf`), so
  **frontend is applied before auth**.
- Every layer publishes non-sensitive outputs to the **SSM config bus** (`/{env}/{component}/{name}`);
  the api/fed repos read them at deploy. Secrets (none for the data tier — DynamoDB is IAM-auth) live in
  Secrets Manager.

## Deferred / phased

| Item | Where | Phase |
|---|---|---|
| og-edge Lambda@Edge + CloudFront viewer-request | api.tf (#6b) | 1 |
| SES domain verification + DKIM | auth.tf (#17) | 2 |
| ElastiCache Redis + SNS domain events (BFF env/policy) | cache.tf / sns.tf | 2 |

## Conventions

- One canonical `terraform/` root; per-env differences via `var.environment` conditionals + `env/*.tfvars`.
- Official `terraform-aws-modules/*` first; trusted `cloudposse/*` where no official module exists —
  pinned to **aws-5-compatible** versions (the project pins `aws ~> 5.0`).
- Encryption at rest (AWS-managed KMS keys, no CMK in Phase 1-3) + TLS in transit everywhere.
- checkov hard-fail gate on every PR (`.checkov.yaml` + inline suppressions, curated).
