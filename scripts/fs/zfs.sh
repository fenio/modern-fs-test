# shellcheck shell=bash
# ZFS backend. Layout "mirror": striped mirror pairs (raid10-like) —
# devices are paired in order, so pass an even number of devices.

FS_REFLINK=0  # block cloning exists in 2.2+ but is off by default; revisit
POOL=fsbench

fs_setup() {
  modprobe zfs
  local vdevs=() i
  if [ "${LAYOUT:-mirror}" = single ]; then
    vdevs=("${DEVICES[0]}")
  else
    for ((i = 0; i < ${#DEVICES[@]}; i += 2)); do
      if [ -n "${DEVICES[i+1]:-}" ]; then
        vdevs+=(mirror "${DEVICES[i]}" "${DEVICES[i+1]}")
      else
        vdevs+=("${DEVICES[i]}")
      fi
    done
  fi
  # layout "…-8k" isolates the recordsize variable: default 128K records
  # amplify 4k random overwrites 32x (read-modify-write + snapshot pinning)
  local extra=()
  case "${LAYOUT:-mirror}" in
    *-8k) extra=(-O recordsize=8k) ;;
  esac
  zpool create -f -O mountpoint="$MNT" -O compression=off -O atime=off \
    "${extra[@]}" "$POOL" "${vdevs[@]}"
  zfs create "$POOL/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  zfs snapshot "$POOL/data@$1"
}

fs_snapshot_delete_all() {
  local i
  for i in $(seq 1 "$1"); do
    zfs destroy "$POOL/data@snap$i"
  done
}

fs_setup_compression() {
  # $1 must be a path under $MNT; create a dataset there
  zfs create -o compression=zstd "$POOL/${1##*/}"
}

fs_compress_ratio() {
  zfs get -H -o value compressratio "$POOL/${1##*/}" | tr -d 'x'
}

fs_teardown() {
  zpool destroy -f "$POOL" 2>/dev/null || true
}

fs_scrub() {
  zpool scrub "$POOL"
  zpool wait -t scrub "$POOL"
  local status found
  status=$(zpool status -p "$POOL")  # -p: exact counts, not "4.09K"
  echo "$status" >&2
  # sum the CKSUM column over member devices
  found=$(awk '$1 ~ /^loop|^\/dev|^sd|^nvme/ && NF >= 5 {s += $5} END {print s+0}' <<<"$status")
  if grep -q 'with 0 errors' <<<"$status"; then
    echo "$found $found"  # everything found was repaired
  else
    echo "$found null"
  fi
}

fs_version() {
  # "zfs-2.3.x / zfs-kmod-2.3.x" — userland and kernel module separately
  zfs version 2>/dev/null | paste -sd' / ' -
}

fs_degrade() {
  [ "${LAYOUT:-mirror}" != single ] || return 1
  zpool offline "$POOL" "${DEVICES[1]}"
}

fs_rebuild() {
  zpool replace "$POOL" "${DEVICES[1]}" "$SPARE_DEV"
  zpool wait -t resilver "$POOL"
}

# drop_caches does not touch the ARC — export/import the pool for a genuinely
# cold read cache.
fs_drop_caches() {
  zpool export "$POOL"
  drop_caches
  local args=() d
  for d in "${DEVICES[@]}"; do args+=(-d "$d"); done
  zpool import "${args[@]}" "$POOL"
}
