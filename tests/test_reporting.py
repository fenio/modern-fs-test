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

METRIC_KEYS = [
    "seqwrite_mbps",
    "randwrite_iops",
    "randwrite4_iops",
    "fsync_p99_ms",
    "fsync_p999_ms",
    "randread_iops",
    "randread4_iops",
    "seqread_mbps",
    "lat_idle_p99_ms",
    "lat_load_p99_ms",
    "lat_load_max_ms",
    "lat_load_ops",
    "smalltree_create_ms",
    "smalltree_create4_ms",
    "smalltree_cp_ms",
    "smalltree_rm_ms",
    "sparse_create_ms",
    "sparse_create_bytes",
    "sparse_grow_ms",
    "snapshot_create_ms",
    "snapshot_delete_ms",
    "reclaim_s",
    "reclaim_write_mbps",
    "compress_ratio",
    "compress_write_mbps",
    "reflink_ms",
    "divergence_plain_mbps",
    "divergence_clone_mbps",
    "divergence_snap_mbps",
    "degraded_randwrite_iops",
    "degraded_randread_iops",
    "rebuild_s",
    "scrub_s",
    "nearfull95_write_mbps",
    "nearfull99_write_mbps",
    "snapscale_create_ms",
    "snapscale_remount_ms",
    "snapscale_delete_ms",
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
        self.assertEqual([metric["key"] for metric in data["metrics"]], METRIC_KEYS)
        self.assertEqual(data["metrics"][0], {
            "key": "seqwrite_mbps",
            "label": "Sequential write",
            "unit": "MB/s",
            "better": "higher",
        })
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


class ResultSchemaTests(unittest.TestCase):
    def test_manifest_preserves_dashboard_metric_contract(self):
        schema = json.loads(SCHEMA.read_text())
        metrics = schema["metrics"]

        self.assertEqual(schema["schema_version"], 1)
        self.assertEqual(
            [metric["key"] for metric in metrics if metric["display"] == "card"],
            METRIC_KEYS,
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


if __name__ == "__main__":
    unittest.main()
