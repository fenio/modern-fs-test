import json
import re
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
XFS_BACKEND = ROOT / "scripts" / "fs" / "xfs.sh"
BENCH_WORKFLOW = ROOT / ".github" / "workflows" / "bench.yml"

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


def run_audit(runs):
    return run_script(AUDIT, "--allow-partial", runs)


def run_benchmark_shell(source, *args):
    return subprocess.run(
        ["bash", "-c", f'source "$1"\n{source}', "bash", str(RUN_BENCH), *args],
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
            html = output.read_text()
            data = dashboard_data(html)

        self.assertEqual(data["latest"]["date"], "2026-07-16T10:02:00Z")
        self.assertEqual(data["latest"]["kernel"], "6.18.0-fixture")
        self.assertEqual(data["runCount"], 2)
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
        self.assertIn('href="https://github.com/nasty-project/nasty"', html)
        for legacy_section in (
            "Latest run",
            "Snapshot aging",
            "Trends across runs",
            "Table view",
        ):
            self.assertIn(legacy_section, html)
        self.assertIn("Explore trends", html)
        self.assertIn("content.appendChild(buildExplorer(view));", html)
        self.assertIn(
            "https://cdn.jsdelivr.net/npm/echarts@6.0.0/dist/echarts.min.js",
            html,
        )
        self.assertNotIn(
            '<script src="https://cdn.jsdelivr.net/npm/echarts',
            html,
        )
        self.assertIn("rebuild();\nloadExplorerLibrary();", html)
        self.assertIn(
            "sha384-F07Cpw5v8spSU0H113F33m2NQQ/o6GqPTnTjf45ssG4Q6q58ZwhxBiQtIaqvnSpR",
            html,
        )
        self.assertIn(
            "the existing dashboard charts are unaffected",
            html,
        )
        self.assertEqual(
            [
                run["results"].get("ext4/single", {}).get("seqwrite_mbps")
                for run in data["runs"]
            ],
            [510.2, None],
        )
        self.assertEqual(
            [
                run["results"].get("btrfs/raid1", {}).get("seqwrite_mbps")
                for run in data["runs"]
            ],
            [None, 360.0],
        )

    def test_dashboard_distinguishes_runs_from_compacted_trend_points(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            runs = tmp / "runs"
            shutil.copytree(FIXTURE_RUNS / "100", runs / "100")
            shutil.copytree(FIXTURE_RUNS / "100", runs / "101")
            shutil.copytree(FIXTURE_RUNS / "101", runs / "102")
            output = tmp / "index.html"

            result = run_script(
                DASHBOARD,
                "--runs",
                runs,
                "--out",
                output,
                "--window",
                1,
            )
            data = dashboard_data(output.read_text())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["runCount"], 3)
        self.assertEqual(len(data["runs"]), 2)
        self.assertTrue(data["runs"][0]["agg"])


class AuditRegressionTests(unittest.TestCase):
    def test_representative_history_has_no_anomalies(self):
        result = run_audit(FIXTURE_RUNS)

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

            result = run_audit(runs)

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

            result = run_audit(runs)

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

            result = run_audit(runs)

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

            result = run_audit(runs)

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

            result = run_audit(runs)

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

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no anomalies found", result.stdout)

    def test_incomplete_latest_matrix_is_a_hard_anomaly(self):
        result = run_script(AUDIT, FIXTURE_RUNS)

        self.assertEqual(result.returncode, 1)
        self.assertIn("latest run missing configurations:", result.stdout)

    def test_real_hardware_allows_skipped_enospc_and_degraded_phases(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["devices"] = "/dev/sdb /dev/sdc /dev/sdd /dev/sde"
            for key in (
                "degraded_randwrite_iops",
                "degraded_randread_iops",
                "rebuild_s",
                "nearfull95_write_mbps",
                "nearfull99_write_mbps",
                "nearfull95_pct",
                "nearfull99_pct",
                "enospc_delete_ok",
                "enospc_recover_ok",
            ):
                document["results"][key] = None
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no anomalies found", result.stdout)

    def test_reclaim_timeout_reports_restored_space(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["results"]["reclaim_s"] = None
            document["results"]["reclaim_free_pct"] = 82.4
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "btrfs/raid1: reclaim did not finish within 300s; "
            "82.4% restored, target 85%",
            result.stdout,
        )

    def test_schema_v3_reclaim_timeout_uses_80_percent_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["schema_version"] = 3
            document["results"]["reclaim_s"] = None
            document["results"]["reclaim_free_pct"] = 78.4
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "btrfs/raid1: reclaim did not finish within 300s; "
            "78.4% restored, target 80%",
            result.stdout,
        )


class ResultSchemaTests(unittest.TestCase):
    def write_complete_result_set(self, directory):
        configurations = json.loads(SCHEMA.read_text())["configurations"]
        template = json.loads(
            (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
        )
        paths = []
        for entity in configurations:
            fs, layout = entity.split("/", 1)
            document = template.copy()
            document["fs"] = fs
            document["layout"] = layout
            path = Path(directory) / f"result-{fs}-{layout}.json"
            path.write_text(json.dumps(document))
            paths.append(path)
        return paths

    def test_manifest_preserves_dashboard_metric_contract(self):
        schema = json.loads(SCHEMA.read_text())
        metrics = schema["metrics"]

        self.assertEqual(schema["schema_version"], 3)
        self.assertEqual(
            [
                (metric["key"], metric["label"], metric["unit"], metric["better"])
                for metric in metrics
                if metric["display"] == "card"
            ],
            METRIC_CONTRACT,
        )
        self.assertEqual(len({metric["key"] for metric in metrics}), len(metrics))

    def test_configurations_match_benchmark_matrix(self):
        schema = json.loads(SCHEMA.read_text())
        matrix = re.findall(
            r"^\s+- fs: (\S+)\n\s+layout: (\S+)",
            BENCH_WORKFLOW.read_text(),
            re.MULTILINE,
        )

        self.assertEqual(
            list(schema["configurations"]),
            [f"{fs}/{layout}" for fs, layout in matrix],
        )

    def test_nullable_metrics_declare_capability_or_special_handling(self):
        schema = json.loads(SCHEMA.read_text())
        unscoped = [
            metric["key"]
            for metric in schema["metrics"]
            if metric.get("nullable") and "capability" not in metric
        ]

        self.assertEqual(unscoped, ["lat_load_p99_ms", "lat_load_max_ms"])

    def test_configuration_capabilities_are_known_and_unique(self):
        schema = json.loads(SCHEMA.read_text())
        metric_capabilities = {
            metric["capability"]
            for metric in schema["metrics"]
            if "capability" in metric
        }
        configured_capabilities = {
            capability
            for capabilities in schema["configurations"].values()
            for capability in capabilities
        }

        self.assertEqual(configured_capabilities, metric_capabilities)
        for capabilities in schema["configurations"].values():
            self.assertEqual(len(capabilities), len(set(capabilities)))

    def test_all_representative_results_validate(self):
        fixtures = sorted(FIXTURE_RUNS.glob("*/*.json"))
        result = run_script(VALIDATOR, *fixtures)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validated 5 result file(s)", result.stdout)

    def test_complete_result_set_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self.write_complete_result_set(tmp)

            result = run_script(VALIDATOR, "--complete-set", *paths)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"validated {len(paths)} result file(s) as a complete matrix",
            result.stdout,
        )

    def test_incomplete_result_set_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self.write_complete_result_set(tmp)
            missing = paths.pop()
            missing_document = json.loads(missing.read_text())
            missing_entity = (
                f"{missing_document['fs']}/{missing_document['layout']}"
            )
            missing.unlink()

            result = run_script(VALIDATOR, "--complete-set", *paths)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            f"result set missing configurations: {missing_entity}",
            result.stderr,
        )

    def test_duplicate_result_configuration_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self.write_complete_result_set(tmp)
            duplicate = Path(tmp) / "duplicate.json"
            shutil.copy2(paths[0], duplicate)

            result = run_script(VALIDATOR, "--complete-set", *paths, duplicate)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "result set has duplicate configurations: ext4/single",
            result.stderr,
        )

    def test_history_publication_requires_complete_result_set(self):
        workflow = BENCH_WORKFLOW.read_text()

        validation = workflow.index("Validate complete result set")
        publication = workflow.index("Append results to history branch")

        self.assertLess(validation, publication)
        self.assertIn(
            "validate-result.py --complete-set incoming/result-*.json",
            workflow,
        )

    def test_unversioned_results_use_v1_contract(self):
        result = run_script(
            VALIDATOR,
            FIXTURE_RUNS / "100" / "result-ext4-single.json",
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_schema_v2_requires_reclaim_telemetry(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            del document["results"]["reclaim_free_pct"]
            result_file.write_text(json.dumps(document))

            result = run_script(VALIDATOR, result_file)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "document.results: missing metrics: reclaim_free_pct",
            result.stderr,
        )

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


class BenchmarkPhaseTests(unittest.TestCase):
    phases = [
        "phase_host_calibration",
        "setup_benchmark_filesystem",
        "phase_sequential_write",
        "phase_random_write",
        "phase_random_read",
        "phase_sequential_read",
        "phase_trivial_latency",
        "phase_source_tree",
        "phase_sparse_files",
        "phase_aging",
        "phase_snapshot_reclaim",
        "phase_snapshot_scaling",
        "phase_compression",
        "phase_divergence",
        "phase_degraded_rebuild",
        "phase_corruption_scrub",
        "phase_enospc",
        "write_result",
    ]

    def test_phases_run_in_destructive_order(self):
        stubs = "\n".join(
            f"{phase}() {{ printf '%s\\n' {phase}; }}" for phase in self.phases
        )

        result = run_benchmark_shell(f"{stubs}\nrun_benchmark_phases")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), self.phases)

    def test_sequential_write_phase_can_run_with_stubs(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = r'''
DATA=$2
SEQ_SIZE=2G
log() { :; }
fio_json() {
  printf '%s\n' "$*" > "$DATA/fio-call"
  printf '%s\n' "$DATA/fio.json"
}
jq() { printf '321.5\n'; }
phase_sequential_write
printf '%s\n' "$SEQWRITE_MBPS"
'''
            result = run_benchmark_shell(source, tmp)
            fio_call = (Path(tmp) / "fio-call").read_text().strip()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "321.5")
        self.assertEqual(
            fio_call,
            f"seqwrite --directory={tmp} --rw=write --bs=1M "
            "--size=2G --end_fsync=1",
        )

    def test_skipped_degraded_phase_resets_optional_metrics(self):
        source = r'''
FS=ext4
LAYOUT=single
SPARE_DEV=
DEG_WRITE_IOPS=1
DEG_READ_IOPS=2
REBUILD_S=3
log() { :; }
phase_degraded_rebuild
printf '%s %s %s\n' "$DEG_WRITE_IOPS" "$DEG_READ_IOPS" "$REBUILD_S"
'''

        result = run_benchmark_shell(source)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "null null null")


class BackendConfigurationTests(unittest.TestCase):
    def test_xfs_zvol_does_not_reserve_space_needed_by_snapshots(self):
        source = XFS_BACKEND.read_text()

        self.assertIn("-o refreservation=none", source)


if __name__ == "__main__":
    unittest.main()
