#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
ANSIBLE_DIR="${ROOT_DIR}/ansible"

AWS_REGION="${AWS_REGION:-}"
KEY_NAME="${KEY_NAME:-}"
PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-}"
ADMIN_CIDR="${ADMIN_CIDR:-}"
DOMAIN="${DOMAIN:-}"
CADDY_EMAIL="${CADDY_EMAIL:-}"
INSTANCE_NAME="${INSTANCE_NAME:-}"
BACKEND_REPO="${BACKEND_REPO:-}"
BACKEND_REF="${BACKEND_REF:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
TF_VARS_FILE="${TF_VARS_FILE:-${TF_DIR}/terraform.tfvars}"
TF_BACKEND_CONFIG_FILE="${TF_BACKEND_CONFIG_FILE:-${TF_DIR}/backend.hcl}"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-}"
TF_STATE_REGION="${TF_STATE_REGION:-}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-}"

usage() {
  cat <<EOF
Usage:
  ./deploy.sh \
    --private-key <path_to_private_key.pem> \
    [--aws-region <region>] \
    [--key-name <aws_key_pair_name>] \
    [--admin-cidr <your_public_ip/32>] \
    [--domain <api.example.com>] \
    [--email <ops@example.com>] \
    [--instance-name <name>] \
    [--instance-type <t3.micro>] \
    [--backend-repo <https://github.com/org/repo.git>] \
    [--backend-ref <branch_or_tag_or_commit>] \
    [--tfvars <path_to_terraform.tfvars>] \
    [--tf-backend-config <path_to_backend.hcl>] \
    [--tf-state-bucket <s3_bucket>] \
    [--tf-state-key <state_key>] \
    [--tf-state-region <region>] \
    [--tf-lock-table <dynamodb_table>]

terraform/terraform.tfvars is loaded automatically when present.
terraform/backend.hcl is loaded automatically when present.
CLI arguments or environment variables override values from those files.

Environment variable alternatives are also supported:
  AWS_REGION, KEY_NAME, PRIVATE_KEY_PATH, ADMIN_CIDR, DOMAIN, CADDY_EMAIL, INSTANCE_NAME,
  INSTANCE_TYPE, BACKEND_REPO, BACKEND_REF, TF_VARS_FILE, TF_BACKEND_CONFIG_FILE,
  TF_STATE_BUCKET, TF_STATE_KEY, TF_STATE_REGION, TF_LOCK_TABLE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-region)
      AWS_REGION="$2"
      shift 2
      ;;
    --key-name)
      KEY_NAME="$2"
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY_PATH="$2"
      shift 2
      ;;
    --admin-cidr)
      ADMIN_CIDR="$2"
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --email)
      CADDY_EMAIL="$2"
      shift 2
      ;;
    --instance-name)
      INSTANCE_NAME="$2"
      shift 2
      ;;
    --instance-type)
      INSTANCE_TYPE="$2"
      shift 2
      ;;
    --backend-repo)
      BACKEND_REPO="$2"
      shift 2
      ;;
    --backend-ref)
      BACKEND_REF="$2"
      shift 2
      ;;
    --tfvars)
      TF_VARS_FILE="$2"
      shift 2
      ;;
    --tf-backend-config)
      TF_BACKEND_CONFIG_FILE="$2"
      shift 2
      ;;
    --tf-state-bucket)
      TF_STATE_BUCKET="$2"
      shift 2
      ;;
    --tf-state-key)
      TF_STATE_KEY="$2"
      shift 2
      ;;
    --tf-state-region)
      TF_STATE_REGION="$2"
      shift 2
      ;;
    --tf-lock-table)
      TF_LOCK_TABLE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${PRIVATE_KEY_PATH}" ]]; then
  echo "--private-key (or PRIVATE_KEY_PATH) is required." >&2
  usage
  exit 1
fi

HAS_BACKEND_FILE=0
if [[ -f "${TF_BACKEND_CONFIG_FILE}" ]]; then
  HAS_BACKEND_FILE=1
fi

if [[ "${HAS_BACKEND_FILE}" -eq 0 && -z "${TF_STATE_BUCKET}" ]]; then
  echo "Provide either terraform/backend.hcl (or --tf-backend-config) or --tf-state-bucket for the Terraform S3 backend." >&2
  usage
  exit 1
fi

if [[ ! -f "${TF_VARS_FILE}" ]]; then
  missing_args=()
  if [[ -z "${KEY_NAME}" ]]; then
    missing_args+=("--key-name")
  fi
  if [[ -z "${ADMIN_CIDR}" ]]; then
    missing_args+=("--admin-cidr")
  fi
  if [[ -z "${BACKEND_REPO}" ]]; then
    missing_args+=("--backend-repo")
  fi

  if (( ${#missing_args[@]} > 0 )); then
    echo "Missing required inputs without tfvars: ${missing_args[*]}" >&2
    usage
    exit 1
  fi
fi

if [[ ! -f "${PRIVATE_KEY_PATH}" ]]; then
  echo "Private key not found: ${PRIVATE_KEY_PATH}" >&2
  exit 1
fi

for bin in terraform ansible-playbook ssh; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "Missing required command: ${bin}" >&2
    exit 1
  fi
done

PRIVATE_KEY_PATH="$(realpath "${PRIVATE_KEY_PATH}")"

DEFAULT_TF_STATE_KEY="zwanga/terraform.tfstate"
DEFAULT_TF_STATE_REGION="${AWS_REGION:-us-east-1}"
if [[ "${HAS_BACKEND_FILE}" -eq 0 ]]; then
  TF_STATE_KEY="${TF_STATE_KEY:-${DEFAULT_TF_STATE_KEY}}"
  TF_STATE_REGION="${TF_STATE_REGION:-${DEFAULT_TF_STATE_REGION}}"
fi

TF_APPLY_ARGS=(-auto-approve)
if [[ -f "${TF_VARS_FILE}" ]]; then
  TF_APPLY_ARGS+=(-var-file="${TF_VARS_FILE}")
fi

if [[ -n "${AWS_REGION}" ]]; then
  TF_APPLY_ARGS+=(-var "aws_region=${AWS_REGION}")
fi
if [[ -n "${KEY_NAME}" ]]; then
  TF_APPLY_ARGS+=(-var "key_name=${KEY_NAME}")
fi
if [[ -n "${ADMIN_CIDR}" ]]; then
  TF_APPLY_ARGS+=(-var "admin_cidr=${ADMIN_CIDR}")
fi
if [[ -n "${INSTANCE_NAME}" ]]; then
  TF_APPLY_ARGS+=(-var "instance_name=${INSTANCE_NAME}")
fi
if [[ -n "${INSTANCE_TYPE}" ]]; then
  TF_APPLY_ARGS+=(-var "instance_type=${INSTANCE_TYPE}")
fi
if [[ -n "${DOMAIN}" ]]; then
  TF_APPLY_ARGS+=(-var "domain_name=${DOMAIN}")
fi
if [[ -n "${CADDY_EMAIL}" ]]; then
  TF_APPLY_ARGS+=(-var "caddy_email=${CADDY_EMAIL}")
fi
if [[ -n "${BACKEND_REPO}" ]]; then
  TF_APPLY_ARGS+=(-var "backend_repo=${BACKEND_REPO}")
fi
if [[ -n "${BACKEND_REF}" ]]; then
  TF_APPLY_ARGS+=(-var "backend_ref=${BACKEND_REF}")
fi

echo "==> Terraform init"
INIT_ARGS=(
  -reconfigure
)

if [[ "${HAS_BACKEND_FILE}" -eq 1 ]]; then
  INIT_ARGS+=("-backend-config=${TF_BACKEND_CONFIG_FILE}")
fi
if [[ -n "${TF_STATE_BUCKET}" ]]; then
  INIT_ARGS+=("-backend-config=bucket=${TF_STATE_BUCKET}")
fi
if [[ -n "${TF_STATE_KEY}" ]]; then
  INIT_ARGS+=("-backend-config=key=${TF_STATE_KEY}")
fi
if [[ -n "${TF_STATE_REGION}" ]]; then
  INIT_ARGS+=("-backend-config=region=${TF_STATE_REGION}")
fi
INIT_ARGS+=("-backend-config=encrypt=true")
if [[ -n "${TF_LOCK_TABLE}" ]]; then
  INIT_ARGS+=("-backend-config=dynamodb_table=${TF_LOCK_TABLE}")
fi

terraform -chdir="${TF_DIR}" init "${INIT_ARGS[@]}"

echo "==> Terraform apply"
terraform -chdir="${TF_DIR}" apply "${TF_APPLY_ARGS[@]}"

PUBLIC_IP="$(terraform -chdir="${TF_DIR}" output -raw elastic_ip)"
APP_URL="$(terraform -chdir="${TF_DIR}" output -raw app_url)"
ADMIN_CIDR="$(terraform -chdir="${TF_DIR}" output -raw deploy_admin_cidr)"
BACKEND_REPO="$(terraform -chdir="${TF_DIR}" output -raw deploy_backend_repo)"
BACKEND_REF="$(terraform -chdir="${TF_DIR}" output -raw deploy_backend_ref)"
DOMAIN="$(terraform -chdir="${TF_DIR}" output -raw deploy_domain_name)"
CADDY_EMAIL="$(terraform -chdir="${TF_DIR}" output -raw deploy_caddy_email)"

if [[ -z "${ADMIN_CIDR}" || -z "${BACKEND_REPO}" ]]; then
  echo "backend_repo and admin_cidr must be provided either via tfvars or CLI/environment overrides." >&2
  exit 1
fi

echo "==> Rendering Ansible inventory"
cat > "${ANSIBLE_DIR}/inventory.ini" <<EOF
[app]
${PUBLIC_IP} ansible_user=ubuntu ansible_ssh_private_key_file=${PRIVATE_KEY_PATH}

[app:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

echo "==> Waiting for SSH"
for i in {1..30}; do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i "${PRIVATE_KEY_PATH}" "ubuntu@${PUBLIC_IP}" "echo ok" >/dev/null 2>&1; then
    break
  fi

  if [[ "${i}" -eq 30 ]]; then
    echo "SSH not reachable after multiple retries." >&2
    exit 1
  fi

  sleep 10
done

echo "==> Running Ansible playbook"
EXTRA_VARS=(
  "admin_cidr=${ADMIN_CIDR}"
  "backend_repo=${BACKEND_REPO}"
  "backend_ref=${BACKEND_REF}"
)
if [[ -n "${DOMAIN}" ]]; then
  EXTRA_VARS+=("domain=${DOMAIN}")
fi
if [[ -n "${CADDY_EMAIL}" ]]; then
  EXTRA_VARS+=("caddy_email=${CADDY_EMAIL}")
fi

ansible-playbook -i "${ANSIBLE_DIR}/inventory.ini" "${ANSIBLE_DIR}/playbook.yml" \
  --extra-vars "${EXTRA_VARS[*]}"

echo "==> Deployment complete"
echo "App URL: ${APP_URL}"
echo "Health: ${APP_URL}/health"