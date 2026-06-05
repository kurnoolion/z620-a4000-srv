#!/usr/bin/env bash
# health.sh — read-only PASS/WARN/FAIL health probes for z620-a4000-srv.
# Exits non-zero on any FAIL (cron-friendly).

set -uo pipefail

DISK_WARN=${DISK_WARN:-85}
GPU_TEMP_WARN=${GPU_TEMP_WARN:-80}
FAIL_COUNT=0
WARN_COUNT=0

g_green="\e[32m"; g_yellow="\e[33m"; g_red="\e[31m"; g_off="\e[0m"
pass() { echo -e "  ${g_green}PASS${g_off}  $1"; }
warn() { echo -e "  ${g_yellow}WARN${g_off}  $1"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { echo -e "  ${g_red}FAIL${g_off}  $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
sec()  { echo; echo "[$1]"; }

# Load .env without exporting (for SITE_HOST + VLLM_MODEL).
if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

sec "Containers"
for c in vllm ollama tei tei-reranker caddy; do
  state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
  if [ "$state" = "running" ]; then pass "$c: running"
  elif [ "$state" = "missing" ]; then fail "$c: container missing"
  else fail "$c: $state"
  fi
done

sec "GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi >/dev/null 2>&1; then
    pass "nvidia-smi responsive"
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits | head -1)
    if [ -n "$temp" ] && [ "$temp" -lt "$GPU_TEMP_WARN" ]; then
      pass "GPU temp ${temp}°C (warn at ${GPU_TEMP_WARN}°C)"
    else
      warn "GPU temp ${temp}°C ≥ ${GPU_TEMP_WARN}°C"
    fi
    mem=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
    pass "GPU mem ${mem} MiB"
  else
    fail "nvidia-smi not responsive"
  fi
else
  fail "nvidia-smi missing — driver/toolkit not installed?"
fi

sec "Endpoints"
host=${SITE_HOST:-localhost}
probe() {
  local name=$1 url=$2 expect=${3:-200}
  local code
  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")
  if [ "$code" = "$expect" ]; then pass "$name → $code"
  else fail "$name → $code (expected $expect, url=$url)"
  fi
}
probe "vLLM /v1/models" "http://localhost/v1/models"
probe "TEI /embed health" "http://localhost/embed/health"
probe "TEI /rerank health" "http://localhost/rerank/health"
probe "Ollama /ollama/api/tags" "http://localhost/ollama/api/tags"

sec "Disk"
for mnt in / /data/active /archive; do
  if mountpoint -q "$mnt" || [ "$mnt" = "/" ]; then
    use=$(df -P "$mnt" | awk 'NR==2{gsub("%","",$5); print $5}')
    avail=$(df -h "$mnt" | awk 'NR==2{print $4}')
    if [ "$use" -lt "$DISK_WARN" ]; then pass "$mnt: ${use}% used, ${avail} free"
    else warn "$mnt: ${use}% used (≥${DISK_WARN}%), ${avail} free"
    fi
  else
    warn "$mnt: not mounted"
  fi
done

sec "Memory"
mem_used=$(free -m | awk '/^Mem:/ {printf "%.0f", $3*100/$2}')
mem_avail=$(free -h | awk '/^Mem:/ {print $7}')
if [ "$mem_used" -lt 90 ]; then pass "RAM: ${mem_used}% used, ${mem_avail} available"
else warn "RAM: ${mem_used}% used (≥90%), only ${mem_avail} available"
fi

echo
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "${g_red}HEALTH: $FAIL_COUNT FAIL, $WARN_COUNT WARN${g_off}"
  exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
  echo -e "${g_yellow}HEALTH: $WARN_COUNT WARN${g_off}"
  exit 0
else
  echo -e "${g_green}HEALTH: OK${g_off}"
fi
