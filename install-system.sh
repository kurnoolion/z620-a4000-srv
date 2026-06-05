#!/usr/bin/env bash
# install-system.sh — install Docker daemon log rotation + journald cap.
# Run as root: `sudo ./install-system.sh`.
#
# Why this exists: NGC / vLLM container images are large; default Docker logs
# grow without bound; journald with no cap can fill /var. This script:
#   1. Merges system/daemon.json into /etc/docker/daemon.json with jq
#      (PRESERVES existing NVIDIA runtime config — does not clobber).
#   2. Installs system/journald-z620.conf as a journald drop-in.
#   3. Restarts both daemons.

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: must run as root (use sudo)."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required. Install: sudo apt-get install -y jq"
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/system"

# ---- Docker daemon.json (merge, don't overwrite) -------------------------
DOCKER_CONF=/etc/docker/daemon.json
mkdir -p /etc/docker

if [ -s "$DOCKER_CONF" ]; then
  echo "[+] Merging $SRC_DIR/daemon.json into existing $DOCKER_CONF"
  # `* ` is jq's recursive merge — right-side wins on conflicts.
  TMP=$(mktemp)
  jq -s '.[0] * .[1]' "$DOCKER_CONF" "$SRC_DIR/daemon.json" > "$TMP"
  mv "$TMP" "$DOCKER_CONF"
else
  echo "[+] Creating $DOCKER_CONF from $SRC_DIR/daemon.json"
  cp "$SRC_DIR/daemon.json" "$DOCKER_CONF"
fi

chmod 644 "$DOCKER_CONF"

# ---- journald drop-in ----------------------------------------------------
JOURNAL_DROP=/etc/systemd/journald.conf.d/z620.conf
mkdir -p "$(dirname "$JOURNAL_DROP")"
echo "[+] Installing journald drop-in: $JOURNAL_DROP"
cp "$SRC_DIR/journald-z620.conf" "$JOURNAL_DROP"
chmod 644 "$JOURNAL_DROP"

# ---- Restart daemons -----------------------------------------------------
echo "[+] Restarting systemd-journald"
systemctl restart systemd-journald

echo "[+] Restarting docker (containers will pause briefly)"
systemctl restart docker

echo "DONE. Verify:"
echo "  docker info | grep -A2 'Logging Driver'"
echo "  journalctl --disk-usage"
