#!/usr/bin/env bash
# Render result JSON files as a GitHub-flavored markdown table.
# Usage: summarize.sh results/result-*.json
set -euo pipefail

echo "### Filesystem benchmark results"
echo
echo "Loop-device numbers are only meaningful *relative to each other within one run* — see README."
echo
echo "| fs | layout | kernel | seq write MB/s | rand write IOPS | rand read IOPS | snap create ms | snap delete ms | reclaim s | aging MB/s (first → last) | zstd ratio | zstd write MB/s | reflink ms | degraded wr IOPS | rebuild s | scrub s | data intact |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"

for f in "$@"; do
  [ -f "$f" ] || continue
  jq -r '
    def fmt: if . == null then "—" else (. * 100 | round / 100 | tostring) end;
    "| \(.fs) | \(.layout) | \(.kernel) | " +
    "\(.results.seqwrite_mbps | round) | " +
    "\(.results.randwrite_iops | round) | " +
    "\(.results.randread_iops | round) | " +
    "\(.results.snapshot_create_ms | fmt) | " +
    "\(.results.snapshot_delete_ms | fmt) | " +
    "\(.results.reclaim_s | fmt) | " +
    "\(.results.aging_mbps | first | round) → \(.results.aging_mbps | last | round) | " +
    "\(.results.compress_ratio | fmt) | " +
    "\(.results.compress_write_mbps | fmt) | " +
    "\(.results.reflink_ms | fmt) | " +
    "\(.results.degraded_randwrite_iops | fmt) | " +
    "\(.results.rebuild_s | fmt) | " +
    "\(.results.scrub_s | fmt) | " +
    "\(if .results.data_intact == true then "yes" elif .results.data_intact == false then "**NO**" else "—" end) |"
  ' "$f"
done
