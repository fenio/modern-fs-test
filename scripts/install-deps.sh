#!/usr/bin/env bash
# Install packages needed to benchmark the given filesystem (Debian/Ubuntu).
set -euo pipefail

FS=${1:?usage: install-deps.sh <ext4|btrfs|zfs|bcachefs>}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

case "$FS" in
  ext4)
    apt-get install -yqq fio jq mdadm lvm2
    ;;
  btrfs)
    apt-get install -yqq fio jq btrfs-progs btrfs-compsize
    ;;
  zfs)
    apt-get install -yqq fio jq zfsutils-linux
    modprobe zfs
    ;;
  bcachefs)
    # bcachefs left mainline in 6.17 — kernel module comes as DKMS from the
    # upstream apt repo (supports Ubuntu plucky+ / Debian trixie+).
    apt-get install -yqq fio jq wget build-essential dkms "linux-headers-$(uname -r)"
    install -d -m 0755 /etc/apt/keyrings
    wget -qO /etc/apt/keyrings/apt.bcachefs.org.asc https://apt.bcachefs.org/apt.bcachefs.org.asc
    chmod 0644 /etc/apt/keyrings/apt.bcachefs.org.asc
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    cat > /etc/apt/sources.list.d/apt.bcachefs.org.sources <<EOF
Types: deb
URIs: https://apt.bcachefs.org/$codename/
Suites: bcachefs-tools-release
Components: main
Signed-By: /etc/apt/keyrings/apt.bcachefs.org.asc
EOF
    apt-get update -qq
    apt-get install -yqq bcachefs-tools bcachefs-kernel-dkms
    modprobe bcachefs
    grep -qw bcachefs /proc/filesystems || {
      echo "ERROR: bcachefs module still unavailable after DKMS install" >&2
      exit 1
    }
    ;;
  *)
    echo "unknown filesystem: $FS" >&2
    exit 1
    ;;
esac
