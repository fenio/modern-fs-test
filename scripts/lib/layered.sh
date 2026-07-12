# shellcheck shell=bash
# Shared md/LVM layering for classic filesystems (ext4, xfs).
# Layouts: single | md-raid10 (mdadm) | lvm-raid10 (LVM, CoW snapshots).

VG=fsbench

# Assemble the block device for the current LAYOUT and print its path.
# Tool chatter goes to stderr so callers can command-substitute.
layered_make_dev() {
  case "${LAYOUT:-single}" in
    single)
      echo "${DEVICES[0]}"
      ;;
    md-*)
      # --assume-clean: skip the initial resync, which would otherwise
      # compete with the benchmark for IO
      mdadm --create /dev/md/fsbench --run --level=10 \
        --raid-devices="${#DEVICES[@]}" --assume-clean "${DEVICES[@]}" >&2
      echo /dev/md/fsbench
      ;;
    lvm-*)
      # Each PV is wrapped in a dm-linear target so the degraded phase can
      # simulate a disk failure by swapping one wrapper to dm-error — the
      # same technique the lvm2 test suite uses (loop detach doesn't work:
      # LVM holds the device open).
      local i sz
      LVM_PVS=()
      for i in "${!DEVICES[@]}"; do
        sz=$(blockdev --getsz "${DEVICES[i]}")
        dmsetup create "fsbench-pv$i" --table "0 $sz linear ${DEVICES[i]} 0" >&2
        LVM_PVS+=("/dev/mapper/fsbench-pv$i")
      done
      pvcreate -y "${LVM_PVS[@]}" >&2
      vgcreate "$VG" "${LVM_PVS[@]}" >&2
      # 50%FREE leaves VG space for the CoW snapshots taken while aging;
      # --nosync skips the initial mirror sync (same reason as md above)
      lvcreate --type raid10 -i $(( ${#DEVICES[@]} / 2 )) -m 1 --nosync \
        -l 50%FREE -n bench -y "$VG" >&2
      echo "/dev/$VG/bench"
      ;;
    *)
      die "unknown layout: $LAYOUT"
      ;;
  esac
}

layered_snapshot() {
  case "${LAYOUT:-single}" in
    lvm-*) lvcreate -s -L 2G -n "$1" -y "$VG/bench" >/dev/null ;;
    *) return 1 ;;
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
        [ "${p%%.*}" = 100 ] && return 0
        sleep 2
      done
      log "lvm raid sync did not finish within 10min"
      return 1
      ;;
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
        [ -e "$d" ] && dmsetup remove "${d##*/}" 2>/dev/null || true
      done
      ;;
  esac
}
