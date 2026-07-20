#!/usr/bin/env bash
# Reproduce an intermittent bcachefs EC device-evacuation stall on five
# disposable loop devices. No real block devices are accepted or modified.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/bcachefs-debug.sh
source "$SCRIPT_DIR/lib/bcachefs-debug.sh"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
for command in bcachefs fio losetup mount mountpoint timeout truncate umount; do
  command -v "$command" >/dev/null || die "missing command: $command"
done
grep -qw bcachefs /proc/filesystems || die "kernel has no bcachefs support"

WORK_ROOT=${WORK_ROOT:-/var/tmp}
OUTPUT_DIR=${OUTPUT_DIR:-$PWD/bcachefs-ec-evacuate-output}
DEVICE_SIZE=${DEVICE_SIZE:-16G}
SEED_SIZE=${SEED_SIZE:-7G}
CHURN_RUNTIME=${CHURN_RUNTIME:-120}
DEGRADED_RUNTIME=${DEGRADED_RUNTIME:-30}

mkdir -p "$WORK_ROOT" "$OUTPUT_DIR"
WORK_DIR=$(mktemp -d "$WORK_ROOT/bcachefs-ec-evacuate.XXXXXX")
MNT="$WORK_DIR/mnt"
DATA="$MNT/data"
mkdir -p "$MNT"
declare -a LOOPS=()

exec > >(tee -a "$OUTPUT_DIR/reproducer.log") 2>&1

cleanup() {
  set +e
  log "cleanup"
  if mountpoint -q "$MNT"; then
    timeout 30s umount "$MNT"
  fi
  if mountpoint -q "$MNT"; then
    log "mount is still busy; preserving $WORK_DIR and its loop devices"
  else
    local device
    for device in "${LOOPS[@]}"; do
      losetup -d "$device" 2>/dev/null || true
    done
    rm -rf "$WORK_DIR"
  fi
  chmod -R a+rX "$OUTPUT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

log "kernel: $(uname -r)"
log "tools: $(bcachefs version 2>/dev/null | head -1)"
log "module: $(modinfo -F version bcachefs 2>/dev/null | head -1)"
log "attempt: ${REPRO_ATTEMPT:-manual}"

for i in 0 1 2 3 4; do
  truncate -s "$DEVICE_SIZE" "$WORK_DIR/dev$i.img"
  LOOPS+=("$(losetup --find --show "$WORK_DIR/dev$i.img")")
done
log "loops: ${LOOPS[*]}"

bcachefs format -f --erasure_code --replicas=3 \
  "${LOOPS[0]}" "${LOOPS[1]}" "${LOOPS[2]}" "${LOOPS[3]}"

printf -v DEVLIST '%s:' "${LOOPS[@]:0:4}"
DEVLIST=${DEVLIST%:}
mount -t bcachefs "$DEVLIST" "$MNT"
bcachefs subvolume create "$DATA"

log "seed $SEED_SIZE of foreground data"
fio --output-format=json --output="$OUTPUT_DIR/fio-seed.json" \
  --name=seed --filename="$DATA/seed.dat" --rw=write --bs=1M \
  --size="$SEED_SIZE" --end_fsync=1

log "churn seed with 4k random writes for ${CHURN_RUNTIME}s"
fio --output-format=json --output="$OUTPUT_DIR/fio-churn.json" \
  --name=churn --filename="$DATA/seed.dat" --rw=randwrite --bs=4k \
  --size="$SEED_SIZE" --runtime="$CHURN_RUNTIME" --time_based --fdatasync=16

bcachefs_debug_dump "$OUTPUT_DIR/before-offline.txt" "$MNT" 0

log "offline ${LOOPS[1]}"
bcachefs device offline --force "${LOOPS[1]}" \
  || bcachefs device offline "${LOOPS[1]}"

log "degraded 4k random write for ${DEGRADED_RUNTIME}s"
fio --output-format=json --output="$OUTPUT_DIR/fio-degraded-write.json" \
  --name=degraded-write --directory="$DATA" --rw=randwrite --bs=4k \
  --size=1G --runtime="$DEGRADED_RUNTIME" --time_based --fdatasync=16

log "degraded 4k random read for ${DEGRADED_RUNTIME}s"
fio --output-format=json --output="$OUTPUT_DIR/fio-degraded-read.json" \
  --name=degraded-read --filename="$DATA/seed.dat" --rw=randread --bs=4k \
  --size="$SEED_SIZE" --runtime="$DEGRADED_RUNTIME" --time_based

log "online ${LOOPS[1]} and add spare ${LOOPS[4]}"
bcachefs device online "${LOOPS[1]}" || die "failed to online original device"
bcachefs device add "$MNT" "${LOOPS[4]}" || die "failed to add spare device"

log "evacuate ${LOOPS[1]}"
if bcachefs_evacuate_with_diagnostics \
     "$MNT" "${LOOPS[1]}" "$OUTPUT_DIR/evacuate"; then
  bcachefs_debug_dump "$OUTPUT_DIR/evacuate-success.txt" "$MNT" 0
  log "evacuation completed"
else
  rc=$?
  log "evacuation failed or timed out with status $rc"
  exit "$rc"
fi
