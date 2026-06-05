#!/usr/bin/env bash
# diagnose-hf.sh — read-only collector for HF download stalls.
# Snapshots env, in-flight HF processes, TCP socket states, log tails,
# cache state, HF API connectivity probes, and auth state. Paste output
# back when triaging proxy-related download issues.

set -uo pipefail

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

ARCHIVE_ROOT="${ARCHIVE_ROOT:-/archive}"
HF_CACHE="${HF_CACHE:-$ARCHIVE_ROOT/models/hf-cache}"

hr() { echo; echo "===== $* ====="; }

hr "Host info"
uname -a
date -Iseconds
id

hr "Proxy / env"
env | grep -iE '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|HF_)' || echo "(none)"

hr "Tooling versions"
which hf huggingface-cli curl skopeo docker 2>&1 || true
hf --version 2>&1 || true
curl --version 2>&1 | head -1
skopeo --version 2>&1 || true
docker --version 2>&1 || true

hr "HF auth"
if [ -f ~/.cache/huggingface/token ]; then
  echo "Token present at ~/.cache/huggingface/token ($(wc -c < ~/.cache/huggingface/token) bytes)"
else
  echo "(no ~/.cache/huggingface/token)"
fi
[ -n "${HF_TOKEN:-}" ] && echo "HF_TOKEN set in env (${#HF_TOKEN} chars)" || echo "(HF_TOKEN not in env)"

hr "In-flight hf / curl processes"
ps -ef | grep -E '(hf|huggingface|curl)' | grep -v grep || echo "(none)"

hr "TCP sockets to huggingface.co (any CLOSE_WAIT is the smoking gun)"
ss -tn state established '( dport = :443 )' 2>/dev/null | head -20
echo "--- CLOSE_WAIT ---"
ss -tn state close-wait 2>/dev/null | head -20

hr "HF cache state ($HF_CACHE)"
if [ -d "$HF_CACHE" ]; then
  du -sh "$HF_CACHE" 2>/dev/null
  echo "Top 5 largest .incomplete (partial) blobs:"
  find "$HF_CACHE" -name '*.incomplete' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -5
  echo "Recent file activity (last 30 min):"
  find "$HF_CACHE" -type f -mmin -30 -printf '%TY-%Tm-%Td %TH:%TM\t%s\t%p\n' 2>/dev/null | head -10
else
  echo "(cache dir does not exist)"
fi

hr "HF API connectivity probes"
T=${HF_TOKEN:-$(cat ~/.cache/huggingface/token 2>/dev/null || echo "")}
H=()
[ -n "$T" ] && H=(-H "Authorization: Bearer $T")

echo "-- whoami --"
curl -s -o /tmp/_hf_whoami.json -w 'code=%{http_code} time=%{time_total}s\n' \
  "${H[@]}" --max-time 10 https://huggingface.co/api/whoami-v2 2>&1 || true

echo "-- tiny file (gpt2 config.json, ~600B) --"
curl -s -o /dev/null -w 'code=%{http_code} time=%{time_total}s size=%{size_download}B\n' \
  --max-time 15 https://huggingface.co/openai-community/gpt2/resolve/main/config.json 2>&1 || true

echo "-- 10 MB range read from a known safetensors --"
curl -s -o /dev/null -w 'code=%{http_code} time=%{time_total}s size=%{size_download}B\n' \
  --max-time 60 -r 0-10485759 \
  https://huggingface.co/openai-community/gpt2/resolve/main/model.safetensors 2>&1 || true

hr "Recent download log (last 50 lines)"
LOG=$HOME/hf-download.log
if [ -f "$LOG" ]; then tail -50 "$LOG"; else echo "(no $LOG)"; fi

hr "DONE — share this output when triaging"
