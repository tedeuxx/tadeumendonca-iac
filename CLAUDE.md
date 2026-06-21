# tadeumendonca-iac

**Infra COMPARTILHADA (Terraform) da plataforma tadeumendonca.io — só a WAF regional.** Pós-migração,
**todo o app** (Cognito, SES, API GW, S3, CloudFront, lambdas, roles de deploy do app) vive no monorepo
**`tadeumendonca-pwa`** (em `iac/`). Este repo ficou enxuto: provisiona **apenas a baseline de segurança
compartilhada** — a **WAF REGIONAL** —, que qualquer workload pode consumir. Irmãos ativos: `-pwa` (o app),
`-skills` (guias). `-fed`/`-api` **arquivados**.

## Propósito na plataforma (por que existe)
tadeumendonca.io é o **artefato de prova de engenharia** do dono — um produto real que ele projeta,
constrói e opera, para se reposicionar de "Architect (AWS Professional Services)" para **Senior Software
Engineer** em product companies; a **arquitetura é parte do argumento**. O papel **deste** repo nesse
argumento é pequeno mas deliberado: ele demonstra **separação de infra shared vs workload-specific** (a WAF
regional é uma baseline reutilizável por qualquer workload, consumida via SSM) e **IaC-first** (zero
ClickOps). O produto que os visitantes veem está no `-pwa`; aqui é só a fundação compartilhada.

**Implicações operacionais (regra):** decisões defensáveis com trade-off articulável (código é público e
é o pitch); **sem over-engineering** (o mínimo que resolve), mas é **produto que precisa funcionar**;
cloud-native, IaC-first, custo controlado, observabilidade básica, CI/CD desde o commit 1.

## ⚠️ Antes de tudo
**Merge em `develop` aplica infra AWS REAL em staging** (auto-apply via pipeline); merge em `main` aplica
em produção (com aprovação do Environment). Confirme o `plan` antes de mergear — o escopo hoje é pequeno
(a WAF compartilhada), mas o risco/custo são reais.

## O que este repo provisiona (`waf.tf`)
- **WAF REGIONAL compartilhada**: `module.waf_regional` (cloudposse/waf, scope `REGIONAL`, block-list:
  `AWSManagedRulesCommonRuleSet` + `KnownBadInputs` + rate-limit), o log group `aws-waf-logs-*`, e o ARN
  publicado em SSM **`/{env}/auth/waf-regional-arn`**.
- **As associações NÃO ficam aqui** — cada workload que consome (ex.: o `-pwa`, em `api.tf` + `auth.tf`)
  lê o ARN via SSM e cria seu próprio `aws_wafv2_web_acl_association` (stage do API GW, hosted UI do Cognito).
- Nada de Cognito/SES/CloudFront/lambda/IAM-de-app aqui — tudo isso é do `-pwa`.

## Decisões fixas (NÃO reverter sem discussão)
- **`-iac` = só infra COMPARTILHADA** (a WAF regional). O critério é **shared vs workload-specific**: o que é
  reutilizável por mais de um workload fica aqui; o que é dedicado a um workload (Cognito, SES bound ao
  domínio, etc.) vive no `-pwa`. Foi essa a régua que colapsou o `-iac` pra WAF-only.
- **As associações WAF NÃO ficam aqui** — o consumidor lê o ARN via **SSM** (`/{env}/auth/waf-regional-arn`)
  e cria a própria associação. SSM é o **config bus** (DAG acíclico, sem `terraform_remote_state`).
- **IaC pipeline-only**; runner do iac **per-env**, bootstrapado out-of-band, confiando em `-iac` + `-pwa`.
- **Terraform >= 1.9**, provider **AWS `~> 5.0`**, **um único provider** (região default). O alias
  `us_east_1` saiu com a infra de CloudFront/ACM/Cognito (foi pro `-pwa`).
- **Terraform Cloud** = backend de state + lock; execução **Local** (o GitHub Actions roda `plan`/`apply`).
  `TFC_API_TOKEN` autentica.
- **Módulos oficiais primeiro** (`terraform-aws-modules/*` / cloudposse), chamados direto no root.

## Layout (`terraform/` — root único, nunca duplicado por env)
`waf.tf` + `providers`/`variables`/`versions`/`outputs`/`locals`. `env/*.tfvars` (só isto difere por
ambiente). Variáveis remanescentes: `project`, `environment`, `aws_region`.

## Estado & ambientes
- **Uma workspace TFC por ambiente**: `tadeumendonca-iac-{staging|production}` (com tag). O CI seleciona
  via `TF_WORKSPACE` + `-var-file=env/<env>.tfvars`. O `cloud{}` não interpola variáveis — literais ali.
- Per-env via condicional `var.environment == "production"`.

## Convenções (NÃO-óbvias)
- **Toda variável tem `type` + bloco `validation`** (falha no `plan`, nunca no `apply`).
- **Tags via `default_tags`**: `Project`/`Environment`/`ManagedBy=terraform`. `Project` é a fronteira de
  workload (conta AWS é compartilhada).
- **Sem `account_id` hardcoded** (→ `data.aws_caller_identity`).
- **Roles de deploy OIDC:** os do app (BFF/FED) vivem no `-pwa` agora. O **runner do iac** é **per-env**
  (`github-actions-tadeumendonca-iac-<env>`), bootstrapado **out-of-band**, e confia tanto no `-iac` quanto
  no `-pwa` (que também roda `infra-apply`).

## CI/CD (`.github/workflows/`)
- `terraform-plan.yml` (PR): **checkov** → `fmt -check` → `init` → `validate` → `plan` → comenta no PR.
  O job assume o role **per-env** via `environment:` (staging em PR→develop, production em PR→main).
- `terraform-deploy.yml`: merge `develop` → `apply` staging (auto); merge `main` → `apply` produção (aprovação).
- `sonar.yml`: **SonarCloud IaC** (check `sonar` obrigatório).

## Secrets (padrão da plataforma — ver skill `/workflow/github-actions`)
- `AWS_INFRA_OIDC_ROLE_ARN` = **environment secret** per-env (staging/production), apontando pro runner per-env.
- Tooling tokens = **repository**: `TFC_API_TOKEN`, `SONAR_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `VERSION_BUMP_TOKEN`.

## Comandos (geralmente via CI)
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
checkov -d terraform/ --config-file .checkov.yaml
```
