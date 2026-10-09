#!/bin/bash
# Formats the node's data disk once and mounts it at /mnt/hks-data, for app and model storage.
# The disk is /dev/hks-data (a fixed name made by the node setup). Safe to run again: it never formats twice.
set -euo pipefail

DEV="${DATA_DEV:-/dev/hks-data}"
MNT="${DATA_MNT:-/mnt/hks-data}"

if [ ! -e "$DEV" ]; then
  echo "No data disk $DEV on $(hostname). Nothing to do."
  exit 0
fi

# Never format a disk that already has something on it
if [ -z "$(blkid -o value -s TYPE "$DEV" || true)" ]; then
  if [ -n "$(lsblk -no NAME "$DEV" | sed 1d)" ] || pvs "$(readlink -f "$DEV")" >/dev/null 2>&1; then
    echo "$DEV has partitions or LVM on it. Leaving it alone."
    exit 1
  fi
  echo "Formatting $DEV"
  mkfs.ext4 -q -L hks-data "$DEV"
fi

uuid=$(blkid -o value -s UUID "$DEV")
mkdir -p "$MNT"
grep -q "UUID=$uuid" /etc/fstab || echo "UUID=$uuid $MNT ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q "$MNT" || mount "$MNT"
mkdir -p "$MNT/local-path"

df -h "$MNT" | tail -1
echo "Data disk ready on $(hostname) at $MNT."
