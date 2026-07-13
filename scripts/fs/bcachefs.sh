# shellcheck shell=bash
# bcachefs backend. Layout "replicas2": --replicas=2 across all devices.
# The kernel module ships as DKMS (see install-deps.sh) since bcachefs
# left mainline in 6.17.

FS_REFLINK=1

fs_setup() {
  modprobe bcachefs 2>/dev/null || true
  grep -qw bcachefs /proc/filesystems \
    || die "kernel has no bcachefs support (needs DKMS or a custom kernel)"
  local fmt=(bcachefs format -f)
  case "${LAYOUT:-replicas2}" in
    *-enc)
      # native whole-fs encryption: ChaCha20/Poly1305, authenticated —
      # checksums become cryptographic MACs
      [ -f "$DISK_DIR/bcachefs.pass" ] || echo "fsbench-ci-passphrase" > "$DISK_DIR/bcachefs.pass"
      fmt+=(--encrypted --passphrase_file="$DISK_DIR/bcachefs.pass")
      ;;
  esac
  if [ "${LAYOUT:-replicas2}" = single ]; then
    "${fmt[@]}" "${DEVICES[0]}"
  else
    "${fmt[@]}" --replicas=2 "${DEVICES[@]}"
  fi
  bcachefs_mount
  bcachefs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  bcachefs subvolume snapshot "$DATA" "$MNT/$1" >/dev/null
}

# Mount respecting layout (single = one device) and encryption (the mount
# helper reads the passphrase file and unlocks itself — a separate
# `bcachefs unlock` puts the key where mount doesn't find it).
bcachefs_mount() {
  local devlist
  if [ "${LAYOUT:-replicas2}" = single ]; then
    devlist=${DEVICES[0]}
  else
    devlist=$(IFS=:; echo "${DEVICES[*]}")
  fi
  case "${LAYOUT:-replicas2}" in
    *-enc)
      # the tools put the unlock key in the USER keyring, but the kernel's
      # mount-time search goes through the SESSION keyring — under sudo
      # they aren't linked ("Required key not available")
      keyctl link @u @s 2>/dev/null || true
      bcachefs mount --passphrase-file "$DISK_DIR/bcachefs.pass" "$devlist" "$MNT"
      ;;
    *) mount -t bcachefs "$devlist" "$MNT" ;;
  esac
}

fs_remount() {
  umount "$MNT"
  bcachefs_mount
}

fs_snap_list() { ls "$MNT" >/dev/null; }

fs_snapscale_delete() {
  local i
  for i in $(seq 1 "$1"); do
    bcachefs subvolume delete "$MNT/scale$i"
  done
}

fs_snapshot_delete_all() {
  local i
  for i in $(seq 1 "$1"); do
    bcachefs subvolume delete "$MNT/snap$i"
  done
}

fs_setup_compression() {
  REPLICAS=2
  [ "${LAYOUT:-replicas2}" = single ] && REPLICAS=1
  mkdir -p "$1"
  # renamed from "setattr" in newer bcachefs-tools
  bcachefs set-file-option --compression=zstd "$1" 2>/dev/null \
    || bcachefs setattr --compression=zstd "$1"
  sync
  COMP_USED_BEFORE=$(bcachefs fs usage "$MNT" | awk '/^Used:/ {print $2}')
}

fs_compress_ratio() {
  # `bcachefs fs usage` has a Compression section with per-algorithm
  # compressed/uncompressed totals (du can't see compression here —
  # st_blocks reports logical allocation)
  local dump="$RESULTS_DIR/raw/$BENCH_ID-fs-usage.txt"
  bcachefs fs usage "$MNT" > "$dump" 2>&1 || true
  local ratio
  ratio=$(awk '
    function bytes(v, u) {
      if (u == "") { if (match(v, /[KMGTP]?i?B$/)) { u = substr(v, RSTART); v = substr(v, 1, RSTART - 1) } }
      v += 0
      if (u == "KiB") return v * 1024
      if (u == "MiB") return v * 1048576
      if (u == "GiB") return v * 1073741824
      if (u == "TiB") return v * 1099511627776
      return v
    }
    insec && NF == 0 { insec = 0 }
    insec && $1 != "type" {
      i = 2
      c = $i; i++
      cu = ""; if ($i ~ /^[KMGTP]?i?B$/) { cu = $i; i++ }
      un = $i; i++
      uu = ""; if ($i ~ /^[KMGTP]?i?B$/) { uu = $i }
      if ($1 != "incompressible" && $1 != "none") {
        comp += bytes(c, cu); uncomp += bytes(un, uu)
      }
    }
    /^Compression:/ { insec = 1 }
    END { if (comp > 0) printf "%.2f", uncomp / comp; else print "null" }
  ' "$dump")
  if [ "$ratio" != null ]; then
    echo "$ratio"
    return
  fi
  # Packaged tools (1.38) lack the Compression section — fall back to the
  # raw Used: delta across the compressible write (replicated bytes).
  local used_after logical
  used_after=$(awk '/^Used:/ {print $2}' "$dump")
  logical=$(numfmt --from=iec "$COMP_SIZE")
  if [ -n "${COMP_USED_BEFORE:-}" ] && [ "$used_after" -gt "$COMP_USED_BEFORE" ]; then
    awk "BEGIN{printf \"%.2f\", $logical * $REPLICAS / ($used_after - $COMP_USED_BEFORE)}"
  else
    echo null
  fi
}

# Degraded mode: take a member offline. With 4 devices and replicas=2
# nothing is left under-replicated by new writes — they simply avoid the
# missing device — so a rejoin has no catch-up to measure (verified: an
# online + reconcile wait returns instantly). The measurable rebuild,
# matching btrfs replace / zpool replace, is relocating everything the
# lost device held: add the spare, then evacuate the device — which
# blocks until it holds zero data.
fs_degrade() {
  [ "${LAYOUT:-replicas2}" != single ] || return 1
  bcachefs device offline --force "${DEVICES[1]}" 2>/dev/null \
    || bcachefs device offline "${DEVICES[1]}"
}

fs_rebuild() {
  bcachefs device online "${DEVICES[1]}"
  bcachefs device add "$MNT" "$SPARE_DEV"
  bcachefs device evacuate "${DEVICES[1]}"
}

fs_teardown() {
  umount "$MNT" 2>/dev/null || true
}

fs_scrub() {
  # scrub may exit non-zero after *finding* errors — that's still a
  # completed scrub; only treat CLI-level failure as unsupported
  local out fixed
  out=$(bcachefs scrub "$MNT" 2>&1) || true
  echo "$out" >&2
  grep -qiE 'usage:|unknown command|invalid option|no such' <<<"$out" && return 1
  # output format varies across tool versions — best-effort count parse;
  # the md5 verdict in run-bench is the authoritative result
  fixed=$(grep -oiE '[0-9]+[[:space:]]+(errors?[[:space:]]+)?(corrected|fixed)' <<<"$out" \
    | grep -oE '[0-9]+' | head -1)
  echo "${fixed:-null} ${fixed:-null}"
}

fs_version() {
  local tools mod
  tools=$(bcachefs version 2>/dev/null | head -1)
  mod=$(modinfo -F version bcachefs 2>/dev/null | head -1)
  echo "tools ${tools:-?} / module ${mod:-?}"
}
