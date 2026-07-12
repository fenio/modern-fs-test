# shellcheck shell=bash
# ZFS backend. Layout "mirror": striped mirror pairs (raid10-like) —
# devices are paired in order, so pass an even number of devices.

FS_REFLINK=0  # block cloning exists in 2.2+ but is off by default; revisit
POOL=fsbench

fs_setup() {
  modprobe zfs
  local vdevs=() i
  for ((i = 0; i < ${#DEVICES[@]}; i += 2)); do
    if [ -n "${DEVICES[i+1]:-}" ]; then
      vdevs+=(mirror "${DEVICES[i]}" "${DEVICES[i+1]}")
    else
      vdevs+=("${DEVICES[i]}")
    fi
  done
  zpool create -f -O mountpoint="$MNT" -O compression=off -O atime=off \
    "$POOL" "${vdevs[@]}"
  zfs create "$POOL/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  zfs snapshot "$POOL/data@$1"
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
