# tadeumendonca-iac

Infraestrutura (Terraform) de **tadeumendonca.io** — **um único repo provisiona TUDO**, para os dois
ambientes (staging + production). Parte do platform `tadeumendonca` (irmãos: `-fed`, `-api`, `-skills`).

## ⚠️ Antes de tudo
**Merge em `develop` aplica infraestrutura AWS REAL em staging** (auto-apply via pipeline); merge em
`main` aplica em produção (com aprovação). Confirme o `plan` antes de mergear — há custo e risco reais.

## Stack
- **Terraform >= 1.9**, provider **AWS `~> 5.0`**. Dois providers: `default` + alias **`us_east_1`** (CloudFront, WAF CLOUDFRONT, ACM, domínio custom do Cognito).
- **Terraform Cloud** como backend de state + lock; execução **Local** (o **GitHub Actions roda `plan`/`apply`**, não a TFC). `TFC_API_TOKEN` autentica.
- **Módulos oficiais primeiro** (`terraform-aws-modules/*`), chamados **direto no root** — sem wrappers L3. `aws_*` cru só onde nenhum módulo serve (API GW, `aws_lambda_permission`, `aws_wafv2_web_acl_association`, SG do lambda, `aws_route53_record`, `aws_ssm_parameter`, `aws_secretsmanager_secret`).

## Layout (`terraform/` — root único, nunca duplicado por env)
Um `.tf` por camada: `api` · `auth` · `frontend` · `iam` · `ses` · `storage` · `data` + `providers`/`variables`/`versions`/`outputs`/`locals`. Mais `env/*.tfvars` (só isto difere entre ambientes), `bootstrap/` (out-of-band), `lambda-src/` (og-edge), `builds/`, `assets/`.

## Estado & ambientes
- **Uma workspace TFC por ambiente**: `tadeumendonca-iac-{staging|production}` (com tag). O CI seleciona via `TF_WORKSPACE` + `-var-file=env/<env>.tfvars`. O `cloud{}` **não interpola variáveis** (parseado antes) — valores literais ali.
- Per-env via condicionais `var.environment == "production"` — evitar variáveis extras.

## Convenções (NÃO-óbvias)
- **Toda variável tem `type` + bloco `validation`** que valida o domínio (regex/contains/cidrhost) — falha no `plan`, nunca no `apply`.
- **Tags via `default_tags`** nos dois providers: `Project` / `Environment` / `ManagedBy=terraform`. O `Project` é a fronteira de workload (conta AWS é compartilhada).
- **Sem `account_id` hardcoded** (→ `data.aws_caller_identity`); ACM por `data.aws_acm_certificate` (cert out-of-band).
- Roles de deploy (OIDC) das pipelines vivem aqui (`iam.tf`); o runner do iac é bootstrapado out-of-band.

## CI/CD (`.github/workflows/`)
- `terraform-plan.yml` (PR): **checkov** (fail em qualquer finding não-suprimido) → `fmt -check` → `init` → `validate` → `plan` → comenta o plan no PR.
- `terraform-deploy.yml`: merge `develop` → `apply` staging (auto); merge `main` → `apply` produção (aprovação de Environment).
- `sonar.yml`: **SonarCloud IaC** (complementar ao checkov; check `sonar` obrigatório).

## Comandos (geralmente via CI)
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
# plan/apply: feitos pela pipeline com TF_WORKSPACE + -var-file=env/<env>.tfvars
checkov -d terraform/ --config-file .checkov.yaml
```
