#!/usr/bin/env bash
# Install Claude Code managed settings on a Linux / WSL developer machine so
# EVERY user's Claude Code sessions (a) export usage telemetry to the collector
# and (b) — unless --monitor-only — are limited to the model allowlist in
# managed-settings.json.
#
# Run as root ON THE DEVELOPER MACHINE, from this directory:
#   sudo ./install-managed-settings.sh [--monitor-only] <collector-ip-or-host> [team-name]
#
#   --monitor-only   telemetry only; do NOT install the model allowlist (and
#                    REMOVE one if a previous run installed it). Use for the
#                    baseline phase — see CLAUDE-CODE-TELEMETRY.md "Migrating
#                    existing users". Re-run without the flag to enforce.
#
# Managed settings live in /etc/claude-code/managed-settings.json (Linux and
# WSL). They take precedence over every user's ~/.claude/settings.json, so a
# user cannot redirect/disable the export or pick a model outside the list.
# Existing keys in an existing file are preserved; ours are merged on top.
# Re-running is safe and is how you change modes. Windows PCs: use
# Install-ManagedSettings.ps1 instead.
set -euo pipefail

MONITOR_ONLY=0
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --monitor-only) MONITOR_ONLY=1; shift ;;
    *) echo "unknown flag: $1"; exit 1 ;;
  esac
done
COLLECTOR="${1:?usage: $0 [--monitor-only] <collector-ip-or-host> [team-name]}"
TEAM="${2:-apex}"
SRC="$(cd "$(dirname "$0")" && pwd)/managed-settings.json"
# CLAUDE_MANAGED_DIR overrides the target dir (testing only; skips the root
# check and the system-wide grant-tool/cron install).
DST_DIR="${CLAUDE_MANAGED_DIR:-/etc/claude-code}"
DST="$DST_DIR/managed-settings.json"
SYSTEM_INSTALL=$([[ -z "${CLAUDE_MANAGED_DIR:-}" ]] && echo 1 || echo 0)

[[ $SYSTEM_INSTALL -eq 0 || $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

if [[ -e "$DST" ]]; then
  cp -a "$DST" "$DST.bak.$(date +%F-%H%M%S)"
  echo "existing $DST backed up"
fi

mkdir -p "$DST_DIR/managed-settings.d"
python3 - "$SRC" "$DST" "$COLLECTOR" "$TEAM" "$(hostname -s)" "$MONITOR_ONLY" <<'PY'
import json, sys
src, dst, collector, team, host, monitor_only = sys.argv[1:]
MODEL_KEYS = ("availableModels", "enforceAvailableModels")
new = json.load(open(src))
new["env"]["OTEL_EXPORTER_OTLP_ENDPOINT"] = f"http://{collector}:4317"
new["env"]["OTEL_RESOURCE_ATTRIBUTES"] = f"host.name={host},team={team}"
try:
    cur = json.load(open(dst))
except Exception:
    cur = {}
cur.setdefault("env", {}).update(new.pop("env"))
if monitor_only == "1":
    for k in MODEL_KEYS:
        new.pop(k, None); cur.pop(k, None)
cur.update(new)
json.dump(cur, open(dst, "w"), indent=2); open(dst, "a").write("\n")
mode = "MONITOR-ONLY (no model allowlist)" if monitor_only == "1" else f"telemetry + model allowlist {cur.get('availableModels')}"
print(f"mode: {mode}")
PY
chmod 644 "$DST"

if [[ $SYSTEM_INSTALL -eq 1 ]]; then
  # Time-boxed model grants (see CLAUDE-CODE-TELEMETRY.md "Case-by-case access").
  install -m 755 "$(dirname "$SRC")/claude-model-grant" /usr/local/sbin/claude-model-grant
  cat > /etc/cron.d/claude-model-grants <<'CRON'
# Expire Claude Code model grants (managed-settings.d/50-grant-*.json). Installed
# by install-managed-settings.sh; safe to leave in place with no grants active.
*/5 * * * * root /usr/local/sbin/claude-model-grant sweep >> /var/log/claude-model-grants.log 2>&1
CRON
  chmod 644 /etc/cron.d/claude-model-grants
  echo "installed /usr/local/sbin/claude-model-grant + /etc/cron.d/claude-model-grants (expiry sweeper)"
  if ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
    echo
    echo "  WARNING: cron is not running, so model grants would never expire."
    if grep -qi microsoft /proc/version 2>/dev/null; then
      echo "  This is WSL — cron is off by default. Fix: sudo service cron start"
      echo "  Persist: sudo systemctl enable cron   (systemd WSL)  or  [boot] command=\"service cron start\" in /etc/wsl.conf"
    else
      echo "  Fix: sudo systemctl enable --now cron"
    fi
  fi
fi

echo "installed $DST:"; cat "$DST"; echo
echo "Reachability check (from this machine):"
if timeout 3 bash -c "</dev/tcp/$COLLECTOR/4317" 2>/dev/null; then
  echo "  OK  — $COLLECTOR:4317 accepts connections"
else
  echo "  FAIL — cannot reach $COLLECTOR:4317. Is the claude-usage stack up and the port open (ufw)?"
fi
echo
echo "Users pick this up on their NEXT claude session (no reboot). Verify inside claude with /status and /model."
