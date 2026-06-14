# tadeumendonca-iac

Infrastructure as Code for [tadeumendonca.io](https://tadeumendonca.io) — Terraform modules provisioning all application infrastructure on AWS.

## Stack

- **IaC**: Terraform
- **Provider**: AWS
- **State**: S3 + DynamoDB (remote state)
- **Foundation**: [`tadeumendonca-io-aws-landing-zone`](https://github.com/tedeuxx/tadeumendonca-io-aws-landing-zone)

## Prerequisites — out-of-band secrets

Some secrets are **not** created by Terraform (they hold credentials issued by third parties). Terraform
**references** them via data sources — reading either the value (when Terraform itself wires it, e.g.
`google-oauth` → Cognito) or just the ARN (when a Lambda fetches it at runtime, e.g. `giphy-api-key`).
Either way each must already exist in **AWS Secrets Manager** (region **us-east-1**) **before** the first
`apply` for that environment, or the plan fails with `ResourceNotFoundException`.

Naming convention: `tadeumendonca/<environment>/<secret>` where `<environment>` is `staging` or
`production`. Create one secret **per environment** (staging is live today; create the production copies
when promoting to prod).

| Secret | Consumed by | JSON shape |
| --- | --- | --- |
| `tadeumendonca/<env>/google-oauth` | Cognito Google identity provider (`auth.tf`) | `{ "client_id": "…", "client_secret": "…" }` |
| `tadeumendonca/<env>/giphy-api-key` | BFF Lambda — blog editor GIF search proxy; ARN in env `GIPHY_SECRET_ARN`, value fetched at runtime (`api.tf`) | `{ "api_key": "…" }` |

### `google-oauth` — Google OAuth client

1. Open the [Google Cloud Console → APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials).
2. **Create Credentials → OAuth client ID**, application type **Web application**.
3. Add the Cognito hosted-UI callback as an **Authorized redirect URI**
   (`https://<your-cognito-domain>/oauth2/idpresponse`).
4. Copy the generated **Client ID** and **Client secret**.

### `giphy-api-key` — Giphy API key

1. Open the [Giphy Developers dashboard](https://developers.giphy.com/dashboard/) and sign in.
2. **Create an App** → choose type **API** (not SDK) — it is the key for server-side HTTP search calls.
3. Name it `tadeumendonca-io-blog`; copy the generated **API key**.
4. The free **beta key** is enough for staging (lower rate limit); request a Production Key later if volume requires it.
5. The key is used **only by the BFF** (server-side proxy) and never exposed to the frontend.

### Storing / rotating a secret

Create or update a secret (replace `<env>`; never paste the value into shell history — read it from a file):

```bash
# create (first time)
aws secretsmanager create-secret --region us-east-1 \
  --name "tadeumendonca/<env>/giphy-api-key" \
  --secret-string file://giphy-secret.json   # { "api_key": "…" }

# rotate (later)
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id "tadeumendonca/<env>/giphy-api-key" \
  --secret-string file://giphy-secret.json
```

> Note: the ACM certificate (us-east-1, referenced via `data.aws_acm_certificate`) and the Terraform
> Cloud / GitHub OIDC deploy credentials are also provisioned out-of-band, but are not application
> secrets — see `docs/architecture.md`.

## Resources

- API Gateway + Lambda functions
- DynamoDB tables
- S3 buckets (assets, static site)
- CloudFront distribution
- Cognito user pool
- Route 53 records (tadeumendonca.io)
- IAM roles and policies
- WAF rules

## Structure

```
modules/
  api/        # API Gateway + Lambda
  frontend/   # S3 + CloudFront
  auth/       # Cognito
  data/       # DynamoDB + S3
  dns/        # Route 53
envs/
  prod/
```

## Related repos

- [`tadeumendonca-fed`](https://github.com/tedeuxx/tadeumendonca-fed) — Frontend
- [`tadeumendonca-api`](https://github.com/tedeuxx/tadeumendonca-api) — Backend API
- [`tadeumendonca-io-aws-landing-zone`](https://github.com/tedeuxx/tadeumendonca-io-aws-landing-zone) — AWS account foundation
