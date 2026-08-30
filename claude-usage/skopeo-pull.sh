#!/usr/bin/env bash
# skopeo-pull.sh — pull the claude-usage images via skopeo and `docker load`
# them. Use when `docker pull`/`docker compose up` cannot reach Docker Hub
# (corp proxy resets TLS) but skopeo — which honours http_proxy/https_proxy —
# can. Idempotent: images already present locally are skipped.
#
#   ./skopeo-pull.sh                 # every image: in compose.yaml
#   ./skopeo-pull.sh grafana/grafana:12.0.2   # explicit list
#   KEEP_TARS=1 ./skopeo-pull.sh     # keep tarballs in $TMP (sneakernet to another box)
#
# Env: TMP (default ./data/images), KEEP_TARS (0), MAX_RETRIES (3), LOG (~/claude-usage-pull.log)
# Tarballs are fed to `docker load` on stdin, so a snap-confined docker CLI
# (which cannot open /tmp or hidden dirs like ~/.cache) still works.
# A tarball left behind by an earlier run (failed load, Ctrl-C after copy) is
# reused instead of re-downloaded; tarballs are deleted only after a successful load.
set -uo pipefail
cd "$(dirname "$0")"

TMP="${TMP:-$PWD/data/images}"; mkdir -p "$TMP"; KEEP_TARS="${KEEP_TARS:-0}"; MAX_RETRIES="${MAX_RETRIES:-3}"
LOG="${LOG:-$HOME/claude-usage-pull.log}"
log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

command -v skopeo >/dev/null || { echo "skopeo not installed: sudo apt-get install -y skopeo" >&2; exit 1; }
docker info >/dev/null 2>&1   || { echo "cannot reach docker daemon (in docker group?)" >&2; exit 1; }

if (( $# > 0 )); then IMAGES=("$@"); else
  mapfile -t IMAGES < <(grep -hE '^\s*image:' compose.yaml | sed -E 's/^\s*image:\s*//; s/["'"'"']//g; s/\s*#.*$//' | sort -u)
fi
(( ${#IMAGES[@]} > 0 )) || { echo "no images found" >&2; exit 1; }

# docker.io shorthand → full skopeo reference
to_src() { local r="$1"; case "$r" in
  */*/*) echo "$r" ;;                       # registry/ns/name
  *.*/*|*:*/*) echo "$r" ;;                 # registry/name
  */*) echo "docker.io/$r" ;;               # ns/name
  *) echo "docker.io/library/$r" ;; esac; }

failed=()
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then log "skip  $img (present)"; continue; fi
  tar="$TMP/$(tr '/:' '__' <<<"$img").tar"; ok=0
  if [[ -s "$tar" ]]; then log "reuse $tar (from an earlier run)"; ok=1; fi
  for ((a=1; a<=MAX_RETRIES && ok==0; a++)); do
    log "pull  $img (try $a/$MAX_RETRIES)"
    if skopeo copy --override-os linux --override-arch amd64 \
         "docker://$(to_src "$img")" "docker-archive:$tar:$img" 2>&1 | tee -a "$LOG"; then ok=1; break; fi
    sleep $((a*5))
  done
  if (( ok )); then
    log "load  $img"
    if docker load < "$tar" 2>&1 | tee -a "$LOG" && docker image inspect "$img" >/dev/null 2>&1; then
      (( KEEP_TARS )) || rm -f "$tar"
    else
      log "load FAILED — tarball kept at $tar"; failed+=("$img")
    fi
  else failed+=("$img"); fi
done

if (( ${#failed[@]} )); then log "FAILED: ${failed[*]}"; exit 1; fi
log "all images present — now: make up"
