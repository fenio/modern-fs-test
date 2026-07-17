#!/usr/bin/env python3
"""Audit recorded benchmark results for anomalies.

Usage: audit-results.py <runs-dir>   (a checkout of the results-data branch)

Two tiers:
- HARD anomalies (exit 1): impossible orderings, self-healing failures on
  checksumming filesystems, ENOSPC regressions, negative values, metrics
  that went missing where the matrix expects them.
- WARNINGS (exit 0): high run-to-run variance outside the known-noisy set,
  flapping verdicts, and the documented-but-worth-eyeballing patterns
  (md/lvm reporting data-intact by read-balancing luck).

Documented-and-expected behaviors are suppressed: degraded writes beating
healthy writes (missing-member savings), scrub-count variance (unit and
overlap dependent), and the by-design null matrix (singles skip degraded,
classic fs skip compression, and so on).
"""

import collections
import glob
import json
import os
import statistics
import sys

from result_schema import load_schema, validate_document

CHECKSUMMING = {"btrfs", "zfs", "bcachefs"}
CLASSIC = {"ext4", "xfs"}

# Metrics whose large run-to-run variance is expected and documented.
NOISY = {
    "scrub_found", "scrub_repaired", "reclaim_write_mbps", "reclaim_s",
    "fsync_p99_ms", "fsync_p999_ms", "snapshot_delete_ms", "reflink_ms",
    "lat_load_p99_ms", "lat_load_max_ms", "lat_idle_p99_ms",
    "nearfull95_write_mbps", "nearfull99_write_mbps",
    "snapscale_remount_ms", "snapscale_list_ms", "snapscale_delete_ms",
    "smalltree_create_ms",  # metadata-heavy create is cache/VM sensitive
    "lat_load_ops",
    "snapshot_create_ms",  # taken mid-aging under IO; txg/commit timing dependent
}


def null_ok(entity, key):
    """Is a null value for this entity/metric by design?"""
    fs, layout = entity.split("/", 1)
    single = layout == "single"
    lvm = "lvm" in layout
    if key in ("calibration", "version"):
        return True
    if single and (key.startswith(("degraded_", "scrub_", "nearfull", "enospc_"))
                   or key in ("rebuild_s", "data_intact")):
        return True
    if entity == "btrfs/raid1-luks" and (key.startswith("degraded_") or key == "rebuild_s"):
        return True  # loop-detach can't fail a dm-crypt mapper (roadmap)
    if fs == "bcachefs" and key in ("scrub_found", "scrub_repaired"):
        return True  # 1.38 tools don't expose counts; md5 verdict authoritative
    if fs in CLASSIC:
        if key.startswith(("compress_", "snapscale")):
            return True
        if key in ("reflink_ms", "reflink_fiemap_shared",
                   "divergence_clone_mbps") and fs == "ext4":
            return True
        if not lvm and key in ("snapshot_create_ms", "snapshot_delete_ms",
                               "reclaim_s", "reclaim_write_mbps",
                               "divergence_snap_mbps"):
            return True
    if fs == "zfs" and key in ("reflink_ms", "reflink_fiemap_shared",
                               "divergence_clone_mbps"):
        return True  # block cloning off by default
    return False


def main():
    runs_dir = sys.argv[1] if len(sys.argv) > 1 else "data/runs"
    run_dirs = sorted(glob.glob(os.path.join(runs_dir, "*")),
                      key=lambda p: int(os.path.basename(p)))
    if not run_dirs:
        print(f"no runs under {runs_dir}")
        return 1

    history = collections.defaultdict(lambda: collections.defaultdict(list))
    latest_docs = {}
    for rd in run_dirs:
        docs = {}
        for f in glob.glob(os.path.join(rd, "result-*.json")):
            with open(f) as fh:
                d = json.load(fh)
            ent = f"{d.get('fs', '?')}/{d.get('layout', os.path.basename(f))}"
            results = d.get("results", {})
            if isinstance(results, dict):
                for k, v in results.items():
                    history[ent][k].append(v)
            docs[ent] = d
        # latest = last run dir that has results at all
        if docs:
            latest_docs = docs

    latest = {
        ent: doc.get("results", {}) if isinstance(doc.get("results"), dict) else {}
        for ent, doc in latest_docs.items()
    }
    schema, metric_schema = load_schema()
    hard, warn = [], []

    for ent, doc in sorted(latest_docs.items()):
        for error in validate_document(doc, schema, metric_schema):
            hard.append(f"{ent}: schema {error}")

    for ent, res in sorted(latest.items()):
        fs = ent.split("/")[0]

        def num(k):
            v = res.get(k)
            return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

        # impossible orderings
        if num("fsync_p999_ms") is not None and num("fsync_p99_ms") is not None \
           and num("fsync_p999_ms") < num("fsync_p99_ms"):
            hard.append(f"{ent}: fsync p99.9 < p99 ({num('fsync_p999_ms'):.1f} < {num('fsync_p99_ms'):.1f})")
        if num("lat_idle_p99_ms") is not None and num("lat_load_p99_ms") is not None \
           and num("lat_idle_p99_ms") > num("lat_load_p99_ms"):
            hard.append(f"{ent}: trivial-op latency idle > under-load")

        # negative values anywhere
        for k, v in res.items():
            if isinstance(v, (int, float)) and not isinstance(v, bool) and v < 0:
                hard.append(f"{ent}.{k}: negative value {v}")

        # self-healing must hold on checksumming filesystems
        if fs in CHECKSUMMING and res.get("data_intact") is False:
            hard.append(f"{ent}: data NOT intact after scrub — self-healing failed")

        # ENOSPC verdicts regressing
        for k in ("enospc_delete_ok", "enospc_recover_ok"):
            if res.get(k) is False:
                hard.append(f"{ent}: {k} = false")

        # unexpected nulls (reclaim_s null = cleaner exceeded its 300s
        # window — a legitimate outcome, warn instead of fail)
        for k, v in res.items():
            if v is None and not null_ok(ent, k):
                if k == "lat_load_p99_ms" and isinstance(res.get("lat_load_ops"), (int, float)) \
                        and res["lat_load_ops"] < 20:
                    continue  # withheld by design below the 20-sample floor
                if k == "reclaim_s":
                    warn.append(f"{ent}: reclaim did not finish within 300s")
                else:
                    hard.append(f"{ent}.{k}: unexpectedly null")

    # verdict flapping + lucky-intact info across history
    for ent, metrics in sorted(history.items()):
        fs = ent.split("/")[0]
        vals = [v for v in metrics.get("data_intact", []) if v is not None]
        if fs not in CHECKSUMMING and True in vals and False in vals:
            warn.append(f"{ent}: data_intact flapped ({vals.count(True)}x intact of "
                        f"{len(vals)}) — read-balancing luck, documented")
        for k, series in sorted(metrics.items()):
            if k in NOISY or k == "aging_mbps":
                continue
            nums = [v for v in series if isinstance(v, (int, float))
                    and not isinstance(v, bool) and v > 0][-8:]
            if len(nums) >= 5 and max(nums) / min(nums) > 4:
                warn.append(f"{ent}.{k}: {max(nums)/min(nums):.1f}x spread over last "
                            f"{len(nums)} runs (median {statistics.median(nums):.1f})")

    print(f"audited {len(run_dirs)} runs, {len(latest)} entities in latest\n")
    if hard:
        print("## HARD anomalies")
        for h in hard:
            print(f"- {h}")
    if warn:
        print("\n## Warnings")
        for w in warn:
            print(f"- {w}")
    if not hard and not warn:
        print("no anomalies found")
    return 1 if hard else 0


if __name__ == "__main__":
    sys.exit(main())
