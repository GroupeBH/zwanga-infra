# Zwanga Infra

This repository provisions an EC2 VM with Terraform, then deploys a Nest.js API behind Caddy with Ansible.

## tfvars

A real `terraform/terraform.tfvars` file is now present, and a reusable template is available in [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example).

Important values to fill in:

- `key_name`: existing EC2 key pair name
- `admin_cidr`: your public IP in `/32` format
- `backend_repo`: GitHub URL of the Nest.js repository to deploy
- `backend_ref`: branch, tag, or commit to deploy
- `domain_name`: optional
- `caddy_email`: optional

Assumption: the GitHub repository referenced by `backend_repo` has the Nest.js app at its root, with its own `Dockerfile`, `package.json`, and `src/`.

## Terraform Backend

The Terraform S3 backend does not belong in `terraform.tfvars`.
Terraform reads the backend during `terraform init`, before it loads normal input variables.
That is why the S3 bucket has to live in a dedicated backend file or in `-backend-config` arguments.

A local backend file is now included in [`terraform/backend.hcl`](terraform/backend.hcl), with a matching template in [`terraform/backend.hcl.example`](terraform/backend.hcl.example).

Example backend file:

```hcl
bucket  = "my-tf-state-bucket"
key     = "zwanga/terraform.tfstate"
region  = "us-east-1"
encrypt = true
# dynamodb_table = "my-tf-lock-table"
```

## Local Deployment

[`deploy.sh`](deploy.sh) automatically loads:

- `terraform/terraform.tfvars` when present
- `terraform/backend.hcl` when present

CLI flags or environment variables can still override these files.

Example:

```bash
PRIVATE_KEY_PATH=~/.ssh/zwanga.pem \
./deploy.sh
```

If you prefer not to use `terraform/backend.hcl`, you can still pass backend values explicitly:

```bash
TF_STATE_BUCKET=my-tf-state-bucket \
TF_STATE_KEY=zwanga/terraform.tfstate \
TF_STATE_REGION=us-east-1 \
PRIVATE_KEY_PATH=~/.ssh/zwanga.pem \
./deploy.sh
```

You can still override any tfvars value with environment variables or CLI flags, for example:

```bash
BACKEND_REF=main ./deploy.sh --private-key ~/.ssh/zwanga.pem
```

## GitHub Actions

Two workflows are included in [`.github/workflows`](.github/workflows):

- [`infra-ci.yml`](.github/workflows/infra-ci.yml): validates Terraform and Ansible syntax
- [`deploy.yml`](.github/workflows/deploy.yml): deploys infrastructure and the Nest.js app with Terraform plus Ansible

### Variables And Secrets For The Infra Repository

GitHub Actions variables:

- `AWS_REGION`
- `TF_STATE_BUCKET` optional if you use `TF_BACKEND_CONFIG_CONTENT`
- `TF_STATE_KEY` optional
- `TF_STATE_REGION` optional
- `TF_LOCK_TABLE` optional
- `BACKEND_REPO` optional if already present inside `TFVARS_CONTENT`
- `BACKEND_REF` optional

GitHub Actions secrets:

- `AWS_ROLE_TO_ASSUME`: IAM role assumed through OIDC
- `EC2_SSH_PRIVATE_KEY`: SSH private key used by Ansible
- `TFVARS_CONTENT`: full production content of `terraform.tfvars`
- `TF_BACKEND_CONFIG_CONTENT`: optional full content of `backend.hcl`

### Recommended CI/CD Split

The cleanest setup is to separate responsibilities:

1. Nest.js repository
   - CI on `pull_request` and `push`
   - `npm ci`
   - `npm run build`
   - `npm run test --if-present`

2. Infra repository
   - CD through [`deploy.yml`](.github/workflows/deploy.yml)
   - manual runs with `workflow_dispatch`
   - or automatic runs through `repository_dispatch` after a merge in the Nest.js repository

### Minimal Workflow For The Nest.js Repository

```yaml
name: Nest CI

on:
  pull_request:
  push:
    branches:
      - main

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
      - run: npm ci
      - run: npm run build
      - run: npm run test --if-present
```

### Trigger Infra Deployment From The Nest.js Repository

After a merge on `main`, the Nest.js repository can call `repository_dispatch` on the infra repository to request a deployment of the current commit:

```yaml
- name: Trigger infra deploy
  if: github.ref == 'refs/heads/main'
  env:
    INFRA_REPO_TOKEN: ${{ secrets.INFRA_REPO_TOKEN }}
  run: |
    curl -L \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${INFRA_REPO_TOKEN}" \
      https://api.github.com/repos/OWNER/INFRA_REPO/dispatches \
      -d "{\"event_type\":\"deploy-nest-api\",\"client_payload\":{\"backend_ref\":\"${GITHUB_SHA}\"}}"
```

The `INFRA_REPO_TOKEN` PAT must have access to the infra repository so it can trigger the workflow.