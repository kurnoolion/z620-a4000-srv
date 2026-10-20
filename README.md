# z620-a4000-srv

Docker Compose stack for an **HP Z620 + NVIDIA RTX A4000 (16 GB)** running
local inference (vLLM + TEI) for the **nora** and **hilda** projects.

A smaller sibling to `dgx-spark-srv`: same operator interface (`make up`,
`make health`), same Caddy gateway pattern, but tuned to a 24 GB / 16 GB-VRAM
/ 250 GB-SSD + 1 TB-HDD box and focused on inference only (no
Postgres/Redis/Qdrant/MinIO here — those live elsewhere).

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
| **TEI** | `text-embeddings-inference:cpu-1.5` | Embeddings (default `bge-m3`) — CPU |
| **TEI reranker** | `text-embeddings-inference:cpu-1.5` | Reranking (default `bge-reranker-large`) — CPU |
| **Caddy** | `caddy:2-alpine` | TLS gateway, hostname-only routing |

| **claude-usage/** (optional, standalone) | own compose project | **Claude Code team usage ledger** (tokens / cost / sessions per developer) + time-boxed model grants. Runs on any Docker host; here it's co-hosted and Caddy proxies `/grafana/` to it. See [claude-usage/README.md](claude-usage/README.md). |

**Not on this box** (intentionally): Postgres/Redis/Qdrant/MinIO. RAM budget
on 24 GB doesn't justify them; this box is focused on inference and meant to
be paired with backend services running elsewhere.

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
make up                        # vLLM, then TEI + Caddy
make health
```

## Routes (via Caddy, `https://$SITE_HOST`)

| Path | Backend | Use |
|---|---|---|
| `/v1/*` | vLLM :8000 | OpenAI-compatible chat / completions. **Also on plain HTTP** so cert-averse clients (nora/hilda RAG pipelines) can skip TLS. |
| `/metrics` | vLLM :8000 | Prometheus-format vLLM metrics (request latency, tokens/s, queue depth, KV-cache hit rate, …). **Also on plain HTTP** for in-cluster Prom scrapes. |
| `/embed/*` | TEI :80 | TEI-native embeddings (`{"inputs":[...]}` → `[[floats]]`) |
| `/rerank/*` | TEI reranker :80 | reranking (Cohere-compatible `/rerank`). **Also on plain HTTP** for the same reason. |
| `/tei/*` | TEI :80 (prefix stripped) | OpenAI-compatible embeddings: `POST /tei/v1/embeddings` with `{"model","input":[...]}` → `{"data":[{"index","embedding"}]}`. The request's `model` value is ignored (TEI serves one model); the response echoes the served `--model-id` path. |

| `/grafana/*` | host :3000 (claude-usage stack) | Claude Code usage dashboards, if `make usage-up` is running. **Also on plain HTTP.** |

Everything else: 404.

## GPU memory budget (16 GB VRAM)

| Consumer | Target | Enforced by |
|---|---|---|
| **vLLM** | ~14.4 GB | `VLLM_GPU_UTIL=0.90` (fraction of 16 GB) |
| **TEI / reranker** | 0 (CPU) | default image is `cpu-1.5` |

vLLM pre-allocates its slice at boot. At `0.90` with Qwen2.5-7B-AWQ and
`VLLM_MAX_MODEL_LEN=131072` (YaRN-extended), the KV cache ends up ~7 GB on
top of ~5 GB of AWQ weights, with the rest for activations/overhead.

Lower `VLLM_GPU_UTIL` and/or `VLLM_MAX_MODEL_LEN` if you want headroom for a
GPU reranker (switch `TEI_IMAGE` in `.env` to the CUDA image). Nothing else on
this box needs VRAM — Ollama has been removed in favor of a vLLM-only serve.

## Model picks (sensible defaults)

| Role | Default | Why |
|---|---|---|
| vLLM LLM | `Qwen2.5-7B-Instruct-AWQ` | ~5 GB AWQ + KV cache fits 0.90 split with 128K YaRN-extended context; strong general model |
| Embedding | `BAAI/bge-m3` | multilingual, dense+sparse, what nora/hilda already use |
| Reranker | `BAAI/bge-reranker-large` | ~568M, CPU-fast (~50-150 ms/query), ONNX weights publish |

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

- `compose.inference.yml` — vllm, tei (embed), tei-reranker
- `compose.gateway.yml` + `Caddyfile` — reverse proxy / TLS
- `claude-usage/` — **standalone** Claude Code usage observability + model grants (own `compose.yaml`, `Makefile`, `.env`, `clients/`, docs). `make usage-up` here, or copy the directory to any Docker host.
- `Makefile` — operator interface
- `.env.example` — copy to `.env`, fill, `chmod 600`
- `setup-storage.sh` — provision `/data/active` (SSD) + `/archive` (HDD)
- `install-system.sh` (`make install-system`) — docker log rotation + journald cap
- `system/` — `daemon.json`, `journald-z620.conf` (installed by above)
- `health.sh` (`make health`) — daily health probes / cron-friendly
- `download-models.sh` (`make download-models`) — bulk HF model pre-download
- `hf-curl-download.sh` — single-curl HF download (proxy fallback)
- `skopeo-pull-stack.sh` (`make pull-stack`) — proxy-friendly image pulls
- `diagnose-hf.sh` — HF download stall diagnostics
- `backup.sh` (`make backup`) — config snapshot + optional restic off-box push
- `OS_INSTALL.md` — bare metal → Ubuntu Server 24.04 + NVIDIA driver + ssh
- `SETUP.md` / `RUNBOOK.md` / `STORAGE.md` — first-time / day-to-day / disk layout
