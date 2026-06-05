#!/usr/bin/env bash
# setup-storage.sh — provision /data/active (SSD) and /archive (HDD) layout
# for z620-a4000-srv. Dry-run by default; pass --apply to actually do it.
#
# Assumptions (verify before --apply):
#   * SSD = 250 GB, OS installed on it. /var/lib/docker already lives on /.
#   * HDD = 1 TB, currently unmounted or empty.
#   * You know which /dev/sdX is the HDD (we'll prompt to confirm).
#
# What it does:
#   1. Creates dir /data/active (on SSD, just under /) with subdirs.
#   2. mkfs.ext4 on the chosen HDD device (CONFIRMS FIRST), labels it ARCHIVE,
#      adds an fstab entry by LABEL, and mounts at /archive.
#   3. Creates /archive subtree (models/{hf-cache,local,ollama}, backups).
#   4. Chowns everything to the current user.
#
# What it does NOT do:
#   * LVM (single-disk box, not worth the complexity here — see dgx-spark-srv
#     for the LVM/quota pattern if this box ever needs to grow).
#   * Swap setup (do `sudo fallocate -l 16G /swapfile` etc. manually if needed).
#   * Move /var/lib/docker (stays on / — Docker images and SSD root coexist).

set -euo pipefail

APPLY=0
HDD_DEV=""
ACTIVE_ROOT="${ACTIVE_ROOT:-/data/active}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/archive}"

usage() {
  cat <<EOF
Usage: $0 [--apply] [--hdd /dev/sdX]

  --apply       Actually make changes (default: print plan only).
  --hdd DEV     HDD block device to format for /archive.
                If omitted, you'll be prompted (with lsblk to help).
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --hdd)   HDD_DEV="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1"; usage ;;
  esac
  shift
done

say() { echo "[setup-storage] $*"; }
do_cmd() {
  if [ "$APPLY" -eq 1 ]; then
    say "+ $*"
    eval "$@"
  else
    say "(dry-run) $*"
  fi
}

# ---- 1. SSD active root --------------------------------------------------
say "step 1/3: create active root on SSD at $ACTIVE_ROOT"
do_cmd "sudo mkdir -p $ACTIVE_ROOT/models/local"
do_cmd "sudo mkdir -p $ACTIVE_ROOT/srv/data"
do_cmd "sudo chown -R $(id -u):$(id -g) $ACTIVE_ROOT"

# ---- 2. HDD: format + mount /archive -------------------------------------
if [ -z "$HDD_DEV" ]; then
  say "step 2/3: HDD device not given — listing block devices:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
  echo
  read -rp "Enter HDD device for /archive (e.g. /dev/sdb): " HDD_DEV
fi

if [ ! -b "$HDD_DEV" ]; then
  echo "ERROR: $HDD_DEV is not a block device. Aborting."
  exit 2
fi

# Sanity: don't reformat something already mounted.
if mount | grep -q "^$HDD_DEV"; then
  echo "ERROR: $HDD_DEV is already mounted. Unmount first or pick a different device."
  exit 2
fi
# Sanity: don't reformat something with an existing filesystem unless --force-fs is set.
EXISTING_FS=$(sudo blkid -o value -s TYPE "$HDD_DEV" 2>/dev/null || true)
if [ -n "$EXISTING_FS" ]; then
  echo "WARNING: $HDD_DEV already has a $EXISTING_FS filesystem."
  if [ "$APPLY" -eq 1 ]; then
    read -rp "Type 'WIPE' to mkfs.ext4 over it: " CONFIRM
    [ "$CONFIRM" = "WIPE" ] || { echo "Aborted."; exit 2; }
  fi
fi

say "step 2/3: format $HDD_DEV as ext4 (label=ARCHIVE) and mount at $ARCHIVE_ROOT"
do_cmd "sudo mkfs.ext4 -F -L ARCHIVE $HDD_DEV"
do_cmd "sudo mkdir -p $ARCHIVE_ROOT"

# fstab by LABEL — survives device-name shuffles.
FSTAB_LINE="LABEL=ARCHIVE  $ARCHIVE_ROOT  ext4  defaults,nofail  0 2"
if [ "$APPLY" -eq 1 ]; then
  if ! grep -qF "LABEL=ARCHIVE" /etc/fstab; then
    say "+ adding fstab entry: $FSTAB_LINE"
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo mount "$ARCHIVE_ROOT" || true
else
  say "(dry-run) would add to /etc/fstab: $FSTAB_LINE"
  say "(dry-run) would: sudo mount $ARCHIVE_ROOT"
fi

# ---- 3. Archive subtree --------------------------------------------------
say "step 3/3: create archive subtree under $ARCHIVE_ROOT"
do_cmd "sudo mkdir -p $ARCHIVE_ROOT/models/{hf-cache,local,ollama}"
do_cmd "sudo mkdir -p $ARCHIVE_ROOT/backups"
do_cmd "sudo chown -R $(id -u):$(id -g) $ARCHIVE_ROOT"

if [ "$APPLY" -eq 0 ]; then
  echo
  say "DRY-RUN COMPLETE. Re-run with --apply to make changes."
else
  echo
  say "DONE. Verify:"
  say "  df -h $ACTIVE_ROOT $ARCHIVE_ROOT"
  say "  ls -la $ARCHIVE_ROOT/models"
fi
