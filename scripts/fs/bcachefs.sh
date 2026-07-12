# shellcheck shell=bash
# bcachefs backend. Layout "replicas2": --replicas=2 across all devices.
# Experimental: the runner kernel may lack bcachefs support entirely.

FS_REFLINK=1

fs_setup() {
  modprobe bcachefs 2>/dev/null || true
  grep -qw bcachefs /proc/filesystems \
    || die "kernel has no bcachefs support (needs DKMS or a custom kernel)"
  bcachefs format -f --replicas=2 "${DEVICES[@]}"
  local devlist
  devlist=$(IFS=:; echo "${DEVICES[*]}")
  mount -t bcachefs "$devlist" "$MNT"
  bcachefs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  bcachefs subvolume snapshot "$DATA" "$MNT/$1" >/dev/null
}

REPLICAS=2

fs_setup_compression() {
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

fs_teardown() {
  umount "$MNT" 2>/dev/null || true
}
