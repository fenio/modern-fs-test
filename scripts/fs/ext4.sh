# shellcheck shell=bash
# ext4 baselines — the "classic stack" answers to multi-device CoW filesystems:
#   single      one device, no redundancy (the raw anchor)
#   md-raid10   ext4 on mdadm raid10
#   lvm-raid10  ext4 on LVM raid10; LVM CoW snapshots make the aging phase
#               comparable with native-snapshot filesystems
# No compression, no reflink on any variant.

FS_REFLINK=0
VG=fsbench

fs_setup() {
  local dev
  case "${LAYOUT:-single}" in
    single)
      dev=${DEVICES[0]}
      ;;
    md-*)
      # --assume-clean: skip the initial resync, which would otherwise
      # compete with the benchmark for IO
      mdadm --create /dev/md/fsbench --run --level=10 \
        --raid-devices="${#DEVICES[@]}" --assume-clean "${DEVICES[@]}"
      dev=/dev/md/fsbench
      ;;
    lvm-*)
      pvcreate -y "${DEVICES[@]}"
      vgcreate "$VG" "${DEVICES[@]}"
      # 50%FREE leaves VG space for the CoW snapshots taken while aging;
      # --nosync skips the initial mirror sync (same reason as md above)
      lvcreate --type raid10 -i $(( ${#DEVICES[@]} / 2 )) -m 1 --nosync \
        -l 50%FREE -n bench -y "$VG"
      dev=/dev/$VG/bench
      ;;
    *)
      die "unknown ext4 layout: $LAYOUT"
      ;;
  esac
  mkfs.ext4 -Fq "$dev"
  mount -o noatime "$dev" "$MNT"
  mkdir -p "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  case "${LAYOUT:-single}" in
    lvm-*) lvcreate -s -L 2G -n "$1" -y "$VG/bench" >/dev/null ;;
    *) return 1 ;;
  esac
}

fs_setup_compression() { return 1; }
fs_compress_ratio() { echo null; }

fs_teardown() {
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
