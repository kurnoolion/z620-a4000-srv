#!/usr/bin/env bash
# Grant / revoke / list time-boxed model access on a Linux or WSL machine,
# from your own desk over ssh (or locally when TARGET is "local").
#
#   ./grant-model.sh <user@host|local> grant  opus[,fable] [HOURS]    default 4h
#   ./grant-model.sh <user@host|local> revoke opus[,fable] | --all
#   ./grant-model.sh <user@host|local> list
#
# The target must have had install-managed-settings.sh run (which installs
# /usr/local/sbin/claude-model-grant + the expiry sweeper). You need sudo there.
# Windows PCs: use Grant-Model.ps1 on the PC instead.
set -euo pipefail
TARGET="${1:?usage: $0 <user@host|local> <grant|revoke|list> [args]}"; shift
[[ $# -ge 1 ]] || { echo "usage: $0 <user@host|local> <grant|revoke|list> [args]"; exit 1; }
if [[ "$TARGET" == "local" ]]; then
  exec sudo claude-model-grant "$@"
else
  # -t so sudo can prompt for a password if the target isn't NOPASSWD.
  exec ssh -t "$TARGET" sudo claude-model-grant "$@"
fi
