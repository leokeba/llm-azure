#!/usr/bin/env bash
set -euo pipefail

# Find region/SKU/image combinations that pass Azure VM preflight validation.
# This script never creates VMs; it only runs `az vm create --validate`.

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Usage: scripts/find-available-nvidia-vm.sh [options]

Options:
  --subscription <id-or-name>      Azure subscription to use.
  --resource-group <name>          Resource group for validation deployments.
                                   Default: rg-llm-azure-scan
  --resource-group-location <loc>  Resource group location (single region).
                                   Default: westeurope
  --regions <r1,r2,...>            Comma-separated regions to scan.
                                   Default: all regions returned by `az account list-locations`
  --images <img1,img2,...>         Comma-separated image aliases/URNs to test.
                                   Default tests multiple Linux + Windows images.
  --max-skus-per-region <n>        Limit candidate NVIDIA SKUs per region.
                                   Default: 40
  --max-success <n>                Stop after finding N successful combinations.
                                   Default: 30
  --log-dir <path>                 Directory for reports/logs.
                                   Default: ./scan-results
  --admin-username <name>          Admin username used for validation.
                                   Default: azureuser
  --ssh-public-key-path <path>     SSH public key for Linux image validation.
                                   Default: ~/.ssh/id_rsa.pub
  --allow-low-priority             Also test low-priority (spot) deployment model.
  --help                           Show this help.

Examples:
  scripts/find-available-nvidia-vm.sh --regions francecentral,centralus
  scripts/find-available-nvidia-vm.sh --subscription <SUB_ID> --max-success 10
EOF
}

subscription=""
resource_group="rg-llm-azure-scan"
resource_group_location="westeurope"
regions_csv=""
images_csv=""
max_skus_per_region=40
max_success=30
log_dir="scan-results"
admin_username="azureuser"
ssh_public_key_path="$HOME/.ssh/id_rsa.pub"
allow_low_priority="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)
      subscription="$2"
      shift 2
      ;;
    --resource-group)
      resource_group="$2"
      shift 2
      ;;
    --resource-group-location)
      resource_group_location="$2"
      shift 2
      ;;
    --regions)
      regions_csv="$2"
      shift 2
      ;;
    --images)
      images_csv="$2"
      shift 2
      ;;
    --max-skus-per-region)
      max_skus_per_region="$2"
      shift 2
      ;;
    --max-success)
      max_success="$2"
      shift 2
      ;;
    --log-dir)
      log_dir="$2"
      shift 2
      ;;
    --admin-username)
      admin_username="$2"
      shift 2
      ;;
    --ssh-public-key-path)
      ssh_public_key_path="$2"
      shift 2
      ;;
    --allow-low-priority)
      allow_low_priority="true"
      shift 1
      ;;
    --help)
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

require_cmd az
require_cmd python3
require_cmd mktemp

if ! az account show >/dev/null 2>&1; then
  echo "Azure CLI is not authenticated. Run: az login" >&2
  exit 1
fi

if [[ -n "$subscription" ]]; then
  az account set --subscription "$subscription" >/dev/null
fi

if [[ ! -f "$ssh_public_key_path" ]]; then
  first_pub_key="$(find "$HOME/.ssh" -maxdepth 1 -type f -name '*.pub' | head -n 1 || true)"
  if [[ -n "$first_pub_key" ]]; then
    ssh_public_key_path="$first_pub_key"
    echo "Using auto-detected SSH public key: $ssh_public_key_path"
  else
    echo "SSH public key not found at: $ssh_public_key_path" >&2
    echo "Provide a key with --ssh-public-key-path to validate Linux images." >&2
    exit 1
  fi
fi

mkdir -p "$log_dir"
report_tsv="$log_dir/nvidia-vm-scan-$(date +%Y%m%d-%H%M%S).tsv"
report_fail_tsv="$log_dir/nvidia-vm-scan-failures-$(date +%Y%m%d-%H%M%S).tsv"

printf "region\tsku\timage\tos\tpriority\tstatus\tmessage\n" > "$report_tsv"
printf "region\tsku\timage\tos\tpriority\treason\n" > "$report_fail_tsv"

if [[ -z "$images_csv" ]]; then
  # Intentionally broad set: Linux + Windows image aliases.
  images_csv="Ubuntu2204,Ubuntu2404,Debian12,RHELRaw8LVMGen2,AlmaLinux85,Win2022Datacenter"
fi

if [[ -z "$regions_csv" ]]; then
  regions=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    regions+=("$line")
  done < <(az account list-locations --query "[].name" -o tsv | sort)
else
  IFS=',' read -r -a regions <<< "$regions_csv"
fi

IFS=',' read -r -a images <<< "$images_csv"

random_password() {
  python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits + "!@#%^*-_"
print("A1!" + "".join(secrets.choice(alphabet) for _ in range(21)))
PY
}

windows_password="$(random_password)"

echo "Ensuring scan resource group exists: $resource_group ($resource_group_location)"
az group create --name "$resource_group" --location "$resource_group_location" >/dev/null

success_count=0
test_count=0

for region in "${regions[@]}"; do
  echo "--- Region: $region ---"

  sku_json_file="$(mktemp)"
  az vm list-skus \
    --location "$region" \
    --resource-type virtualMachines \
    --all \
    -o json > "$sku_json_file"

  sku_list_file="$(mktemp)"
  python3 - "$max_skus_per_region" "$sku_json_file" > "$sku_list_file" <<'PY'
import json
import re
import sys

limit = int(sys.argv[1])
path = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    items = json.load(f)

def is_nvidia(item):
    name = (item.get("name") or "")
    lname = name.lower()
    caps = item.get("capabilities") or []
    gpu_values = " ".join((c.get("value") or "") for c in caps if isinstance(c, dict)).lower()

    if "nvidia" in gpu_values:
      return True

    if re.search(r"^standard_(nc|nd)", lname):
      return True
    if "_a10_" in lname or "_a100_" in lname or "_h100_" in lname or "_h200_" in lname or "_t4_" in lname:
      return True
    if re.search(r"^standard_nv(\d+s?_v2|\d+s?_v3|\d+ads_a10_v5)", lname):
      return True

    return False

names = sorted({(item.get("name") or "") for item in items if isinstance(item, dict) and is_nvidia(item)})
for n in names[:limit]:
    print(n)
PY

  skus=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    skus+=("$line")
  done < "$sku_list_file"

  rm -f "$sku_json_file" "$sku_list_file"

  if [[ ${#skus[@]} -eq 0 ]]; then
    echo "No NVIDIA SKUs discovered in $region"
    continue
  fi

  for sku in "${skus[@]}"; do
    for image in "${images[@]}"; do
      os_type="linux"
      if [[ "$image" == Win* || "$image" == *Windows* || "$image" == *Datacenter* ]]; then
        os_type="windows"
      fi

      priorities=("regular")
      if [[ "$allow_low_priority" == "true" ]]; then
        priorities+=("spot")
      fi

      for priority in "${priorities[@]}"; do
        test_count=$((test_count + 1))
        validate_name="scan-${region//-/}-${sku//_/}-${RANDOM}"
        validate_log="$(mktemp)"

        args=(
          vm create
          --resource-group "$resource_group"
          --location "$region"
          --name "$validate_name"
          --image "$image"
          --size "$sku"
          --validate
          --only-show-errors
        )

        if [[ "$priority" == "spot" ]]; then
          args+=(--priority Spot --max-price -1)
        fi

        if [[ "$os_type" == "linux" ]]; then
          args+=(
            --admin-username "$admin_username"
            --authentication-type ssh
            --ssh-key-values "$ssh_public_key_path"
            --public-ip-address ""
          )
        else
          args+=(
            --admin-username "$admin_username"
            --admin-password "$windows_password"
            --public-ip-address ""
          )
        fi

        set +e
        az "${args[@]}" >"$validate_log" 2>&1
        rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
          echo "PASS: region=$region sku=$sku image=$image os=$os_type priority=$priority"
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$region" "$sku" "$image" "$os_type" "$priority" "pass" "validated" >> "$report_tsv"
          success_count=$((success_count + 1))
        else
          reason="$(rg -o "QuotaExceeded|SkuNotAvailable|OperationNotAllowed|AuthorizationFailed|InvalidParameter|Insufficient|NotAvailable" "$validate_log" 2>/dev/null | head -n 1 || true)"
          if [[ -z "$reason" ]]; then
            reason="validation_failed"
          fi
          printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$region" "$sku" "$image" "$os_type" "$priority" "$reason" >> "$report_fail_tsv"
        fi

        rm -f "$validate_log"

        if [[ $success_count -ge $max_success ]]; then
          echo "Reached max successes ($max_success), stopping early."
          break 4
        fi
      done
    done
  done
done

echo
echo "Scan complete."
echo "Total tests: $test_count"
echo "Successful combinations: $success_count"
echo "Success report: $report_tsv"
echo "Failure report: $report_fail_tsv"

echo
echo "Top successful combinations:"
if [[ $success_count -gt 0 ]]; then
  head -n 1 "$report_tsv"
  tail -n +2 "$report_tsv" | head -n 20
else
  echo "No successful combinations found."
fi
