#!/usr/bin/env bash
# download-models.sh — bulk HF model pre-download via `hf` CLI.
# Falls back to `hf-curl-download.sh` automatically if hf CLI not installed.
#
# Usage:
#   ./download-models.sh                              # use VLLM_MODEL + TEI_MODEL + TEI_RERANKER_MODEL
#   ./download-models.sh Qwen/Qwen2.5-7B-Instruct-AWQ
#   ./download-models.sh -f models.txt                # one repo-id per line, # comments OK
#
# Targets:
#   * HF repo IDs (Org/Name)  → cached under $ARCHIVE_ROOT/models/hf-cache
#   * Bare-name targets (no /) → flat dir at $ARCHIVE_ROOT/models/local/<name>
#     (these go through hf-curl-download.sh so vLLM can load by name)

set -uo pipefail

ARCHIVE_ROOT="${ARCHIVE_ROOT:-/archive}"
HF_CACHE="$ARCHIVE_ROOT/models/hf-cache"
LOCAL_DIR="$ARCHIVE_ROOT/models/local"
LOG="$HOME/hf-download.log"

# Load .env defaults.
if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

mkdir -p "$HF_CACHE" "$LOCAL_DIR"

MODELS=()
LIST_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) LIST_FILE="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) MODELS+=("$1") ;;
  esac
  shift
done

if [ -n "$LIST_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -n "$line" ] && MODELS+=("$line")
  done < "$LIST_FILE"
fi

if [ "${#MODELS[@]}" -eq 0 ]; then
  # Default: pull VLLM_MODEL + TEI_MODEL + TEI_RERANKER_MODEL.
  [ -n "${VLLM_MODEL:-}" ]          && MODELS+=("${VLLM_MODEL}")
  [ -n "${TEI_MODEL:-}" ]           && MODELS+=("${TEI_MODEL}")
  [ -n "${TEI_RERANKER_MODEL:-}" ]  && MODELS+=("${TEI_RERANKER_MODEL}")
fi

if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "ERROR: no models given and none in .env (VLLM_MODEL / TEI_MODEL / TEI_RERANKER_MODEL)." >&2
  exit 1
fi

HF_CLI=""
command -v hf >/dev/null 2>&1 && HF_CLI="hf"

echo "[$(date -Iseconds)] === download-models begin ===" | tee -a "$LOG"
echo "[+] HF cache:  $HF_CACHE"
echo "[+] Local dir: $LOCAL_DIR"
echo "[+] CLI:       ${HF_CLI:-(not installed — using curl fallback)}"
echo "[+] Targets:   ${MODELS[*]}"

OVERALL=0
for m in "${MODELS[@]}"; do
  if [[ "$m" == */* ]]; then
    # Repo ID → cache via HF CLI (if available) else curl fallback.
    rc=1
    if [ -n "$HF_CLI" ]; then
      echo "[$(date -Iseconds)] hf download $m → $HF_CACHE"
      for try in 1 2 3; do
        HF_HOME="$HF_CACHE" HF_TOKEN="${HF_TOKEN:-}" \
          "$HF_CLI" download "$m" 2>&1 | tee -a "$LOG"
        rc=${PIPESTATUS[0]}
        [ "$rc" -eq 0 ] && break
        echo "  retry $try/3 in 10s..." | tee -a "$LOG"
        sleep 10
      done
    fi
    if [ "$rc" -ne 0 ]; then
      # hf CLI missing or all retries failed — fall through to single-curl path.
      echo "[$(date -Iseconds)] hf CLI path failed (rc=$rc) — trying hf-curl-download.sh" | tee -a "$LOG"
      ./hf-curl-download.sh "$m" "$LOCAL_DIR/$(basename "$m")" 2>&1 | tee -a "$LOG"
      rc=${PIPESTATUS[0]}
    fi
  else
    # Bare name → curl flat-dir under $LOCAL_DIR/<name>.
    # Resolve owner from a default-mapping or require Org/Name; we accept
    # bare-name only when it matches a default we know about.
    case "$m" in
      Qwen2.5-7B-Instruct-AWQ)        repo="Qwen/Qwen2.5-7B-Instruct-AWQ" ;;
      Qwen2.5-14B-Instruct-AWQ)       repo="Qwen/Qwen2.5-14B-Instruct-AWQ" ;;
      Qwen3-8B-AWQ)                   repo="Qwen/Qwen3-8B-AWQ" ;;
      Mistral-7B-Instruct-v0.3-AWQ)   repo="solidrust/Mistral-7B-Instruct-v0.3-AWQ" ;;
      Meta-Llama-3.1-8B-Instruct-AWQ) repo="hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4" ;;
      bge-m3)                         repo="BAAI/bge-m3" ;;
      bge-large-en-v1.5)              repo="BAAI/bge-large-en-v1.5" ;;
      bge-reranker-large)             repo="BAAI/bge-reranker-large" ;;
      mxbai-rerank-large-v1)          repo="mixedbread-ai/mxbai-rerank-large-v1" ;;
      *)
        echo "ERROR: bare name '$m' has no default repo mapping — pass full Org/Name." >&2
        OVERALL=1
        continue
        ;;
    esac
    ./hf-curl-download.sh "$repo" "$LOCAL_DIR/$m" 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
  fi
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: $m failed (rc=$rc)" | tee -a "$LOG"
    OVERALL=1
  fi
done

echo "[$(date -Iseconds)] === download-models end (rc=$OVERALL) ===" | tee -a "$LOG"
exit "$OVERALL"
