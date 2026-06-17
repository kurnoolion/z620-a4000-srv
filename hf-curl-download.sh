#!/usr/bin/env bash
# hf-curl-download.sh — single-connection curl-based HF download.
#
# Use when `hf download` / huggingface-hub opens many connections that the
# corp proxy chokes on (symptom: 0-byte .incomplete blobs, flat cache).
# This script reads the HF API for the file list, then curl-downloads each
# with --continue-at --retry, and VERIFIES sizes against the API after.
#
# Usage:
#   ./hf-curl-download.sh <repo-id> [dest-dir]
#   ./hf-curl-download.sh Qwen/Qwen2.5-7B-Instruct-AWQ
#   ./hf-curl-download.sh BAAI/bge-m3 /archive/models/local/bge-m3
#
# Auth: $HF_TOKEN (or ~/.cache/huggingface/token).

set -euo pipefail

REPO="${1:?usage: $0 <repo-id> [dest-dir]}"
DEST="${2:-${ARCHIVE_ROOT:-/archive}/models/local/$(basename "$REPO")}"
BRANCH="${HF_BRANCH:-main}"

TOKEN="${HF_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f ~/.cache/huggingface/token ]; then
  TOKEN="$(cat ~/.cache/huggingface/token)"
fi

AUTH_HEADER=()
[ -n "$TOKEN" ] && AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")

mkdir -p "$DEST"
echo "[hf-curl] repo=$REPO branch=$BRANCH dest=$DEST"

API="https://huggingface.co/api/models/$REPO/tree/$BRANCH?recursive=true"
echo "[hf-curl] listing files: $API"
FILES_JSON=$(curl -s --fail "${AUTH_HEADER[@]}" "$API") || {
  echo "ERROR: HF API list failed. Check repo, branch, and token." >&2
  exit 2
}

# parse: type=file → path, size
PATHS=$(echo "$FILES_JSON" | python3 -c '
import json, sys
for item in json.load(sys.stdin):
    if item.get("type") == "file":
        print(item["path"], item.get("size", 0), sep="\t")
')

if [ -z "$PATHS" ]; then
  echo "ERROR: no files found in $REPO@$BRANCH" >&2
  exit 2
fi

TOTAL=$(echo "$PATHS" | wc -l)
echo "[hf-curl] $TOTAL files to download"

n=0
while IFS=$'\t' read -r path size; do
  n=$((n+1))
  out="$DEST/$path"
  mkdir -p "$(dirname "$out")"
  url="https://huggingface.co/$REPO/resolve/$BRANCH/$path"

  # Skip if already-complete (size matches HF API).
  if [ -f "$out" ]; then
    local_size=$(stat -c '%s' "$out" 2>/dev/null || echo 0)
    if [ "$local_size" = "$size" ] && [ "$size" != "0" ]; then
      echo "[$n/$TOTAL] $path — already complete ($size B), skip"
      continue
    fi
  fi

  echo "[$n/$TOTAL] $path (expect $size B)"
  # --http1.1 sidesteps "HTTP/2 stream N was not closed cleanly: CANCEL (err 8)"
  # — HF's CDN over HTTP/2 drops large streams on flaky / proxied links; HTTP/1.1
  # keeps the byte stream simple and lets --retry-all-errors actually recover.
  curl --fail --location \
       --http1.1 \
       --continue-at - \
       --retry 100 --retry-all-errors --retry-delay 5 --retry-max-time 600 \
       "${AUTH_HEADER[@]}" \
       -o "$out" \
       "$url"

  # Verify size.
  if [ "$size" != "0" ]; then
    actual=$(stat -c '%s' "$out")
    if [ "$actual" != "$size" ]; then
      echo "ERROR: $path size mismatch — expected $size, got $actual" >&2
      exit 3
    fi
  fi
done <<< "$PATHS"

echo "[hf-curl] DONE: $REPO → $DEST"
