# shellcheck shell=bash
# XFS baselines on the classic stack — single | md-raid10 | lvm-raid10.
# Unlike ext4, XFS has reflink (on by default in mkfs.xfs), so it joins the
# CoW filesystems in that column. Snapshots come from LVM in the lvm layout.

source "$SCRIPT_DIR/lib/layered.sh"

FS_REFLINK=1

fs_setup() {
  layered_make_dev
  mkfs.xfs -fq "$LAYERED_DEV"
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
fs_version() { mkfs.xfs -V 2>&1 | head -1; }
