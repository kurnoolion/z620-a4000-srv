# z620-a4000-srv — runbook

Day-to-day operations. Assume you're in `~/work/z620-a4000-srv/`.

## Quick status

```bash
make ps          # what's running
make health      # PASS/WARN/FAIL across containers, GPU, endpoints, disk, RAM
docker stats --no-stream    # per-container CPU/mem snapshot
nvidia-smi                  # GPU util + per-process VRAM
```

## Logs

```bash
make logs                # all services, follow
make logs svc=vllm       # one service
docker logs --tail 200 -f vllm
```

`vllm` logs include per-request stats (tok/s, queue depth) at startup; turn
the noise down or up with the `--disable-log-requests` flag (already set in
`compose.inference.yml`).

## Model management

### vLLM — switching the served model

vLLM serves **one** model at a time. Switching:

```bash
# 1. Download the new model.
./hf-curl-download.sh Qwen/Qwen2.5-14B-Instruct-AWQ
# (lands at /archive/models/local/Qwen2.5-14B-Instruct-AWQ)

# 2. Update VLLM_MODEL in .env to the bare name (resolver finds it).
sed -i 's|^VLLM_MODEL=.*|VLLM_MODEL=Qwen2.5-14B-Instruct-AWQ|' .env

# 3. Recreate vLLM (only). NOT `make restart` — restart keeps the old
#    container, which has the old model name baked into its command.
make apply svc=vllm
```

Cold reload: 1-3 min for a 7B AWQ off SSD page-cache, 3-5 min off HDD cold.
Watch `make logs svc=vllm`.

For a **reasoning model** (Qwen3-*, DeepSeek-R1), also set in `.env`:

```bash
VLLM_REASONING_PARSER=qwen3      # or deepseek_r1
```

so `<think>` blocks route into `choices[].message.reasoning_content` rather
than `message.content`.

### TEI — switching embedding or reranker model

`TEI_MODEL` / `TEI_RERANKER_MODEL` are **bare basenames** under
`/archive/models/local/` (compose prepends `/local-models/` itself — a full
path or `Org/Name` repo ID in `.env` will NOT load). Download first, then
point `.env` at the basename:

```bash
./hf-curl-download.sh BAAI/bge-large-en-v1.5
# → /archive/models/local/bge-large-en-v1.5
sed -i 's|^TEI_MODEL=.*|TEI_MODEL=bge-large-en-v1.5|' .env
make apply svc=tei

./hf-curl-download.sh mixedbread-ai/mxbai-rerank-large-v1
sed -i 's|^TEI_RERANKER_MODEL=.*|TEI_RERANKER_MODEL=mxbai-rerank-large-v1|' .env
make apply svc=tei-reranker
```

TEI is picky about models: needs ONNX weights and a `model_type` field in
`config.json`. Models that DON'T load (verified):
- `BAAI/bge-reranker-v2-m3` — no ONNX
- `jinaai/jina-reranker-v2-base-multilingual` — no `model_type`

## Memory tuning

```bash
# Current split is in VLLM_GPU_UTIL in .env.
grep VLLM_GPU_UTIL .env
nvidia-smi --query-gpu=memory.used,memory.total --format=csv

# To change: edit .env then apply.
sed -i 's|^VLLM_GPU_UTIL=.*|VLLM_GPU_UTIL=0.80|' .env
make apply svc=vllm
```

Decision guide (vLLM is the only GPU consumer; `TEI_IMAGE` is CPU by default):

| Need | Set util / max-model-len |
|---|---|
| Default: Qwen2.5-7B at 128K YaRN | 0.90 / 131072 |
| Native 32K context, more headroom | 0.80 / 32768 (clear `VLLM_ROPE_SCALING`) |
| Switch TEI to GPU (faster embeddings) | 0.60 / 32768 + swap `TEI_IMAGE` to the CUDA tag |

## Disk + cleanup

```bash
df -h / /archive
du -sh /archive/models/* | sort -h
make prune-status         # what docker can reclaim
make prune                # reclaim images > 14d + build cache + stopped containers
```

## Restarting individual services

```bash
make restart svc=vllm           # ~2-5 min reload
make restart svc=tei            # ~1 min
make restart svc=tei-reranker   # ~1 min
make restart svc=caddy          # near-instant
```

`restart` re-runs the **existing** container — it does not pick up `.env` or
compose-file edits (those are baked in at container creation). After changing
either, use `make apply svc=<name>` instead. Exception: the Caddyfile is
bind-mounted and re-parsed on start, so `make restart svc=caddy` is enough
for Caddyfile-only changes.

Full restart: `make down && make up` (vLLM reloads from scratch).

## Backups

```bash
make backup
```

Config + Caddy state → `$ARCHIVE_ROOT/backups/staging/<ts>/`.
If `RESTIC_REPO` + `RESTIC_PASSWORD` are set in `.env`, also pushes to that
restic repo with retention (daily 7, weekly 4, monthly 6). Models are NOT
backed up — they're reproducible from HuggingFace.

Cron line for nightly:

```cron
30 2 * * * cd $HOME/work/z620-a4000-srv && make backup >> $HOME/backup.log 2>&1
```

## User management

Single-user box by default — no need for group / quota tooling like
dgx-spark-srv has. If a second user lands:

```bash
sudo adduser bob
sudo usermod -aG docker bob
# Optionally: separate HF cache per user
echo 'export HF_HOME=/archive/models/hf-cache' | sudo tee -a /home/bob/.bashrc
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `make up` hangs at "Waiting for vLLM /health" | Model not yet loaded (first cold start is slow off HDD) | `make logs svc=vllm` — look for "Started server" |
| vLLM container restarts in a loop with OOM | `VLLM_MAX_MODEL_LEN` too high for `VLLM_GPU_UTIL` | Lower `VLLM_MAX_MODEL_LEN` (e.g. 131072 → 65536) or add `--kv-cache-dtype fp8` to the compose exec |
| `tlsv1 alert internal error` from curl | URL uses IP, not hostname | Use `z620-a4000.local` (add `/etc/hosts` entry on client) |
| TEI fails to start ("model not supported") | Reranker without ONNX or without `model_type` | Pick a different reranker; see model-management section |
| `make download-models` opens connections, 0 bytes | Corp proxy throttles HF multi-stream | Use `./hf-curl-download.sh <repo>` directly |
| Containers fail with "could not select device driver nvidia" | Missing nvidia-container-toolkit, or daemon.json clobbered | Re-run `make install-system` (it merges, doesn't overwrite) |
| Disk filling fast under `/var/lib/docker` | Image churn without rotation | `make prune`; verify `make install-system` ran |
| `nvidia-smi` shows VRAM in use after `make down` | Driver caches the context briefly | Wait 10 s; if persistent, `sudo nvidia-smi --gpu-reset` (may need driver persistence daemon) |

## When to upgrade what

- **NVIDIA driver:** when a new vLLM major requires it (release notes). Keep
  at R535+ for sm_86 + CUDA 12.x.
- **vLLM image** (`vllm/vllm-openai`): when AWQ kernels improve or you want
  newer model architectures. Pin a tag; don't follow `:latest`.
- **TEI:** stable; bump only when you need new reranker support.
