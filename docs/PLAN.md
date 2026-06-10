# Plan: tadeumendonca.io — Multi-Repo Platform Architecture

## Context

Greenfield platform for tadeumendonca.io — personal digital presence and engineering portfolio.
Owner: Luiz Tadeu Mendonça, Senior Cloud Application Architect, AWS ProServ.
Goal: showcase product-engineering capability (not just architecture) via a public-facing site
evolving from CV → Feed → Articles. Four repositories, coordinated via SSM Parameter Store,
GitHub Actions OIDC, and Terraform Cloud (remote state only).

AWS account: 858049036700 | TFC org: tadeumendonca-io.

**Landing zone migration:** `tadeumendonca-io-aws-landing-zone` repo will have its infrastructure
destroyed and the repo archived. All VPC/networking that lived there is migrated into
`tadeumendonca-iac` via `terraform-aws-modules/vpc/aws` in `vpc.tf`, making IaC the single
source of truth for all AWS infrastructure.

---

## Repositories

| Repo | Purpose |
|---|---|
| `tadeumendonca-iac` | Terraform — provisions all AWS resources, writes SSM outputs |
| `tadeumendonca-api` | Node.js + TypeScript — BFF Lambda (Hono) + API GW (REST v1) |
| `tadeumendonca-fed` | React + TypeScript + Vite — CloudFront SPA |
| `tadeumendonca-skills` | Claude Code custom slash command library |

---

## Cross-Repo Architecture

### Dependency Graph

```
tadeumendonca-iac  ← single source of truth for all AWS infrastructure (canonical .tf + per-env tfvars)
  ├── vpc.tf            → VPC, public/private subnets (2 AZs), NAT GW, S3 gw endpoint (inline)
  ├── storage/data/auth/api/frontend/iam .tf → public modules called directly + glue
  ├── writes SSM parameters (all outputs)
  └── creates OIDC roles for api + fed repos (iam-assumable-role-with-oidc module)

# tadeumendonca-io-aws-landing-zone → ARCHIVED (infra destroyed, VPC re-created inline in vpc.tf)

tadeumendonca-api (the BFF) ──reads SSM──► BFF fn name, API id, DynamoDB table names, Redis secret ARN, artifacts bucket
  └── deploys via: esbuild → zip → S3 → update-function-code (BFF) + put-rest-api + create-deployment (generated OpenAPI)

tadeumendonca-fed ──reads SSM──► S3 bucket name, CloudFront distribution ID, API URL, Cognito params
  └── deploys via: vite build → S3 sync → CloudFront invalidation

tadeumendonca-skills  (no AWS dependency — Claude Code skills consumed by developers)
```

### Runtime AWS Network Topology

```
                              Internet
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
  WAF (CLOUDFRONT)          WAF (REGIONAL)      WAF (REGIONAL)
              │                   │                   │
        CloudFront           API GW REST v1      Cognito Hosted UI
        (AWS edge,           (AWS edge,          (auth.*.tadeumendonca.io
         global)              NOT in VPC)         self-signup + admin)
              │                   │
  Lambda@Edge (Viewer Req) BFF Lambda (Hono, 1×) — API GW fronts only this
  ├── bot UA? → fetch OG   (VPC private subnet, arm64, routes at root)
  │   from BFF /og-meta     domain modules: profile / posts / articles /
  │   + /prerender          og-image / prerender / notifications
  │                         │
  └── human → S3 (SPA)     ├──[VPC GW Endpoint]──► S3 + DynamoDB (AWS backbone, off-NAT; IAM-auth)
                            ├──[SG port 6379]────► ElastiCache Redis (cache, private subnet)
                            └──[NAT GW]──────────► Secrets Manager (redis auth) · SES (email)
   (JWT validated at the API GW Cognito authorizer — not in the BFF)

WAF:
  CLOUDFRONT → 1× WebACL (us-east-1): CloudFront distribution
  REGIONAL   → 1× WebACL (us-east-1): API GW + Cognito User Pool
```

### Deployment Topology: Code Change → Prd

```
Developer PR
    │
    ▼
[ci.yml] lint + typecheck + test  (runs in every repo on PR)
    │
    ▼
merge → develop
    ├── tadeumendonca-iac:  terraform-plan.yml → terraform-deploy.yml → stg (auto)
    │     └── SSM params written/updated → downstream repos always read current values
    ├── tadeumendonca-api:  deploy.yml → esbuild → zip → S3 → update-function-code (BFF, stg)
    └── tadeumendonca-fed:  deploy.yml → vite build → S3 sync → CF invalidation (stg)

merge → main (PR from develop, requires review)
    ├── tadeumendonca-iac:  terraform-plan.yml → terraform-deploy.yml (workflow_dispatch approval)
    ├── tadeumendonca-api:  deploy.yml → same → prd
    └── tadeumendonca-fed:  deploy.yml → same → prd
```

### Environment Isolation

| Resource | Stg | Prd |
|---|---|---|
| Frontend domain | `staging.tadeumendonca.io` | `tadeumendonca.io` |
| API domain | `api.staging.tadeumendonca.io` | `api.tadeumendonca.io` |
| Auth domain (Cognito hosted UI) | `auth.staging.tadeumendonca.io` | `auth.tadeumendonca.io` |
| DynamoDB tables | `tadeumendonca-<entity>-staging` | `tadeumendonca-<entity>-production` |
| BFF Lambda | `tadeumendonca-bff-staging` | `tadeumendonca-bff-production` |
| S3 frontend | `staging.tadeumendonca.io` | `tadeumendonca.io` |
| S3 artifacts | `tadeumendonca-artifacts-staging` | `tadeumendonca-artifacts-production` |
| Cognito pool domain prefix | `auth-staging-tadeumendonca` | `auth-production-tadeumendonca` |

### SSM Parameter Namespace

`{env}` = `staging` | `production` (matches `var.environment`).

```
/{env}/frontend/s3-bucket-name
/{env}/frontend/cloudfront-distribution-id
/{env}/frontend/ga-measurement-id                  ← Google Analytics GA4 measurement id (build-time)
/{env}/frontend/rum-app-monitor-id                 ← CloudWatch RUM app monitor id (build-time)
/{env}/frontend/rum-identity-pool-id               ← Cognito identity pool for RUM guest auth
/{env}/api/gateway-url
/{env}/api/gateway-id                              ← REST API id; api repo uses this for put-rest-api
/{env}/api/bff-function-name                       ← the single BFF Lambda (API GW fronts only this)
/{env}/api/lambda-edge-og-qualified-arn
/{env}/auth/cognito-user-pool-id
/{env}/auth/cognito-client-id
/{env}/auth/cognito-domain                             ← Cognito-managed prefix (fallback)
/{env}/auth/cognito-hosted-ui-url                      ← FQDN: https://auth.{env-domain}
/{env}/data/profile-table-name                     ← DynamoDB table names (IAM access; no secret/endpoint)
/{env}/data/posts-table-name
/{env}/data/articles-table-name
/{env}/data/subscriptions-table-name
/{env}/data/audits-table-name
/{env}/cache/redis-endpoint                        ← ElastiCache Redis primary endpoint (AUTH token in Secrets Manager)
/{env}/storage/artifacts-bucket-name
/{env}/storage/og-images-bucket-name
/{env}/iam/github-actions-api-role-arn
/{env}/iam/github-actions-fed-role-arn
```

---

## Cognito — redesenho social-only (Google) — ✅ COMPLETO e verificado E2E em staging (2026-06-10)

Configuração aplicada (substitui o self-signup nativo). Skill: `/infrastructure/cognito`. Pool `us-east-1_7NhhMepZr` atualizado **in-place**: tier PLUS, MFA OFF, advanced security ENFORCED, email SES, Google único IdP, client Google-only, branding on-brand, trigger `fn-cognito-groups` (timeout-safe, override de claim + membership best-effort). Conta admin nativa deletada; secret em `tadeumendonca/staging/google-oauth`. **Login Google + grupo admin confirmados no navegador pelo dono.** (iac PRs #39–#43, fed #12.)

| Feature | Decisão |
|---|---|
| Sign-up | **Social-only via Google** (sem senha nativa; `allow_admin_create_user_only=true`) |
| Provedores | **Google** (nativo). Microsoft/LinkedIn/GitHub/Apple = drop-in futuro (cada um = app OAuth + secret) |
| Perfis (grupos) | **`admin` + `registered`** (público = não-autenticado, sem grupo) |
| Atribuição de grupo | Trigger `fn-cognito-groups`: post-auth → `registered`; email na allowlist → `admin`; pre-token garante claim |
| MFA | **OFF no Cognito** (federado → 2FA é do Google) |
| Threat protection | **ENFORCED** (tier Plus, ~US$0,05/MAU) |
| Email | **Via SES** (`no-reply@<host>`, identidade já verificada) |
| Tokens | Padrão (access/id 60min, refresh 30d) |
| Atributos | email + nome (mapeados do Google) |
| Hosted UI | **Branding customizado** (logo + cores) |
| App client | público PKCE, `supported_identity_providers=["Google"]` (sem COGNITO) |

**Feito (Claude + dono, 2026-06-10):**
- ✅ Google OAuth client criado (dono) + client_id/secret no Secrets Manager `tadeumendonca/staging/google-oauth`.
- ✅ `auth.tf` aplicado: tier PLUS, Google IdP, client Google-only, MFA OFF, advanced security ENFORCED, email SES, `fn-cognito-groups` (trigger fail-open + role + allowlist).
- ✅ Conta admin nativa deletada; fed ajustado (`signInWithRedirect({provider:'Google'})`); federação verificada (authorize 302 → Google com o client_id correto).

**Falta (dono):**
1. **Teste de login no navegador:** staging.tadeumendonca.io → Sign in → Google (tadeu.tyf@gmail.com) → confirmar que loga e cai no grupo `admin` (aparece "New post"/compose). Se o grupo não aparecer, ver logs do `fn-cognito-groups` (é fail-open, login funciona sem o grupo).
2. **2FA na conta Google** do admin (a MFA agora é do provedor).
3. ✅ **Branding do hosted UI** — FEITO (paleta dark slate + ciano + logo wordmark; `aws_cognito_user_pool_ui_customization`, iac PR #41).
4. **Produção:** quando promover, criar um Google OAuth client próprio (redirect `https://auth.tadeumendonca.io/oauth2/idpresponse`) + secret em `tadeumendonca/production/google-oauth`.

## Repo 1: tadeumendonca-iac

### Community Modules

| Service | Community Module | Version |
|---|---|---|
| VPC | `terraform-aws-modules/vpc/aws` | ~> 5.0 |
| S3 | `terraform-aws-modules/s3-bucket/aws` | ~> 4.0 |
| CloudFront | `terraform-aws-modules/cloudfront/aws` | ~> 3.0 |
| Cognito | `lgallard/cognito-user-pool/aws` | ~> 0.31 |
| WAF (CLOUDFRONT + REGIONAL) | `cloudposse/waf/aws` | ~> 1.0 |
| DynamoDB | `terraform-aws-modules/dynamodb-table/aws` (one call per entity table) | ~> 4.0 |
| ElastiCache (Redis) | `cloudposse/elasticache-redis/aws` | ~> 1.0 |
| SES | `cloudposse/ses/aws` (domain verify + DKIM + Route53 records) | ~> 0.25 |
| API GW (REST v1) | raw `aws_api_gateway_*` (no official module fits the OpenAPI-body + reimport flow) | — |
| Lambda | `terraform-aws-modules/lambda/aws` | ~> 7.0 |
| IAM (OIDC roles) | `terraform-aws-modules/iam/aws` (submodule: `iam-assumable-role-with-oidc`) | ~> 5.0 |
| IAM (deploy policies) | `terraform-aws-modules/iam/aws` (submodule: `iam-policy`) | ~> 5.0 |
| Route53 | `data "aws_route53_zone"` (zone pre-exists) | — |
| ACM | **pre-created out-of-band; ARN resolved via `data "aws_acm_certificate" "main"` — no ARNs in tfvars** | — |
| SSM Parameters | `aws_ssm_parameter` (raw) — sem módulo comunitário estabelecido; recurso simples | — |

**Raw `aws_*` resources** (justified exceptions):
- `aws_lambda_permission` — invoke grant for API GW (broad `/*/*` source ARN so reimported routes need no new perms)
- `aws_wafv2_web_acl_association` — `aws_api_gateway_stage` (REST) não tem atributo WAF nativo; a associação requer recurso separado. REST stages **são** WAF-associáveis (HTTP APIs v2 não são).
- `aws_security_group` (lambda) — SG específico da aplicação; fora do escopo do módulo VPC
- `aws_route53_record` (api) — Route53 record para custom domain da API (mesmo padrão do frontend record)

**Pipeline independence principle:**
All pipelines are independent by repository — cross-repo triggers are antipattern. If an IaC apply resets the API GW body (seed spec), the api deploy pipeline is re-run manually. No automatic coupling between repos.

**ACM — pre-created out-of-band, looked up by domain (decision):**
ACM DNS validation via Terraform (`wait_for_validation`) blocks `apply` e acopla o lifecycle do cert ao da infra. Certs são criados e validados **uma única vez, fora do Terraform**. Em vez de passar ARNs como variáveis (dados sensíveis no tfvars), `data "aws_acm_certificate"` os resolve pelo domain name em runtime — nenhum dado sensível no repositório.

O cert existente (`786ca8c9-cdbd-4098-b998-8694506a85bb`, us-east-1) cobre 4 domínios:
- `tadeumendonca.io` + `*.tadeumendonca.io` (cobre frontend e api de prd, e `staging.tadeumendonca.io`)
- `*.staging.tadeumendonca.io` (cobre `api.staging.tadeumendonca.io`)
- `*.production.tadeumendonca.io`

Um único data source cobre stg e prd:

```hcl
# data.tf — junto com aws_route53_zone e aws_caller_identity
data "aws_caller_identity" "current" {}

data "aws_route53_zone" "main" {
  name = "tadeumendonca.io"
}

data "aws_acm_certificate" "main" {
  provider    = aws.us_east_1          # CloudFront + API GW exigem cert em us-east-1
  domain      = "tadeumendonca.io"     # primary domain — SANs cobrem staging.* e api.*
  statuses    = ["ISSUED"]
  most_recent = true
}
```

Uso: `data.aws_acm_certificate.main.arn` (tanto frontend/CloudFront quanto API GW custom domain), `data.aws_caller_identity.current.account_id`.

**Lambda module — Pattern B:**
`terraform-aws-modules/lambda/aws` has a built-in `ignore_source_code_hash = true` variable for exactly this use case. Set it with `create_package = false` + `s3_existing_package = { bucket, key }`. IaC provisions with a placeholder zip; `update-function-code` handles all subsequent deploys.

**IAM module — OIDC roles:**
`terraform-aws-modules/iam/aws` submodule `iam-assumable-role-with-oidc` handles the GitHub OIDC trust policy natively. Pass `provider_url`, `role_policy_arns`, and `oidc_subjects_with_wildcards` — no raw `aws_iam_role` needed.

**API GW REST v1 — raw resources + put-rest-api (decision):**
REST API (REGIONAL) chosen over HTTP API: it's the conventional, full-featured gateway — **WAF-associable** (per-IP managed rules), with usage plans/API keys and request validation. Raw `aws_api_gateway_*` (no official module fits the OpenAPI-body flow): `aws_api_gateway_rest_api` with `body` (seed spec: `GET /health` → BFF, `lifecycle.ignore_changes=[body]`) + deployment + stage + custom domain + base-path mapping + `method_settings` (throttling) + WAF stage association. IaC owns the shell; the `tadeumendonca-api` repo owns the contract **as code** — the OpenAPI is generated from the Hono handlers (`@hono/zod-openapi`), overlaid with the AWS integration + Cognito `cognito_user_pools` authorizer + CORS (`OPTIONS` MOCK + gateway responses), and published via `aws apigateway put-rest-api --mode overwrite` + `create-deployment` on deploy. Pipelines are independent — if a future IaC apply resets the body, the api deploy is re-run manually.

### Directory Structure

```
tadeumendonca-iac/
├── VERSION
├── .bumpversion.toml
├── .gitignore
├── docs/
│   └── architecture.md      # diagrama mermaid: topologia de rede, dependências entre módulos
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml
│       ├── terraform-deploy.yml
│       ├── version-develop.yml
│       └── version-main.yml
└── terraform/                 # Terraform root (mirrors landing-zone convention)
    ├── versions.tf            # terraform{} + required_providers + cloud{}
    ├── providers.tf           # aws (default) + aws.us_east_1 alias
    ├── variables.tf           # ALL input variables (canonical)
    ├── vpc.tf                 # terraform-aws-modules/vpc: pub/priv subnets (2 AZ), NAT GW, S3 GW endpoint, flow logs + raw lambda SG
    ├── storage.tf             # s3-bucket module ×3 (frontend=domain, artifacts, og-images) + SSM
    ├── data.tf                # dynamodb-table module ×5 (per entity) + SSM table names (IAM access, no secret)
    ├── cache.tf               # elasticache-redis module + Secrets Manager (AUTH token) + SSM
    ├── auth.tf                # cognito (lgallard) + ses + cloudposse/waf (REGIONAL) + WAF↔Cognito assoc + SSM
    ├── api.tf                 # raw aws_api_gateway_* (REST) + lambda module ×6 + lambda_permission + WAF assoc + SSM
    ├── frontend.tf            # cloudposse/waf (CLOUDFRONT) + cloudfront + Route53 A-alias + SSM
    ├── iam.tf                 # iam-policy ×2 (deploy policies) + iam-assumable-role-with-oidc ×2 (api, fed) + SSM
    ├── outputs.tf
    ├── bootstrap/
    │   └── placeholder.zip   # minimal Lambda zip for first apply (Pattern B)
    └── env/
        ├── stg.tfvars
        └── prd.tfvars
```

**Canonical IaC + per-env tfvars (decision):** single `terraform/` root (landing-zone convention), never duplicated per environment. The only thing that differs between stg and prd is the `.tfvars` file passed at plan/apply time (`-var-file=env/stg.tfvars`). Public modules are called **directly** — no custom L3 wrapper modules. `frontend.tf` and `api.tf` compose several public modules + glue inline.

> **TFC workspace selection:** `cloud{}` block uses `workspaces { tags = ["tadeumendonca-iac"] }`; CI selects the target workspace via `TF_WORKSPACE=tadeumendonca-iac-staging` or `TF_WORKSPACE=tadeumendonca-iac-production`, paired with the matching `-var-file=env/stg.tfvars` or `-var-file=env/prd.tfvars`. TFC workspace names use the short form (`staging`/`production`); `var.environment` inside Terraform also uses the full word.

### Implementation lives in skills

The full `.tf` for each layer — `variables.tf`, `env/*.tfvars`, `versions.tf`/`providers.tf`, the
canonical root wiring, and the per-layer module configs — is owned by the infrastructure skills
(canonical). This plan keeps the module choices and directory layout (above) and the network
topology (see *Runtime AWS Network Topology*). HCL by layer:

| Layer | Skill(s) |
|---|---|
| Repo structure, providers, tfvars, TFC workspaces, checkov CI | `/infrastructure/terraform` |
| `vpc.tf` — subnets, NAT, S3 endpoint, lambda SG | `/infrastructure/vpc` |
| `storage.tf` — frontend / artifacts / og-images buckets | `/infrastructure/s3` |
| `data.tf` — DynamoDB tables (per entity) + SSM | `/infrastructure/dynamodb` |
| `cache.tf` — ElastiCache Redis + AUTH in Secrets Manager | `/infrastructure/elasticache` |
| `auth.tf` — Cognito + SES + WAF (REGIONAL) | `/infrastructure/cognito` · `/infrastructure/ses` · `/infrastructure/waf` |
| `api.tf` — API GW (REST v1) + Lambdas (Pattern B) | `/infrastructure/api-gateway` · `/infrastructure/lambda` |
| `frontend.tf` — WAF (CLOUDFRONT) + CloudFront + Route53 | `/infrastructure/cloudfront` · `/infrastructure/waf` |
| `iam.tf` — deploy policies + OIDC roles (api, fed) | `/infrastructure/iam` |
| SSM outputs (cross-repo config bus) | `/infrastructure/ssm` |
| GitFlow + numeric versioning + Terraform CI/CD | `/workflow/github-actions` · `/infrastructure/terraform` |

## Repo 2: tadeumendonca-api

### Directory Structure

```
tadeumendonca-api/
├── VERSION
├── .bumpversion.toml
├── package.json
├── tsconfig.json
├── tsconfig.build.json
├── eslint.config.mjs
├── vitest.config.ts
├── esbuild.config.mjs
├── .env.staging             # non-secret per-env config (dotenv); secrets stay in Secrets Manager
├── .env.production
├── docs/
│   ├── data-model.md        # mermaid erDiagram: tables profile/posts/articles/subscriptions + attrs + GSIs
│   ├── sequences.md         # mermaid sequenceDiagram: auth flow (PKCE), CRUD post, OG edge flow, notificação
│   └── architecture.md      # mermaid flowchart: Lambda + API GW + DynamoDB + S3 + SES
├── openapi.json            # COMMITTED root copy of the contract (info.version == VERSION) — /backend/openapi
├── openapi/
│   └── openapi.aws.tftpl.json  # AWS overlay: integration + cognito authorizer + CORS; envsubst at deploy → put-rest-api
├── postman/
│   ├── tadeumendonca-api.postman_collection.json   # all routes + request examples + test scripts
│   └── tadeumendonca-api.postman_environment.json  # environment variables (base_url, auth tokens)
├── .github/
│   └── workflows/
│       ├── ci.yml              # PR: lint + typecheck + test (blocks if coverage < 85%)
│       ├── deploy.yml          # push develop/main → build → deploy
│       ├── version-develop.yml # push develop → bump patch → vX.Y.Z
│       └── version-main.yml    # push main → bump from PR label → vX.Y.Z + GitHub Release
├── scripts/
│   ├── seed.ts              # one-off: seed the profile table item (profile_id="me")
│   └── gen-openapi.ts       # emit openapi.gen.json from the Hono app (CI, before deploy)
└── src/
    ├── shared/
    │   ├── db/
    │   │   ├── client.ts        # DynamoDBDocumentClient singleton (SDK v3, IAM — no secret)
    │   │   └── tables.ts        # table-name accessors (from env via SSM) — shared across fns
    │   ├── cache/
    │   │   └── client.ts        # ioredis singleton + cache-aside helper (fail-open)
    │   ├── config/
    │   │   └── index.ts         # typed accessor over process.env (.env.{environment} locally)
    │   ├── secrets.ts           # Secrets Manager fetch + in-memory cache (redis auth only)
    │   ├── metrics.ts           # Powertools Metrics → EMF → CloudWatch (no collector)
    │   ├── render/
    │   │   └── index.ts         # bot HTML: og-meta (head) + prerender (full, markdown→HTML, JSON-LD)
    │   ├── middleware/
    │   │   ├── logger.ts        # Hono middleware: Powertools Logger context (cold start, request id)
    │   │   ├── error.ts         # Hono onError: AppError → HTTP response (snake_case body)
    │   │   ├── auth.ts          # Hono middleware: JWT group guard (requireGroup)
    │   │   └── audit.ts         # Hono middleware: actionType → insert into audits
    │   ├── constants/
    │   │   └── action-types.ts  # ActionType const enum — um código por rota/verbo
    │   ├── types/
    │   │   ├── entities.ts      # Profile, Post, Article, Subscriber, Audit TypeScript types
    │   │   └── api.ts           # Request/Response shapes
    │   └── errors/
    │       └── http-errors.ts   # AppError, NotFoundError, UnauthorizedError
    ├── index.ts                # the BFF: OpenAPIHono app (root routes) + aws-lambda adapter (handle)
    ├── modules/                # domain modules registered onto the single BFF app
    │   ├── profile/            # routes.ts, handler.ts, repository.ts, __tests__/
    │   ├── posts/              # routes.ts, handler.ts, repository.ts, __tests__/
    │   ├── articles/           # routes.ts, handler.ts, repository.ts, __tests__/
    │   ├── og-image/           # GET /og/{type}/{slug}.png (satori→SVG + resvg→PNG, S3 cache)
    │   ├── prerender/          # public /og-meta + /prerender (markdown→HTML + JSON-LD for bots)
    │   └── notifications/      # POST/DELETE /subscriptions + SES send (Phase 2)
    └── dist/                   # gitignored, esbuild output (index.mjs = BFF)

# NOTE: og-edge code lives in the IAC repo (terraform/lambda-src/og-edge/index.js), NOT here.
# IaC owns the edge lifecycle because CloudFront must reference a specific published version
# (qualified ARN) — Terraform publishes the version AND repoints the distribution atomically.
# Zero-dep CJS; derives the API base from the Host header (api.<host>) → no env vars, no bundle.
```

### Key Dependencies

```json
{
  "dependencies": {
    "@aws-lambda-powertools/logger":  "^2.0.0",
    "@aws-lambda-powertools/tracer":  "^2.0.0",
    "@aws-lambda-powertools/metrics":  "^2.0.0",
    "@aws-sdk/client-secrets-manager": "^3.0.0",
    "@aws-sdk/client-dynamodb":        "^3.0.0",
    "@aws-sdk/lib-dynamodb":           "^3.0.0",
    "ioredis":                         "^5.0.0",
    "markdown-it":                     "^14.0.0",
    "hono":                            "^4.0.0",
    "@hono/zod-openapi":               "^0.16.0",
    "zod":                             "^3.23.0"
  }
}
```

### DynamoDB Tables (per-entity, on-demand)

Per-entity tables (one per aggregate), **on-demand billing** (`PAY_PER_REQUEST`, ~$0 idle). One table set per environment — names `tadeumendonca-<entity>-<env>` (e.g. `tadeumendonca-posts-staging`). Access is **pure IAM** (no creds/secret); design owned by `/infrastructure/dynamodb`, client by `/backend/dynamodb`.

**Convention — snake_case everywhere:** DynamoDB attribute names, TypeScript entity interfaces, and JSON API request/response fields all follow **snake_case**. No mapping layer — one convention across the entire stack (DB → handler → wire format → frontend). DynamoDB is schemaless except for key/GSI attributes; only those are declared in IaC.

```
Table         │ Hash / Range        │ GSIs                          │ Attributes
──────────────┼─────────────────────┼───────────────────────────────┼────────────────────────────
profile       │ profile_id = "me"   │ —  (single item)              │ experience[], education[],
              │                     │                               │ certs[], skills{}, metadata{}
posts         │ post_id             │ by-created (gsi_pk="POST"      │ content, tags[], status,
              │                     │   / created_at DESC)           │ created_at, updated_at
articles      │ article_id          │ by-slug (slug),               │ title, body (md), summary,
              │                     │ by-tag (tag / created_at DESC) │ tags[], status, slug,
              │                     │                               │ created_at, updated_at
subscriptions │ email               │ by-cognito (cognito_sub),     │ cognito_sub, status,
              │                     │ by-status (status / email)     │ subscribed_at, preferences{}
audits        │ audit_id            │ by-entity (entity / created   │ created_at, action_type,
              │                     │   _at), by-actor (actor / cre  │ user{…}, request{…},
              │                     │   ated_at)                     │ response{…}, http_status_code,
              │                     │                               │ success, duration_ms,
              │                     │  TTL on `ttl` (epoch seconds)  │ function_name, request_id, ttl
```

> **Tag queries (DynamoDB ≠ Mongo multikey):** a GSI can't index a list, so `tags[]` isn't directly queryable. The `by-tag` GSI indexes a single **primary `tag`** per article; broader multi-tag filtering is done BFF-side on the candidate set, or via an `article_tags` adjacency table if it ever needs to scale. Audit lookups use `entity` (`<type>#<id>`) and `actor` (`user_id`) partition keys on GSIs; "failures only" is a BFF filter (low cardinality), not a GSI.

**Action types** (`src/shared/constants/action-types.ts`) — constantes uppercase definidas centralmente. Cada handler declara seu `action_type` na configuração do middleware. Nenhuma derivação dinâmica de URI/método em runtime. O atributo no DynamoDB é `action_type` (snake_case); a constante TypeScript usa SCREAMING_SNAKE_CASE (padrão para enums/consts).

```typescript
export const ActionType = {
  PROFILE_VIEW:        'PROFILE_VIEW',
  POSTS_LIST:          'POSTS_LIST',
  POST_VIEW:           'POST_VIEW',
  POST_CREATE:         'POST_CREATE',
  POST_UPDATE:         'POST_UPDATE',
  POST_DELETE:         'POST_DELETE',
  ARTICLES_LIST:       'ARTICLES_LIST',
  ARTICLE_VIEW:        'ARTICLE_VIEW',
  ARTICLE_CREATE:      'ARTICLE_CREATE',
  ARTICLE_UPDATE:      'ARTICLE_UPDATE',
  ARTICLE_DELETE:      'ARTICLE_DELETE',
  SUBSCRIPTION_CREATE: 'SUBSCRIPTION_CREATE',
  SUBSCRIPTION_DELETE: 'SUBSCRIPTION_DELETE',
  OG_IMAGE_VIEW:       'OG_IMAGE_VIEW',
  OG_META_VIEW:        'OG_META_VIEW',
} as const;

export type ActionType = typeof ActionType[keyof typeof ActionType];
```

**Audit middleware** (`src/shared/middleware/audit.ts`) — middy middleware aplicado em todos os VPC Lambda handlers. Recebe `actionType` como opção de configuração por handler. Captura request/response, extrai claims do JWT (quando presente), e escreve (`PutItem`) na tabela `audits`. `fn-og-edge` (Lambda@Edge) **não** escreve audits — sem acesso de baixa latência ao DynamoDB.

#### Access Patterns

```
Get CV profile                     → GetItem(profile, { profile_id: "me" })
List posts (timeline, paginated)   → Query(posts.by-created, gsi_pk="POST", ScanIndexForward=false, Limit=20, ExclusiveStartKey=cursor)
Get single post                    → GetItem(posts, { post_id })
Get article by slug                → Query(articles.by-slug, slug, Limit=1)
List articles (paginated, by tag)  → Query(articles.by-tag, tag, ScanIndexForward=false, ExclusiveStartKey=cursor)
List subscribers (active)          → Query(subscriptions.by-status, status="active")
List audits (admin, paginated)     → Query(audits.by-entity / by-actor, ExclusiveStartKey=cursor)   # newest-first
List audits by user                → Query(audits.by-actor, actor=user_id, ScanIndexForward=false)
List audit failures                → BFF filter on success=false over the page (no Scan)
```
Cursor pagination is `LastEvaluatedKey` (base64) — never `Scan` in a request path (`/backend/dynamodb`).

### API Contract

**Conventions:**
- **REST:** routes are nouns (resources); HTTP verbs (`GET`/`POST`/`PUT`/`DELETE`) express the action — never verbs in path
- **Naming — routes:** all path segments and parameters follow **kebab-case** (e.g. `{post-id}`, `/og-meta`)
- **Naming — JSON fields:** request bodies and response payloads follow **snake_case** (consistent with DB and TypeScript entities — no mapping layer)
- **Pagination:** cursor-based (`?cursor=<token>&limit=N`) — never offset/skip
- **Auth:** JWT via Cognito (`Authorization: Bearer <token>`); scoped by Cognito group claim
- **Errors:** standard HTTP status codes; body `{ error: string, message: string }`
- **Contract:** generated from the Hono handlers via `@hono/zod-openapi` — the routes below are the surface; the OpenAPI is emitted from code, not hand-written (`/backend/openapi`)

**Phase 1 — Profile (public)**
```
GET /profile
→ { metadata, experience[], education[], certifications[], skills: { [category]: string[] } }
```

**Phase 2 — Posts**
```
GET    /posts?limit=20&cursor=<token>      → { items: Post[], nextCursor? }
GET    /posts/{post-id}                    → Post
POST   /posts          [JWT: admin group]  → Post
PUT    /posts/{post-id} [JWT: admin group] → Post
DELETE /posts/{post-id} [JWT: admin group] → 204
```

**Phase 3 — Articles**
```
GET    /articles?limit=10&cursor=<token>&tag=<tag>  → { items: ArticleSummary[], nextCursor? }
GET    /articles/{slug}                             → Article (markdown body included)
POST   /articles          [JWT: admin]              → Article
PUT    /articles/{slug}   [JWT: admin]              → Article
DELETE /articles/{slug}   [JWT: admin]              → 204
```

**Cross-cutting — OG + Notifications**
```
GET    /og-meta/{type}/{slug}   → { title, description, imageUrl, url }  (internal, Lambda@Edge)
GET    /og/{type}/{slug}.png    → PNG (200×200, cached em S3, gerado via satori+resvg)
POST   /subscriptions           → { email } [Cognito registered user ou email-only]
DELETE /subscriptions           → [JWT: registered user] unsubscribe
```

**User Profiles**
```
Public user    → all GET endpoints, no auth
Registered     → self-signup via Cognito, receives email notifications, can subscribe/unsubscribe
Administrator  → Cognito group "admin", full CRUD on posts/articles, triggers notifications
```

### Build & deploy

esbuild bundling and the `deploy.yml` pipeline (build → zip → S3 → `update-function-code` +
`put-rest-api`, coverage gate) are owned by `/workflow/github-actions` — see also `/backend/framework-hono`
(handler/bundle shape) and `/backend/coverage`.

## Repo 3: tadeumendonca-fed

### Directory Structure

```
tadeumendonca-fed/
├── VERSION
├── .bumpversion.toml
├── index.html
├── vite.config.ts
├── playwright.config.ts     # E2E test configuration
├── tsconfig.json
├── tsconfig.node.json
├── eslint.config.mjs
├── vitest.config.ts
├── package.json
├── .env.example             # VITE_API_BASE_URL, VITE_COGNITO_*
├── docs/
│   ├── architecture.md      # mermaid flowchart: componentes React, roteamento, fluxo de estado
│   └── sequences.md         # mermaid sequenceDiagram: auth PKCE, fetch profile, infinite scroll posts
├── .github/
│   └── workflows/
│       ├── ci.yml           # PR: lint + typecheck + unit tests (coverage ≥ 85%) + E2E (Playwright)
│       ├── deploy.yml       # push develop/main → build → deploy (blocks if coverage < 85%)
│       ├── version-develop.yml
│       └── version-main.yml
├── public/
│   └── robots.txt           # SEO: allow all + sitemap pointer
├── scripts/
│   └── generate-sitemap.ts  # SEO: build sitemap.xml from articles list (run in deploy.yml)
├── e2e/
│   ├── home.spec.ts         # Phase 1: CV page renders profile sections
│   ├── feed.spec.ts         # Phase 2: feed loads, infinite scroll
│   └── auth.spec.ts         # Phase 2: Cognito PKCE callback flow
└── src/
    ├── main.tsx
    ├── App.tsx
    ├── router.tsx            # React Router v6
    ├── env.ts                # typed import.meta.env wrapper
    ├── pages/
    │   ├── home/
    │   │   ├── HomePage.tsx          # Phase 1: CV composite
    │   │   └── sections/
    │   │       ├── HeroSection.tsx
    │   │       ├── ExperienceSection.tsx
    │   │       ├── EducationSection.tsx
    │   │       ├── CertificationsSection.tsx
    │   │       └── SkillsSection.tsx
    │   ├── feed/
    │   │   ├── FeedPage.tsx          # Phase 2
    │   │   ├── PostCard.tsx
    │   │   └── PostCompose.tsx       # admin only
    │   ├── articles/
    │   │   ├── ArticlesPage.tsx      # Phase 3: list
    │   │   └── ArticlePage.tsx       # single + markdown render
    │   └── auth/
    │       └── CallbackPage.tsx      # Cognito OAuth2 PKCE callback
    ├── components/
    │   ├── layout/
    │   │   ├── Layout.tsx
    │   │   ├── Header.tsx
    │   │   └── Footer.tsx
    │   ├── ui/
    │   │   ├── Badge.tsx, Card.tsx, Spinner.tsx, Timeline.tsx, ErrorBoundary.tsx
    │   ├── seo/
    │   │   └── Seo.tsx               # react-helmet-async: title/meta/canonical/OG/JSON-LD per route
    │   └── auth/
    │       └── RequireAuth.tsx       # guards admin routes
    ├── hooks/
    │   ├── useProfile.ts
    │   ├── usePosts.ts               # Phase 2: infinite scroll
    │   └── useArticles.ts            # Phase 3: tag filter + pagination
    ├── services/
    │   └── api.ts                    # typed fetch wrapper (all endpoints)
    ├── store/
    │   └── authStore.ts              # Zustand + persist: accessToken + isAdmin flag
    └── types/
        ├── profile.ts, post.ts, article.ts
```

### Key Dependencies

```json
{
  "dependencies": {
    "react": "^18.3.0", "react-dom": "^18.3.0",
    "react-router-dom": "^6.23.0",
    "@tanstack/react-query": "^5.0.0",
    "aws-amplify": "^6.0.0",        // Cognito SDK (auth)
    "zustand": "^4.5.0",
    "@cloudscape-design/components": "^3.0.0",
    "@cloudscape-design/global-styles": "^1.0.0",
    "@cloudscape-design/design-tokens": "^3.0.0",
    "react-markdown": "^9.0.0",     // Phase 3: article rendering
    "rehype-highlight": "^7.0.0",   // Phase 3: code highlighting
    "react-helmet-async": "^2.0.0"  // SEO: per-route title/meta/canonical + JSON-LD
  },
  "devDependencies": {
    "@playwright/test": "^1.44.0"   // E2E tests
  }
}
```

Cloudscape DS (https://cloudscape.design/) is AWS's open-source design system — used internally
across AWS console products. Using it on a personal portfolio signals fluency with AWS-grade
UX patterns and component-driven design. Key components used:
- `AppLayout` + `SideNavigation` — consistent page shell
- `ContentLayout` + `SpaceBetween` — layout primitives
- `Cards`, `Table` — experience / certifications lists
- `Badge` — skill tags
- `Container` + `Header` — section wrappers
- `Button`, `Form`, `Textarea` — admin compose UI (Phase 2)
- `Alert`, `Spinner`, `StatusIndicator` — feedback states
```

### Build & deploy

The `deploy.yml` pipeline (Vite build → S3 sync with split cache headers → CloudFront invalidation,
coverage + E2E gates) is owned by `/workflow/github-actions` — see also `/frontend/seo` (sitemap build
step) and `/frontend/coverage`.

## Repo 4: tadeumendonca-skills

Claude Code custom slash command library. No AWS dependencies.

### Skills are the source of truth

The implementation pattern for every component lives as a Claude Code slash command in the
**`tadeumendonca-skills`** repo (`.claude/commands/`) — **not duplicated here**. This plan owns
architecture, decisions, and cross-repo contracts; the skills own *how* each piece is implemented.
Full command reference: `tadeumendonca-skills/CLAUDE.md`.

Skills are created up front (before `v0.2.0`) and validated by the owner before each phase — never
ad-hoc during development. Installed per consuming repo by symlinking/copying `.claude/commands/`.

Current coverage (67 skills):

- **architecture/ (1)** — `fed-spa-bff` (blueprint: SPA + BFF + modular-monolith backend)
- **backend/ (20)** — `framework-hono`, `openapi`, `bff`, `lambda-handler`, `dynamodb`, `audit-middleware`,
  `action-types`, `error-handling`, `logging`, `metrics`, `tracing`, `environment-config`,
  `secrets-management`, `redis-cache`, `notifications`, `og-image-generator`, `og-edge-handler`, `prerender`,
  `postman`, `coverage`
- **frontend/ (18)** — `framework-react`, `authentication`, `authorization`, `routing`, `state`,
  `api-client`, `pagination`, `forms`, `markdown`, `ux-states`, `design-system`, `storybook`,
  `environment-config`, `analytics`, `cloudwatch-rum`, `seo`, `playwright`, `coverage`
- **infrastructure/ (21)** — one skill per AWS service / tool (cross-cutting policies folded into their
  owning service): `terraform` (+module-policy +tagging), `vpc`, `route53` (+domain model), `acm`,
  `s3`, `cloudfront` (+spa), `waf`, `lambda` (+Pattern B), `api-gateway` (+contract), `cognito`
  (+custom-domain), `dynamodb`, `elasticache`, `ses`, `sns`, `iam` (+OIDC roles), `secrets-manager`,
  `ssm`, `kms` (+encryption), `cloudwatch`, `cloudwatch-rum`, `cloudwatch-xray`
- **workflow/ (7)** — `github-actions` (CI/CD umbrella: OIDC, GitFlow, deploys, backlog), `versioning`
  (numeric SemVer + bump-my-version), `terraform-cloud`, `sonarcloud`, `claude-code` (Claude GitHub App:
  assistant + auto PR review), `documentation-standard`, `license` (MIT standard)

> Stack invariants encoded by the skills: **Hono** on Lambda (not middy); **BFF** (API GW fronts only it; auth external — Cognito SDK + GW authorizer); Powertools Logger/Metrics(EMF)/Tracer → CloudWatch (no collector, no AMP, no Prometheus); all secrets via Secrets Manager;
> ElastiCache Redis (cache-aside, fail-open); encrypted in transit + at rest; numeric SemVer (no
> `-dev`); SEO via edge dynamic rendering (no SSR).


---

## Product Backlog — GitHub Issues

Per-repo GitHub Issues. Labels, milestones, issue templates, and the auto-maintained-backlog
convention are owned by `/workflow/github-actions`. The initial per-repo deliverables follow.

### Backlog inicial por repo

Issues abaixo representam os deliverables do plano traduzidos em itens de backlog. Claude cria estas issues no início da implementação.

**tadeumendonca-iac** (milestone v0.1.0)
- [x] `[infra] vpc.tf — VPC + subnets + NAT + S3 endpoint` `phase:1 type:infra semver:minor` ✅ aplicado em staging (vpc-03ea5f4a…)
- [x] `[infra] storage.tf — S3 buckets (frontend, artifacts, og-images)` `phase:1 type:infra semver:minor` ✅ aplicado em staging (OAC policies → #7)
- [x] `[infra] data.tf — DynamoDB tables (per entity, on-demand) + SSM` `phase:1 type:infra semver:minor` ✅ aplicado em staging (5 tabelas + 5 SSM)
- [x] `[infra] auth.tf — Cognito + WAF regional` `phase:1 type:infra semver:minor` ✅ aplicado em staging (pool us-east-1_7NhhMepZr, custom domain auth.staging.*; SES → Phase 2 #17)
- [x] `[infra] api.tf — API GW (REST v1) + BFF Lambda + og-edge (Lambda@Edge)` `phase:1 type:infra semver:minor` ✅ aplicado em staging (REST /health → 200, WAF no stage; og-edge associado ao CloudFront viewer-request — #6b/#22)
- [x] `[infra] frontend.tf — WAF CloudFront + CloudFront + Route53` `phase:1 type:infra semver:minor` ✅ aplicado em staging (CloudFront E2WH8SGP85H34K; Lambda@Edge → #6)
- [x] `[infra] iam.tf — OIDC roles para api e fed repos` `phase:1 type:infra semver:minor` ✅ aplicado em staging (github-actions-{api,fed}-staging + SSM)
- [x] `[docs] architecture.md — diagrama mermaid topologia + módulos` `phase:1 type:docs semver:patch` ✅ docs/architecture.md (topologia + grafo de dependência, mermaid validado)

**tadeumendonca-api** (milestones v0.2.0 → v0.4.0)
- [x] `[feature] fn-profile — GET /profile (Phase 1)` `phase:1 type:feature semver:minor` ✅ VIVO: api.staging.*/profile → 200 com o CV (seedado), CORS OK
- [x] `[feature] fn-og-image — GET /og/{type}/{slug}.png` `phase:1 type:feature semver:minor` ✅ VIVO: api.staging.*/og/profile/me.png → 302 → CDN serve PNG 1200×630 (satori + resvg-wasm, cache-aside S3). WASM (não native .node), assets embutidos via esbuild binary loader, generator lazy-import (tsx/vitest não resolvem binários). Gotchas resolvidos: S3 key = og/<type>/<slug>.png (CloudFront /og/* encaminha URI verbatim) + BFF precisa s3:ListBucket (HeadObject de key ausente → 404 não 403). og:image aponta p/ apiOrigin (PRs api #13/#14/#15, iac #33)
- [x] `[feature] fn-og-edge — Lambda@Edge bot UA detection` `phase:1 type:feature semver:minor` ✅ VIVO: staging.* com Googlebot/facebookexternalhit → x-prerendered-by:og-edge (crawler /prerender, social /og-meta); humano → SPA. Código no repo IAC (terraform/lambda-src/og-edge), Host-header API base, IaC owns version↔CloudFront (PR #32)
- [ ] `[chore] seed.ts — seed the profile table item (profile_id="me")` `phase:1 type:chore semver:patch`
- [ ] `[docs] data-model.md, sequences.md, architecture.md` `phase:1 type:docs semver:patch`
- [x] `[feature] fn-posts — CRUD admin JWT (Phase 2)` `phase:2 type:feature semver:minor` ✅ VIVO: GET /posts (feed público, cursor, gsi_pk='POST' esparso) + GET /posts/{id} (publicados); POST/PUT/DELETE admin (Cognito authorizer no contrato + checagem de grupo `admin` no BFF). Claims via requestContext.authorizer.claims (REST v1). (api PR #16)
- [x] `[feature] fn-notifications — SES email (Phase 2)` `phase:2 type:feature semver:minor` ✅ VIVO: POST/DELETE /subscriptions (autenticado, upsert/soft-unsub) + notifyPostPublished (fan-out SES por subscriber ativo, fail-open, inline; SNS é o caminho de escala). iac: SES domain identity staging.* + DKIM VERIFICADOS, BFF ses:SendEmail (iac #35, api PR #18). Deploy fixes: settle+single create-deployment (#17/#19)
- [x] `[feature] fn-articles — slug routing + tag queries (Phase 3)` `phase:3 type:feature semver:minor` ✅ VIVO: GET /articles (Scan list-all + ?tag via by-tag GSI) + GET /articles/{slug} (by-slug GSI, publicados); POST/PUT/DELETE admin (slug único, 409 ConflictError); og-meta/prerender/og-image type=articles. Um só param {slug} por recurso (API GW). (api PR #21)

**tadeumendonca-fed** (milestones v0.2.0 → v0.4.0)
- [x] `[feature] HomePage — Hero, Experience, Education, Certs, Skills` `phase:1 type:feature semver:minor` ✅ VIVO: staging.tadeumendonca.io serve a SPA (CloudFront+OAC, SSE-S3) → renderiza o CV de /profile
- [ ] `[docs] architecture.md, sequences.md` `phase:1 type:docs semver:patch`
- [x] `[feature] FeedPage + PostCompose + authStore (Phase 2)` `phase:2 type:feature semver:minor` ✅ VIVO: staging.*/feed (feed público + cursor), /posts/:id, /compose (admin RequireAuth → cria post), SubscribeButton; authStore (zustand, isAdmin do id token), react-router + Cloudscape TopNav/SideNav (fed PRs #9/#10)
- [x] `[feature] CallbackPage — Cognito PKCE callback (Phase 2)` `phase:2 type:feature semver:minor` ✅ VIVO: Amplify hosted-UI PKCE, /callback completa o code exchange (Hub), authedFetch envia Bearer (access token) + re-login no 401 (fed PR #9)
- [x] `[feature] ArticlesPage + ArticlePage + markdown render (Phase 3)` `phase:3 type:feature semver:minor` ✅ VIVO: staging.*/articles (lista + filtro por tag) + /articles/:slug (markdown + rehype-highlight); ComposeArticlePage (admin); componente Markdown compartilhado; og-edge roteia /articles/<slug> (fed PR #11, iac #37)

**tadeumendonca-skills** (milestone v0.2.0 — todas antes do início da Phase 1) ✅ entregue (67 skills, v0.3.3)
- [x] `[feature] backend/ skills — lambda-handler, dynamodb, audit-middleware, og-image-generator, og-edge-handler` `phase:1 type:feature`
- [x] `[feature] frontend/ skills — authentication, authorization, pagination, design-system` `phase:1 type:feature`
- [x] `[feature] infrastructure/ skills — lambda-pattern-b, api-gw-contract, ssm-config-bus, cognito-custom-domain` `phase:1 type:feature`
- [x] `[feature] workflow/ skills — gitflow, deploy-api, deploy-fed` `phase:1 type:feature`

---

## Documentation Standard

Markdown + Mermaid only (no static image diagrams); diagram types and per-repo docs are owned
by `/workflow/documentation-standard`.

## Phased Rollout

> **Skills:** todas criadas e validadas antes do início do v0.2.0 — não são entregues por fase.

### Phase 1 — CV Digital (public read-only) → v0.2.0

| Repo | Deliverables |
|---|---|
| `iac` | Todos os módulos live (vpc, storage, data/DynamoDB, auth, api, frontend, iam). Ambos os ambientes provisionados. |
| `api` | `fn-profile` (`GET /profile`) + `fn-og-image` + `fn-og-edge` (Lambda@Edge). Seed script (profile table). `docs/` completo. |
| `fed` | `HomePage` + todas as seções CV (Cloudscape). `useProfile`. Sem auth. `docs/` completo. |

### Phase 2 — Feed (registered users + notifications) → v0.3.0

| Repo | Deliverables |
|---|---|
| `iac` | SES domain verification + email identity ativada. |
| `api` | `fn-posts` (CRUD admin JWT) + `fn-notifications` (SES) + `GET /og-meta/posts/{id}`. |
| `fed` | `FeedPage`, `PostCard`, `PostCompose` (admin). `authStore` + `RequireAuth` + `CallbackPage` (Cognito PKCE). Subscription form. |

### Phase 3 — Articles (long-form) → v0.4.0

| Repo | Deliverables |
|---|---|
| `iac` | Sem mudanças de infra. |
| `api` | `fn-articles` (slug routing, tag queries) + `GET /og-meta/articles/{slug}`. |
| `fed` | `ArticlesPage` (list + tag filter), `ArticlePage` (markdown + `rehype-highlight`). `useArticles`. |

---

## Version Roadmap

Versões semânticas por release público (merge → `main`). Cada repo tem seu próprio `VERSION` e versionamento independente.

```
v0.1.0   Bootstrap infra
         iac: VPC + storage + DynamoDB + Cognito + WAF + API GW shell (seed)
         api: —
         fed: —

v0.2.0   Phase 1 — CV Digital (público, read-only)
         iac: Lambda fns provisionadas (profile, og-image, og-edge) + CloudFront + Route53
         api: fn-profile (GET /profile) + fn-og-image + fn-og-edge + seed script
         fed: HomePage completo (Hero, Experience, Education, Certifications, Skills)
         skills: backend/, frontend/, infrastructure/, workflow/ — todos os 15 guias criados e validados

v0.3.0   Phase 2 — Feed (usuários registrados + notificações) ✅ COMPLETO em staging (2026-06-09)
         iac: SES domain identity staging.* + DKIM VERIFICADOS; BFF ses:SendEmail
         api: fn-posts (CRUD admin JWT, Cognito authorizer no contrato) + fn-notifications (subscriptions + SES notify-on-publish, fail-open) + og-meta/prerender/og-image para posts
         fed: FeedPage, PostCard, PostPage, ComposePage (admin), SubscribeButton, authStore (PKCE), RequireAuth, CallbackPage; og-edge roteia /posts/<id>
         admin user de teste: tadeu.tyf@gmail.com (grupos admin+registered) — senha temp passada ao dono. SES sandbox: verificar destinatário p/ receber emails.

v0.4.0   Phase 3 — Articles (long-form) ✅ COMPLETO em staging (2026-06-09)
         api: fn-articles (slug routing, tag queries) + og-meta/prerender/og-image type=articles
         fed: ArticlesPage (list + tag filter), ArticlePage (markdown + rehype-highlight), ComposeArticlePage (admin)
         iac: og-edge roteia /articles/<slug>

NOTA: Phases 1-3 todas COMPLETAS e verificadas em STAGING. Falta: promoção para PRODUÇÃO (branch main).

v1.0.0   Estabilidade pública
         Todos os fluxos end-to-end validados em prd.
         Documentação completa (docs/ em todos repos com diagramas mermaid).
```

SemVer puramente numérico (sem sufixos `-dev`): cada merge em `develop` faz **bump de patch** automático (`v0.1.4`, `v0.1.5`, …); o merge `develop → main` faz o **bump do label** da release (`v0.2.0`) + GitHub Release (aprovação manual).

---

## Key Architectural Decisions

The rationale for each decision now lives in the **owning skill** (`tadeumendonca-skills`) — this
section is just the registry. See the skill for the full "why".

| # | Decision | Skill (owns rationale) |
|---|---|---|
| 1 | Pattern B — IaC owns Lambda config, api repo ships code | `/infrastructure/lambda` |
| 1b | API GW (REST) shell in IaC, OpenAPI contract in api repo (put-rest-api); CORS in the OpenAPI body | `/infrastructure/api-gateway` |
| 1c | ACM pre-created out-of-band, resolved by domain data source | `/infrastructure/terraform` |
| 2 | SSM Parameter Store as the cross-repo config bus | `/infrastructure/ssm` |
| 3 | Three user profiles: public / registered (self-signup) / admin | `/infrastructure/cognito` |
| 4 | Cursor-based pagination (not offset) | `/frontend/pagination` |
| 5 | arm64 (Graviton2) Lambda architecture | `/infrastructure/lambda` |
| 6 | CloudFront cache split (immutable assets vs no-cache index.html) | `/workflow/github-actions` |
| 7 | DynamoDB over DocumentDB — cost (on-demand ~$0 idle vs ~$54/mo always-on cluster); per-entity tables, IAM-auth | `/infrastructure/dynamodb` |
| 7b | Lambda@Edge: social OG + SEO dynamic rendering (no SSR) | `/backend/og-edge-handler` |
| 7c | OG image generation (satori + resvg, S3 cache) | `/backend/og-image-generator` |
| 8 | Cloudscape Design System | `/frontend/design-system` |
| 9 | VPC module + NAT: single (staging) vs per-AZ (production) | `/infrastructure/vpc` |
| 9b | Gateway Endpoints (S3 & DynamoDB off the NAT path) | `/infrastructure/vpc` |
| 10 | No API versioning in Phase 1-3 | `/infrastructure/api-gateway` |
| 11 | ElastiCache Redis cache-aside (fail-open) | `/backend/redis-cache` |
| 12 | Observability: Powertools Logger/Metrics(EMF)/Tracer → CloudWatch (no collector, no AMP) | `/backend/metrics` |
| 13 | dotenv per env (non-secret) + Secrets Manager (sensitive) | `/backend/secrets-management` |
| 14 | Backend framework: Hono (replaces middy) | `/backend/framework-hono` |

---

## Bootstrap, migration & verification (one-time)

One-time, out-of-band steps run once before the first IaC apply — not Terraform-managed, **not skills**.

### 1. Landing-zone migration
```bash
cd tadeumendonca-io-aws-landing-zone/terraform
TF_WORKSPACE=tadeumendonca-lz-stg terraform destroy -auto-approve -var-file=env/main.tfvars
TF_WORKSPACE=tadeumendonca-lz-prd terraform destroy -var-file=env/main.tfvars   # manual confirm
```
Then archive the repo (GitHub → Settings → Archive). `vpc.tf` in `iac` re-creates the VPC inline (same topology); the serverless stack is created fresh — no state import.

### 2. TFC workspaces
Create `tadeumendonca-iac-staging` + `-production` in org `tadeumendonca-io`, execution mode **Local** (state strategy → `/infrastructure/terraform`).

### 3. ACM certificates
Pre-created + DNS-validated once — one us-east-1 cert covering `tadeumendonca.io`, `*.tadeumendonca.io`, `*.staging.tadeumendonca.io`, `*.production.tadeumendonca.io`. Resolved at runtime via `data "aws_acm_certificate"` — never in tfvars.

### 4. IaC repo OIDC role
`github-actions-tadeumendonca-iac` created once manually (chicken-and-egg): trust `token.actions.githubusercontent.com` scoped to `tadeumendonca/tadeumendonca-iac:*`, broad admin policy (S3, CloudFront, Lambda, APIGW, Cognito, DynamoDB, ElastiCache, EC2/VPC, Secrets Manager, Route53, WAF, SSM, IAM, Logs). The OIDC mechanism itself is a skill — `/infrastructure/iam` (it provisions the api/fed roles).

### 5. GitHub secrets & environments
- iac: `TFC_API_TOKEN`, `AWS_ROLE_ARN`, `VERSION_BUMP_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`.
- api/fed (after first apply): `AWS_OIDC_ROLE_ARN` ← SSM `/{env}/iam/github-actions-{api|fed}-role-arn`; + `VERSION_BUMP_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`.
- Environments: `staging` (no rules), `production` (required reviewer). Branch protection → `/workflow/github-actions`.

### 6. Verification
```bash
TF_WORKSPACE=tadeumendonca-iac-staging terraform plan -var-file=env/stg.tfvars
aws ssm get-parameter --name /staging/frontend/s3-bucket-name
curl https://api.staging.tadeumendonca.io/health    # 200 from seed route
```
