#!/usr/bin/env bash
# Install packages needed to benchmark the given filesystem (Debian/Ubuntu).
set -euo pipefail

FS=${1:?usage: install-deps.sh <ext4|btrfs|zfs|bcachefs>}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

case "$FS" in
  ext4)
    apt-get install -yqq fio jq
    ;;
  btrfs)
    apt-get install -yqq fio jq btrfs-progs btrfs-compsize
    ;;
  zfs)
    apt-get install -yqq fio jq zfsutils-linux
    modprobe zfs
    ;;
  bcachefs)
    apt-get install -yqq fio jq bcachefs-tools || \
      echo "WARNING: bcachefs-tools not installable" >&2
    modprobe bcachefs 2>/dev/null || true
    if ! grep -qw bcachefs /proc/filesystems; then
      echo "WARNING: kernel has no bcachefs support — benchmark will skip" >&2
    fi
    ;;
  *)
    echo "unknown filesystem: $FS" >&2
    exit 1
    ;;
esac
