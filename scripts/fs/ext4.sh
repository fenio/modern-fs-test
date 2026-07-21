# shellcheck shell=bash
# ext4 baselines on the classic stack — single | md-raid10 | lvm-raid10.
# The single layout is the "what does any of this cost" anchor. Snapshots
# come from LVM in the lvm layout; no compression, no reflink.

# shellcheck source=../lib/layered.sh
source "$SCRIPT_DIR/lib/layered.sh"

# shellcheck disable=SC2034  # consumed by run-bench.sh
FS_REFLINK=0

fs_setup() {
  layered_make_dev
  case "${LAYOUT:-single}" in
    *-luks)
      # the classic-stack way: assemble the raid FIRST, encrypt ONCE on
      # top — one dm-crypt layer total, vs one per device for btrfs
      luks_wrap_top "$LAYERED_DEV"
      LAYERED_DEV=$LUKS_TOP_DEV
      ;;
  esac
  mkfs.ext4 -Fq "$LAYERED_DEV"
  mount -t ext4 -o noatime "$LAYERED_DEV" "$MNT"
  mkdir -p "$MNT/data"
  # shellcheck disable=SC2034  # consumed by run-bench.sh
  DATA="$MNT/data"
}

fs_snapshot() { layered_snapshot "$@"; }
fs_snapshot_delete_all() { layered_snapshot_delete_all "$@"; }
fs_remount() { layered_remount; }
fs_snap_list() { layered_snap_list; }
fs_snapscale_delete() { layered_snapscale_delete "$@"; }
fs_free_bytes() { layered_free_bytes; }
fs_setup_compression() { return 1; }
fs_compress_ratio() { echo null; }
fs_degrade() { layered_degrade; }
fs_rebuild() { layered_rebuild; }
fs_scrub() { layered_scrub; }
fs_teardown() {
  umount "$MNT" 2>/dev/null || true
  luks_close_all
  layered_teardown
}
fs_version() { mke2fs -V 2>&1 | head -1; }
