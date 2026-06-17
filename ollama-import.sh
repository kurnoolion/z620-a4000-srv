#!/usr/bin/env bash
# ollama-import.sh — import a GGUF model from HuggingFace into Ollama.
#
# Bypasses the Ollama registry (registry.ollama.ai) — useful when the corp
# proxy/firewall allows huggingface.co but blocks Ollama's CDN. Flow:
#   1. download GGUF files via hf-curl-download.sh
#   2. write a minimal Modelfile next to the chosen quant
#   3. `docker exec ollama ollama create <name>` to ingest into Ollama's
#      blob store
#
# Usage:
#   ./ollama-import.sh <hf-repo> <ollama-name> [quant-pattern]
#
# Examples:
#   ./ollama-import.sh Qwen/Qwen2.5-7B-Instruct-GGUF qwen2.5-7b-q4
#   ./ollama-import.sh Qwen/Qwen2.5-7B-Instruct-GGUF qwen2.5-7b-q5 q5_k_m
#   ./ollama-import.sh bartowski/Llama-3.2-3B-Instruct-GGUF llama3.2-3b
#
# Defaults: quant-pattern = q4_k_m (good balance of quality/size for 7B-ish).
# The pattern is a case-insensitive glob fragment matched against *.gguf
# filenames in the repo — pick something more specific if multiple match.
#
# After `ollama create`, Ollama has its own copy in the blob store and the
# downloaded GGUF is no longer needed. The script offers to delete it.

set -euo pipefail

ARCHIVE_ROOT="${ARCHIVE_ROOT:-/archive}"
OLLAMA_DATA="$ARCHIVE_ROOT/models/ollama"
IMPORT_ROOT="$OLLAMA_DATA/import"
CONTAINER="${OLLAMA_CONTAINER:-ollama}"

# Load .env for ARCHIVE_ROOT override.
[ -f .env ] && { set -a; . ./.env; set +a; }

if [ $# -lt 2 ]; then
  sed -n '2,26p' "$0"; exit 1
fi

REPO="$1"
NAME="$2"
QUANT_PATTERN="${3:-q4_k_m}"

TARGET="$IMPORT_ROOT/$NAME"
mkdir -p "$TARGET"

echo "[+] Repo:           $REPO"
echo "[+] Ollama name:    $NAME"
echo "[+] Quant pattern:  $QUANT_PATTERN"
echo "[+] Staging at:     $TARGET  (container path: /root/.ollama/import/$NAME)"

# Sanity: container must be up.
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "ERROR: container '$CONTAINER' is not running. Start the stack first (make up)." >&2
  exit 1
fi

# Step 1: download the repo into TARGET.
echo "[+] Downloading $REPO → $TARGET"
./hf-curl-download.sh "$REPO" "$TARGET"

# Step 2: pick the .gguf matching the quant pattern.
GGUF=$(find "$TARGET" -maxdepth 1 -type f -iname "*${QUANT_PATTERN}*.gguf" -print -quit)
if [ -z "$GGUF" ]; then
  echo "ERROR: no .gguf matching '*${QUANT_PATTERN}*.gguf' under $TARGET" >&2
  echo "       available:" >&2
  ls "$TARGET"/*.gguf 2>/dev/null >&2 || echo "       (no .gguf files at all)" >&2
  exit 1
fi
GGUF_BASENAME="$(basename "$GGUF")"
echo "[+] Selected:       $GGUF_BASENAME"

# Step 3: minimal Modelfile. Ollama autodetects chat template from GGUF
# metadata for most modern models (Qwen2.5, Llama-3.x, Mistral-Nemo). If a
# specific model needs an explicit TEMPLATE / PARAMETER block, append to
# this file before re-running and pass a -m flag — or just edit by hand.
MODELFILE="$TARGET/Modelfile"
cat > "$MODELFILE" <<EOF
FROM ./$GGUF_BASENAME
EOF
echo "[+] Wrote:          $MODELFILE"

# Step 4: ollama create inside the container. /root/.ollama is bind-mounted
# from \$ARCHIVE_ROOT/models/ollama, so the import dir is visible at
# /root/.ollama/import/<name>/.
CONTAINER_MODELFILE="/root/.ollama/import/$NAME/Modelfile"
echo "[+] docker exec $CONTAINER ollama create $NAME -f $CONTAINER_MODELFILE"
docker exec "$CONTAINER" ollama create "$NAME" -f "$CONTAINER_MODELFILE"

# Step 5: verify.
echo "[+] Verifying..."
docker exec "$CONTAINER" ollama list | awk -v n="$NAME" 'NR==1 || $1==n'

# Step 6: cleanup prompt.
echo
read -rp "Delete staging dir $TARGET (Ollama has its own copy now)? [y/N] " ans
case "${ans:-N}" in
  y|Y|yes|YES)
    rm -rf "$TARGET"
    echo "[+] removed staging."
    ;;
  *)
    echo "[+] kept staging at $TARGET — re-importing won't re-download."
    ;;
esac

echo
echo "Try it: docker exec -it $CONTAINER ollama run $NAME 'say hi'"
