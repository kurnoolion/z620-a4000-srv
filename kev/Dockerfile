# Kev-4B decision-model serve image, built on 247 via build-kev-image.sh.
#
# Baked contents:
#   - kev source (cloned from github.com/jaredpalmer/kev @ KEV_REF)
#   - CUDA PyTorch 2.6+ via standard pypi wheels (torch wheels ship CUDA 12.4)
#   - LoRA adapter + pointer head (jaredpalmer/kev-4b, ~160 MB)
#   - Qwen3.5-4B-Base backbone pinned to the revision the adapter was trained
#     against (1001bb4d, ~8 GB)
# So the container doesn't need HuggingFace at runtime — fast startup, no
# corp-proxy coupling.

FROM python:3.13-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH=/root/.local/bin:$PATH \
    HF_HOME=/opt/hf-cache \
    HF_HUB_ENABLE_HF_TRANSFER=1

WORKDIR /app
ARG KEV_REPO=https://github.com/jaredpalmer/kev.git
ARG KEV_REF=main
RUN git clone --depth 1 --branch "${KEV_REF}" "${KEV_REPO}" /app

# Pulls torch (CUDA 12.4 wheels from pypi), fastapi, uvicorn, transformers, peft, …
# Corp networks sometimes reset bursty parallel TLS fetches (SSL inspection /
# rate-limiting). Serialize downloads and raise the per-request timeout so
# the big NVIDIA CUDA wheels (~1 GB combined) don't trip connection resets.
RUN UV_CONCURRENT_DOWNLOADS=1 UV_HTTP_TIMEOUT=180 uv sync --extra serve

# Bake weights (~8.2 GB total). BASE_REVISION pin is important: the LoRA
# adapter is only valid against this exact backbone revision — later
# revisions can shift tokenizer / layer indices and break the pointer head.
ARG KEV_MODEL=jaredpalmer/kev-4b
ARG BASE_MODEL=Qwen/Qwen3.5-4B-Base
ARG BASE_REVISION=1001bb4d
RUN uv run --extra serve python -c "\
from huggingface_hub import snapshot_download; \
snapshot_download('${KEV_MODEL}'); \
snapshot_download('${BASE_MODEL}', revision='${BASE_REVISION}')"

EXPOSE 8008

# Kev's CLI (from `python -m kev.serve --help`):
#   --run <hub-id-or-path>       default: runs/kev
#   --fallback <hub-id-or-path>  default: runs/smoke
#   --host <bind>                default: 127.0.0.1  (must be 0.0.0.0 in a container)
#   --port <n>                   default: 8008
#   --device {auto,cpu,cuda,mps} default: auto      (force cuda on this box)
# Runtime env knobs: KEV_DTYPE (bf16 default on GPU), KEV_TEMPERATURE,
#   KEV_API_KEY, KEV_PREFIX_CACHE, KEV_BACKEND, KEV_DEVICE_PROBE_TIMEOUT, ...
CMD ["uv", "run", "--extra", "serve", "python", "-m", "kev.serve", \
     "--run", "jaredpalmer/kev-4b", \
     "--host", "0.0.0.0", "--port", "8008", \
     "--device", "cuda"]
