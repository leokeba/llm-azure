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

require_cmd az

if ! az account show >/dev/null 2>&1; then
  echo "Azure CLI is not authenticated. Run: az login" >&2
  exit 1
fi

AZ_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-rg-llm-azure}"
AZ_VM_NAME="${AZ_VM_NAME:-llm-ministral-vllm}"

if [[ -n "${AZ_SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "${AZ_SUBSCRIPTION_ID}" >/dev/null
fi

echo "Looking up VM: ${AZ_VM_NAME} in ${AZ_RESOURCE_GROUP}"
if ! az vm show --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" >/dev/null 2>&1; then
  echo "No VM found named ${AZ_VM_NAME} in ${AZ_RESOURCE_GROUP}. Nothing to destroy."
  exit 0
fi

NIC_IDS="$(az vm show --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" --query "networkProfile.networkInterfaces[].id" -o tsv)"
DISK_IDS="$(az vm show --resource-group "${AZ_RESOURCE_GROUP}" --name "${AZ_VM_NAME}" --query "storageProfile.osDisk.managedDisk.id" -o tsv)"

echo "Deleting VM ${AZ_VM_NAME}"
az vm delete \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --name "${AZ_VM_NAME}" \
  --yes >/dev/null

if [[ -n "${NIC_IDS}" ]]; then
  while IFS= read -r NIC_ID; do
    [[ -z "${NIC_ID}" ]] && continue
    PUBLIC_IP_IDS="$(az network nic show --ids "${NIC_ID}" --query "ipConfigurations[].publicIPAddress.id" -o tsv 2>/dev/null || true)"
    NSG_ID="$(az network nic show --ids "${NIC_ID}" --query "networkSecurityGroup.id" -o tsv 2>/dev/null || true)"

    az resource delete --ids "${NIC_ID}" >/dev/null 2>&1 || true

    if [[ -n "${PUBLIC_IP_IDS}" ]]; then
      while IFS= read -r PIP_ID; do
        [[ -z "${PIP_ID}" ]] && continue
        az resource delete --ids "${PIP_ID}" >/dev/null 2>&1 || true
      done <<< "${PUBLIC_IP_IDS}"
    fi

    if [[ -n "${NSG_ID}" ]]; then
      az resource delete --ids "${NSG_ID}" >/dev/null 2>&1 || true
    fi
  done <<< "${NIC_IDS}"
fi

if [[ -n "${DISK_IDS}" ]]; then
  while IFS= read -r DISK_ID; do
    [[ -z "${DISK_ID}" ]] && continue
    az resource delete --ids "${DISK_ID}" >/dev/null 2>&1 || true
  done <<< "${DISK_IDS}"
fi

echo "Destroyed ${AZ_VM_NAME} and attempted cleanup of attached NIC/public IP/NSG/disk resources."
