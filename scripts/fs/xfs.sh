# shellcheck shell=bash
# XFS baselines on the classic stack — single | md-raid10 | lvm-raid10.
# Unlike ext4, XFS has reflink (on by default in mkfs.xfs), so it joins the
# CoW filesystems in that column. Snapshots come from LVM in the lvm layout.

source "$SCRIPT_DIR/lib/layered.sh"

FS_REFLINK=1

ZPOOL=fsbench

fs_setup() {
  if [ "${LAYOUT:-single}" = zvol ]; then
    # The Franken-stack people actually run: XFS semantics on top, ZFS
    # snapshots/self-healing/compression underneath. Pool topology
    # matches zfs/mirror (striped mirror pairs) for comparability.
    modprobe zfs
    zpool create -f -O mountpoint=none -o ashift=12 "$ZPOOL" \
      mirror "${DEVICES[0]}" "${DEVICES[1]}" \
      mirror "${DEVICES[2]}" "${DEVICES[3]}"
    # 75% of the pool: leaves room for snapshot divergence, and scales
    # down for the ENOSPC phase's small rebuild (a fixed size would hit
    # pool-exhaustion EIO instead of clean filesystem ENOSPC). The default
    # refreservation=volsize makes the first snapshot fail once pre-aging
    # writes consume the remaining pool headroom.
    local avail
    avail=$(zfs get -Hp -o value available "$ZPOOL")
    zfs create -V "$(( avail * 3 / 4 ))" -o volblocksize=16k \
      -o refreservation=none "$ZPOOL/zvol"
    udevadm settle 2>/dev/null || sleep 2
    mkfs.xfs -fq "/dev/zvol/$ZPOOL/zvol"
    mount -o noatime "/dev/zvol/$ZPOOL/zvol" "$MNT"
    mkdir -p "$MNT/data"
    DATA="$MNT/data"
    return 0
  fi
  layered_make_dev
  mkfs.xfs -fq "$LAYERED_DEV"
  mount -o noatime "$LAYERED_DEV" "$MNT"
  mkdir -p "$MNT/data"
  DATA="$MNT/data"
}

zvol_case() { [ "${LAYOUT:-single}" = zvol ]; }

# ZFS-backed hooks for the zvol layout: snapshots are zvol snapshots
# (fsfreeze makes them XFS-consistent), scrub/degraded/rebuild are pool
# operations, free space and compression live at the pool layer.
fs_snapshot() {
  if zvol_case; then
    fsfreeze -f "$MNT"
    local rc=0
    zfs snapshot "$ZPOOL/zvol@$1" || rc=1
    fsfreeze -u "$MNT"
    return $rc
  fi
  layered_snapshot "$@"
}

fs_snapshot_delete_all() {
  if zvol_case; then
    zfs destroy "$ZPOOL/zvol@snap1%snap$1"
    return
  fi
  layered_snapshot_delete_all "$@"
}

fs_snapscale_delete() {
  if zvol_case; then
    zfs destroy "$ZPOOL/zvol@scale1%scale$1"
    return
  fi
  layered_snapscale_delete "$@"
}

fs_remount() {
  if zvol_case; then
    umount "$MNT"
    mount -o noatime "/dev/zvol/$ZPOOL/zvol" "$MNT"
    return
  fi
  layered_remount
}

fs_snap_list() {
  if zvol_case; then
    zfs list -t snapshot >/dev/null
    return
  fi
  layered_snap_list
}

fs_free_bytes() {
  if zvol_case; then
    zfs get -Hp -o value available "$ZPOOL"
    return
  fi
  layered_free_bytes
}

fs_setup_compression() {
  if zvol_case; then
    # compression happens at the pool layer, under XFS
    zfs set compression=zstd "$ZPOOL/zvol"
    mkdir -p "$1"
    return
  fi
  return 1
}

fs_compress_ratio() {
  if zvol_case; then
    # cumulative for the zvol: dominated by the compressible write since
    # compression was off for everything before it (documented caveat)
    zfs get -H -o value compressratio "$ZPOOL/zvol" | tr -d 'x'
    return
  fi
  echo null
}

fs_degrade() {
  if zvol_case; then
    zpool offline "$ZPOOL" "${DEVICES[1]}"
    return
  fi
  layered_degrade
}

fs_rebuild() {
  if zvol_case; then
    zpool replace "$ZPOOL" "${DEVICES[1]}" "$SPARE_DEV"
    zpool wait -t resilver "$ZPOOL"
    return
  fi
  layered_rebuild
}

fs_scrub() {
  if zvol_case; then
    zpool scrub "$ZPOOL"
    zpool wait -t scrub "$ZPOOL"
    local status found
    status=$(zpool status -p "$ZPOOL")
    echo "$status" >&2
    found=$(awk '$1 ~ /^loop|^\/dev/ && NF >= 5 {s += $5} END {print s+0}' <<<"$status")
    if grep -q 'with 0 errors' <<<"$status"; then
      echo "$found $found"
    else
      echo "$found null"
    fi
    return
  fi
  layered_scrub
}

fs_drop_caches() {
  if zvol_case; then
    # ARC underneath: export/import like the zfs backend (unmount XFS first)
    umount "$MNT"
    zpool export "$ZPOOL"
    drop_caches
    local args=() d
    for d in "${DEVICES[@]}"; do args+=(-d "$d"); done
    zpool import "${args[@]}" "$ZPOOL"
    udevadm settle 2>/dev/null || sleep 2
    mount -o noatime "/dev/zvol/$ZPOOL/zvol" "$MNT"
    return
  fi
  drop_caches
}

fs_teardown() {
  if zvol_case; then
    umount "$MNT" 2>/dev/null || true
    zpool destroy -f "$ZPOOL" 2>/dev/null || true
    return
  fi
  layered_teardown
}

fs_version() {
  if zvol_case; then
    echo "$(mkfs.xfs -V 2>&1 | head -1) on $(zfs version 2>/dev/null | head -1)"
    return
  fi
  mkfs.xfs -V 2>&1 | head -1
}
