# shellcheck shell=bash
# btrfs backend. Layout: raid1 data + metadata across all devices.

FS_REFLINK=1

fs_setup() {
  local profile=${LAYOUT:-raid1}
  case "$profile" in
    *-luks)
      # btrfs has no native encryption — dm-crypt under EVERY device is
      # the only option, so replicated writes are encrypted once per copy
      profile=${profile%-luks}
      luks_wrap_devices
      ;;
  esac
  if [ "$profile" = raid6 ]; then
    # raid1c3 metadata: parity-raid metadata is strongly discouraged
    # (write hole) — this is the pairing the btrfs docs recommend
    mkfs.btrfs -f -d raid6 -m raid1c3 "${DEVICES[@]}"
    mount -o noatime "${DEVICES[0]}" "$MNT"
    btrfs subvolume create "$MNT/data"
    DATA="$MNT/data"
    return 0
  fi
  if [ "$profile" = single ]; then
    # -m single: the default DUP metadata would double metadata writes
    # vs the other single-device filesystems (thanks to the Reddit
    # reviewer who caught this)
    mkfs.btrfs -f -d single -m single "${DEVICES[0]}"
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

fs_snapshot_delete_all() {
  btrfs subvolume delete "$MNT"/snap[0-9]* >/dev/null
}

fs_setup_compression() {
  # compress-force bypasses the compressibility heuristic; the property-based
  # approach left data uncompressed on 6.17 (ratio 1.0 in CI)
  mount -o "remount,compress-force=zstd" "$MNT"
  btrfs subvolume create "$1" >/dev/null
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

# Simulate device loss: unmount, drop one member, remount degraded.
# Loop-device only — real hardware would need a SCSI/NVMe offline mechanism.
fs_degrade() {
  [ "${LAYOUT:-raid1}" != single ] || return 1
  umount "$MNT"
  if ! losetup -d "${DEVICES[1]}" 2>/dev/null; then
    mount -o noatime "${DEVICES[0]}" "$MNT"
    return 1
  fi
  mount -o degraded,noatime "${DEVICES[0]}" "$MNT"
}

fs_rebuild() {
  local devid
  devid=$(btrfs filesystem show "$MNT" \
    | awk '/devid/ && /MISSING|missing/ {for (i = 1; i <= NF; i++) if ($i == "devid") print $(i+1)}' \
    | head -1)
  btrfs replace start -B "${devid:-2}" "$SPARE_DEV" "$MNT"
}

fs_teardown() {
  umount "$MNT" 2>/dev/null || true
}

fs_remount() {
  umount "$MNT"
  mount -o noatime "${DEVICES[0]}" "$MNT"
}

fs_snap_list() { btrfs subvolume list "$MNT" >/dev/null; }

fs_snapscale_delete() {
  btrfs subvolume delete "$MNT"/scale[0-9]* >/dev/null
}

fs_scrub() {
  local out found corrected
  out=$(btrfs scrub start -B "$MNT" 2>&1) || true  # exits non-zero when errors were found
  echo "$out" >&2
  # Error summary can list several categories (read= verify= csum= super=);
  # Corrected covers all of them, so "found" must too
  found=$(grep -E '^.*Error summary:' <<<"$out" | head -1 \
    | grep -oE '[a-z]+=[0-9]+' | cut -d= -f2 | paste -sd+ - | bc)
  corrected=$(grep -iE '^[[:space:]]*corrected' <<<"$out" | grep -oE '[0-9]+' | head -1)
  echo "${found:-null} ${corrected:-null}"
}

fs_version() {
  btrfs --version 2>/dev/null | head -1
}
