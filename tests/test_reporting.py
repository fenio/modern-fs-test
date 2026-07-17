import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_RUNS = ROOT / "tests" / "fixtures" / "runs"
DASHBOARD = ROOT / "scripts" / "make-dashboard.py"
AUDIT = ROOT / "scripts" / "audit-results.py"
SCHEMA = ROOT / "scripts" / "result-schema.json"
VALIDATOR = ROOT / "scripts" / "validate-result.py"
RUN_BENCH = ROOT / "scripts" / "run-bench.sh"

METRIC_CONTRACT = [
    ("seqwrite_mbps", "Sequential write", "MB/s", "higher"),
    ("randwrite_iops", "Random write, 4k + fsync", "IOPS", "higher"),
    ("randwrite4_iops", "Random write, 4 threads", "IOPS", "higher"),
    ("fsync_p99_ms", "fsync p99 latency", "ms", "lower"),
    ("fsync_p999_ms", "fsync p99.9 latency", "ms", "lower"),
    ("randread_iops", "Random read, 4k cold cache", "IOPS", "higher"),
    ("randread4_iops", "Random read, 4 threads", "IOPS", "higher"),
    ("seqread_mbps", "Sequential read", "MB/s", "higher"),
    ("lat_idle_p99_ms", "Trivial-op p99, idle", "ms", "lower"),
    ("lat_load_p99_ms", "Trivial-op p99 under streaming write", "ms", "lower"),
    ("lat_load_max_ms", "Trivial-op worst case under load", "ms", "lower"),
    ("lat_load_ops", "Trivial ops completed under load", "ops", "higher"),
    ("smalltree_create_ms", "Create 20k-file tree", "ms", "lower"),
    ("smalltree_create4_ms", "Create 20k-file tree, 4 workers", "ms", "lower"),
    ("smalltree_cp_ms", "cp -r 20k-file tree, cold", "ms", "lower"),
    ("smalltree_rm_ms", "rm -rf 20k-file tree", "ms", "lower"),
    ("sparse_create_ms", "ftruncate empty file to 1G", "ms", "lower"),
    ("sparse_create_bytes", "Bytes allocated for sparse 1G", "B", "lower"),
    ("sparse_grow_ms", "ftruncate 256M file to 512M", "ms", "lower"),
    ("snapshot_create_ms", "Snapshot create", "ms", "lower"),
    ("snapshot_delete_ms", "Snapshot delete (all)", "ms", "lower"),
    ("reclaim_s", "Space reclaim after delete", "s", "lower"),
    ("reclaim_write_mbps", "Write during reclaim", "MB/s", "higher"),
    ("compress_ratio", "zstd compression ratio", "x", "higher"),
    ("compress_write_mbps", "Compressible-data write", "MB/s", "higher"),
    ("reflink_ms", "Reflink copy of 2G", "ms", "lower"),
    ("divergence_plain_mbps", "Overwrite plain file", "MB/s", "higher"),
    ("divergence_clone_mbps", "Overwrite fresh reflink clone", "MB/s", "higher"),
    ("divergence_snap_mbps", "Overwrite freshly-snapshotted file", "MB/s", "higher"),
    ("degraded_randwrite_iops", "Degraded random write", "IOPS", "higher"),
    ("degraded_randread_iops", "Degraded random read", "IOPS", "higher"),
    ("rebuild_s", "Rebuild after device loss", "s", "lower"),
    ("scrub_s", "Scrub after corruption", "s", "lower"),
    ("nearfull95_write_mbps", "Write near full (95% target)", "MB/s", "higher"),
    ("nearfull99_write_mbps", "Write near full (99% target)", "MB/s", "higher"),
    ("snapscale_create_ms", "Snapshot create at 500 snaps", "ms", "lower"),
    ("snapscale_remount_ms", "Remount with 500 snaps", "ms", "lower"),
    ("snapscale_delete_ms", "Delete 500 snapshots", "ms", "lower"),
]


def run_script(script, *args):
    return subprocess.run(
        [sys.executable, str(script), *(str(arg) for arg in args)],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def dashboard_data(html):
    prefix = "const DATA = "
    suffix = ";\nconst SLOTS = "
    start = html.index(prefix) + len(prefix)
    end = html.index(suffix, start)
    return json.loads(html[start:end])


class DashboardRegressionTests(unittest.TestCase):
    def test_generated_dashboard_preserves_current_data_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "index.html"
            result = run_script(
                DASHBOARD,
                "--runs",
                FIXTURE_RUNS,
                "--out",
                output,
                "--repo",
                "https://example.test/fsbench",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("wrote", result.stdout)
            data = dashboard_data(output.read_text())

        self.assertEqual(data["latest"]["date"], "2026-07-16T10:02:00Z")
        self.assertEqual(data["latest"]["kernel"], "6.18.0-fixture")
        self.assertEqual(data["stale"], ["ext4/single", "zfs/mirror"])
        self.assertEqual(
            [entity["id"] for entity in data["entities"]],
            [
                "ext4/single",
                "xfs/zvol",
                "zfs/mirror",
                "btrfs/raid1",
                "bcachefs/replicas2",
            ],
        )
        self.assertEqual(
            data["metrics"],
            [
                {"key": key, "label": label, "unit": unit, "better": better}
                for key, label, unit, better in METRIC_CONTRACT
            ],
        )
        latest = data["latest"]["results"]
        self.assertEqual(latest["ext4/single"]["seqwrite_mbps"], 510.2)
        self.assertEqual(latest["btrfs/raid1"]["aging_mbps"], [42.0, 39.5, 37.0])
        self.assertIsNone(latest["zfs/mirror"]["reflink_ms"])
        self.assertIsNone(latest["bcachefs/replicas2"]["scrub_found"])
        self.assertEqual(
            latest["bcachefs/replicas2"]["calibration"],
            {"seqwrite_mbps": 404.0, "randwrite_iops": 14300.0},
        )
        self.assertEqual(
            latest["bcachefs/replicas2"]["version"],
            "tools 1.38.1 / module 1.38.1",
        )
        self.assertEqual(data["repo"], "https://example.test/fsbench")


class AuditRegressionTests(unittest.TestCase):
    def test_representative_history_has_no_anomalies(self):
        result = run_script(AUDIT, FIXTURE_RUNS)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("audited 2 runs, 3 entities in latest", result.stdout)
        self.assertIn("no anomalies found", result.stdout)

    def test_integrity_failure_is_a_hard_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["results"]["data_intact"] = False
            result_file.write_text(json.dumps(document))

            result = run_script(AUDIT, runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn("## HARD anomalies", result.stdout)
        self.assertIn(
            "btrfs/raid1: data NOT intact after scrub — self-healing failed",
            result.stdout,
        )

    def test_fiemap_null_is_expected_without_reflink_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            for name in ("result-ext4-single.json", "result-zfs-mirror.json"):
                shutil.copy2(runs / "100" / name, runs / "101" / name)

            result = run_script(AUDIT, runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("audited 2 runs, 5 entities in latest", result.stdout)
        self.assertIn("no anomalies found", result.stdout)

    def test_fiemap_null_is_rejected_with_reflink_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-xfs-zvol.json"
            document = json.loads(result_file.read_text())
            document["results"]["reflink_fiemap_shared"] = None
            result_file.write_text(json.dumps(document))

            result = run_script(AUDIT, runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "xfs/zvol.reflink_fiemap_shared: unexpectedly null",
            result.stdout,
        )

    def test_missing_latest_metric_is_a_hard_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            del document["results"]["sparse_grow_bytes"]
            result_file.write_text(json.dumps(document))

            result = run_script(AUDIT, runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "btrfs/raid1: schema document.results: missing metrics: "
            "sparse_grow_bytes",
            result.stdout,
        )

    def test_wrong_latest_metric_type_is_a_hard_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["results"]["seqwrite_mbps"] = "fast"
            result_file.write_text(json.dumps(document))

            result = run_script(AUDIT, runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "btrfs/raid1: schema document.results.seqwrite_mbps: "
            "expected number, got str",
            result.stdout,
        )

    def test_historical_documents_are_not_forced_through_current_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "100" / "result-ext4-single.json"
            document = json.loads(result_file.read_text())
            del document["results"]["sparse_grow_bytes"]
            result_file.write_text(json.dumps(document))

            result = run_script(AUDIT, runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no anomalies found", result.stdout)


class ResultSchemaTests(unittest.TestCase):
    def test_manifest_preserves_dashboard_metric_contract(self):
        schema = json.loads(SCHEMA.read_text())
        metrics = schema["metrics"]

        self.assertEqual(schema["schema_version"], 1)
        self.assertEqual(
            [
                (metric["key"], metric["label"], metric["unit"], metric["better"])
                for metric in metrics
                if metric["display"] == "card"
            ],
            METRIC_CONTRACT,
        )
        self.assertEqual(len({metric["key"] for metric in metrics}), len(metrics))

    def test_all_representative_results_validate(self):
        fixtures = sorted(FIXTURE_RUNS.glob("*/*.json"))
        result = run_script(VALIDATOR, *fixtures)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validated 5 result file(s)", result.stdout)

    def test_wrong_metric_type_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            document["results"]["seqwrite_mbps"] = "fast"
            result_file.write_text(json.dumps(document))

            result = run_script(VALIDATOR, result_file)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "document.results.seqwrite_mbps: expected number, got str",
            result.stderr,
        )

    def test_missing_metric_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            del document["results"]["sparse_grow_bytes"]
            result_file.write_text(json.dumps(document))

            result = run_script(VALIDATOR, result_file)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "document.results: missing metrics: sparse_grow_bytes",
            result.stderr,
        )

    def test_benchmark_validates_result_before_reporting_success(self):
        source = RUN_BENCH.read_text()

        write_result = source.index('> "$RESULT_FILE"')
        validate_result = source.index(
            'python3 "$SCRIPT_DIR/validate-result.py" "$RESULT_FILE"'
        )
        report_success = source.index('log "done: $RESULT_FILE"')

        self.assertLess(write_result, validate_result)
        self.assertLess(validate_result, report_success)


if __name__ == "__main__":
    unittest.main()
