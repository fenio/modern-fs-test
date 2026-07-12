# modern-fs-test

Continuous benchmarks for **multi-device, copy-on-write filesystems** — btrfs,
ZFS, bcachefs — measuring the things single-device ext4-style benchmarks
(Phoronix et al.) never touch: redundancy layouts, snapshots, CoW aging,
transparent compression, and reflinks.

## Why

Classic filesystem benchmarks run fio on one device with default mkfs options.
That says nothing about what modern filesystems are actually deployed for.
This suite benchmarks the *machinery*:

| Phase | What it measures |
|---|---|
| seq / rand write, rand read | baseline throughput on the chosen redundancy layout |
| snapshot aging | random-overwrite bandwidth as snapshots accumulate (CoW fragmentation cost) |
| snapshot create | metadata cost of taking a snapshot |
| compression | zstd ratio + write throughput on 75%-compressible data |
| reflink | `cp --reflink=always` of a large file |

Default matrix (4 devices, 2-copy redundancy, plus baselines):

- **ext4 single** — one device, the "what does any of this cost" anchor
- **ext4 on md raid10** — the classic layered stack
- **ext4 on LVM raid10** — layered stack with block-layer CoW snapshots,
  so the snapshot-aging phase is comparable with the native-CoW filesystems
- **btrfs** — `-d raid1 -m raid1`
- **ZFS** — striped mirror pairs (raid10-like)
- **bcachefs** — `--replicas=2` (experimental; kernel module built via DKMS from
  [apt.bcachefs.org](https://apt.bcachefs.org/) since bcachefs left mainline in 6.17)

## How it runs

### CI (GitHub Actions, loop devices)

Every push/weekly cron builds each filesystem across 4 loop devices backed by
sparse files, runs the suite, and publishes a results table in the job summary
plus JSON artifacts.

**Interpret CI numbers carefully.** Runners are shared VMs and all "devices"
live on one virtual disk, so absolute MB/s is meaningless and RAID striping
gains are fiction. What *is* meaningful: relative comparisons within a run
(fs A vs fs B, compression on vs off), behavioral curves (aging degradation,
cost per snapshot), and regressions of those over kernel versions.

### Real hardware

The same scripts take real block devices — this is where absolute numbers
become valid:

```sh
sudo BENCH_DEVICES="/dev/sdb /dev/sdc /dev/sdd /dev/sde" BENCH_WIPE=1 \
  scripts/run-bench.sh btrfs raid1
```

Safety: devices must be unmounted, and anything carrying a filesystem
signature is refused unless `BENCH_WIPE=1`. **Listed devices are wiped.**

To drive real hardware from GitHub: register the machine as a
[self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners),
then trigger the workflow manually (`workflow_dispatch`) with `runs_on` set to
your runner label and `devices` set to the disks to use. Scale up workload
sizes via env (`SEQ_SIZE`, `AGING_SIZE`, `AGING_ITERS`, …) — CI defaults are
sized for 4×16 GB loop files.

### Locally (Linux, loop devices)

```sh
sudo scripts/install-deps.sh btrfs
sudo scripts/run-bench.sh btrfs raid1
scripts/summarize.sh results/result-*.json
```

## Layout

```
scripts/run-bench.sh      orchestrates the phases, emits results/result-<fs>-<layout>.json
scripts/lib/common.sh     device layer (loop files or BENCH_DEVICES), fio helpers
scripts/fs/<fs>.sh        per-filesystem backend: mkfs/mount, snapshot, compression, teardown
scripts/install-deps.sh   Debian/Ubuntu package setup per filesystem
scripts/summarize.sh      JSON results → markdown table
```

Adding a filesystem = one file in `scripts/fs/` implementing `fs_setup`,
`fs_snapshot`, `fs_setup_compression`, `fs_compress_ratio`, `fs_teardown`.

## Roadmap

- [ ] Kernel matrix: boot mainline kernels in qemu (runners support nested KVM)
      and track behavioral regressions per kernel release
- [ ] Persist results to a branch + static dashboard charting trends over time
- [ ] Degraded-mode tests: yank a device, measure degraded mount + rebuild/scrub time
- [ ] send/receive and device add/remove/rebalance timing
