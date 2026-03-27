# Zwanga Infra

This repository provisions a low-cost two-node AWS deployment for the Zwanga Nest.js API.
Terraform creates the infrastructure, then Ansible deploys the same Docker Hub image on a primary and secondary EC2 node. Each node runs Caddy, and the public Caddy entry point load balances across both Nest.js instances over private VPC traffic.

## Architecture

```text
Internet
  -> External DNS provider
     -> Active public IP (primary or secondary)
        -> Caddy on the active node
           -> local Nest.js container
           -> peer Nest.js container over private IP
```

What this repo now provisions by default:

- 1 VPC
- 1 internet gateway
- 2 public subnets in 2 AZs when available
- 2 EC2 instances when `secondary_instance_enabled = true`
- 2 Elastic IPs
- 1 shared security group
- 2 CloudWatch log groups (`/${instance_name}/app` and `/${instance_name}/caddy`)
- 2 CloudWatch alarms per node for EC2 status checks
- optional SNS email notifications for infra alerts
- optional SSM Parameter Store secure parameters

The design goal is simple:

- keep the stack inexpensive
- use Caddy as the application-layer load balancer between the two EC2 nodes
- avoid the biggest single point of failure of a single EC2 node
- stay compatible with an external DNS provider instead of Route 53

## Read First

Detailed documentation lives here:

- [`docs/low-cost-failover.md`](docs/low-cost-failover.md): architecture, tradeoffs, DNS strategy, and HTTPS behavior
- [`docs/manual-failover-runbook.md`](docs/manual-failover-runbook.md): operational runbook for failover, failback, and incident handling

If you only read one warning before deploying, read this one:

> In this low-cost design, HTTPS on the passive node is the main operational tradeoff.
> With Caddy using ACME HTTP/TLS challenges and an external DNS provider pointing to the primary node, the secondary node may not be able to pre-issue the same public certificate until DNS is switched to it.
> This is acceptable for low-cost failover, but it is not as seamless as an ALB-based architecture.

## Terraform Inputs

A reusable template is available in [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example).

Important values:

- `key_name`: existing EC2 key pair name
- `admin_cidr`: your public IP in `/32` format
- `app_image_repository`: Docker Hub repository to deploy
- `app_image_tag`: Docker image tag to deploy
- `secondary_instance_enabled`: enables the second failover node, defaults to `true`
- `secondary_availability_zone`: optional manual override for the failover AZ
- `secondary_public_subnet_cidr`: CIDR block for the failover subnet
- `domain_name`: optional public domain served by Caddy
- `caddy_email`: optional ACME contact email
- `app_healthcheck_path`: only used for outputs/documentation, not for deployment gating
- `alarm_email_endpoints`: optional email recipients for CloudWatch/SNS alerts

Assumption: `app_image_repository` points to a production-ready Nest.js image for the EC2 target architecture.

## Terraform Backend

The Terraform S3 backend does not belong in `terraform.tfvars`.
Terraform reads the backend during `terraform init`, before it loads normal input variables.
That is why the S3 bucket has to live in a dedicated backend file or in `-backend-config` arguments.

This repository is now aligned on a Frankfurt deployment with native S3 state locking.
That means you can use an S3 backend file with `use_lockfile = true` and skip the DynamoDB lock table entirely.

Use [`terraform/backend.hcl`](terraform/backend.hcl) locally, or create it from [`terraform/backend.hcl.example`](terraform/backend.hcl.example).

Current example:

```hcl
bucket       = "zwanga-tfstates"
key          = "zwanga/eu-central-1/terraform.tfstate"
region       = "eu-central-1"
encrypt      = true
use_lockfile = true
```

How it works:

- Terraform creates and removes a `.tflock` object in the S3 backend automatically
- locking happens automatically on write operations such as `apply`
- if a lock gets stuck, use `terraform force-unlock <LOCK_ID>` carefully
- a DynamoDB lock table is no longer required for this setup

HashiCorp docs: [Terraform state locking](https://developer.hashicorp.com/terraform/language/state/locking)

## Local Deployment

[`deploy.sh`](deploy.sh) automatically loads:

- `terraform/terraform.tfvars` when present
- `terraform/backend.hcl` when present

CLI flags or environment variables can override those values.

Example:

```bash
PRIVATE_KEY_PATH=~/.ssh/zwanga-keys.pem \
./deploy.sh
```

If you prefer not to use `terraform/backend.hcl`, you can still pass backend values explicitly:

```bash
TF_STATE_BUCKET=zwanga-tfstates \
TF_STATE_KEY=zwanga/eu-central-1/terraform.tfstate \
TF_STATE_REGION=eu-central-1 \
TF_BACKEND_USE_LOCKFILE=true \
PRIVATE_KEY_PATH=~/.ssh/zwanga-keys.pem \
./deploy.sh
```

Override the image tag directly when you want to deploy a specific build:

```bash
APP_IMAGE_TAG=2026-03-23-sha123 \
PRIVATE_KEY_PATH=~/.ssh/zwanga-keys.pem \
./deploy.sh
```

Inject an app env file from your workstation without going through GitHub Actions:

```bash
APP_ENV_FILE=./app/.env.production \
PRIVATE_KEY_PATH=~/.ssh/zwanga-keys.pem \
./deploy.sh
```

`deploy.sh` now builds an Ansible inventory with a `primary` host and, when enabled, a `secondary` host, including each node's private IP so Caddy can build its upstream mesh. The deploy script also uses `StrictHostKeyChecking=accept-new` during the run instead of disabling host-key checks entirely.
The playbook deploys serially to reduce blast radius during rollouts.

## External DNS Strategy

This stack intentionally assumes your DNS is hosted outside AWS.

Recommended setup:

- create a public record such as `api.example.com`
- simplest mode: point it to the primary Elastic IP in normal operation; that node's Caddy will still round-robin traffic across both app instances
- keep the secondary Elastic IP documented as the standby target
- set a low TTL, typically `60` or `120` seconds
- if your DNS provider supports weighted, multi-value, or health-checked records, you can publish both public IPs for more even edge distribution
- if your DNS provider supports automated failover/health checks, use the two Terraform outputs as primary/secondary targets
- otherwise use the manual runbook in [`docs/manual-failover-runbook.md`](docs/manual-failover-runbook.md)

Terraform outputs expose the values you need:

- `deploy_primary_public_ip`
- `deploy_secondary_public_ip`
- `external_dns_failover_targets`
- `ssh_commands`

## HTTPS And Caddy

Caddy automatically serves HTTPS only when `domain_name` is configured.
If `domain_name` is empty, Caddy serves plain HTTP on port 80.
Each public Caddy node uses round-robin load balancing with retries and passive failure detection across the local and peer Nest.js containers.

For HTTPS:

1. create a DNS record at your external DNS provider that points to the primary Elastic IP
2. set `domain_name`
3. set `caddy_email`
4. redeploy

Important limitation of the low-cost failover model:

- while DNS points at the primary node, the secondary node may not be able to complete public ACME validation for the same hostname
- after a DNS cutover, Caddy on the secondary can retry certificate issuance
- if you need seamless active-active HTTPS, move to an ALB-based design or use a certificate strategy that does not depend on traffic reaching a single node during issuance

## CloudWatch Logs And Alarms

Container logs are shipped through Docker's `awslogs` driver to the existing log groups:

- `/${instance_name}/app`
- `/${instance_name}/caddy`

With the new multi-host inventory, streams are easier to read:

- `app-primary`
- `app-secondary`
- `caddy-primary`
- `caddy-secondary`

The infra also creates:

- a `StatusCheckFailed_System` alarm per node, with EC2 recovery action
- a `StatusCheckFailed_Instance` alarm per node
- optional SNS email subscriptions when `alarm_email_endpoints` is not empty

## GitHub Actions

Three workflows are included in [`.github/workflows`](.github/workflows):

- [`infra-ci.yml`](.github/workflows/infra-ci.yml): validates Terraform and Ansible syntax
- [`deploy.yml`](.github/workflows/deploy.yml): deploys infrastructure and the Nest.js app with Terraform plus Ansible
- [`docker-image.yml`](.github/workflows/docker-image.yml): builds and pushes the Nest.js image to Docker Hub

### Variables And Secrets For The Infra Repository

GitHub Actions variables:

- `AWS_REGION`
- `TF_STATE_BUCKET` optional if you use `TF_BACKEND_CONFIG_CONTENT`
- `TF_STATE_KEY` optional
- `TF_STATE_REGION` optional
- `TF_LOCK_TABLE` optional legacy fallback if you still use DynamoDB locking
- `APP_IMAGE_REPOSITORY` optional if already present inside `TFVARS_CONTENT`
- `APP_IMAGE_TAG` optional, defaults to `latest`
- `DOCKERHUB_USERNAME` optional, needed for Docker image publishing or private image pulls

GitHub Actions secrets:

- `AWS_ROLE_TO_ASSUME`: IAM role assumed through OIDC
- `EC2_SSH_PRIVATE_KEY`: SSH private key used by Ansible
- `TFVARS_CONTENT`: full production content of `terraform.tfvars`
- `TF_BACKEND_CONFIG_CONTENT`: optional full content of `backend.hcl`
- `DOCKERHUB_TOKEN`: optional, needed for Docker image publishing or private image pulls

## Recommended CI/CD Split

The cleanest setup is still:

1. Build the Nest.js image from the application repository and push it to Docker Hub.
2. Deploy immutable image tags from this infra repository.
3. Keep infrastructure values in Terraform, and keep application secrets outside Terraform when possible.

A good deployment tag is the Git commit SHA, not `latest`.
