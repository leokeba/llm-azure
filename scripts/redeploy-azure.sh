#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

expand_home_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    ~/*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

require_cmd az
require_cmd ssh
require_cmd scp
require_cmd ssh-keygen

if ! az account show >/dev/null 2>&1; then
  echo "Azure CLI is not authenticated. Run: az login" >&2
  exit 1
fi

AZ_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-rg-llm-azure}"
AZ_VM_NAME="${AZ_VM_NAME:-llm-ministral-vllm}"
AZ_ADMIN_USERNAME="${AZ_ADMIN_USERNAME:-ubuntu}"
AZ_SSH_PRIVATE_KEY_PATH="${AZ_SSH_PRIVATE_KEY_PATH:-}"

AZ_SSH_PRIVATE_KEY_PATH="$(expand_home_path "${AZ_SSH_PRIVATE_KEY_PATH}")"

VLLM_BASE_IMAGE="${VLLM_BASE_IMAGE:-vllm/vllm-openai:latest}"
MODEL_ID="${MODEL_ID:-mistralai/Ministral-3-8B-Instruct-2512}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-ministral-8b}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_BIND_IP="${VLLM_BIND_IP:-0.0.0.0}"
VLLM_ALLOWED_CIDRS="${VLLM_ALLOWED_CIDRS:-}"
VLLM_DTYPE="${VLLM_DTYPE:-float16}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-24}"
VLLM_READY_TIMEOUT_SEC="${VLLM_READY_TIMEOUT_SEC:-900}"
HF_CACHE_DIR="${HF_CACHE_DIR:-/data/models}"
HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-}"

if [[ -n "${AZ_SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "${AZ_SUBSCRIPTION_ID}" >/dev/null
fi

if ! az vm show --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" >/dev/null 2>&1; then
  echo "No VM found named ${AZ_VM_NAME} in ${AZ_RESOURCE_GROUP}." >&2
  echo "Use scripts/deploy-azure.sh for first deployment." >&2
  exit 1
fi

POWER_STATE="$(az vm get-instance-view --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv)"
if [[ "${POWER_STATE}" != "VM running" ]]; then
  echo "VM state is ${POWER_STATE}, powering on"
  az vm start --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" >/dev/null
fi

SERVER_IP="$(az vm show -d --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" --query publicIps -o tsv)"
if [[ -z "${SERVER_IP}" ]]; then
  echo "Could not resolve VM public IP." >&2
  exit 1
fi

SSH_BASE_ARGS=( -o StrictHostKeyChecking=accept-new )
SCP_BASE_ARGS=( -o StrictHostKeyChecking=accept-new )
if [[ -n "${AZ_SSH_PRIVATE_KEY_PATH}" ]]; then
  if [[ ! -f "${AZ_SSH_PRIVATE_KEY_PATH}" ]]; then
    echo "Configured AZ_SSH_PRIVATE_KEY_PATH does not exist: ${AZ_SSH_PRIVATE_KEY_PATH}" >&2
    exit 1
  fi
  SSH_BASE_ARGS+=( -i "${AZ_SSH_PRIVATE_KEY_PATH}" )
  SCP_BASE_ARGS+=( -i "${AZ_SSH_PRIVATE_KEY_PATH}" )
fi

echo "Server IP: ${SERVER_IP}"
echo "Refreshing SSH host key for ${SERVER_IP}"
ssh-keygen -R "${SERVER_IP}" >/dev/null 2>&1 || true

echo "Waiting for SSH to become reachable"
for _ in {1..60}; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_BASE_ARGS[@]}" "${AZ_ADMIN_USERNAME}@${SERVER_IP}" 'echo SSH_OK' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_BASE_ARGS[@]}" "${AZ_ADMIN_USERNAME}@${SERVER_IP}" 'echo SSH_OK' >/dev/null 2>&1; then
  echo "SSH is not reachable for ${AZ_ADMIN_USERNAME}@${SERVER_IP}." >&2
  exit 1
fi

echo "Preparing runtime env file"
TMP_ENV_FILE="$(mktemp)"
cat > "${TMP_ENV_FILE}" <<EOF
VLLM_BASE_IMAGE=${VLLM_BASE_IMAGE}
MODEL_ID=${MODEL_ID}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME}
VLLM_PORT=${VLLM_PORT}
VLLM_BIND_IP=${VLLM_BIND_IP}
VLLM_ALLOWED_CIDRS=${VLLM_ALLOWED_CIDRS}
VLLM_DTYPE=${VLLM_DTYPE}
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}
MAX_MODEL_LEN=${MAX_MODEL_LEN}
MAX_NUM_SEQS=${MAX_NUM_SEQS}
VLLM_READY_TIMEOUT_SEC=${VLLM_READY_TIMEOUT_SEC}
HF_CACHE_DIR=${HF_CACHE_DIR}
HUGGING_FACE_HUB_TOKEN=${HUGGING_FACE_HUB_TOKEN}
EOF

echo "Uploading compose and env files"
scp "${SCP_BASE_ARGS[@]}" docker-compose.yml "${AZ_ADMIN_USERNAME}@${SERVER_IP}:/opt/llm-azure/docker-compose.yml"
scp "${SCP_BASE_ARGS[@]}" "${TMP_ENV_FILE}" "${AZ_ADMIN_USERNAME}@${SERVER_IP}:/opt/llm-azure/.env"
rm -f "${TMP_ENV_FILE}"

echo "Restarting vLLM container in place"
ssh "${SSH_BASE_ARGS[@]}" "${AZ_ADMIN_USERNAME}@${SERVER_IP}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd /opt/llm-azure
mkdir -p /data/models
set -a
source .env
set +a

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found on host. This VM size may not expose NVIDIA GPUs required by vLLM CUDA." >&2
  echo "Use an NVIDIA-backed SKU (for example NCASv3_T4, NCSv3, or A10/A100 families with quota)." >&2
  exit 1
fi

docker compose --env-file .env pull
docker compose --env-file .env up -d

apply_vllm_allowlist() {
  local port="${VLLM_PORT:-8000}"
  local allowlist="${VLLM_ALLOWED_CIDRS:-}"

  if [[ -z "${allowlist// }" ]]; then
    sudo iptables -D INPUT -p tcp --dport "${port}" -j VLLM_ALLOWLIST 2>/dev/null || true
    sudo iptables -F VLLM_ALLOWLIST 2>/dev/null || true
    echo "No VLLM_ALLOWED_CIDRS configured; port ${port} remains open."
    return 0
  fi

  sudo iptables -N VLLM_ALLOWLIST 2>/dev/null || true
  sudo iptables -F VLLM_ALLOWLIST
  sudo iptables -A VLLM_ALLOWLIST -s 127.0.0.1/32 -j ACCEPT

  IFS=',' read -r -a cidrs <<< "${allowlist}"
  local cidr
  local clean_cidr
  for cidr in "${cidrs[@]}"; do
    clean_cidr="$(echo "${cidr}" | xargs)"
    [[ -z "${clean_cidr}" ]] && continue
    sudo iptables -A VLLM_ALLOWLIST -s "${clean_cidr}" -j ACCEPT
  done

  sudo iptables -A VLLM_ALLOWLIST -j DROP
  sudo iptables -C INPUT -p tcp --dport "${port}" -j VLLM_ALLOWLIST 2>/dev/null || sudo iptables -I INPUT -p tcp --dport "${port}" -j VLLM_ALLOWLIST
  echo "Applied VLLM allowlist on port ${port}: ${allowlist}"
}

apply_vllm_allowlist

wait_for_vllm_ready() {
  local timeout_sec="${VLLM_READY_TIMEOUT_SEC:-900}"
  local interval_sec=5
  local elapsed=0

  while (( elapsed < timeout_sec )); do
    if curl -fsS -m 4 "http://127.0.0.1:${VLLM_PORT:-8000}/v1/models" >/dev/null 2>&1; then
      echo "vLLM API is ready on /v1/models"
      return 0
    fi
    sleep "${interval_sec}"
    elapsed=$((elapsed + interval_sec))
  done

  echo "vLLM did not become ready within ${timeout_sec}s." >&2
  docker logs --tail 120 vllm-ministral >&2 || true
  return 1
}

wait_for_vllm_ready
REMOTE

echo
echo "Redeploy complete."
echo "OpenAI-compatible endpoint: http://${SERVER_IP}:${VLLM_PORT}/v1"
echo "Test with:"
echo "curl http://${SERVER_IP}:${VLLM_PORT}/v1/models"
