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
DEV_SIZE=${DEV_SIZE:-16G}
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
SPARE_DEV=
LOOPS_CREATED=0

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (mounts, mkfs, losetup)"
}

# Millisecond timestamps via the bash builtin — `date +%s%3N` returns
# nanoseconds on newer coreutils, which silently corrupted timings.
now_ms() {
  local t=${EPOCHREALTIME/,/.}
  echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))
}

drop_caches() {
  sync
  echo 3 > /proc/sys/vm/drop_caches
}

# Cold-cache barrier before read phases. Backends with their own cache
# (ZFS ARC ignores drop_caches) override this.
fs_drop_caches() {
  drop_caches
}

# Degraded-mode hooks. Backends that support failing a device override
# these; the default skips the phase.
fs_degrade() { return 1; }
fs_rebuild() { return 1; }

# Snapshot-reclaim hooks. fs_snapshot_delete_all <count> deletes the aging
# snapshots (snap1..snapN); fs_free_bytes prints reclaimable free space —
# df for filesystems, VG free space for LVM (its snapshots live outside
# the filesystem).
fs_snapshot_delete_all() { return 1; }
fs_free_bytes() {
  df -B1 --output=avail "$MNT" | tail -1 | tr -d ' '
}

# Scrub hook: run a full scrub/check to completion, print "<found> <repaired>"
# counts on stdout (fs-specific units; "null" when unparseable), diagnostics
# to stderr. Default: unsupported.
fs_scrub() { return 1; }

# Tool/module version string recorded in the result JSON. Matters most for
# out-of-tree modules (ZFS, bcachefs DKMS) where the kernel version alone
# says nothing about what was actually tested.
fs_version() { echo ""; }

# Populate DEVICES[] — real devices from BENCH_DEVICES, or loop devices.
setup_devices() {
  if [ -n "${BENCH_DEVICES:-}" ]; then
    read -ra DEVICES <<< "$BENCH_DEVICES"
    SPARE_DEV=${BENCH_SPARE_DEVICE:-}
    log "using real devices: ${DEVICES[*]}${SPARE_DEV:+ (spare: $SPARE_DEV)}"
    local dev
    for dev in "${DEVICES[@]}" ${SPARE_DEV:+"$SPARE_DEV"}; do
      [ -b "$dev" ] || die "$dev is not a block device"
      if grep -q "^$dev " /proc/mounts || lsblk -no MOUNTPOINTS "$dev" | grep -q .; then
        die "$dev (or a partition on it) is mounted — refusing"
      fi
      if [ "${BENCH_WIPE:-0}" != 1 ] && blkid -p "$dev" >/dev/null 2>&1; then
        die "$dev contains a filesystem/signature — set BENCH_WIPE=1 to allow wiping it"
      fi
    done
  else
    log "creating $NDEV loop devices of $DEV_SIZE (+1 spare) in $DISK_DIR"
    mkdir -p "$DISK_DIR"
    LOOPS_CREATED=1
    local i img dev
    for i in $(seq 0 "$NDEV"); do
      img="$DISK_DIR/dev$i.img"
      rm -f "$img"
      truncate -s "$DEV_SIZE" "$img"
      dev=$(losetup --find --show "$img")
      if [ "$i" -lt "$NDEV" ]; then
        DEVICES+=("$dev")
      else
        SPARE_DEV=$dev
      fi
    done
    log "loop devices: ${DEVICES[*]} (spare: $SPARE_DEV)"
  fi
  mkdir -p "$MNT"
}

teardown_devices() {
  fs_teardown || true
  if [ "$LOOPS_CREATED" = 1 ]; then
    local dev
    for dev in "${DEVICES[@]}" ${SPARE_DEV:+"$SPARE_DEV"}; do
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
