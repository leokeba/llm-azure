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
require_cmd python3
require_cmd ssh-keygen

if ! az account show >/dev/null 2>&1; then
  echo "Azure CLI is not authenticated. Run: az login" >&2
  exit 1
fi

AZ_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-rg-llm-azure}"
AZ_LOCATION="${AZ_LOCATION:-westeurope}"
AZ_VM_NAME="${AZ_VM_NAME:-llm-ministral-vllm}"
AZ_VM_SIZE="${AZ_VM_SIZE:-Standard_NC4as_T4_v3}"
AZ_VM_IMAGE="${AZ_VM_IMAGE:-Ubuntu2204}"
AZ_OS_DISK_SIZE_GB="${AZ_OS_DISK_SIZE_GB:-80}"
AZ_ADMIN_USERNAME="${AZ_ADMIN_USERNAME:-ubuntu}"
AZ_ATTACH_PUBLIC_IP="${AZ_ATTACH_PUBLIC_IP:-true}"
AZ_PUBLIC_IP_SKU="${AZ_PUBLIC_IP_SKU:-Standard}"
AZ_SSH_PUBLIC_KEY_PATH="${AZ_SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
AZ_SSH_PRIVATE_KEY_PATH="${AZ_SSH_PRIVATE_KEY_PATH:-}"

AZ_SSH_PUBLIC_KEY_PATH="$(expand_home_path "${AZ_SSH_PUBLIC_KEY_PATH}")"
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

if [[ "${AZ_ATTACH_PUBLIC_IP}" != "true" && "${AZ_ATTACH_PUBLIC_IP}" != "false" ]]; then
  echo "AZ_ATTACH_PUBLIC_IP must be either true or false" >&2
  exit 1
fi

if [[ ! -f "${AZ_SSH_PUBLIC_KEY_PATH}" ]]; then
  echo "Configured AZ_SSH_PUBLIC_KEY_PATH does not exist: ${AZ_SSH_PUBLIC_KEY_PATH}" >&2
  exit 1
fi

if [[ -n "${AZ_SSH_PRIVATE_KEY_PATH}" && ! -f "${AZ_SSH_PRIVATE_KEY_PATH}" ]]; then
  echo "Configured AZ_SSH_PRIVATE_KEY_PATH does not exist: ${AZ_SSH_PRIVATE_KEY_PATH}" >&2
  exit 1
fi

echo "Checking if VM exists: ${AZ_VM_NAME}"
if az vm show --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" >/dev/null 2>&1; then
  echo "VM already exists (${AZ_VM_NAME})." >&2
  echo "Refusing to deploy twice. Use scripts/redeploy-azure.sh or change AZ_VM_NAME." >&2
  exit 1
fi

echo "Ensuring resource group exists: ${AZ_RESOURCE_GROUP}"
az group create --name "${AZ_RESOURCE_GROUP}" --location "${AZ_LOCATION}" >/dev/null

echo "Validating VM configuration (quota/capacity preflight)"
VALIDATE_LOG_FILE="$(mktemp)"
set +e
az vm create \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --location "${AZ_LOCATION}" \
  --name "validate-${AZ_VM_NAME}" \
  --image "${AZ_VM_IMAGE}" \
  --size "${AZ_VM_SIZE}" \
  --admin-username "${AZ_ADMIN_USERNAME}" \
  --ssh-key-values "${AZ_SSH_PUBLIC_KEY_PATH}" \
  --public-ip-address "" \
  --validate >"${VALIDATE_LOG_FILE}" 2>&1
VALIDATE_EXIT_CODE=$?
set -e

if [[ ${VALIDATE_EXIT_CODE} -ne 0 ]]; then
  if command -v rg >/dev/null 2>&1; then
    rg -n "QuotaExceeded|SkuNotAvailable|not available|Total Regional Cores|InvalidParameter" "${VALIDATE_LOG_FILE}" || cat "${VALIDATE_LOG_FILE}"
  else
    cat "${VALIDATE_LOG_FILE}"
  fi
  rm -f "${VALIDATE_LOG_FILE}"
  echo "VM preflight validation failed. Update AZ_LOCATION/AZ_VM_SIZE or request quota increase, then retry." >&2
  exit 1
fi

rm -f "${VALIDATE_LOG_FILE}"

VM_CREATE_ARGS=(
  --resource-group "${AZ_RESOURCE_GROUP}"
  --location "${AZ_LOCATION}"
  --name "${AZ_VM_NAME}"
  --image "${AZ_VM_IMAGE}"
  --size "${AZ_VM_SIZE}"
  --admin-username "${AZ_ADMIN_USERNAME}"
  --ssh-key-values "${AZ_SSH_PUBLIC_KEY_PATH}"
  --os-disk-size-gb "${AZ_OS_DISK_SIZE_GB}"
  --nsg-rule SSH
  --public-ip-sku "${AZ_PUBLIC_IP_SKU}"
)

if [[ "${AZ_ATTACH_PUBLIC_IP}" == "false" ]]; then
  VM_CREATE_ARGS+=(--public-ip-address "")
fi

echo "Creating new VM ${AZ_VM_NAME} (${AZ_VM_SIZE}) in ${AZ_LOCATION}"
az vm create "${VM_CREATE_ARGS[@]}" >/dev/null

if [[ "${AZ_ATTACH_PUBLIC_IP}" == "true" ]]; then
  echo "Opening inbound port ${VLLM_PORT} on VM NSG"
  az vm open-port \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --name "${AZ_VM_NAME}" \
    --port "${VLLM_PORT}" \
    --priority 1001 >/dev/null
fi

echo "Installing NVIDIA GPU driver extension"
az vm extension set \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --vm-name "${AZ_VM_NAME}" \
  --publisher Microsoft.HpcCompute \
  --name NvidiaGpuDriverLinux >/dev/null

SERVER_IP="$(az vm show -d --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" --query publicIps -o tsv)"
if [[ "${AZ_ATTACH_PUBLIC_IP}" == "true" && -z "${SERVER_IP}" ]]; then
  echo "Could not resolve VM public IP." >&2
  exit 1
fi

SSH_BASE_ARGS=( -o StrictHostKeyChecking=accept-new )
SCP_BASE_ARGS=( -o StrictHostKeyChecking=accept-new )
if [[ -n "${AZ_SSH_PRIVATE_KEY_PATH}" ]]; then
  SSH_BASE_ARGS+=( -i "${AZ_SSH_PRIVATE_KEY_PATH}" )
  SCP_BASE_ARGS+=( -i "${AZ_SSH_PRIVATE_KEY_PATH}" )
fi

if [[ "${AZ_ATTACH_PUBLIC_IP}" == "false" ]]; then
  echo "VM created without public IP. Use your private network path to continue bootstrap." >&2
  echo "Set AZ_ATTACH_PUBLIC_IP=true for scripted bootstrap." >&2
  exit 1
fi

echo "Server IP: ${SERVER_IP}"
echo "Refreshing SSH host key for ${SERVER_IP}"
ssh-keygen -R "${SERVER_IP}" >/dev/null 2>&1 || true

echo "Waiting for SSH to become reachable"
for _ in {1..80}; do
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

echo "Installing Docker + NVIDIA runtime on remote host"
ssh "${SSH_BASE_ARGS[@]}" "${AZ_ADMIN_USERNAME}@${SERVER_IP}" 'bash -s' <<'REMOTE'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
fi

. /etc/os-release
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit iptables

if command -v nvidia-ctk >/dev/null 2>&1; then
  sudo nvidia-ctk runtime configure --runtime=docker || true
  sudo systemctl restart docker || true
fi

sudo usermod -aG docker "$USER" || true
sudo mkdir -p /opt/llm-azure /data/models
sudo chown -R "$USER":"$USER" /opt/llm-azure /data/models
REMOTE

echo "Uploading compose and env files"
scp "${SCP_BASE_ARGS[@]}" docker-compose.yml "${AZ_ADMIN_USERNAME}@${SERVER_IP}:/opt/llm-azure/docker-compose.yml"
scp "${SCP_BASE_ARGS[@]}" "${TMP_ENV_FILE}" "${AZ_ADMIN_USERNAME}@${SERVER_IP}:/opt/llm-azure/.env"
rm -f "${TMP_ENV_FILE}"

echo "Starting vLLM container"
ssh "${SSH_BASE_ARGS[@]}" "${AZ_ADMIN_USERNAME}@${SERVER_IP}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd /opt/llm-azure
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
echo "Deployment complete."
echo "OpenAI-compatible endpoint: http://${SERVER_IP}:${VLLM_PORT}/v1"
echo "Test with:"
echo "curl http://${SERVER_IP}:${VLLM_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${SERVED_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
