# z620-a4000-srv — runbook

Day-to-day operations. Assume you're in the deploy directory, and prefix
`make` with `sudo` on boxes running snap Docker.

## Quick status

```bash
make ps          # what's running
make llm         # which LLM is active: vllm or kev
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

## Switching between vLLM and Kev

Only one LLM holds the GPU at a time. Switch with:

```bash
make up llm=kev      # stops vllm (if up), starts kev + TEI + Caddy
make up llm=vllm     # stops kev (if up), starts vllm + TEI + Caddy
make llm             # confirm which is running
make llm-stop        # stop both; TEI + Caddy stay up
```

`make up` waits until the chosen LLM reports healthy (Kev ~1-2 min, vLLM
~1-3 min warm). TEI and Caddy are not restarted, so `/embed` and `/rerank`
stay up throughout. While Kev is active, `/v1/*` and `/metrics` return 502;
while vLLM is active, `/systemone/*` returns 502.

## Kev (decision model)

### What it is

Kev-4B: a LoRA adapter (rank 16) + bilinear pointer head on a frozen
`Qwen/Qwen3.5-4B-Base`, served by `kev.serve` from
`github.com/jaredpalmer/kev`. It speaks TypeSafe's System One API — a
classifier over a supplied option set, **not** a chat model. Gateway base
URL: `https://$SITE_HOST/systemone`.

### Building the image

```bash
make build-kev       # = kev/build-kev-image.sh
```

One-shot, ~15-30 min (mostly the ~8 GB backbone download). Produces
`kev-serve:local` (~30 GB) with source, Python deps and weights baked in —
the container never reaches HuggingFace at runtime. Rebuild only when
`kev/Dockerfile`, the upstream kev ref, or the weight pins change:

```bash
KEV_REF=<git-ref> make build-kev          # different upstream kev commit
make apply svc=kev                        # pick up the new image
```

Build-time knobs in the Dockerfile exist because of the corp network:

| Knob | Why |
|---|---|
| base image pre-pulled via `skopeo-pull-stack.sh` | `docker pull` from Docker Hub gets reset |
| `OPENSSL_CONF` → classical groups (`X25519:P-256:P-384`) | corp DPI resets post-quantum TLS ClientHellos (OpenSSL 3.5+) |
| `pip`, not `uv` | uv uses bundled rustls (PQ ClientHello, ignores `OPENSSL_CONF`) |
| `HF_HUB_DISABLE_XET=1` | HF's Xet client is rustls too; legacy CDN path goes through OpenSSL |

Build from a shell **without** the corp proxy set (`unset http_proxy
https_proxy`): the proxy itself resets pypi, and direct access works.

### Verifying it

```bash
curl -s http://$SITE_HOST/systemone/v1/models | jq '.models[] | {name, lora, temperature, device, dtype}'
```

Expect `kev-latest` and `jev-latest`, `lora` non-null, `temperature`
non-zero, `device: cuda`, `dtype: bf16`. NORA's decision arm checks the
same fields (`assert_remote_head`) and refuses to run without them.

### Runtime knobs (`.env`, then `make apply svc=kev`)

Leave these **commented out** unless overriding — compose passes only the
ones that are set (an empty value crashes kev's `int()` parsing).

| Var | Default | Effect |
|---|---|---|
| `KEV_DTYPE` | `bf16` | `fp32` won't fit on 16 GB |
| `KEV_TEMPERATURE` | adapter-calibrated | `1.0` returns raw probabilities |
| `KEV_API_KEY` | unset (open) | bearer auth on `/v1/*` |
| `KEV_PREFIX_CACHE` | `4` | prefix-state cache entries; `0` disables |

Startup warns that `causal_conv1d` and `flash-linear-attention` are missing
and falls back to reference PyTorch kernels — correct but slower. Not
required to run.

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

Decision guide (TEI is CPU by default; Kev's footprint is fixed at ~14 GB):

| Need | Settings |
|---|---|
| Default: Qwen2.5-7B, native 32K | `VLLM_GPU_UTIL=0.55`, `VLLM_MAX_MODEL_LEN=32768`, `VLLM_ROPE_SCALING=` (blank) |
| Qwen2.5-7B at 128K YaRN | `0.90` / `131072` / `VLLM_ROPE_SCALING={"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":32768}` — **unquoted** JSON |
| GPU TEI under vLLM (faster embeddings) | `0.55` / `32768` + CUDA `TEI_IMAGE` + `<<: *gpu` on `tei`. Revert before `make up llm=kev`. |
| Kev | nothing to tune — needs the card to itself (TEI on CPU) |

## Disk + cleanup

```bash
df -h / /archive
du -sh /archive/models/* | sort -h
make prune-status         # what docker can reclaim
make prune                # reclaim images > 14d + build cache + stopped containers
```

**Careful with image prunes.** `make prune` and `docker image prune -a`
delete every image not used by a running container — with time-sharing,
that includes the idle LLM's image. Re-fetch vLLM with `make pull-stack`;
`kev-serve:local` can only be rebuilt (`make build-kev`, ~15-30 min). Safe
alternatives: `docker builder prune -af` and `docker image prune -f`
(dangling only), or `docker rmi <specific-image>`.

## Restarting individual services

```bash
make restart svc=vllm           # ~2-5 min reload
make restart svc=kev            # ~1-2 min reload
make restart svc=tei            # ~1 min
make restart svc=tei-reranker   # ~1 min
make restart svc=caddy          # near-instant
```

`restart` re-runs the **existing** container — it does not pick up `.env` or
compose-file edits (those are baked in at container creation). After changing
either, use `make apply svc=<name>` instead. Exception: the Caddyfile is
bind-mounted and re-parsed on start, so `make restart svc=caddy` is enough
for Caddyfile-only changes.

Full restart: `make down && make up llm=<vllm|kev>`.

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
| `make up` fails pulling an image (`connection reset by peer`) | Corp proxy resets docker's registry pulls | `make pull-stack`, then retry |
| `kev` restart-loops, `torch.OutOfMemoryError` in `cuda_graphs.py` | Something else holds VRAM (GPU TEI, or vllm not stopped) | `nvidia-smi` to find it; keep TEI on CPU; `make up llm=kev` stops vllm |
| `kev` restart-loops, `ValueError: invalid literal for int()` | A `KEV_*` var set to empty in `.env` | Comment it out entirely |
| `/systemone/...` returns `{"detail":"Not Found"}` | Path wrong — kev serves `/v1/models`, `/v1/systemone` | Use base `/systemone` + `/v1/...` (Caddy strips the prefix) |
| `/systemone/*` returns 502 | Kev not the active LLM, or still loading | `make llm`; `make logs svc=kev` |
| `make build-kev` fails with `Connection reset by peer` | Proxy set in shell, or a new rustls-based downloader | `unset http_proxy https_proxy`; see the Kev build-knob table |
| vllm exits: `--rope-scaling: invalid loads value` | `VLLM_ROPE_SCALING` quoted in `.env` | Store the JSON unquoted |
| `Failed to initialize NVML: Driver/library version mismatch` | apt upgraded NVIDIA userspace past the loaded kernel module | Reboot; keep NVIDIA packages `apt-mark hold`-ed |

## When to upgrade what

- **NVIDIA driver:** when a new vLLM major requires it (release notes). Keep
  at R535+ for sm_86 + CUDA 12.x.
- **vLLM image** (`vllm/vllm-openai`): when AWQ kernels improve or you want
  newer model architectures. Pin a tag; don't follow `:latest`.
- **TEI:** stable; bump only when you need new reranker support.
- **Kev:** rebuild (`KEV_REF=<ref> make build-kev`) when upstream kev ships a
  fix you need. Keep `BASE_REVISION` matched to what the adapter pins.
- **NVIDIA packages** are `apt-mark hold`-ed. To upgrade: unhold, upgrade,
  reboot in the same session, re-hold.
