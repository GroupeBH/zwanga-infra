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
APP_IMAGE_REPOSITORY="${APP_IMAGE_REPOSITORY:-}"
APP_IMAGE_TAG="${APP_IMAGE_TAG:-}"
APP_ENV_FILE="${APP_ENV_FILE:-}"
APP_HEALTHCHECK_PATH="${APP_HEALTHCHECK_PATH:-/health}"
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
TF_VARS_FILE="${TF_VARS_FILE:-${TF_DIR}/terraform.tfvars}"
TF_BACKEND_CONFIG_FILE="${TF_BACKEND_CONFIG_FILE:-${TF_DIR}/backend.hcl}"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-}"
TF_STATE_REGION="${TF_STATE_REGION:-}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-}"
SSH_RETRIES="${SSH_RETRIES:-30}"
SSH_RETRY_DELAY_SECONDS="${SSH_RETRY_DELAY_SECONDS:-10}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"

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
    [--app-image-repository <dockerhub-org/app>] \
    [--app-image-tag <tag>] \
    [--app-env-file <path_to_env_file>] \
    [--app-healthcheck-path </health>] \
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
  INSTANCE_TYPE, APP_IMAGE_REPOSITORY, APP_IMAGE_TAG, APP_ENV_FILE, APP_HEALTHCHECK_PATH, TF_VARS_FILE, TF_BACKEND_CONFIG_FILE,
  TF_STATE_BUCKET, TF_STATE_KEY, TF_STATE_REGION, TF_LOCK_TABLE, SSH_RETRIES,
  SSH_RETRY_DELAY_SECONDS, SSH_CONNECT_TIMEOUT
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
    --app-image-repository)
      APP_IMAGE_REPOSITORY="$2"
      shift 2
      ;;
    --app-image-tag)
      APP_IMAGE_TAG="$2"
      shift 2
      ;;
    --app-env-file)
      APP_ENV_FILE="$2"
      shift 2
      ;;
    --app-healthcheck-path)
      APP_HEALTHCHECK_PATH="$2"
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
  if [[ -z "${APP_IMAGE_REPOSITORY}" ]]; then
    missing_args+=("--app-image-repository")
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

if [[ -n "${APP_ENV_FILE}" ]]; then
  if [[ ! -f "${APP_ENV_FILE}" ]]; then
    echo "App env file not found: ${APP_ENV_FILE}" >&2
    exit 1
  fi
  APP_ENV_FILE="$(realpath "${APP_ENV_FILE}")"
fi

if [[ "${APP_HEALTHCHECK_PATH}" != /* ]]; then
  echo "App healthcheck path must start with /: ${APP_HEALTHCHECK_PATH}" >&2
  exit 1
fi

# If the AWS provider is already present locally, use it as a filesystem mirror
# to avoid flaky registry calls during repeated deploy runs.
TF_PROVIDER_MIRROR_DIR="${TF_DIR}/.terraform/providers"
shopt -s nullglob
aws_provider_binaries=("${TF_PROVIDER_MIRROR_DIR}"/registry.terraform.io/hashicorp/aws/*/*/terraform-provider-aws_*)
shopt -u nullglob
if (( ${#aws_provider_binaries[@]} > 0 )); then
  TF_CLI_CONFIG_FILE="$(mktemp)"
  cat > "${TF_CLI_CONFIG_FILE}" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${TF_PROVIDER_MIRROR_DIR}"
    include = ["registry.terraform.io/hashicorp/aws"]
  }
  direct {
    exclude = ["registry.terraform.io/hashicorp/aws"]
  }
}
EOF
  export TF_CLI_CONFIG_FILE
  trap 'rm -f "${TF_CLI_CONFIG_FILE}"' EXIT
fi

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
if [[ -n "${APP_IMAGE_REPOSITORY}" ]]; then
  TF_APPLY_ARGS+=(-var "app_image_repository=${APP_IMAGE_REPOSITORY}")
fi
if [[ -n "${APP_IMAGE_TAG}" ]]; then
  TF_APPLY_ARGS+=(-var "app_image_tag=${APP_IMAGE_TAG}")
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

terraform_output_snapshot() {
  local attempt=1
  local max_attempts=5
  local delay_seconds=3
  local output
  local status=0

  while (( attempt <= max_attempts )); do
    if output="$(terraform -chdir="${TF_DIR}" output -no-color 2>&1)"; then
      printf '%s\n' "${output}"
      return 0
    else
      status=$?
    fi

    if (( attempt == max_attempts )); then
      printf '%s\n' "${output}" >&2
      return "${status}"
    fi

    echo "terraform output failed (attempt ${attempt}/${max_attempts}); retrying in ${delay_seconds}s..." >&2
    sleep "${delay_seconds}"
    delay_seconds=$(( delay_seconds * 2 ))
    attempt=$(( attempt + 1 ))
  done
}

extract_tf_output() {
  local key="$1"
  local value

  value="$(printf '%s\n' "${TF_OUTPUTS}" | sed -n "s/^${key} = //p" | head -n 1)"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s' "${value}"
}

echo "==> Loading Terraform outputs"
TF_OUTPUTS="$(terraform_output_snapshot)"

PUBLIC_IP="$(extract_tf_output elastic_ip)"
APP_URL="$(extract_tf_output app_url)"
ADMIN_CIDR="$(extract_tf_output deploy_admin_cidr)"
APP_IMAGE_REPOSITORY="$(extract_tf_output deploy_app_image_repository)"
APP_IMAGE_TAG="$(extract_tf_output deploy_app_image_tag)"
DOMAIN="$(extract_tf_output deploy_domain_name)"
CADDY_EMAIL="$(extract_tf_output deploy_caddy_email)"

if [[ -z "${ADMIN_CIDR}" || -z "${APP_IMAGE_REPOSITORY}" ]]; then
  echo "app_image_repository and admin_cidr must be provided either via tfvars or CLI/environment overrides." >&2
  exit 1
fi

echo "==> Rendering Ansible inventory"
cat > "${ANSIBLE_DIR}/inventory.ini" <<EOF
[app]
${PUBLIC_IP} ansible_user=ubuntu ansible_ssh_private_key_file=${PRIVATE_KEY_PATH} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[app:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

echo "==> Waiting for SSH"
last_ssh_error=""
for ((i=1; i<=SSH_RETRIES; i++)); do
  if last_ssh_error="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -i "${PRIVATE_KEY_PATH}" "ubuntu@${PUBLIC_IP}" "echo ok" 2>&1 >/dev/null)"; then
    last_ssh_error=""
    break
  fi

  if (( i == SSH_RETRIES )); then
    echo "SSH not reachable after ${SSH_RETRIES} attempts." >&2
    if [[ -n "${last_ssh_error}" ]]; then
      echo "Last SSH error: ${last_ssh_error}" >&2
    fi
    echo "Target IP: ${PUBLIC_IP}" >&2
    echo "Configured admin CIDR: ${ADMIN_CIDR}" >&2
    echo "Private key path: ${PRIVATE_KEY_PATH}" >&2
    echo "Check that your current public IP still matches the configured admin CIDR and that this private key matches the EC2 key pair." >&2
    exit 1
  fi

  echo "SSH not ready yet (attempt ${i}/${SSH_RETRIES}); retrying in ${SSH_RETRY_DELAY_SECONDS}s..." >&2
  sleep "${SSH_RETRY_DELAY_SECONDS}"
done

echo "==> Running Ansible playbook"
EXTRA_VARS=(
  "admin_cidr=${ADMIN_CIDR}"
  "app_image_repository=${APP_IMAGE_REPOSITORY}"
  "app_image_tag=${APP_IMAGE_TAG}"
)
if [[ -n "${DOMAIN}" ]]; then
  EXTRA_VARS+=("domain=${DOMAIN}")
fi
if [[ -n "${CADDY_EMAIL}" ]]; then
  EXTRA_VARS+=("caddy_email=${CADDY_EMAIL}")
fi
if [[ -n "${APP_ENV_FILE}" ]]; then
  EXTRA_VARS+=("app_env_file=${APP_ENV_FILE}")
fi
EXTRA_VARS+=("app_healthcheck_path=${APP_HEALTHCHECK_PATH}")

ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "${ANSIBLE_DIR}/inventory.ini" "${ANSIBLE_DIR}/playbook.yml" \
  --extra-vars "${EXTRA_VARS[*]}"

echo "==> Deployment complete"
echo "App URL: ${APP_URL}"
echo "Health: ${APP_URL}/health"