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
ALL_LOOPS=()
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

# Wrap every device in DEVICES with LUKS2/dm-crypt (one layer PER DEVICE —
# what a multi-device filesystem must pay for layered encryption). Mapper
# names derive from the device basename so re-invocations (ENOSPC phase)
# don't collide. Closed in teardown_devices.
luks_wrap_devices() {
  local keyfile="$DISK_DIR/luks.key" i dev name
  [ -f "$keyfile" ] || dd if=/dev/urandom of="$keyfile" bs=64 count=1 status=none
  for i in "${!DEVICES[@]}"; do
    dev=${DEVICES[i]}
    name="fsbench-luks-${dev##*/}"
    cryptsetup luksFormat -q --type luks2 --key-file "$keyfile" "$dev"
    cryptsetup open --key-file "$keyfile" "$dev" "$name"
    DEVICES[i]="/dev/mapper/$name"
  done
}

# Single LUKS layer on top of an assembled array (the classic-stack way:
# raid first, encrypt once). Prints nothing; sets LUKS_TOP_DEV.
luks_wrap_top() {
  local keyfile="$DISK_DIR/luks.key" name="fsbench-luks-${1##*/}"
  [ -f "$keyfile" ] || dd if=/dev/urandom of="$keyfile" bs=64 count=1 status=none
  cryptsetup luksFormat -q --type luks2 --key-file "$keyfile" "$1"
  cryptsetup open --key-file "$keyfile" "$1" "$name"
  # shellcheck disable=SC2034  # consumed by layered filesystem backends
  LUKS_TOP_DEV="/dev/mapper/$name"
}

luks_close_all() {
  local m
  for m in /dev/mapper/fsbench-luks-*; do
    if [ -e "$m" ]; then
      cryptsetup close "${m##*/}" 2>/dev/null || true
    fi
  done
}

# Overwrite a region of a block device with random bytes (corruption
# injection). Not dd: uutils dd (Ubuntu 26.04 coreutils) returns spurious
# ENOSPC when seeking on dm devices.
corrupt_device() {  # <device> <offset-bytes> <length-bytes>
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.lseek(fd, int(sys.argv[2]), os.SEEK_SET)
left = int(sys.argv[3])
while left > 0:
    n = min(1 << 20, left)
    os.write(fd, os.urandom(n))
    left -= n
os.fsync(fd)
os.close(fd)
PY
}

# Snapshot-scaling hooks (btrfs/zfs/bcachefs override).
fs_remount() { return 1; }
fs_snap_list() { return 1; }
fs_snapscale_delete() { return 1; }  # $1 = count

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
    local i
    for i in $(seq 0 "$NDEV"); do
      make_loop "$DEV_SIZE" "dev$i"
      if [ "$i" -lt "$NDEV" ]; then
        DEVICES+=("$LOOP_DEV")
      else
        SPARE_DEV=$LOOP_DEV
      fi
    done
    log "loop devices: ${DEVICES[*]} (spare: $SPARE_DEV)"
  fi
  mkdir -p "$MNT"
}

# Create a loop device; sets LOOP_DEV (no subshell echo — appending to
# ALL_LOOPS must happen in the caller's shell).
make_loop() {
  local img="$DISK_DIR/$2.img"
  rm -f "$img"
  truncate -s "$1" "$img"
  LOOP_DEV=$(losetup --find --show "$img")
  ALL_LOOPS+=("$LOOP_DEV")
}

teardown_devices() {
  fs_teardown || true
  luks_close_all
  if [ "$LOOPS_CREATED" = 1 ]; then
    local dev
    for dev in "${ALL_LOOPS[@]}"; do
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
