# shellcheck shell=bash
# ext4 baseline. Single device, no snapshots, no compression, no reflink.
# Exists so the CoW filesystems have a "what does the machinery cost" anchor.

FS_REFLINK=0

fs_setup() {
  mkfs.ext4 -Fq "${DEVICES[0]}"
  mount -o noatime "${DEVICES[0]}" "$MNT"
  mkdir -p "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() { return 1; }
fs_setup_compression() { return 1; }
fs_compress_ratio() { echo null; }

fs_teardown() {
  umount "$MNT" 2>/dev/null || true
}
