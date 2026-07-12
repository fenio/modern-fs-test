# shellcheck shell=bash
# bcachefs backend. Layout "replicas2": --replicas=2 across all devices.
# Experimental: the runner kernel may lack bcachefs support entirely.

FS_REFLINK=1

fs_setup() {
  modprobe bcachefs 2>/dev/null || true
  grep -qw bcachefs /proc/filesystems \
    || die "kernel has no bcachefs support (needs DKMS or a custom kernel)"
  bcachefs format -f --replicas=2 "${DEVICES[@]}"
  local devlist
  devlist=$(IFS=:; echo "${DEVICES[*]}")
  mount -t bcachefs "$devlist" "$MNT"
  bcachefs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  bcachefs subvolume snapshot "$DATA" "$MNT/$1" >/dev/null
}

fs_setup_compression() {
  mkdir -p "$1"
  bcachefs setattr --compression=zstd "$1"
}

fs_compress_ratio() {
  # Approximation: apparent size vs allocated blocks (st_blocks tracks
  # compressed allocation on bcachefs)
  local apparent actual
  apparent=$(du -sb --apparent-size "$1" | cut -f1)
  actual=$(du -sB1 "$1" | cut -f1)
  if [ "${actual:-0}" -gt 0 ]; then
    awk "BEGIN{printf \"%.2f\", $apparent/$actual}"
  else
    echo null
  fi
}

fs_teardown() {
  umount "$MNT" 2>/dev/null || true
}
