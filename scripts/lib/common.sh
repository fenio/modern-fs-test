# shellcheck shell=bash
# Shared helpers for the benchmark scripts. Sourced, not executed.
#
# Device layer: by default the suite creates NDEV loop devices backed by
# sparse files (CI mode). Set BENCH_DEVICES="/dev/sdb /dev/sdc ..." to run
# on real block devices instead — the same benchmarks run unchanged.
# Real devices are WIPED (mkfs); the suite refuses to touch them unless
# they are unmounted and either blank or BENCH_WIPE=1 is set.

set -euo pipefail

DISK_DIR=${DISK_DIR:-/mnt/fsbench-disks}
MNT=${MNT:-/mnt/fsbench}
NDEV=${NDEV:-4}
DEV_SIZE=${DEV_SIZE:-8G}
RESULTS_DIR=${RESULTS_DIR:-$PWD/results}
AGING_ITERS=${AGING_ITERS:-8}

# Workload sizes — kept modest so 4 x 8G loop devices with 2-copy
# redundancy never fill up. Scale these up on real hardware.
SEQ_SIZE=${SEQ_SIZE:-2G}
READ_SIZE=${READ_SIZE:-2G}
AGING_SIZE=${AGING_SIZE:-2G}
AGING_IO=${AGING_IO:-256M}
COMP_SIZE=${COMP_SIZE:-2G}
RUNTIME=${RUNTIME:-30}

DEVICES=()
LOOPS_CREATED=0

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (mounts, mkfs, losetup)"
}

now_ms() { date +%s%3N; }

drop_caches() {
  sync
  echo 3 > /proc/sys/vm/drop_caches
}

# Populate DEVICES[] — real devices from BENCH_DEVICES, or loop devices.
setup_devices() {
  if [ -n "${BENCH_DEVICES:-}" ]; then
    read -ra DEVICES <<< "$BENCH_DEVICES"
    log "using real devices: ${DEVICES[*]}"
    local dev
    for dev in "${DEVICES[@]}"; do
      [ -b "$dev" ] || die "$dev is not a block device"
      if grep -q "^$dev " /proc/mounts || lsblk -no MOUNTPOINTS "$dev" | grep -q .; then
        die "$dev (or a partition on it) is mounted — refusing"
      fi
      if [ "${BENCH_WIPE:-0}" != 1 ] && blkid -p "$dev" >/dev/null 2>&1; then
        die "$dev contains a filesystem/signature — set BENCH_WIPE=1 to allow wiping it"
      fi
    done
  else
    log "creating $NDEV loop devices of $DEV_SIZE in $DISK_DIR"
    mkdir -p "$DISK_DIR"
    LOOPS_CREATED=1
    local i img dev
    for i in $(seq 0 $((NDEV - 1))); do
      img="$DISK_DIR/dev$i.img"
      rm -f "$img"
      truncate -s "$DEV_SIZE" "$img"
      dev=$(losetup --find --show "$img")
      DEVICES+=("$dev")
    done
    log "loop devices: ${DEVICES[*]}"
  fi
  mkdir -p "$MNT"
}

teardown_devices() {
  fs_teardown || true
  if [ "$LOOPS_CREATED" = 1 ]; then
    local dev
    for dev in "${DEVICES[@]}"; do
      losetup -d "$dev" 2>/dev/null || true
    done
    rm -rf "$DISK_DIR"
  fi
}

# fio_json <name> <fio args...> — run fio, store JSON output, print its path.
fio_json() {
  local name=$1; shift
  local out="$RESULTS_DIR/raw/$BENCH_ID-$name.json"
  fio --output-format=json --output="$out" --name="$name" "$@" >/dev/null
  echo "$out"
}
