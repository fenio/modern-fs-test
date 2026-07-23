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

import argparse
import collections
import glob
import json
import os
import statistics
import sys

from result_schema import load_schema, validate_document

CHECKSUMMING = {"btrfs", "zfs", "bcachefs"}

# Metrics whose large run-to-run variance is expected and documented.
NOISY = {
    "scrub_found", "scrub_repaired", "reclaim_write_mbps", "reclaim_s",
    "fsync_p99_ms", "fsync_p999_ms", "snapshot_delete_ms", "reflink_ms",
    "lat_load_p99_ms", "lat_load_max_ms", "lat_idle_p99_ms",
    "nearfull95_write_mbps", "nearfull99_write_mbps",
    "snapscale_remount_ms", "snapscale_list_ms", "snapscale_delete_ms",
    "smalltree_create_ms",  # metadata-heavy create is cache/VM sensitive
    "largedir_create_ms", "largedir_readdir_cold_ms", "largedir_stat_cold_ms",
    "largedir_delete_ms",
    "lat_load_ops",
    "snapshot_create_ms",  # taken mid-aging under IO; txg/commit timing dependent
}


def capabilities_for(entity, document, configurations):
    capabilities = set(configurations.get(entity, []))
    version = document.get("schema_version", 1)
    if entity.startswith("zfs/") and (not isinstance(version, int) or version < 5):
        # ZFS block cloning was omitted from the contract before schema v5.
        capabilities.discard("reflink")
    if document.get("devices") != "loop":
        # Real-hardware runs skip the destructive small-array ENOSPC phase
        # and may not have the spare device required for rebuild testing.
        capabilities.difference_update(("enospc", "degraded"))
    return capabilities


def null_ok(key, capabilities, metrics):
    """Is a null value for this metric unsupported by this configuration?"""
    capability = metrics.get(key, {}).get("capability")
    return capability is not None and capability not in capabilities


def reclaim_target_pct(document):
    version = document.get("schema_version", 1)
    return 80 if isinstance(version, int) and version >= 3 else 85


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runs_dir", nargs="?", default="data/runs")
    parser.add_argument("--allow-partial", action="store_true",
                        help="do not require every configured matrix entity")
    args = parser.parse_args()
    runs_dir = args.runs_dir
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
    configurations = schema.get("configurations", {})
    hard, warn = [], []

    if not args.allow_partial:
        missing = sorted(set(configurations) - set(latest_docs))
        if missing:
            hard.append(f"latest run missing configurations: {', '.join(missing)}")

    for ent, doc in sorted(latest_docs.items()):
        for error in validate_document(doc, schema, metric_schema):
            hard.append(f"{ent}: schema {error}")

    for ent, res in sorted(latest.items()):
        fs = ent.split("/")[0]
        capabilities = capabilities_for(ent, latest_docs[ent], configurations)

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
            if v is None and not null_ok(k, capabilities, metric_schema):
                if k == "lat_load_p99_ms" and isinstance(res.get("lat_load_ops"), (int, float)) \
                        and res["lat_load_ops"] < 20:
                    continue  # withheld by design below the 20-sample floor
                if k == "reclaim_s":
                    pct = res.get("reclaim_free_pct")
                    target = reclaim_target_pct(latest_docs[ent])
                    restored = (
                        f"; {pct:.1f}% restored, target {target}%"
                        if isinstance(pct, (int, float)) else ""
                    )
                    warn.append(f"{ent}: reclaim did not finish within 300s{restored}")
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
