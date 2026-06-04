# tadeumendonca-iac

Infrastructure as Code for [tadeumendonca.io](https://tadeumendonca.io) — Terraform modules provisioning all application infrastructure on AWS.

## Stack

- **IaC**: Terraform
- **Provider**: AWS
- **State**: S3 + DynamoDB (remote state)
- **Foundation**: [`tadeumendonca-io-aws-landing-zone`](https://github.com/tedeuxx/tadeumendonca-io-aws-landing-zone)

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
