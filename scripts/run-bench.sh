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

# --- Phase 0: host calibration --------------------------------------------
# Same micro-workload on the runner's own disk, before any filesystem is
# created. Matrix jobs run on separate ephemeral VMs — this anchor makes
# outlier runners visible and cross-job numbers normalizable.
log "phase: host calibration"
mkdir -p "$DISK_DIR"
out=$(fio_json calib-seqwrite --directory="$DISK_DIR" --rw=write --bs=1M \
  --size=1G --end_fsync=1)
CALIB_SEQ_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")
out=$(fio_json calib-randwrite --directory="$DISK_DIR" --rw=randwrite --bs=4k \
  --size=256M --runtime=15 --time_based --fdatasync=16)
CALIB_RAND_IOPS=$(jq '.jobs[0].write.iops' "$out")
rm -f "$DISK_DIR"/calib-*.0.0
log "calibration: seq ${CALIB_SEQ_MBPS%.*} MB/s, rand ${CALIB_RAND_IOPS%.*} IOPS"

fs_setup
FS_VERSION=$(fs_version 2>/dev/null || true)
log "$FS ($LAYOUT) mounted at $MNT, data dir $DATA${FS_VERSION:+ [$FS_VERSION]}"

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
fs_drop_caches
out=$(fio_json randread --filename="$DATA/read.dat" --rw=randread --bs=4k \
  --size="$READ_SIZE" --runtime="$RUNTIME" --time_based)
RANDREAD_IOPS=$(jq '.jobs[0].read.iops' "$out")

# --- Phase 4: CoW aging — overwrite under a growing pile of snapshots -----
log "phase: aging, $AGING_ITERS iterations of snapshot + $AGING_IO overwrite"
fio --name=agingprep --filename="$DATA/aging.dat" --rw=write --bs=1M \
  --size="$AGING_SIZE" --end_fsync=1 --output=/dev/null
FREE_BEFORE_AGING=$(fs_free_bytes)
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

# --- Phase 5: snapshot delete + space reclaim ------------------------------
# Deleting snapshots is where CoW filesystems differ wildly: the delete
# call may return instantly while background cleaning (btrfs cleaner, ZFS
# async destroy) reclaims the pinned extents. Measured: delete latency,
# foreground write bandwidth during reclaim (same workload as one aging
# iteration), and time until the space is actually back.
SNAP_DELETE_MS=null
RECLAIM_S=null
RECLAIM_WRITE_MBPS=null
if [ "$SNAPSHOTS_OK" = 1 ] && [ "${#SNAP_MS[@]}" -gt 0 ]; then
  log "phase: delete $AGING_ITERS snapshots + reclaim"
  t0=$(now_ms)
  if fs_snapshot_delete_all "$AGING_ITERS"; then
    SNAP_DELETE_MS=$(( $(now_ms) - t0 ))
    out=$(fio_json reclaim-write --filename="$DATA/aging.dat" --rw=randwrite \
      --bs=4k --size="$AGING_SIZE" --io_size="$AGING_IO" --end_fsync=1)
    RECLAIM_WRITE_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")
    # 85%: post-reclaim free never quite matches pre-aging (CoW'd file
    # generations, metadata growth) — 90% missed by <1% in testing
    target=$(( FREE_BEFORE_AGING * 85 / 100 ))
    for i in $(seq 1 300); do
      if [ "$(fs_free_bytes)" -ge "$target" ]; then
        RECLAIM_S=$(( ($(now_ms) - t0) / 1000 ))
        break
      fi
      sleep 1
    done
    [ "$RECLAIM_S" = null ] \
      && log "space not back within 300s (free: $(( $(fs_free_bytes) / 1048576 ))M, target: $(( target / 1048576 ))M)"
    log "snapshot delete: ${SNAP_DELETE_MS}ms, reclaim: ${RECLAIM_S}s"
  else
    log "snapshot delete unsupported on $FS ($LAYOUT)"
  fi
fi

# --- Phase 6: compression (zstd, 75%-compressible data) -------------------
log "phase: compression"
COMP_RATIO=null
COMP_MBPS=null
if fs_setup_compression "$MNT/comp"; then
  # fallocate=none: btrfs (at least) never compresses writes into
  # preallocated extents, and fio preallocates by default
  out=$(fio_json compwrite --directory="$MNT/comp" --rw=write --bs=1M \
    --size="$COMP_SIZE" --end_fsync=1 --refill_buffers \
    --buffer_compress_percentage=75 --fallocate=none)
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

# --- Phase 7: silent corruption + scrub + self-healing ---------------------
# Overwrite 2G on one device *behind the filesystem's back*, scrub, then
# verify the test file. Checksummed CoW filesystems repair from the good
# copy; md/lvm can only count mismatches (no checksums to know which leg
# is right) and may serve corrupted data — that's the point of the test.
SCRUB_S=null
SCRUB_FOUND=null
SCRUB_REPAIRED=null
DATA_INTACT=null
if [ "$LAYOUT" != single ] && [ "${#DEVICES[@]}" -ge 3 ]; then
  log "phase: silent corruption (2G of garbage onto ${DEVICES[2]}), then scrub"
  sync
  MD5_BEFORE=$(md5sum "$DATA/read.dat" | cut -d' ' -f1)
  dd if=/dev/urandom of="${DEVICES[2]}" bs=1M seek=1024 count=2048 \
    conv=notrunc oflag=direct status=none
  drop_caches
  t0=$(now_ms)
  if counts=$(fs_scrub 2>"$RESULTS_DIR/raw/$BENCH_ID-scrub.log"); then
    SCRUB_S=$(( ($(now_ms) - t0) / 1000 ))
    SCRUB_FOUND=$(awk '{print $1}' <<<"$counts")
    SCRUB_REPAIRED=$(awk '{print $2}' <<<"$counts")
    [[ $SCRUB_FOUND =~ ^[0-9]+$ ]] || SCRUB_FOUND=null
    [[ $SCRUB_REPAIRED =~ ^[0-9]+$ ]] || SCRUB_REPAIRED=null
  else
    log "scrub unsupported on $FS ($LAYOUT)"
  fi
  fs_drop_caches || true
  if [ "$(md5sum "$DATA/read.dat" 2>/dev/null | cut -d' ' -f1)" = "$MD5_BEFORE" ]; then
    DATA_INTACT=true
  else
    DATA_INTACT=false
  fi
  log "scrub: ${SCRUB_S}s, found=$SCRUB_FOUND repaired=$SCRUB_REPAIRED data-intact=$DATA_INTACT"
fi

# --- Phase 8: degraded mode + rebuild --------------------------------------
DEG_WRITE_IOPS=null
DEG_READ_IOPS=null
REBUILD_S=null
if [ -n "$SPARE_DEV" ] && fs_degrade; then
  log "phase: degraded IO (one device failed)"
  out=$(fio_json degraded-randwrite --directory="$DATA" --rw=randwrite \
    --bs=4k --size=1G --runtime="$RUNTIME" --time_based --fdatasync=16)
  DEG_WRITE_IOPS=$(jq '.jobs[0].write.iops' "$out")
  fs_drop_caches || true
  out=$(fio_json degraded-randread --filename="$DATA/read.dat" --rw=randread \
    --bs=4k --size="$READ_SIZE" --runtime="$RUNTIME" --time_based)
  DEG_READ_IOPS=$(jq '.jobs[0].read.iops' "$out")
  log "phase: rebuild onto spare device"
  t0=$(now_ms)
  if fs_rebuild; then
    REBUILD_S=$(( ($(now_ms) - t0) / 1000 ))
    log "rebuild finished in ${REBUILD_S}s"
  else
    log "rebuild failed"
  fi
else
  log "degraded phase unsupported on $FS ($LAYOUT) — skipping"
fi

# --- Assemble result -------------------------------------------------------
AGING_JSON=$(printf '%s\n' "${AGING_BW[@]}" | jq -s '.')
if [ "${#SNAP_MS[@]}" -gt 0 ]; then
  # median, not mean — VM clock steps can corrupt individual samples
  SNAP_AVG=$(printf '%s\n' "${SNAP_MS[@]}" | jq -s 'sort | .[length/2|floor]')
else
  SNAP_AVG=null
fi

jq -n \
  --arg fs "$FS" \
  --arg layout "$LAYOUT" \
  --arg kernel "$(uname -r)" \
  --arg version "$FS_VERSION" \
  --arg date "$(date -u +%FT%TZ)" \
  --arg devices "${BENCH_DEVICES:-loop}" \
  --argjson ndev "${#DEVICES[@]}" \
  --argjson seqwrite_mbps "$SEQWRITE_MBPS" \
  --argjson randwrite_iops "$RANDWRITE_IOPS" \
  --argjson randread_iops "$RANDREAD_IOPS" \
  --argjson aging_mbps "$AGING_JSON" \
  --argjson snapshot_create_ms "$SNAP_AVG" \
  --argjson snapshot_delete_ms "$SNAP_DELETE_MS" \
  --argjson reclaim_s "$RECLAIM_S" \
  --argjson reclaim_write_mbps "$RECLAIM_WRITE_MBPS" \
  --argjson compress_ratio "$COMP_RATIO" \
  --argjson compress_write_mbps "$COMP_MBPS" \
  --argjson reflink_ms "$REFLINK_MS" \
  --argjson degraded_randwrite_iops "$DEG_WRITE_IOPS" \
  --argjson degraded_randread_iops "$DEG_READ_IOPS" \
  --argjson rebuild_s "$REBUILD_S" \
  --argjson scrub_s "$SCRUB_S" \
  --argjson scrub_found "$SCRUB_FOUND" \
  --argjson scrub_repaired "$SCRUB_REPAIRED" \
  --argjson data_intact "$DATA_INTACT" \
  --argjson calib_seqwrite_mbps "$CALIB_SEQ_MBPS" \
  --argjson calib_randwrite_iops "$CALIB_RAND_IOPS" \
  '{fs: $fs, layout: $layout, kernel: $kernel, version: $version, date: $date,
    devices: $devices, ndev: $ndev,
    calibration: {seqwrite_mbps: $calib_seqwrite_mbps,
                  randwrite_iops: $calib_randwrite_iops},
    results: {seqwrite_mbps: $seqwrite_mbps,
              randwrite_iops: $randwrite_iops,
              randread_iops: $randread_iops,
              aging_mbps: $aging_mbps,
              snapshot_create_ms: $snapshot_create_ms,
              snapshot_delete_ms: $snapshot_delete_ms,
              reclaim_s: $reclaim_s,
              reclaim_write_mbps: $reclaim_write_mbps,
              compress_ratio: $compress_ratio,
              compress_write_mbps: $compress_write_mbps,
              reflink_ms: $reflink_ms,
              degraded_randwrite_iops: $degraded_randwrite_iops,
              degraded_randread_iops: $degraded_randread_iops,
              rebuild_s: $rebuild_s,
              scrub_s: $scrub_s,
              scrub_found: $scrub_found,
              scrub_repaired: $scrub_repaired,
              data_intact: $data_intact}}' \
  > "$RESULTS_DIR/result-$BENCH_ID.json"

chmod -R a+rX "$RESULTS_DIR"
log "done: $RESULTS_DIR/result-$BENCH_ID.json"
jq . "$RESULTS_DIR/result-$BENCH_ID.json" >&2
