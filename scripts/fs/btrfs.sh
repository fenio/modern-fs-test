# shellcheck shell=bash
# btrfs backend. Layout: raid1 data + metadata across all devices.

FS_REFLINK=1

fs_setup() {
  local profile=${LAYOUT:-raid1}
  if [ "$profile" = single ]; then
    mkfs.btrfs -f "${DEVICES[0]}"
  else
    mkfs.btrfs -f -d "$profile" -m "$profile" "${DEVICES[@]}"
  fi
  mount -o noatime "${DEVICES[0]}" "$MNT"
  btrfs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  btrfs subvolume snapshot -r "$DATA" "$MNT/$1" >/dev/null
}

fs_setup_compression() {
  btrfs subvolume create "$1" >/dev/null
  btrfs property set "$1" compression zstd
}

fs_compress_ratio() {
  # compsize TOTAL line: "TOTAL  43%  900M  2.0G  2.0G" — perc = disk/uncompressed
  local perc
  perc=$(compsize "$1" 2>/dev/null | awk '/^TOTAL/ {gsub("%","",$2); print $2}')
  if [ -n "$perc" ] && [ "$perc" -gt 0 ]; then
    awk "BEGIN{printf \"%.2f\", 100/$perc}"
  else
    echo null
  fi
}

fs_teardown() {
  umount "$MNT" 2>/dev/null || true
}
