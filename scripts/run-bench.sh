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

# Full command trace (every command, with source file and line) into the
# artifacts — the readable job log keeps only the phase lines and tool
# output, while raw/<id>-trace.log answers "what exactly was run".
# BENCH_TRACE=1 mirrors the trace into the live log instead.
export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
if [ "${BENCH_TRACE:-0}" = 1 ]; then
  set -x
else
  exec {BASH_XTRACEFD}>"$RESULTS_DIR/raw/$BENCH_ID-trace.log"
  set -x
fi

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

# Calibration floor: on shared CI runners an unlucky VM (observed: ~190
# vs ~400 MB/s host disk) produces junk numbers — fail fast so the job
# can be rerun on a fresh runner instead of polluting the results.
# Disabled by default and always skipped on real hardware.
CALIB_MIN_SEQ_MBPS=${CALIB_MIN_SEQ_MBPS:-0}
CALIB_MIN_RAND_IOPS=${CALIB_MIN_RAND_IOPS:-0}
if [ -z "${BENCH_DEVICES:-}" ]; then
  if [ "${CALIB_SEQ_MBPS%.*}" -lt "$CALIB_MIN_SEQ_MBPS" ] \
     || [ "${CALIB_RAND_IOPS%.*}" -lt "$CALIB_MIN_RAND_IOPS" ]; then
    die "runner below calibration floor (seq ${CALIB_SEQ_MBPS%.*}/${CALIB_MIN_SEQ_MBPS} MB/s, rand ${CALIB_RAND_IOPS%.*}/${CALIB_MIN_RAND_IOPS} IOPS) — rerun on a fresh runner"
  fi
fi

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
# fsync tail latency — CoW transaction commits (ZFS txg, btrfs commit
# interval) show up as periodic spikes that the IOPS average hides
FSYNC_P99_MS=$(jq '(.jobs[0].sync.lat_ns.percentile."99.000000" // null) | if . then . / 1000000 else null end' "$out")
FSYNC_P999_MS=$(jq '(.jobs[0].sync.lat_ns.percentile."99.900000" // null) | if . then . / 1000000 else null end' "$out")
rm -f "$DATA"/randwrite*
# 4-thread variant: filesystem locking architecture only shows under
# concurrency (bcachefs author's request) — 4 threads = the runner's
# 4 vCPUs, each with its own file
out=$(fio_json randwrite-par --directory="$DATA" --rw=randwrite --bs=4k \
  --size=256M --runtime="$RUNTIME" --time_based --fdatasync=16 \
  --numjobs=4 --group_reporting)
RANDWRITE4_IOPS=$(jq '.jobs[0].write.iops' "$out")
rm -f "$DATA"/randwrite-par*

# --- Phase 3: random read (cold cache) ------------------------------------
log "phase: random read 4k, ${RUNTIME}s"
fio --name=readprep --filename="$DATA/read.dat" --rw=write --bs=1M \
  --size="$READ_SIZE" --end_fsync=1 --output=/dev/null
fs_drop_caches
# single pass over distinct blocks (fio's random map forbids repeats):
# a time-based run loops back over cached blocks and blends cold reads
# with page-cache hits — observed 4.7x run-to-run swings
out=$(fio_json randread --filename="$DATA/read.dat" --rw=randread --bs=4k \
  --size="$READ_SIZE" --io_size=512M)
RANDREAD_IOPS=$(jq '.jobs[0].read.iops' "$out")
# Parallel readers: a mirror can only serve reads from both copies when
# there IS concurrency — a single dependent-read stream can't show it.
# (On CI loop devices there's still just one physical disk underneath;
# this measurement earns its keep on real hardware.)
fs_drop_caches
out=$(fio_json randread-par --filename="$DATA/read.dat" --rw=randread --bs=4k \
  --size="$READ_SIZE" --io_size=128M --numjobs=4 --group_reporting)
RANDREAD4_IOPS=$(jq '.jobs[0].read.iops' "$out")

# --- Phase 3.4: sequential read (cold cache) --------------------------------
fs_drop_caches
# one pass over the whole file — a time-based loop re-reads cached
# blocks and reports RAM speed (same flaw the random reads had)
out=$(fio_json seqread --filename="$DATA/read.dat" --rw=read --bs=1M \
  --size="$READ_SIZE")
SEQREAD_MBPS=$(jq '.jobs[0].read.bw_bytes / 1048576' "$out")

# --- Phase 3.5: trivial-op latency, idle vs under streaming write -----------
# "How long until my prompt comes back": a tiny 4k write+fsync every
# 200ms (shell history, editor swap file), measured alone and then while
# a 1M streaming writer floods the filesystem. CoW commit storms show up
# here as multi-second worst cases that averages never reveal.
log "phase: trivial-op latency, idle then under streaming write"
out=$(fio_json lat-idle --directory="$DATA" --rw=write --bs=4k --size=4k \
  --time_based --runtime=10 --fsync=1 --thinktime=200000)
LAT_IDLE_P99=$(jq '(.jobs[0].sync.lat_ns.percentile."99.000000" // null) | if . then . / 1000000 else null end' "$out")
out=$(fio_json lat-load --directory="$DATA" --rw=write --bs=1M --size="${LOAD_STREAM_SIZE:-8G}" \
  --time_based --runtime=30 \
  --name=tiny --directory="$DATA" --rw=write --bs=4k --size=4k \
  --time_based --runtime=30 --fsync=1 --thinktime=200000)
LAT_LOAD_P99=$(jq '([.jobs[] | select(.jobname == "tiny")][0].sync.lat_ns.percentile."99.000000" // null) | if . then . / 1000000 else null end' "$out")
LAT_LOAD_MAX=$(jq '([.jobs[] | select(.jobname == "tiny")][0].sync.lat_ns.max // null) | if . then . / 1000000 else null end' "$out")
# ops completed vs the ~145 the 200ms cadence allows: a starvation ratio
# immune to fio's log-histogram binning, meaningful even when individual
# ops take seconds and the percentile has almost no samples
LAT_LOAD_OPS=$(jq '[.jobs[] | select(.jobname == "tiny")][0].write.total_ios // null' "$out")
# a percentile from a handful of samples is void, and fio's log-histogram
# bins make it a bucket-edge constant (17112.76...) or even p99 > max —
# below 20 completed ops the ops count IS the measurement
if [ "$LAT_LOAD_OPS" != null ] && [ "$LAT_LOAD_OPS" -lt 20 ]; then
  LAT_LOAD_P99=null
fi
rm -f "$DATA"/lat-idle* "$DATA"/lat-load* "$DATA"/tiny*
log "trivial-op p99: idle ${LAT_IDLE_P99%.*}ms, under load ${LAT_LOAD_P99%.*}ms (worst ${LAT_LOAD_MAX%.*}ms)"

# --- Phase 3.6: source-tree ops (20k small files) ----------------------------
# The "cp -r a kernel tree" test: 20k files of 1-8k across 200 dirs.
log "phase: source-tree ops (20k small files)"
t0=$(now_ms)
python3 - "$DATA/tree" <<'PY'
import os, random, sys
random.seed(42)
base = sys.argv[1]
for i in range(20000):
    d = os.path.join(base, "d%d" % ((i % 200) // 20), "d%d" % (i % 200))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "f%d" % i), "wb") as f:
        f.write(os.urandom(random.choice((1024, 2048, 4096, 8192))))
PY
sync
SMALLTREE_CREATE_MS=$(( $(now_ms) - t0 ))
# parallel variant: 4 workers, disjoint directory subsets — metadata
# lock contention (tree locks vs per-AG allocation vs b-tree design)
t0=$(now_ms)
python3 - "$DATA/tree4" <<'PY'
import multiprocessing, os, random, sys
base = sys.argv[1]
def worker(w):
    rnd = random.Random(1000 + w)
    for i in range(5000):
        n = w * 5000 + i
        d = os.path.join(base, "d%d" % ((n % 200) // 20), "d%d" % (n % 200))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "f%d" % n), "wb") as f:
            f.write(os.urandom(rnd.choice((1024, 2048, 4096, 8192))))
# fork context: 3.14 defaults to forkserver, which cannot re-import a
# heredoc __main__ and kills the workers
with multiprocessing.get_context("fork").Pool(4) as p:
    p.map(worker, range(4))
PY
sync
SMALLTREE_CREATE4_MS=$(( $(now_ms) - t0 ))
rm -rf "$DATA/tree4"
fs_drop_caches || true
t0=$(now_ms)
cp -r "$DATA/tree" "$DATA/tree2"
sync
SMALLTREE_CP_MS=$(( $(now_ms) - t0 ))
t0=$(now_ms)
rm -rf "$DATA/tree2"
sync
SMALLTREE_RM_MS=$(( $(now_ms) - t0 ))
rm -rf "$DATA/tree"
log "source tree: create ${SMALLTREE_CREATE_MS}ms, cp -r ${SMALLTREE_CP_MS}ms, rm -rf ${SMALLTREE_RM_MS}ms"

# --- Phase 3.7: sparse file ops (ftruncate) ---------------------------------
# Community request: is sparse actually sparse, and what does growing a
# file cost? (a) ftruncate an empty file to 1GiB — time + allocated
# bytes; (b) double a written 256MiB file — time + allocation delta.
log "phase: sparse file ops (ftruncate)"
SPARSE_JSON=$(python3 - "$DATA" <<'PY'
import json, os, sys, time
base = sys.argv[1]
def blocks(p):
    os.sync()
    return os.stat(p).st_blocks * 512
r = {}
p1 = os.path.join(base, "sparse1.dat")
fd = os.open(p1, os.O_WRONLY | os.O_CREAT)
t = time.perf_counter()
os.ftruncate(fd, 1 << 30)
os.fsync(fd)
r["sparse_create_ms"] = round((time.perf_counter() - t) * 1000, 3)
os.close(fd)
r["sparse_create_bytes"] = blocks(p1)
p2 = os.path.join(base, "sparse2.dat")
with open(p2, "wb") as f:
    for _ in range(256):
        f.write(os.urandom(1 << 20))
    f.flush()
    os.fsync(f.fileno())
before = blocks(p2)
fd = os.open(p2, os.O_WRONLY)
t = time.perf_counter()
os.ftruncate(fd, 512 << 20)
os.fsync(fd)
r["sparse_grow_ms"] = round((time.perf_counter() - t) * 1000, 3)
os.close(fd)
r["sparse_grow_bytes"] = max(0, blocks(p2) - before)
os.remove(p1)
os.remove(p2)
print(json.dumps(r))
PY
)
SPARSE_CREATE_MS=$(jq '.sparse_create_ms' <<<"$SPARSE_JSON")
SPARSE_CREATE_BYTES=$(jq '.sparse_create_bytes' <<<"$SPARSE_JSON")
SPARSE_GROW_MS=$(jq '.sparse_grow_ms' <<<"$SPARSE_JSON")
SPARSE_GROW_BYTES=$(jq '.sparse_grow_bytes' <<<"$SPARSE_JSON")
log "sparse: 1G create ${SPARSE_CREATE_MS}ms/${SPARSE_CREATE_BYTES}B allocated, grow 256M->512M ${SPARSE_GROW_MS}ms/+${SPARSE_GROW_BYTES}B"

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

# --- Phase 5.5: snapshot-count scaling --------------------------------------
# How do snapshot operations behave at 500 snapshots (no data churn between
# them — this isolates metadata scaling from retention cost)? Native-snapshot
# filesystems only; dm-snapshot can't survive triple digits by design.
SNAPSCALE_N=null
SNAPSCALE_CREATE_MS=null
SNAPSCALE_TOTAL_S=null
SNAPSCALE_LIST_MS=null
SNAPSCALE_REMOUNT_MS=null
SNAPSCALE_DELETE_MS=null
# native-snapshot filesystems, plus LVM: with no churn between snapshots
# there's no CoW amplification during creation, so dm-snapshot can
# genuinely attempt 500 small snapshots — and wherever it stops,
# snapscale_count records how far the classic stack got.
if [[ "$FS" =~ ^(btrfs|zfs|bcachefs)$ || "$LAYOUT" == lvm-* ]]; then
  LVM_SNAP_SIZE=24M  # snapshots must fit the VG's free half
  SNAPSCALE_N=${SNAPSCALE_COUNT:-500}
  if [[ "$LAYOUT" == lvm-* ]] && [ "$SNAPSCALE_N" -gt 150 ]; then
    # old-style snapshot cost grows with count (each create suspends an
    # origin carrying every prior snapshot) — 500 would take ~25min of
    # creates; 150 shows the curve within the job's time budget
    SNAPSCALE_N=150
  fi
  log "phase: snapshot-count scaling ($SNAPSCALE_N snapshots)"
  t0=$(now_ms)
  TAIL_MS=()
  for i in $(seq 1 "$SNAPSCALE_N"); do
    ts=$(now_ms)
    if ! fs_snapshot "scale$i"; then
      log "snapshot $i failed — stopping at $((i-1))"
      SNAPSCALE_N=$((i-1))
      break
    fi
    if [ "$i" -gt $(( SNAPSCALE_N - 20 )) ]; then
      TAIL_MS+=($(( $(now_ms) - ts )))
    fi
  done
  SNAPSCALE_TOTAL_S=$(( ($(now_ms) - t0) / 1000 ))
  if [ "${#TAIL_MS[@]}" -gt 0 ]; then
    SNAPSCALE_CREATE_MS=$(printf '%s\n' "${TAIL_MS[@]}" | jq -s 'sort | .[length/2|floor]')
  fi
  if fs_snap_list; then
    t0=$(now_ms); fs_snap_list; SNAPSCALE_LIST_MS=$(( $(now_ms) - t0 ))
  fi
  t0=$(now_ms)
  if fs_remount; then
    SNAPSCALE_REMOUNT_MS=$(( $(now_ms) - t0 ))
  fi
  # a failed remount must not let later phases silently benchmark the
  # bare mountpoint directory on the runner's root filesystem
  mountpoint -q "$MNT" || die "filesystem lost after remount attempt"
  t0=$(now_ms)
  if [ "$SNAPSCALE_N" -gt 0 ] && fs_snapscale_delete "$SNAPSCALE_N"; then
    SNAPSCALE_DELETE_MS=$(( $(now_ms) - t0 ))
  fi
  log "snapscale: $SNAPSCALE_N snaps in ${SNAPSCALE_TOTAL_S}s, create@tail ${SNAPSCALE_CREATE_MS}ms, list ${SNAPSCALE_LIST_MS}ms, remount ${SNAPSCALE_REMOUNT_MS}ms, delete ${SNAPSCALE_DELETE_MS}ms"
  LVM_SNAP_SIZE=2G  # aging/divergence snapshots go back to full size
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

# --- Phase 6: reflink + clone divergence ------------------------------------
# The unshare penalty: overwriting a block that a reflink clone or a
# snapshot still shares forces the filesystem to break the sharing.
# Same 4k-overwrite workload three ways — plain file (baseline), fresh
# reflink clone, freshly-snapshotted file. XFS participates via reflink,
# LVM via its snapshots: integrated vs classic on both axes.
REFLINK_MS=null
REFLINK_FIEMAP_SHARED=null
DIV_PLAIN_MBPS=null
DIV_CLONE_MBPS=null
DIV_SNAP_MBPS=null
log "phase: reflink + clone divergence"
fio --name=plainprep --filename="$DATA/plain.dat" --rw=write --bs=1M \
  --size="$READ_SIZE" --end_fsync=1 --output=/dev/null
out=$(fio_json div-plain --filename="$DATA/plain.dat" --rw=randwrite \
  --bs=4k --size="$READ_SIZE" --io_size=128M --end_fsync=1)
DIV_PLAIN_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")
if [ "${FS_REFLINK:-0}" = 1 ]; then
  t0=$(now_ms)
  if cp --reflink=always "$DATA/read.dat" "$DATA/reflink-copy"; then
    REFLINK_MS=$(( $(now_ms) - t0 ))
    # deep-feature check: does FIEMAP actually report the extents as
    # shared? (checked before the clone-overwrite unshares them)
    if filefrag -v "$DATA/reflink-copy" 2>/dev/null | grep -qw shared; then
      REFLINK_FIEMAP_SHARED=true
    else
      REFLINK_FIEMAP_SHARED=false
    fi
    out=$(fio_json div-clone --filename="$DATA/reflink-copy" --rw=randwrite \
      --bs=4k --size="$READ_SIZE" --io_size=128M --end_fsync=1)
    DIV_CLONE_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")
  fi
fi
if [ "$SNAPSHOTS_OK" = 1 ]; then
  if fs_snapshot divsnap; then
    out=$(fio_json div-snap --filename="$DATA/plain.dat" --rw=randwrite \
      --bs=4k --size="$READ_SIZE" --io_size=128M --end_fsync=1)
    DIV_SNAP_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out")
  fi
fi
log "divergence: plain ${DIV_PLAIN_MBPS%.*}, clone ${DIV_CLONE_MBPS%.*}, after-snapshot ${DIV_SNAP_MBPS%.*} MB/s"

# --- Phase 7: degraded mode + rebuild --------------------------------------
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

# --- Phase 8: silent corruption + scrub + self-healing ---------------------
# Runs AFTER degraded+rebuild: the scrub then also validates the rebuilt
# array, and — critically — md/lvm cannot repair what their check finds,
# so nothing may run on the poisoned filesystem afterwards (the ENOSPC
# phase builds a fresh array). XFS force-shuts-down on garbage metadata
# reads, which is how the old order (corrupt, then keep benchmarking)
# died. Overwrite 2G on one device behind the filesystem's back, then
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
  corrupt_device "${DEVICES[2]}" $(( 1 << 30 )) $(( 2 << 30 ))
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

# --- Phase 9: near-full / ENOSPC -------------------------------------------
# On a FRESH small array of the same layout (filling the main 64G-raw
# arrays would exhaust the runner's own disk): throughput at 95% and 99%
# full, then fill to ENOSPC and answer the CoW question — can you still
# delete at 100%, and does deleting actually get you writable space back?
# Loop-device mode only; skipped on real hardware.
NEARFULL95_MBPS=null
NEARFULL99_MBPS=null
NEARFULL95_PCT=null
NEARFULL99_PCT=null
ENOSPC_DELETE_OK=null
ENOSPC_RECOVER_OK=null

enospc_free() { df -B1 --output=avail "$MNT" | tail -1 | tr -d ' '; }
enospc_pct() {  # actual fullness percent right now
  local size free
  size=$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')
  free=$(enospc_free)
  echo $(( 100 - free * 100 / size ))
}

enospc_fill_to() {  # $1 = stop when free <= this percent of fs size
  local size target free chunk n=${FILL_N:-0}
  size=$(df -B1 --output=size "$MNT" | tail -1 | tr -d ' ')
  target=$(( size * $1 / 100 ))
  while :; do
    free=$(enospc_free)
    [ "$free" -le "$target" ] && { FILL_N=$n; return 0; }
    chunk=$(( free / 2 / 1048576 ))
    [ "$chunk" -gt 256 ] && chunk=256
    [ "$chunk" -lt 8 ] && chunk=8
    if ! dd if=/dev/urandom of="$DATA/fill.$n" bs=1M count="$chunk" \
         conv=fsync status=none 2>/dev/null; then
      FILL_N=$n
      return 1  # ENOSPC
    fi
    n=$((n+1))
  done
}

if [ -z "${BENCH_DEVICES:-}" ]; then
  log "phase: near-full / ENOSPC (fresh 4x${ENOSPC_DEV_SIZE:-2G} $LAYOUT array)"
  fs_teardown || true
  DEVICES=()
  SPARE_DEV=
  for i in 0 1 2 3; do
    make_loop "${ENOSPC_DEV_SIZE:-2G}" "enospc$i"
    DEVICES+=("$LOOP_DEV")
  done
  if fs_setup; then
    FILL_N=0
    dd if=/dev/urandom of="$DATA/probe.dat" bs=1M count=128 conv=fsync status=none
    # probes run even if the fill hit ENOSPC early (btrfs df avail
    # overstates what's allocatable) — a ~0 result is honest data
    # btrfs can hit its allocation wall before df crosses the target
    # (1G chunk granularity on small devices) — the probe then runs AT
    # the wall; the actual fullness is recorded alongside the number
    enospc_fill_to 5 || log "hit ENOSPC before the 95% mark (df avail vs allocatable)"
    NEARFULL95_PCT=$(enospc_pct)
    out=$(fio_json nearfull95 --filename="$DATA/probe.dat" --rw=randwrite \
      --bs=4k --size=128M --io_size=64M --end_fsync=1) || true
    NEARFULL95_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out" 2>/dev/null || echo null)
    [ -n "$NEARFULL95_MBPS" ] || NEARFULL95_MBPS=null
    enospc_fill_to 1 || true
    NEARFULL99_PCT=$(enospc_pct)
    out=$(fio_json nearfull99 --filename="$DATA/probe.dat" --rw=randwrite \
      --bs=4k --size=128M --io_size=64M --end_fsync=1) || true
    NEARFULL99_MBPS=$(jq '.jobs[0].write.bw_bytes / 1048576' "$out" 2>/dev/null || echo null)
    [ -n "$NEARFULL99_MBPS" ] || NEARFULL99_MBPS=null
    enospc_fill_to 0 || true  # push to hard ENOSPC
    log "ENOSPC reached (free: $(( $(enospc_free) / 1048576 ))M) — delete test"
    FREE_AT_FULL=$(enospc_free)
    ENOSPC_DELETE_OK=false
    if rm -f "$DATA/fill.0" 2>/dev/null; then
      sync
      for i in $(seq 1 30); do
        if [ "$(enospc_free)" -gt $(( FREE_AT_FULL + 8388608 )) ]; then
          ENOSPC_DELETE_OK=true
          break
        fi
        sleep 1
      done
    fi
    ENOSPC_RECOVER_OK=false
    if dd if=/dev/urandom of="$DATA/after.dat" bs=1M count=32 \
         conv=fsync status=none 2>/dev/null; then
      ENOSPC_RECOVER_OK=true
    fi
    log "near-full: 95%=$NEARFULL95_MBPS MB/s, 99%=$NEARFULL99_MBPS MB/s, delete@full=$ENOSPC_DELETE_OK, write-after-delete=$ENOSPC_RECOVER_OK"
    fs_teardown || true
  else
    log "ENOSPC phase: small-array setup failed — skipping"
  fi
fi

# --- Assemble result -------------------------------------------------------
AGING_JSON=$(printf '%s\n' "${AGING_BW[@]}" | jq -s '.')
if [ "${#SNAP_MS[@]}" -gt 0 ]; then
  # median, not mean — VM clock steps can corrupt individual samples
  SNAP_AVG=$(printf '%s\n' "${SNAP_MS[@]}" | jq -s 'sort | .[length/2|floor]')
else
  SNAP_AVG=null
fi

RESULT_FILE="$RESULTS_DIR/result-$BENCH_ID.json"
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
  --argjson fsync_p99_ms "$FSYNC_P99_MS" \
  --argjson fsync_p999_ms "$FSYNC_P999_MS" \
  --argjson randread_iops "$RANDREAD_IOPS" \
  --argjson randread4_iops "$RANDREAD4_IOPS" \
  --argjson seqread_mbps "$SEQREAD_MBPS" \
  --argjson lat_idle_p99_ms "$LAT_IDLE_P99" \
  --argjson lat_load_p99_ms "$LAT_LOAD_P99" \
  --argjson lat_load_max_ms "$LAT_LOAD_MAX" \
  --argjson lat_load_ops "$LAT_LOAD_OPS" \
  --argjson smalltree_create_ms "$SMALLTREE_CREATE_MS" \
  --argjson smalltree_create4_ms "$SMALLTREE_CREATE4_MS" \
  --argjson randwrite4_iops "$RANDWRITE4_IOPS" \
  --argjson smalltree_cp_ms "$SMALLTREE_CP_MS" \
  --argjson smalltree_rm_ms "$SMALLTREE_RM_MS" \
  --argjson aging_mbps "$AGING_JSON" \
  --argjson snapshot_create_ms "$SNAP_AVG" \
  --argjson snapshot_delete_ms "$SNAP_DELETE_MS" \
  --argjson reclaim_s "$RECLAIM_S" \
  --argjson reclaim_write_mbps "$RECLAIM_WRITE_MBPS" \
  --argjson compress_ratio "$COMP_RATIO" \
  --argjson compress_write_mbps "$COMP_MBPS" \
  --argjson sparse_create_ms "$SPARSE_CREATE_MS" \
  --argjson sparse_create_bytes "$SPARSE_CREATE_BYTES" \
  --argjson sparse_grow_ms "$SPARSE_GROW_MS" \
  --argjson sparse_grow_bytes "$SPARSE_GROW_BYTES" \
  --argjson reflink_ms "$REFLINK_MS" \
  --argjson reflink_fiemap_shared "$REFLINK_FIEMAP_SHARED" \
  --argjson divergence_plain_mbps "$DIV_PLAIN_MBPS" \
  --argjson divergence_clone_mbps "$DIV_CLONE_MBPS" \
  --argjson divergence_snap_mbps "$DIV_SNAP_MBPS" \
  --argjson degraded_randwrite_iops "$DEG_WRITE_IOPS" \
  --argjson degraded_randread_iops "$DEG_READ_IOPS" \
  --argjson rebuild_s "$REBUILD_S" \
  --argjson snapscale_count "$SNAPSCALE_N" \
  --argjson snapscale_create_ms "$SNAPSCALE_CREATE_MS" \
  --argjson snapscale_total_s "$SNAPSCALE_TOTAL_S" \
  --argjson snapscale_list_ms "$SNAPSCALE_LIST_MS" \
  --argjson snapscale_remount_ms "$SNAPSCALE_REMOUNT_MS" \
  --argjson snapscale_delete_ms "$SNAPSCALE_DELETE_MS" \
  --argjson nearfull95_write_mbps "$NEARFULL95_MBPS" \
  --argjson nearfull99_write_mbps "$NEARFULL99_MBPS" \
  --argjson nearfull95_pct "$NEARFULL95_PCT" \
  --argjson nearfull99_pct "$NEARFULL99_PCT" \
  --argjson enospc_delete_ok "$ENOSPC_DELETE_OK" \
  --argjson enospc_recover_ok "$ENOSPC_RECOVER_OK" \
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
              fsync_p99_ms: $fsync_p99_ms,
              fsync_p999_ms: $fsync_p999_ms,
              randread_iops: $randread_iops,
              randread4_iops: $randread4_iops,
              seqread_mbps: $seqread_mbps,
              lat_idle_p99_ms: $lat_idle_p99_ms,
              lat_load_p99_ms: $lat_load_p99_ms,
              lat_load_max_ms: $lat_load_max_ms,
              lat_load_ops: $lat_load_ops,
              smalltree_create_ms: $smalltree_create_ms,
              smalltree_create4_ms: $smalltree_create4_ms,
              randwrite4_iops: $randwrite4_iops,
              smalltree_cp_ms: $smalltree_cp_ms,
              smalltree_rm_ms: $smalltree_rm_ms,
              aging_mbps: $aging_mbps,
              snapshot_create_ms: $snapshot_create_ms,
              snapshot_delete_ms: $snapshot_delete_ms,
              reclaim_s: $reclaim_s,
              reclaim_write_mbps: $reclaim_write_mbps,
              compress_ratio: $compress_ratio,
              compress_write_mbps: $compress_write_mbps,
              sparse_create_ms: $sparse_create_ms,
              sparse_create_bytes: $sparse_create_bytes,
              sparse_grow_ms: $sparse_grow_ms,
              sparse_grow_bytes: $sparse_grow_bytes,
              reflink_ms: $reflink_ms,
              reflink_fiemap_shared: $reflink_fiemap_shared,
              divergence_plain_mbps: $divergence_plain_mbps,
              divergence_clone_mbps: $divergence_clone_mbps,
              divergence_snap_mbps: $divergence_snap_mbps,
              degraded_randwrite_iops: $degraded_randwrite_iops,
              degraded_randread_iops: $degraded_randread_iops,
              rebuild_s: $rebuild_s,
              snapscale_count: $snapscale_count,
              snapscale_create_ms: $snapscale_create_ms,
              snapscale_total_s: $snapscale_total_s,
              snapscale_list_ms: $snapscale_list_ms,
              snapscale_remount_ms: $snapscale_remount_ms,
              snapscale_delete_ms: $snapscale_delete_ms,
              nearfull95_write_mbps: $nearfull95_write_mbps,
              nearfull99_write_mbps: $nearfull99_write_mbps,
              nearfull95_pct: $nearfull95_pct,
              nearfull99_pct: $nearfull99_pct,
              enospc_delete_ok: $enospc_delete_ok,
              enospc_recover_ok: $enospc_recover_ok,
              scrub_s: $scrub_s,
              scrub_found: $scrub_found,
              scrub_repaired: $scrub_repaired,
              data_intact: $data_intact}}' \
  > "$RESULT_FILE"

python3 "$SCRIPT_DIR/validate-result.py" "$RESULT_FILE"
chmod -R a+rX "$RESULTS_DIR"
log "done: $RESULT_FILE"
jq . "$RESULT_FILE" >&2
