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

echo "==> Building $IMAGE"
echo "    KEV_REF=$KEV_REF"
echo "    KEV_MODEL=$KEV_MODEL"
echo "    BASE=$BASE_MODEL @ $BASE_REVISION"
echo

docker build \
  --tag "$IMAGE" \
  --build-arg KEV_REF="$KEV_REF" \
  --build-arg KEV_MODEL="$KEV_MODEL" \
  --build-arg BASE_MODEL="$BASE_MODEL" \
  --build-arg BASE_REVISION="$BASE_REVISION" \
  .

echo
echo "==> Built $IMAGE"
docker images "$IMAGE"
echo
echo "Next on this box:  sudo make up llm=kev"
