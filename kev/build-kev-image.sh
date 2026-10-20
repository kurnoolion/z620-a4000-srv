#!/usr/bin/env bash
# Build the kev-serve:local image on this box.
#
# One-shot. Rebuild only when the Dockerfile, kev upstream, or weight pins
# change. Pulls through whatever proxy is wired into docker on this host —
# the Dockerfile does a git clone + uv sync + HF snapshot_download during
# build, so HTTP(S)_PROXY must be available to the docker daemon.
#
# Vars (override as needed):
#   KEV_IMAGE     image tag to build  (default: kev-serve:local)
#   KEV_REF       kev git ref/branch  (default: main)
#   KEV_MODEL     adapter repo id     (default: jaredpalmer/kev-4b)
#   BASE_MODEL    backbone repo id    (default: Qwen/Qwen3.5-4B-Base)
#   BASE_REVISION backbone commit sha (default: 1001bb4d — matches adapter)

set -euo pipefail

IMAGE="${KEV_IMAGE:-kev-serve:local}"
KEV_REF="${KEV_REF:-main}"
KEV_MODEL="${KEV_MODEL:-jaredpalmer/kev-4b}"
BASE_MODEL="${BASE_MODEL:-Qwen/Qwen3.5-4B-Base}"
BASE_REVISION="${BASE_REVISION:-1001bb4d}"

cd "$(dirname "$0")"

# docker.io can reset / EOF for `docker pull` through the corp proxy on work
# hosts. Delegate the base-image fetch to ../skopeo-pull-stack.sh, which uses
# skopeo (proxy-friendly) and loads the result into the local docker daemon.
# No-op if the base image is already loaded.
BASE_IMAGE=$(sed -nE 's/^FROM\s+([^ ]+).*/\1/p' Dockerfile | head -1)
if [ -n "$BASE_IMAGE" ]; then
  echo "[+] staging base image $BASE_IMAGE via skopeo-pull-stack.sh..."
  ../skopeo-pull-stack.sh "$BASE_IMAGE"
fi

# `uv sync` and `snapshot_download` inside the build container need the corp
# proxy. `sudo` normally strips http_proxy / https_proxy; recover from
# /etc/environment or /etc/wgetrc if the current shell doesn't have them.
# Best-effort — grep's no-match (exit 1) must not kill the script.
set +e
if [ -z "${http_proxy:-}${HTTP_PROXY:-}${https_proxy:-}${HTTPS_PROXY:-}" ]; then
  # Source 1: /etc/environment (KEY=VALUE lines)
  if [ -r /etc/environment ]; then
    for var in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
      val=$(grep -E "^${var}=" /etc/environment 2>/dev/null | tail -1 \
            | sed -e "s/^${var}=//" -e 's/^"//' -e 's/"$//')
      [ -n "$val" ] && export "${var}=${val}"
    done
  fi
  # Source 2: /etc/wgetrc (KEY = VALUE lines, with optional spaces around =)
  if [ -r /etc/wgetrc ] && [ -z "${http_proxy:-}${https_proxy:-}" ]; then
    for var in http_proxy https_proxy no_proxy; do
      # Match "key = value" or "key=value", skip commented lines (#).
      val=$(grep -E "^[[:space:]]*${var}[[:space:]]*=" /etc/wgetrc 2>/dev/null \
            | grep -v '^[[:space:]]*#' | tail -1 \
            | sed -E "s|^[[:space:]]*${var}[[:space:]]*=[[:space:]]*||" \
            | sed -e 's/^"//' -e 's/"$//' -e 's/[[:space:]]*$//')
      [ -n "$val" ] && export "${var}=${val}" && export "$(echo "$var" | tr a-z A-Z)=${val}"
    done
  fi
fi
set -e

BUILD_ARGS=(
  --tag "$IMAGE"
  --build-arg KEV_REF="$KEV_REF"
  --build-arg KEV_MODEL="$KEV_MODEL"
  --build-arg BASE_MODEL="$BASE_MODEL"
  --build-arg BASE_REVISION="$BASE_REVISION"
)
# Propagate proxy to the build container (uv, pip, huggingface_hub honor these).
# HTTP_PROXY/HTTPS_PROXY/NO_PROXY (and lowercase) are *pre-defined* build-args
# in Docker — their values do NOT persist in the final image's history, so a
# proxy URL with userinfo is safe to pass here.
PROXY_SET=0
for var in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  if [ -n "${!var:-}" ]; then
    BUILD_ARGS+=(--build-arg "${var}=${!var}")
    PROXY_SET=1
  fi
done
if [ "$PROXY_SET" = "1" ]; then
  echo "[+] proxy env detected; propagating to docker build"
else
  echo "[+] no proxy env detected; building without --build-arg proxy"
fi

echo "==> Building $IMAGE"
echo "    KEV_REF=$KEV_REF"
echo "    KEV_MODEL=$KEV_MODEL"
echo "    BASE=$BASE_MODEL @ $BASE_REVISION"
echo

docker build "${BUILD_ARGS[@]}" .

echo
echo "==> Built $IMAGE"
docker images "$IMAGE"
echo
echo "Next on this box:  sudo make up llm=kev"
