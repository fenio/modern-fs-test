# shellcheck shell=bash
# ext4 baselines on the classic stack — single | md-raid10 | lvm-raid10.
# The single layout is the "what does any of this cost" anchor. Snapshots
# come from LVM in the lvm layout; no compression, no reflink.

source "$SCRIPT_DIR/lib/layered.sh"

FS_REFLINK=0

fs_setup() {
  layered_make_dev
  mkfs.ext4 -Fq "$LAYERED_DEV"
  mount -o noatime "$LAYERED_DEV" "$MNT"
  mkdir -p "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() { layered_snapshot "$@"; }
fs_snapshot_delete_all() { layered_snapshot_delete_all "$@"; }
fs_free_bytes() { layered_free_bytes; }
fs_setup_compression() { return 1; }
fs_compress_ratio() { echo null; }
fs_degrade() { layered_degrade; }
fs_rebuild() { layered_rebuild; }
fs_scrub() { layered_scrub; }
fs_teardown() { layered_teardown; }
fs_version() { mke2fs -V 2>&1 | head -1; }
