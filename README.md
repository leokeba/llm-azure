# llm-azure

Run `mistralai/Ministral-3-8B-Instruct-2512` with `vLLM` on an Azure GPU VM.

This repo includes:
- `docker-compose.yml` for vLLM runtime
- `.env.example` for model/runtime/deploy variables
- `scripts/deploy-azure.sh` to provision + deploy using Azure CLI
- `scripts/redeploy-azure.sh` to update container config/image on an existing VM
- `scripts/destroy-azure.sh` to delete the GPU VM (and attached resources)

## Prerequisites

- Azure subscription with GPU quota in your target region
- `az` CLI installed and authenticated (`az login`)
- Local tools: `bash`, `ssh`, `scp`, `python3`
- SSH key available locally

## Quick start

1. Copy environment file:

```bash
cp .env.example .env
```

2. Edit `.env` (at least verify these):
	- `AZ_RESOURCE_GROUP` (example: `rg-llm-azure`)
	- `AZ_LOCATION` (example: `westeurope`)
	- `AZ_VM_NAME`
	- `AZ_VM_SIZE` (default: `Standard_NC4as_T4_v3`)
	- `AZ_VM_IMAGE` (default: `Ubuntu2204`)
	- `AZ_ATTACH_PUBLIC_IP` (`true` for bootstrap over public SSH)
	- `AZ_SSH_PUBLIC_KEY_PATH`
	- `AZ_SSH_PRIVATE_KEY_PATH` (optional)
	- `VLLM_ALLOWED_CIDRS` (comma-separated source CIDRs allowed to call API)
	- `VLLM_READY_TIMEOUT_SEC` (max wait before deploy fails if `/v1/models` is not ready)
	- `HUGGING_FACE_HUB_TOKEN` (if model access requires it)

3. Run deployment:

```bash
chmod +x scripts/deploy-azure.sh
./scripts/deploy-azure.sh
```

The script will:
- create the GPU VM only if it does not already exist
- install NVIDIA driver extension on the VM
- wait for SSH readiness and prepare Docker + NVIDIA container toolkit remotely
- upload `docker-compose.yml` + generated env
- start `vllm/vllm-openai` as a detached container
- apply optional CIDR allowlist firewall on the VM for `VLLM_PORT`
- wait for `/v1/models` readiness

If a VM with `AZ_VM_NAME` already exists, deployment stops with an error (to prevent deploying the same instance twice).

## Redeploy in place

To update runtime config/model/image without destroying the VM:

```bash
chmod +x scripts/redeploy-azure.sh
./scripts/redeploy-azure.sh
```

This script requires an existing VM with `AZ_VM_NAME` and will only:
- upload `docker-compose.yml` and runtime `.env`
- run `docker compose pull`
- run `docker compose up -d`
- wait for `/v1/models` readiness

## Access control

You can restrict who can call the vLLM API with `.env`:

```bash
VLLM_BIND_IP=0.0.0.0
VLLM_ALLOWED_CIDRS=163.172.162.19/32
```

- `VLLM_ALLOWED_CIDRS` is a comma-separated CIDR allowlist applied on the VM firewall for `VLLM_PORT`.
- `/32` means one exact source IP.
- Keep it empty only if you intentionally want open access.

## Test endpoint

After deploy, test OpenAI-compatible API:

```bash
curl http://<VM_PUBLIC_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-8b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain KV cache like I am 10."}
    ],
    "temperature": 0.3
  }'
```

## Runtime tuning

Configured defaults are production-leaning:
- `GPU_MEMORY_UTILIZATION=0.90`
- `MAX_MODEL_LEN=8192`
- `MAX_NUM_SEQS=24`

If you see OOM under load, lower:
- `GPU_MEMORY_UTILIZATION` to `0.85`
- `MAX_MODEL_LEN` to `4096`

## Notes

- This repo targets the Azure GPU VM approach from the shared discussion.
- `AZ_VM_SIZE` must be available in your subscription quota/region.
- All runtime/deploy values are sourced from `.env`.

## Destroy instance

To tear down the GPU VM and cleanup attached resources:

```bash
chmod +x scripts/destroy-azure.sh
./scripts/destroy-azure.sh
```