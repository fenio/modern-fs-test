# shellcheck shell=bash
# Diagnostic helpers shared by the bcachefs backend and EC reproducer.

bcachefs_debug_section() {
  printf '\n===== %s =====\n' "$1"
}

bcachefs_debug_dump() { # <output> <mountpoint> [dump-blocked-tasks]
  local output=$1 mountpoint=$2 dump_blocked=${3:-0}
  (
    set +e
    umask 022
    mkdir -p "$(dirname "$output")"
    exec >"$output" 2>&1

    bcachefs_debug_section "identity"
    date -u +%FT%TZ
    uname -a
    bcachefs version
    modinfo bcachefs

    bcachefs_debug_section "mount and devices"
    findmnt "$mountpoint"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS

    bcachefs_debug_section "filesystem usage"
    timeout 15s bcachefs fs usage -a -h "$mountpoint"

    bcachefs_debug_section "reconcile status"
    timeout 15s bcachefs reconcile status "$mountpoint"

    local fsdir path
    for fsdir in /sys/fs/bcachefs/*; do
      [ -d "$fsdir" ] || continue
      for path in \
        reconcile_status \
        internal/moving_ctxts \
        internal/new_stripes \
        internal/alloc_debug \
        options/ec_stripe_buf_limit \
        options/move_bytes_in_flight; do
        [ -r "$fsdir/$path" ] || continue
        bcachefs_debug_section "$fsdir/$path"
        timeout 15s cat "$fsdir/$path"
      done
    done

    bcachefs_debug_section "pressure and memory"
    cat /proc/pressure/io
    cat /proc/pressure/memory
    cat /proc/meminfo

    bcachefs_debug_section "bcachefs processes"
    ps -e -o pid,ppid,stat,wchan:32,comm,args
    local proc comm
    for proc in /proc/[0-9]*; do
      [ -r "$proc/comm" ] || continue
      read -r comm < "$proc/comm"
      case "$comm" in
        bch-*|bcachefs*)
          bcachefs_debug_section "$proc ($comm)"
          cat "$proc/status"
          cat "$proc/wchan"
          cat "$proc/stack"
          ;;
      esac
    done

    if [ "$dump_blocked" = 1 ] && [ -w /proc/sysrq-trigger ]; then
      bcachefs_debug_section "blocked tasks requested through sysrq-w"
      printf w > /proc/sysrq-trigger
      sleep 1
    fi

    bcachefs_debug_section "kernel log"
    dmesg --color=never
  )
}

bcachefs_evacuate_with_diagnostics() { # <mountpoint> <device> <output-prefix>
  local mountpoint=$1 device=$2 prefix=$3
  local evac_timeout=${BCACHEFS_EVAC_TIMEOUT:-12m}
  local diag_after=${BCACHEFS_EVAC_DIAG_AFTER:-180}
  local marker="${prefix}.done" watchdog rc

  mkdir -p "$(dirname "$prefix")"
  rm -f "$marker"
  bcachefs_debug_dump "${prefix}-before.txt" "$mountpoint" 0

  (
    sleep "$diag_after"
    if [ ! -e "$marker" ]; then
      bcachefs_debug_dump "${prefix}-stalled.txt" "$mountpoint" 1
    fi
  ) &
  watchdog=$!

  if timeout --signal=TERM --kill-after=30s "$evac_timeout" \
       bcachefs device evacuate "$device" 2>&1 \
       | tee "${prefix}.log"; then
    rc=0
  else
    rc=${PIPESTATUS[0]}
  fi

  : > "$marker"
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  rm -f "$marker"

  if [ "$rc" -ne 0 ]; then
    bcachefs_debug_dump "${prefix}-failed.txt" "$mountpoint" 1
  fi
  return "$rc"
}
