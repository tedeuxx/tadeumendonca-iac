# tadeumendonca-iac

**Shared infrastructure (Terraform) for the tadeumendonca.io platform — the regional WAF, and nothing else.**
After the migration, the **entire app** (Cognito, SES, API GW, S3, CloudFront, lambdas, the app deploy roles)
lives in the **`tadeumendonca-pwa`** monorepo (under `iac/`). This repo was slimmed to provision **only the
shared security baseline** — the **regional WAF** — which any workload can consume. Active siblings: `-pwa`
(the product), `-skills` (the Claude skills plugin). `-fed`/`-api` were deleted.

> Convention: everything **published on GitHub** (this file, descriptions, commits, PRs) is in **English**.

## Engineering principles (always-on floor)
This repo consumes the **`tadeumendonca-skills`** plugin's **principles layer** (enabled in
`.claude/settings.json`; its `PreToolUse` permission-guard hook activates automatically). The
non-negotiable floor — never bends to risk:
- **Plan-first** — design and align before changing infra; **ask on the boundaries** (architecture,
  contracts, anything irreversible), decide autonomously on in-pattern work. Never a solo architectural call.
- **Thin vertical slices, WIP = 1** — one reviewable increment at a time; surgical changes, debt tracked as issues.
- **Quality is a gate** — checkov + `fmt`/`validate` + a **reviewed `plan`** + Sonar; **apply only on merge,
  pipeline-only** (`terraform apply`/`destroy` never run on a laptop). For app repos the floor adds **100% E2E + API regression** — here the equivalent is a clean reviewed plan before any merge.
- **Observability is part of done** — WAF logging (`aws-waf-logs-*`) and a post-apply check that the ARN
  published to SSM is what consumers read.
- **Security & resilience by-design** — least-privilege (per-env runner roles), no hardcoded account IDs,
  the WAF block-list as the shared baseline.
- **Rigor calibrated to blast-radius** — light on staging (auto-apply on merge to `develop`), heavy on
  production (merge to `main`, gated by Environment approval; **promotion always asks**).
- **Environment = git branch** — `develop` → staging, `main` → production; the pipeline deploys on merge, the
  agent never deploys. Local is **read-only** (`fmt`/`validate`/inspection `plan`).

Depth lives in the plugin's `/principles/*` skills — `/principles/engineering-philosophy`,
`/principles/verification-and-gates`, `/principles/dev-loop`, `/principles/permissions-and-environments` (the
canonical environment + permission model this repo's `.claude/settings.json` encodes). For deliberate
validation of a non-trivial decision, invoke the **`principles-guide`** subagent.

## Purpose in the platform (why it exists)
tadeumendonca.io is the owner's **proof-of-engineering product** (repositioning from "Architect / AWS
Professional Services" to **Senior Software Engineer** at product companies); the architecture IS part of the
argument. This repo's role is small but deliberate: it demonstrates **shared-vs-workload-specific infra
separation** (the regional WAF is a reusable baseline consumed via SSM) and **IaC-first** (zero ClickOps). The
product visitors see is in `-pwa`; here is only the shared foundation.

## Architectural decisions & trade-offs (rationale)
The platform runs a real product on a personal budget. Two requirements drive everything: **R1 —
cost-controlled / scale-to-zero**; **R2 — a defensible security posture** (security is part of the argument).
This repo's slice:
- **Shared regional WAF = the cost reason for the shared-vs-workload split.** A WAF web ACL costs ~$5/mo +
  ~$1/rule/mo + $0.60/M requests. Provisioning **one** regional WAF here and **sharing it across workloads**
  (API GW stages, Cognito hosted UIs) via the SSM config bus avoids duplicating that cost per workload. That
  is exactly why "shared vs workload-specific" is the dividing line — reusable baselines live here.
- **WAF kept despite cost (R2).** WAF (and, in `-pwa`, Cognito threat protection) is a deliberate security
  investment — part of the defensible posture, not cut for cost.
- **Least-privilege, per-env CI runner (R2 — compensates for R1's account choice).** Staging and production
  share **one AWS account** (no account-level isolation — a cost decision). The **per-env iac runner roles**
  (`github-actions-tadeumendonca-iac-{staging,production}`) restore that isolation cheaply: a leaked staging
  OIDC token can't assume the production role, and the prod role is released only after the `production`
  Environment approval. The IAM role boundary IS the isolation here.
- **Single AWS account** (`Project` tag = workload boundary), **TFC free tier + Local execution**, **AWS
  Support Basic** — same cost discipline as the rest of the platform.

## What this repo provisions (`waf.tf`)
- **Shared REGIONAL WAF:** `module.waf_regional` (cloudposse/waf, scope `REGIONAL`, block-list:
  `AWSManagedRulesCommonRuleSet` + `KnownBadInputs` + rate-limit), the log group `aws-waf-logs-*`, and the ARN
  published to SSM **`/{env}/auth/waf-regional-arn`**.
- **Associations do NOT live here** — each consuming workload (e.g. `-pwa`, in `api.tf` + `auth.tf`) reads the
  ARN via SSM and creates its own `aws_wafv2_web_acl_association` (API GW stage, Cognito hosted UI).
- No Cognito/SES/CloudFront/lambda/app-IAM here — all of that is in `-pwa`.

## Branching strategy (GitFlow — same as -pwa)
- **`develop`** is the default. Feature/fix branches from `develop` → PR → merge → **auto-apply to staging**.
- **`main`** = **production**: merge applies to prod, gated by the `production` Environment approval.
- Numeric SemVer auto-bump (`version-develop` patch on develop; `version-main` from the PR `semver:` label on main).
- Note: **`-skills` uses a different model** (plugin release-cut, not a deploy) — see its CLAUDE.md.

## Stack
- **Terraform >= 1.9**, AWS provider `~> 5.0`, **single provider** (default region; the `us_east_1` alias left
  with the CloudFront/ACM/Cognito infra when it moved to `-pwa`).
- **Terraform Cloud** = state + lock backend; **Local** execution (GitHub Actions runs `plan`/`apply`). `TFC_API_TOKEN` authenticates.
- Official modules first (`terraform-aws-modules/*` / cloudposse), called directly at the root.

## Layout (`terraform/` — single root, never duplicated per env)
`waf.tf` + `providers`/`variables`/`versions`/`outputs`/`locals`. `env/*.tfvars` (the only per-env difference).
Remaining variables: `project`, `environment`, `aws_region`.

## State & environments
- **One TFC workspace per env:** `tadeumendonca-iac-{staging|production}` (tagged). CI selects via
  `TF_WORKSPACE` + `-var-file=env/<env>.tfvars`. The `cloud{}` block doesn't interpolate — literals only.
- Per-env via the `var.environment == "production"` conditional.

## Conventions
- Every variable has a `type` + a `validation` block (fail at `plan`, never at `apply`).
- Tags via `default_tags` (`Project`/`Environment`/`ManagedBy=terraform`); `Project` is the workload boundary
  (the AWS account is shared).
- No hardcoded `account_id` (→ `data.aws_caller_identity`).
- App deploy OIDC roles (BFF/FED) live in `-pwa` now. The **iac runner** is per-env, bootstrapped out-of-band,
  trusting both `-iac` and `-pwa`.

## CI/CD (`.github/workflows/`)
- `terraform-plan.yml` (PR): checkov → fmt → init → validate → plan → comment. The job assumes the **per-env**
  role via `environment:` (staging for PR→develop, production for PR→main).
- `terraform-deploy.yml`: merge `develop` → apply staging; merge `main` → apply production (Environment approval).
- `sonar.yml`: SonarCloud IaC (required `sonar` check).

## Secrets (platform standard — see `/workflow/github-actions`)
- `AWS_INFRA_OIDC_ROLE_ARN` = **environment secret** per-env (points to the per-env runner role).
- Tooling tokens = **repository**: `TFC_API_TOKEN`, `SONAR_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `VERSION_BUMP_TOKEN`.

## ⚠️ Destructive / requires explicit confirmation
- **Merge to `develop`** auto-applies real AWS infra to **staging**; **merge to `main`** applies **production**
  (with approval). Confirm the `plan` first.
- `terraform apply`/`destroy` run in CI only (pipeline-only). Local is read-only (`fmt`/`validate`/inspection `plan`).
