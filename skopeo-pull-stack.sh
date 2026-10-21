#!/usr/bin/env bash
# skopeo-pull-stack.sh — proxy-friendly image pull via skopeo.
# Use when `docker pull` EOFs through the corp proxy but curl/skopeo work.
# Same pattern as dgx-spark-srv (see that repo's RUNBOOK for diagnostics).

set -uo pipefail

LOG="$HOME/skopeo-pull-stack.log"
KEEP_TARS="${KEEP_TARS:-0}"

# Discover images from compose files (one per line, dedup).
# envsubst only handles `${VAR}` / `$VAR` — compose uses `${VAR:-default}`
# for inline defaults. Rewrite those to `${VAR}` before envsubst, so vars
# the Makefile exported from .env substitute cleanly.
IMAGES_FROM_COMPOSE=$(
  grep -hE '^\s*image:' compose.inference.yml compose.gateway.yml claude-usage/compose.yaml 2>/dev/null \
    | sed -E 's/^\s*image:\s*//; s/[[:space:]]*$//; s/^"//; s/"$//' \
    | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*):-[^}]*\}/${\1}/g' \
    | envsubst \
    | sort -u
)

# Also discover `FROM` base images from any Dockerfile in subdirs (kev/, …) —
# these are needed to BUILD locally-built images (e.g. kev-serve:local), not
# just to run compose services.
IMAGES_FROM_DOCKERFILES=$(
  find . -maxdepth 3 -name Dockerfile -not -path './.git/*' 2>/dev/null \
    | xargs -I{} grep -hE '^FROM\s+' {} 2>/dev/null \
    | sed -E 's/^FROM\s+([^ ]+).*/\1/' \
    | grep -vE '^(scratch$|\$)' \
    | sort -u
)

IMAGES_DISCOVERED=$(printf '%s\n%s\n' "$IMAGES_FROM_COMPOSE" "$IMAGES_FROM_DOCKERFILES" | sort -u)

# Allow overrides via $1..$N.
if [ "$#" -gt 0 ]; then IMAGES=("$@"); else mapfile -t IMAGES <<< "$IMAGES_DISCOVERED"; fi

if [ "${#IMAGES[@]}" -eq 0 ]; then
  echo "ERROR: no images discovered." >&2
  exit 1
fi

if ! command -v skopeo >/dev/null 2>&1; then
  echo "ERROR: skopeo not installed. sudo apt-get install -y skopeo" >&2
  exit 1
fi

echo "[$(date -Iseconds)] === skopeo-pull-stack begin ===" | tee -a "$LOG"
echo "[+] Images: ${IMAGES[*]}" | tee -a "$LOG"

OVERALL=0
for img in "${IMAGES[@]}"; do
  [ -z "$img" ] && continue
  # Skip if already locally present.
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "[skip] $img already loaded" | tee -a "$LOG"
    continue
  fi

  # Sanitize for filename. Tar suffix matters so `docker load` preserves the name.
  safe=$(echo "$img" | tr '/:' '__')
  tar="${TMP:-$PWD/images}/${safe}.tar"; mkdir -p "$(dirname "$tar")"

  CREDS_ARG=()
  case "$img" in
    nvcr.io/*) CREDS_ARG=(--src-creds "\$oauthtoken:${NGC_API_KEY:-}") ;;
  esac

  ok=0
  for try in 1 2 3; do
    echo "[pull] $img (try $try/3) → $tar" | tee -a "$LOG"
    if skopeo copy "${CREDS_ARG[@]}" \
         --override-arch amd64 --override-os linux \
         docker://"$img" docker-archive:"$tar:$img" 2>&1 | tee -a "$LOG"; then
      ok=1; break
    fi
    sleep 5
  done

  if [ "$ok" -eq 1 ]; then
    echo "[load] $img" | tee -a "$LOG"
    docker load < "$tar" 2>&1 | tee -a "$LOG"
    [ "$KEEP_TARS" = "0" ] && rm -f "$tar"
  else
    echo "ERROR: pull failed for $img" | tee -a "$LOG"
    OVERALL=1
  fi
done

echo "[$(date -Iseconds)] === skopeo-pull-stack end (rc=$OVERALL) ===" | tee -a "$LOG"
exit "$OVERALL"
