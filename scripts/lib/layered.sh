# shellcheck shell=bash
# Shared md/LVM layering for classic filesystems (ext4, xfs).
# Layouts: single | md-raid10 (mdadm) | lvm-raid10 (LVM, CoW snapshots).

VG=fsbench

# Assemble the block device for the current LAYOUT and set LAYERED_DEV.
# Must run in the caller's shell, NOT in a $(…) subshell: the lvm layout
# exports LVM_SYSTEM_DIR, which every later LVM command needs.
layered_make_dev() {
  case "${LAYOUT:-single}" in
    single)
      LAYERED_DEV=${DEVICES[0]}
      ;;
    md-*)
      # level from the layout name (md-raid10 -> 10, md-raid6 -> 6);
      # --assume-clean skips the initial resync, which would otherwise
      # compete with the benchmark for IO
      local level=${LAYOUT#md-raid}; level=${level%%-*}
      mdadm --create /dev/md/fsbench --run --level="$level" \
        --raid-devices="${#DEVICES[@]}" --assume-clean "${DEVICES[@]}"
      LAYERED_DEV=/dev/md/fsbench
      ;;
    lvm-*)
      modprobe dm_raid
      modprobe dm_snapshot
      case "$LAYOUT" in *-int) modprobe dm_integrity ;; esac
      # Each PV is wrapped in a dm-linear target so the degraded phase can
      # simulate a disk failure by swapping one wrapper to dm-error — the
      # same technique the lvm2 test suite uses (loop detach doesn't work:
      # LVM holds the device open).
      #
      # LVM sees the same PV signature through both the wrapper and its
      # backing loop and rejects them as duplicates — scope scanning to
      # the wrappers (and the spare, for vgextend during rebuild) via a
      # private LVM_SYSTEM_DIR so the system config stays untouched.
      export LVM_SYSTEM_DIR="$DISK_DIR/lvm"
      mkdir -p "$LVM_SYSTEM_DIR"
      cat > "$LVM_SYSTEM_DIR/lvm.conf" <<EOF
devices {
  global_filter = [ "a|^/dev/mapper/fsbench-pv|", "a|^${SPARE_DEV:-/nonexistent}\$|", "r|.*|" ]
  use_devicesfile = 0
}
EOF
      local i sz
      LVM_PVS=()
      for i in "${!DEVICES[@]}"; do
        sz=$(blockdev --getsz "${DEVICES[i]}")
        dmsetup create "fsbench-pv$i" --table "0 $sz linear ${DEVICES[i]} 0"
        LVM_PVS+=("/dev/mapper/fsbench-pv$i")
      done
      pvcreate -y "${LVM_PVS[@]}"
      vgcreate "$VG" "${LVM_PVS[@]}"
      # 50%FREE leaves VG space for the CoW snapshots taken while aging;
      # --nosync skips the initial mirror sync (same reason as md above).
      # -int layouts add dm-integrity under each raid leg: per-sector
      # checksums give the classic stack detection AND correction — the
      # fairest comparison against CoW checksumming (community request).
      local integrity=()
      case "$LAYOUT" in *-int) integrity=(--raidintegrity y) ;; esac
      lvcreate --type raid10 -i $(( ${#DEVICES[@]} / 2 )) -m 1 --nosync \
        "${integrity[@]}" -l 50%FREE -n bench -y "$VG"
      # shellcheck disable=SC2034  # consumed by filesystem backends
      LAYERED_DEV="/dev/$VG/bench"
      ;;
    *)
      die "unknown layout: $LAYOUT"
      ;;
  esac
}

layered_snapshot() {
  case "${LAYOUT:-single}" in
    lvm-*) lvcreate -s -L "${LVM_SNAP_SIZE:-2G}" -n "$1" -y "$VG/bench" >/dev/null ;;
    *) return 1 ;;
  esac
}

layered_remount() {
  case "${LAYOUT:-single}" in
    lvm-*)
      umount "$MNT"
      mount -t "$FS" -o noatime "/dev/$VG/bench" "$MNT"
      ;;
    *) return 1 ;;
  esac
}

layered_snap_list() {
  case "${LAYOUT:-single}" in
    lvm-*) lvs "$VG" >/dev/null ;;
    *) return 1 ;;
  esac
}

layered_snapscale_delete() {
  case "${LAYOUT:-single}" in
    lvm-*)
      local i
      for i in $(seq 1 "$1"); do
        lvremove -fy "$VG/scale$i" >/dev/null 2>&1 || true
      done
      ;;
    *) return 1 ;;
  esac
}

layered_snapshot_delete_all() {
  case "${LAYOUT:-single}" in
    lvm-*)
      local i
      for i in $(seq 1 "$1"); do
        lvremove -fy "$VG/snap$i" >&2
      done
      ;;
    *) return 1 ;;
  esac
}

# LVM snapshots live in the VG, not in filesystem free space — reclaim
# is measured against VG free bytes for the lvm layouts.
layered_free_bytes() {
  case "${LAYOUT:-single}" in
    lvm-*) vgs --noheadings --units b --nosuffix -o vg_free "$VG" | tr -d ' ' | cut -d. -f1 ;;
    *) df -B1 --output=avail "$MNT" | tail -1 | tr -d ' ' ;;
  esac
}

layered_degrade() {
  case "${LAYOUT:-single}" in
    md-*)
      mdadm --fail /dev/md/fsbench "${DEVICES[1]}"
      mdadm --remove /dev/md/fsbench "${DEVICES[1]}"
      ;;
    lvm-*)
      # Old-style snapshots with extents on the failing PV would just be
      # invalidated and complicate the repair — drop them first.
      local s
      for s in $(lvs --noheadings -o lv_name "$VG" 2>/dev/null | tr -d ' ' | grep -vx bench); do
        lvremove -fy "$VG/$s" >&2 || true
      done
      # Swap one PV wrapper to dm-error: every IO to it now fails and the
      # raid10 LV runs degraded from the first write.
      local sz
      sz=$(blockdev --getsz /dev/mapper/fsbench-pv1)
      dmsetup suspend fsbench-pv1
      dmsetup reload fsbench-pv1 --table "0 $sz error"
      dmsetup resume fsbench-pv1
      ;;
    *) return 1 ;;  # single: nothing to degrade
  esac
}

layered_rebuild() {
  case "${LAYOUT:-single}" in
    md-*)
      mdadm --add /dev/md/fsbench "$SPARE_DEV"
      mdadm --wait /dev/md/fsbench || true
      ;;
    lvm-*)
      vgextend -y "$VG" "$SPARE_DEV" >&2
      lvconvert --repair -y "$VG/bench" >&2
      # --repair returns before the new leg is synced; poll until done
      local i p
      for i in $(seq 1 300); do
        p=$(lvs --noheadings -o sync_percent "$VG/bench" 2>/dev/null | tr -d ' ')
        if [ "${p%%.*}" = 100 ]; then
          layered_rebuild_lvm_cleanup
          return 0
        fi
        sleep 2
      done
      log "lvm raid sync did not finish within 10min"
      return 1
      ;;
  esac
}

# Drop the failed PV from the VG once repair is done — a VG carrying a
# dead PV makes lvchange --syncaction check silently no-op (scrub_s was
# 0 with zero mismatches for six runs after the phase reorder).
layered_rebuild_lvm_cleanup() {
  vgreduce --removemissing --force "$VG" >&2 || true
}

# "Scrub" for the classic stack: a raid check counts sectors that differ
# between mirror legs, but with no checksums it cannot know which leg is
# right — repaired is always 0, and reads may serve the corrupted copy.
layered_scrub() {
  case "${LAYOUT:-single}" in
    md-*)
      local md
      md=$(readlink -f /dev/md/fsbench)
      md=${md##*/}
      echo check > "/sys/block/$md/md/sync_action"
      mdadm --wait /dev/md/fsbench >&2 || true
      echo "$(cat "/sys/block/$md/md/mismatch_cnt") 0"
      ;;
    lvm-*)
      lvchange --syncaction check "$VG/bench" >&2
      local i act
      for i in $(seq 1 300); do
        act=$(lvs --noheadings -o raid_sync_action "$VG/bench" 2>/dev/null | tr -d ' ')
        [ "$act" = idle ] && break
        sleep 2
      done
      echo "$(lvs --noheadings -o raid_mismatch_count "$VG/bench" | tr -d ' ') 0"
      ;;
    *) return 1 ;;
  esac
}

layered_teardown() {
  umount "$MNT" 2>/dev/null || true
  case "${LAYOUT:-single}" in
    md-*)
      mdadm --stop /dev/md/fsbench 2>/dev/null || true
      mdadm --zero-superblock "${DEVICES[@]}" 2>/dev/null || true
      ;;
    lvm-*)
      vgremove -fy "$VG" 2>/dev/null || true
      local d
      for d in /dev/mapper/fsbench-pv*; do
        if [ -e "$d" ]; then
          dmsetup remove "${d##*/}" 2>/dev/null || true
        fi
      done
      ;;
  esac
}
