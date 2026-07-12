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
      pvcreate -y "${DEVICES[@]}" >&2
      vgcreate "$VG" "${DEVICES[@]}" >&2
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
    *) return 1 ;;  # single: nothing to degrade; lvm raid repair: future work
  esac
}

layered_rebuild() {
  mdadm --add /dev/md/fsbench "$SPARE_DEV"
  mdadm --wait /dev/md/fsbench || true
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
      ;;
  esac
}
