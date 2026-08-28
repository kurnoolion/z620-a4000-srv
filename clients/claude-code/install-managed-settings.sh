#!/usr/bin/env bash
# Install Claude Code managed settings on a Linux / WSL developer machine so
# EVERY user's Claude Code sessions (a) export usage telemetry to the z620
# collector and (b) are limited to the model allowlist in managed-settings.json.
#
# Run as root ON THE DEVELOPER MACHINE, from this directory:
#   sudo ./install-managed-settings.sh <collector-ip-or-host> [team-name]
#
# Managed settings live in /etc/claude-code/managed-settings.json (Linux and
# WSL). They take precedence over every user's ~/.claude/settings.json, so a
# user cannot redirect/disable the export or pick a model outside the list.
# Existing keys in an existing file are preserved; ours are merged on top.
# Windows PCs: use Install-ManagedSettings.ps1 instead.
set -euo pipefail

COLLECTOR="${1:?usage: $0 <collector-ip-or-host> [team-name]}"
TEAM="${2:-apex}"
SRC="$(cd "$(dirname "$0")" && pwd)/managed-settings.json"
DST_DIR=/etc/claude-code
DST="$DST_DIR/managed-settings.json"

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

if [[ -e "$DST" ]]; then
  cp -a "$DST" "$DST.bak.$(date +%F-%H%M%S)"
  echo "existing $DST backed up"
fi

mkdir -p "$DST_DIR"
python3 - "$SRC" "$DST" "$COLLECTOR" "$TEAM" "$(hostname -s)" <<'PY'
import json, sys
src, dst, collector, team, host = sys.argv[1:]
new = json.load(open(src))
new["env"]["OTEL_EXPORTER_OTLP_ENDPOINT"] = f"http://{collector}:4317"
new["env"]["OTEL_RESOURCE_ATTRIBUTES"] = f"host.name={host},team={team}"
try:
    cur = json.load(open(dst))
except Exception:
    cur = {}
cur.setdefault("env", {}).update(new.pop("env"))
cur.update(new)                     # availableModels, enforceAvailableModels, ...
json.dump(cur, open(dst, "w"), indent=2); open(dst, "a").write("\n")
PY
chmod 644 "$DST"
mkdir -p "$DST_DIR/managed-settings.d"

# Time-boxed model grants (see CLAUDE-CODE-TELEMETRY.md "Case-by-case access").
install -m 755 "$(dirname "$SRC")/claude-model-grant" /usr/local/sbin/claude-model-grant
cat > /etc/cron.d/claude-model-grants <<'CRON'
# Expire Claude Code model grants (managed-settings.d/50-grant-*.json). Installed
# by install-managed-settings.sh; safe to leave in place with no grants active.
*/5 * * * * root /usr/local/sbin/claude-model-grant sweep >> /var/log/claude-model-grants.log 2>&1
CRON
chmod 644 /etc/cron.d/claude-model-grants
echo "installed /usr/local/sbin/claude-model-grant + /etc/cron.d/claude-model-grants (expiry sweeper)"

echo "installed $DST:"; cat "$DST"; echo
echo "Reachability check (from this machine):"
if timeout 3 bash -c "</dev/tcp/$COLLECTOR/4317" 2>/dev/null; then
  echo "  OK  — $COLLECTOR:4317 accepts connections"
else
  echo "  FAIL — cannot reach $COLLECTOR:4317. Is otel-collector up on the z620 and the port open (ufw)?"
fi
echo
echo "Users pick this up on their NEXT claude session (no reboot). Verify inside claude with /status and /model."
