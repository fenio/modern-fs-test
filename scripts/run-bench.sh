#!/usr/bin/env bash
# Usage: run-bench.sh <fs> <layout>
#   fs:     ext4 | btrfs | zfs | bcachefs   (scripts/fs/<fs>.sh)
#   layout: free-form label passed to the fs backend (e.g. raid1, mirror)
#
# CI mode (default): benchmarks run on loop devices backed by sparse files.
# Real hardware:     BENCH_DEVICES="/dev/sdb /dev/sdc /dev/sdd /dev/sde" \
#                    BENCH_WIPE=1 run-bench.sh btrfs raid1
#
# Emits $RESULTS_DIR/result-<fs>-<layout>.json plus raw fio output.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"

FS=${1:?usage: run-bench.sh <fs> <layout>}
LAYOUT=${2:?usage: run-bench.sh <fs> <layout>}
BENCH_ID="$FS-$LAYOUT"

[ -f "$SCRIPT_DIR/fs/$FS.sh" ] || die "unknown filesystem: $FS"
source "$SCRIPT_DIR/fs/$FS.sh"

require_root
mkdir -p "$RESULTS_DIR/raw"

setup_devices
trap teardown_devices EXIT
fs_setup
log "$FS ($LAYOUT) mounted at $MNT, data dir $DATA"

# --- Phase 1: sequential write -------------------------------------------
log "phase: sequential write ($SEQ_SIZE)"
out=$(fio_json seqwrite --directory="$DATA" --rw=write --bs=1M \
  --size="$SEQ_SIZE" --end_fsync=1)
SEQWRITE_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")
rm -f "$DATA"/seqwrite*

# --- Phase 2: random write (fdatasync every 16 IOs) ----------------------
log "phase: random write 4k, ${RUNTIME}s"
out=$(fio_json randwrite --directory="$DATA" --rw=randwrite --bs=4k \
  --size=1G --runtime="$RUNTIME" --time_based --fdatasync=16)
RANDWRITE_IOPS=$(jq '.jobs[0].write.iops' "$out")
rm -f "$DATA"/randwrite*

# --- Phase 3: random read (cold cache) ------------------------------------
log "phase: random read 4k, ${RUNTIME}s"
fio --name=readprep --filename="$DATA/read.dat" --rw=write --bs=1M \
  --size="$READ_SIZE" --end_fsync=1 --output=/dev/null
drop_caches
out=$(fio_json randread --filename="$DATA/read.dat" --rw=randread --bs=4k \
  --size="$READ_SIZE" --runtime="$RUNTIME" --time_based)
RANDREAD_IOPS=$(jq '.jobs[0].read.iops' "$out")

# --- Phase 4: CoW aging — overwrite under a growing pile of snapshots -----
log "phase: aging, $AGING_ITERS iterations of snapshot + $AGING_IO overwrite"
fio --name=agingprep --filename="$DATA/aging.dat" --rw=write --bs=1M \
  --size="$AGING_SIZE" --end_fsync=1 --output=/dev/null
AGING_BW=()
SNAP_MS=()
SNAPSHOTS_OK=1
for i in $(seq 1 "$AGING_ITERS"); do
  if [ "$SNAPSHOTS_OK" = 1 ]; then
    t0=$(now_ms)
    if fs_snapshot "snap$i"; then
      SNAP_MS+=($(( $(now_ms) - t0 )))
    else
      SNAPSHOTS_OK=0
      log "snapshots unsupported on $FS — aging runs without them"
    fi
  fi
  out=$(fio_json "aging$i" --filename="$DATA/aging.dat" --rw=randwrite \
    --bs=4k --size="$AGING_SIZE" --io_size="$AGING_IO" --end_fsync=1)
  AGING_BW+=("$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")")
done

# --- Phase 5: compression (zstd, 75%-compressible data) -------------------
log "phase: compression"
COMP_RATIO=null
COMP_MBPS=null
if fs_setup_compression "$MNT/comp" 2>/dev/null; then
  out=$(fio_json compwrite --directory="$MNT/comp" --rw=write --bs=1M \
    --size="$COMP_SIZE" --end_fsync=1 --refill_buffers \
    --buffer_compress_percentage=75)
  COMP_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")
  sync
  COMP_RATIO=$(fs_compress_ratio "$MNT/comp")
else
  log "compression unsupported on $FS — skipping"
fi

# --- Phase 6: reflink copy -------------------------------------------------
REFLINK_MS=null
if [ "${FS_REFLINK:-0}" = 1 ]; then
  log "phase: reflink copy of $READ_SIZE file"
  t0=$(now_ms)
  if cp --reflink=always "$DATA/read.dat" "$DATA/reflink-copy"; then
    REFLINK_MS=$(( $(now_ms) - t0 ))
  fi
fi

# --- Assemble result -------------------------------------------------------
AGING_JSON=$(printf '%s\n' "${AGING_BW[@]}" | jq -s '.')
if [ "${#SNAP_MS[@]}" -gt 0 ]; then
  SNAP_AVG=$(printf '%s\n' "${SNAP_MS[@]}" | jq -s 'add / length | round')
else
  SNAP_AVG=null
fi

jq -n \
  --arg fs "$FS" \
  --arg layout "$LAYOUT" \
  --arg kernel "$(uname -r)" \
  --arg date "$(date -u +%FT%TZ)" \
  --arg devices "${BENCH_DEVICES:-loop}" \
  --argjson ndev "${#DEVICES[@]}" \
  --argjson seqwrite_mbps "$SEQWRITE_MBPS" \
  --argjson randwrite_iops "$RANDWRITE_IOPS" \
  --argjson randread_iops "$RANDREAD_IOPS" \
  --argjson aging_mbps "$AGING_JSON" \
  --argjson snapshot_create_ms "$SNAP_AVG" \
  --argjson compress_ratio "$COMP_RATIO" \
  --argjson compress_write_mbps "$COMP_MBPS" \
  --argjson reflink_ms "$REFLINK_MS" \
  '{fs: $fs, layout: $layout, kernel: $kernel, date: $date,
    devices: $devices, ndev: $ndev,
    results: {seqwrite_mbps: $seqwrite_mbps,
              randwrite_iops: $randwrite_iops,
              randread_iops: $randread_iops,
              aging_mbps: $aging_mbps,
              snapshot_create_ms: $snapshot_create_ms,
              compress_ratio: $compress_ratio,
              compress_write_mbps: $compress_write_mbps,
              reflink_ms: $reflink_ms}}' \
  > "$RESULTS_DIR/result-$BENCH_ID.json"

chmod -R a+rX "$RESULTS_DIR"
log "done: $RESULTS_DIR/result-$BENCH_ID.json"
jq . "$RESULTS_DIR/result-$BENCH_ID.json" >&2
