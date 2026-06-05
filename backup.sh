#!/usr/bin/env bash
# backup.sh — config + state backup for z620-a4000-srv.
#
# Stages:
#   1. Snapshot $PWD config (compose, Caddyfile, .env.example, scripts).
#   2. Snapshot Caddy state (caddy-data, caddy-config volumes).
#   3. List installed Ollama models (not the blobs — those are reproducible).
#   4. If RESTIC_REPO + RESTIC_PASSWORD are set, push to that repo with retention.
#      Otherwise stage locally under $ARCHIVE_ROOT/backups and WARN.
#
# Models are NOT backed up — they're reproducible from HuggingFace.

set -euo pipefail

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

ARCHIVE_ROOT="${ARCHIVE_ROOT:-/archive}"
STAGE="$ARCHIVE_ROOT/backups/staging"
TS=$(date +%Y%m%d-%H%M%S)
SNAP="$STAGE/$TS"

mkdir -p "$SNAP"
echo "[backup] staging dir: $SNAP"

# 1. Config snapshot.
echo "[+] config"
tar -czf "$SNAP/config.tgz" \
  Caddyfile Makefile compose.*.yml .env.example \
  *.sh system/ 2>/dev/null || true

# 2. Caddy state (volumes).
echo "[+] caddy state"
docker run --rm \
  -v z620-a4000-srv_caddy-data:/data:ro \
  -v z620-a4000-srv_caddy-config:/config:ro \
  -v "$SNAP":/snap alpine \
  tar -czf /snap/caddy-state.tgz -C / data config 2>/dev/null || \
  echo "[backup] WARN: caddy volume snapshot failed (volumes may not exist yet)"

# 3. Ollama models inventory (just the list, not the blobs).
echo "[+] ollama inventory"
docker exec ollama ollama list > "$SNAP/ollama-models.txt" 2>/dev/null || \
  echo "(ollama not running or no models)" > "$SNAP/ollama-models.txt"

# Manifest.
{
  echo "host: $(hostname)"
  echo "ts:   $TS"
  echo "files:"
  ls -la "$SNAP"
} > "$SNAP/MANIFEST.txt"

# 4. Push off-box via restic, or warn if not configured.
if [ -n "${RESTIC_REPO:-}" ] && [ -n "${RESTIC_PASSWORD:-}" ]; then
  echo "[+] restic push to $RESTIC_REPO"
  export RESTIC_REPO RESTIC_PASSWORD
  restic snapshots --quiet >/dev/null 2>&1 || restic init
  restic backup --tag z620-config "$SNAP"
  restic backup --tag z620-home "$HOME" --exclude "$HOME/.cache" --exclude "$HOME/snap" || true
  restic forget --tag z620-config --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  echo "[backup] DONE: off-box snapshot tagged z620-config"
else
  echo "[backup] WARN: RESTIC_REPO/RESTIC_PASSWORD not set in .env — staged locally only at $SNAP"
  echo "[backup] WARN: this is NOT a disaster-recovery backup. Set RESTIC_REPO to push off-box."
fi
