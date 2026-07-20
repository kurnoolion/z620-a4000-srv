# z620-a4000-srv

Docker Compose stack for an **HP Z620 + NVIDIA RTX A4000 (16 GB)** running
local inference (vLLM + Ollama + TEI) for the **nora** and **hilda** projects.

A smaller sibling to `dgx-spark-srv`: same operator interface (`make up`,
`make health`, `make rebalance`), same Caddy gateway pattern, but tuned to a
24 GB / 16 GB-VRAM / 250 GB-SSD + 1 TB-HDD box and focused on inference only
(no Postgres/Redis/Qdrant/MinIO here — those live elsewhere).

## Hardware

| | |
|---|---|
| Chassis | HP Z620 workstation (Xeon E5 Sandy/Ivy Bridge era) |
| RAM | 24 GB DDR3 ECC |
| Storage | 250 GB SSD (OS + Docker + active models) + 1 TB HDD (model archive + backups) |
| GPU | NVIDIA RTX A4000 — **Ampere, sm_86, 16 GB GDDR6** |
| Arch | x86_64 |
| CUDA | 12.x (use `cu121`/`cu122` wheels for any host-side Python) |

## What runs here

| Service | Image | Role |
|---|---|---|
| **vLLM** | `vllm/vllm-openai:v0.6.3` | One LLM ≤12B (AWQ/GPTQ) — OpenAI-compatible chat/completions |
| **Ollama** | `ollama/ollama:latest` | GGUF model rotation — load/unload on demand |
| **TEI** | `text-embeddings-inference:cpu-1.5` | Embeddings (default `bge-m3`) — CPU to save VRAM |
| **TEI reranker** | `text-embeddings-inference:cpu-1.5` | Reranking (default `bge-reranker-large`) — CPU |
| **Caddy** | `caddy:2-alpine` | TLS gateway, hostname-only routing |

**Not on this box** (intentionally): Postgres/Redis/Qdrant/MinIO, observability
stack (Prom/Grafana). RAM budget on 24 GB doesn't justify them; this box is
focused on inference and meant to be paired with backend services running
elsewhere.

## First-time deploy

Two docs, in order:
1. **[OS_INSTALL.md](OS_INSTALL.md)** — bare metal → Ubuntu Server 24.04 LTS
   + NVIDIA driver + ssh. Skip if the OS is already up and `nvidia-smi`
   shows the RTX A4000.
2. **[SETUP.md](SETUP.md)** — Ubuntu installed → stack serving requests:
   storage, install-system, `.env`, launch.

TL;DR once the box is provisioned:

```bash
cp .env.example .env          # fill in, then chmod 600
make init                      # network + storage dirs
make download-models           # pull VLLM_MODEL + TEI_MODEL + reranker
make up                        # vLLM first, then Ollama + TEI + Caddy
make health
```

## Routes (via Caddy, `https://$SITE_HOST`)

| Path | Backend | Use |
|---|---|---|
| `/v1/*` | vLLM :8000 | OpenAI-compatible chat / completions. **Also on plain HTTP** so cert-averse clients (nora/hilda RAG pipelines) can skip TLS. |
| `/ollama/*` | Ollama :11434 | Ollama API (model pull, generate, chat) |
| `/embed/*` | TEI :80 | TEI-native embeddings (`{"inputs":[...]}` → `[[floats]]`) |
| `/rerank/*` | TEI reranker :80 | reranking (Cohere-compatible `/rerank`). **Also on plain HTTP** for the same reason. |
| `/tei/*` | TEI :80 (prefix stripped) | OpenAI-compatible embeddings: `POST /tei/v1/embeddings` with `{"model","input":[...]}` → `{"data":[{"index","embedding"}]}`. The request's `model` value is ignored (TEI serves one model); the response echoes the served `--model-id` path. |

Everything else: 404.

## GPU memory budget (16 GB VRAM)

| Consumer | Target | Enforced by |
|---|---|---|
| **vLLM** | ~10.4 GB | `VLLM_GPU_UTIL=0.65` (fraction of 16 GB) |
| **Ollama** | ~5.6 GB | uses whatever vLLM leaves; `OLLAMA_MAX_LOADED_MODELS=1` |
| **TEI / reranker** | 0 (CPU) | default image is `cpu-1.5` |

Two facts this depends on:
- **vLLM pre-allocates at boot** — `make up` starts it first and waits for
  `/health` before launching Ollama. Don't reorder.
- **Ollama has no hard cap** — pick GGUFs that fit its slice. With vLLM up,
  ≤7B-Q4 fits. To run a 13B-Q4 or larger, `make vllm-stop` first.

### Changing the split

```bash
make rebalance util=0.50      # writes VLLM_GPU_UTIL=0.50 to .env + restarts vLLM
```

| `VLLM_GPU_UTIL` | vLLM gets | Left for Ollama | Ollama can run |
|---|---|---|---|
| 0.40 | ~6.4 GB | ~9 GB | 13B Q4 (tight), 8B Q4-Q8 |
| 0.55 | ~8.8 GB | ~6.5 GB | 7B Q4-Q5, room for GPU TEI (~1.5 GB) |
| **0.65** *(default)* | ~10.4 GB | ~5.0 GB | 7B Q4 (≤4 GB) |
| 0.80 | ~12.8 GB | ~2 GB | embed-only (no Ollama LLM) |

**Temporary: hand the whole 16 GB to Ollama** (e.g. to run a 13B-Q5 once):
```bash
make vllm-stop      # frees all VRAM
# … run your Ollama job …
make vllm-start
```

## Model picks (sensible defaults)

| Role | Default | Why |
|---|---|---|
| vLLM LLM | `Qwen2.5-7B-Instruct-AWQ` | ~5 GB AWQ + KV cache fits 0.65 split with room; strong general model |
| Embedding | `BAAI/bge-m3` | multilingual, dense+sparse, what nora/hilda already use |
| Reranker | `BAAI/bge-reranker-large` | ~568M, CPU-fast (~50-150 ms/query), ONNX weights publish |
| Ollama | (load as needed) | e.g. `llama3.2:3b`, `nomic-embed-text` |

Avoid for the reranker: `bge-reranker-v2-m3` (no ONNX weights),
`jina-reranker-v2-base-multilingual` (no `model_type` in config) — neither
loads in TEI. See `.env.example`.

## Reaching the stack from other machines

**Always use the hostname (`$SITE_HOST`) in URLs, never the raw IP.** Caddy's
TLS stack (Go crypto/tls) has a long-standing issue with IP-literal SNI —
`openssl s_client` works against `https://<ip>/`, but `curl`/`wget`/Python
clients fail with `tlsv1 alert internal error`. Hostname SNI works for every
client. (Same gotcha as `dgx-spark-srv`.)

To make this work on every client:

- **DNS** (cleanest): an A record `z620-a4000.<corp-domain>` → box IP.
- **mDNS** (zero-config on LAN): `sudo apt install avahi-daemon` on the box;
  Linux/Mac clients auto-resolve `z620-a4000.local`.
- **`/etc/hosts`** (simplest, per-machine):
  ```
  <box-ip>  z620-a4000.local
  ```
  Windows: `C:\Windows\System32\drivers\etc\hosts` (edit as Admin).

`.env` should always have `SITE_HOST=z620-a4000.local` (or your real
hostname) — never the IP.

## Securing the gateway

The gateway is **currently unauthenticated** — Caddy proxies directly to each
backend. Only acceptable on a VPN / trusted network. If that ever stops being
true, the dgx-spark-srv Caddyfile git history has working patterns for:

- **Basic auth (htpasswd)** per route.
- **Static API key** for `/v1/*`, `/embed/*`, `/rerank/*`.
- **oauth2-proxy + Caddy `forward_auth`** for full IdP.

## Storage at a glance

| Mount | Backing | Holds |
|---|---|---|
| `/` (SSD) | 250 GB SSD | OS + `/var/lib/docker` (images, volumes) |
| `/data/active` (SSD) | dir on `/` | Active model copies (fast cold-start), srv state |
| `/archive` (HDD) | 1 TB HDD | HF cache, downloaded models (`models/local/`), backups |

Models loaded from HDD page-cache in after first read; cold start of a 7B
AWQ off HDD is ~30-60 s, then hot. See [STORAGE.md](STORAGE.md) for details
and the SSD-promotion trick for guaranteed fast cold-start.

## Day-to-day operations

See [RUNBOOK.md](RUNBOOK.md) — health checks, model management, memory
rebalancing, log tail, backups, and a symptom → fix troubleshooting table.

## Files

- `compose.inference.yml` — vllm, ollama, tei (embed), tei-reranker
- `compose.gateway.yml` + `Caddyfile` — reverse proxy / TLS
- `Makefile` — operator interface
- `.env.example` — copy to `.env`, fill, `chmod 600`
- `setup-storage.sh` — provision `/data/active` (SSD) + `/archive` (HDD)
- `install-system.sh` (`make install-system`) — docker log rotation + journald cap
- `system/` — `daemon.json`, `journald-z620.conf` (installed by above)
- `health.sh` (`make health`) — daily health probes / cron-friendly
- `download-models.sh` (`make download-models`) — bulk HF model pre-download
- `hf-curl-download.sh` — single-curl HF download (proxy fallback)
- `ollama-import.sh` — import a GGUF from HF into Ollama (bypasses registry.ollama.ai)
- `skopeo-pull-stack.sh` (`make pull-stack`) — proxy-friendly image pulls
- `diagnose-hf.sh` — HF download stall diagnostics
- `backup.sh` (`make backup`) — config snapshot + optional restic off-box push
- `OS_INSTALL.md` — bare metal → Ubuntu Server 24.04 + NVIDIA driver + ssh
- `SETUP.md` / `RUNBOOK.md` / `STORAGE.md` — first-time / day-to-day / disk layout
