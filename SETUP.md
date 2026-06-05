# z620-a4000-srv — first-time deploy

Ordered, copy-pasteable procedure to bring the box up from "Ubuntu freshly
installed, NVIDIA driver installed" to "stack serving requests."

Two parts:
- **Part A — pre-Docker host prep** (storage, hostname, kernel, user).
- **Part B — Docker stack** (compose, models, gateway, health).

## Part A — host prep

### A1. Preflight checks

```bash
# Identify the GPU. Must show "RTX A4000" with 16 GB.
nvidia-smi -L
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv

# Confirm CUDA toolkit (only needed if you run host-side Python; container
# inference does NOT need CUDA installed on the host — only the driver +
# nvidia-container-toolkit).
nvcc --version || echo "(host CUDA not installed; that's OK)"

# Confirm both disks are visible.
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL

# RAM / CPU.
free -h
lscpu | grep -E '^(Model name|CPU\(s\))'
```

Required versions:
- NVIDIA driver **≥ 535** (R535+ is what supports Ampere/sm_86 + CUDA 12.x).
- Docker Engine **≥ 24** with `nvidia-container-toolkit` installed.

If the driver is older, install the latest stable from
[nvidia.com/en-us/drivers/](https://www.nvidia.com/en-us/drivers/) (search
"RTX A4000 Linux") and reboot before continuing.

### A2. Hostname + mDNS

```bash
sudo hostnamectl set-hostname z620-a4000
sudo apt-get install -y avahi-daemon
sudo systemctl enable --now avahi-daemon
```

Verify from another LAN machine: `ping z620-a4000.local`.

### A3. Storage layout

The single-disk-per-tier layout here is intentional — no LVM, no quotas. See
[STORAGE.md](STORAGE.md) for the design rationale.

```bash
# Dry-run first to see the plan.
./setup-storage.sh
# Then apply (you'll be asked to confirm the HDD device, and to type WIPE
# if the HDD has any pre-existing filesystem).
./setup-storage.sh --apply --hdd /dev/sdb   # adjust device

# Verify.
df -h / /archive
ls -la /archive/models
```

Optional: add a swapfile (helps page-cache headroom on a 24 GB box):

```bash
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

### A4. Docker + NVIDIA Container Toolkit

If not already installed:

```bash
# Docker.
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker   # or log out + back in

# NVIDIA Container Toolkit.
distribution=$(. /etc/os-release;echo "$ID$VERSION_ID")
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/"$distribution"/libnvidia-container.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Smoke test (downloads a small CUDA image and runs nvidia-smi inside).
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

### A5. Place the bundle

You already have the bundle at `~/work/z620-a4000-srv`. From here on, all
commands run from that directory.

```bash
cd ~/work/z620-a4000-srv
```

### A6. `.env`

```bash
cp .env.example .env
# Edit at minimum:
#   SITE_HOST=z620-a4000.local   (or your actual hostname)
#   VLLM_MODEL=Qwen2.5-7B-Instruct-AWQ
#   HF_TOKEN=hf_xxx   (required only for gated models like Llama)
$EDITOR .env
chmod 600 .env
```

### A7. System hygiene

Installs Docker log rotation (50 MB × 3 per container) + journald cap (1 GB
system). **The daemon.json install is a jq-merge** — it preserves any existing
NVIDIA runtime config.

```bash
sudo apt-get install -y jq    # required by install-system.sh
make install-system
```

### A8. HF CLI (host-side, optional but convenient)

The `make download-models` target prefers the `hf` CLI; falls back to a curl
script automatically if it's missing. To install:

```bash
pipx install --upgrade huggingface_hub
hf auth login    # paste your token if you have gated models
```

### A9. Pre-download models

Goes to `$ARCHIVE_ROOT/models/hf-cache` (HDD). The first download of a 7B AWQ
is ~5 GB; bge-m3 + reranker together are ~4 GB.

```bash
# Defaults: pulls VLLM_MODEL + TEI_MODEL + TEI_RERANKER_MODEL from .env.
make download-models

# Or specific:
./hf-curl-download.sh Qwen/Qwen2.5-7B-Instruct-AWQ
./hf-curl-download.sh BAAI/bge-m3
./hf-curl-download.sh BAAI/bge-reranker-large
```

If `hf download` stalls (corp proxy symptom: connections open, no bytes), use
`./hf-curl-download.sh` directly — it goes through one curl connection per
file with `--continue-at` and size-verifies after.

To diagnose a stall: `./diagnose-hf.sh` (read-only collector; share output).

### A10. (Optional) Pre-promote one model to SSD

For guaranteed fast vLLM cold-start, copy the currently-served model onto SSD
and point `VLLM_MODEL` at the bare name (resolver checks SSD first):

```bash
cp -a /archive/models/local/Qwen2.5-7B-Instruct-AWQ \
      /data/active/models/local/Qwen2.5-7B-Instruct-AWQ
# .env already has VLLM_MODEL=Qwen2.5-7B-Instruct-AWQ; no change needed.
```

## Part B — Docker stack

### B1. Create the network + storage dirs

```bash
make init
```

### B2. Pull images

In a normal network, skip this — `make up` will pull. Behind a hostile corp
proxy, pre-pull via skopeo:

```bash
# Optional NGC creds for nvcr.io images (we don't use any by default here).
# export NGC_API_KEY=...
make pull-stack
```

### B3. Bring up the stack

```bash
make up
# vLLM starts FIRST. The Makefile waits up to 5 min for /health
# before launching Ollama / TEI / Caddy — don't interrupt this.

make ps         # all containers should be 'Up (healthy)'
make health     # PASS/WARN/FAIL summary
```

First load: vLLM compiles CUDA graphs and warms up the model. Watch:

```bash
make logs svc=vllm
```

### B4. Smoke tests

```bash
# vLLM: list models, then a chat completion.
curl -s https://z620-a4000.local/v1/models | jq
curl -s https://z620-a4000.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct-AWQ","messages":[{"role":"user","content":"Say hi."}]}' \
  | jq -r '.choices[0].message.content'

# TEI embeddings.
curl -s https://z620-a4000.local/embed/embed \
  -H 'Content-Type: application/json' \
  -d '{"inputs":"hello world"}' | jq '.[0][:5]'

# TEI reranker.
curl -s https://z620-a4000.local/rerank/rerank \
  -H 'Content-Type: application/json' \
  -d '{"query":"cellular network","texts":["5G NR","cookies","CDMA"]}' \
  | jq

# Ollama: list models + pull a small one.
curl -s https://z620-a4000.local/ollama/api/tags | jq
curl -s -X POST https://z620-a4000.local/ollama/api/pull \
  -d '{"name":"llama3.2:3b"}'
```

If `curl` errors with `tlsv1 alert internal error`, you're using an IP in the
URL. Add `<box-ip>  z620-a4000.local` to `/etc/hosts` on the client and use
the hostname.

### B5. Cron health probe

```bash
crontab -e
# Add: every 15 min, run health.sh; exit non-zero on any FAIL.
*/15 * * * * cd $HOME/work/z620-a4000-srv && ./health.sh >> $HOME/health.log 2>&1
# Add: weekly docker prune.
0 3 * * 0 cd $HOME/work/z620-a4000-srv && make prune >> $HOME/prune.log 2>&1
```

### B6. (Optional) restic off-box backup

`backup.sh` only stages locally unless `RESTIC_REPO` + `RESTIC_PASSWORD` are
in `.env`. To wire it up to a remote restic repo (S3, SFTP, B2, etc.), set
both in `.env` and:

```bash
make backup       # first run will `restic init` if repo is empty
```

## Done

Stack should now be:
- Serving on `https://z620-a4000.local/{v1,ollama,embed,rerank}/*`.
- Self-monitoring via cron `health.sh`.
- Reproducible from this directory (config + scripts are all here).

For day-to-day ops, [RUNBOOK.md](RUNBOOK.md).
