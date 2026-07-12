# modern-fs-benchmark

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
| host calibration | fio on the runner's own disk *before* any filesystem exists — a VM-noise anchor |
| seq / rand write, rand read | baseline throughput on the chosen redundancy layout |
| fsync tail latency | p99 / p99.9 fdatasync completion latency from the random-write phase — CoW transaction commits (ZFS txg, btrfs commit interval) spike periodically in ways the IOPS average hides |
| snapshot aging | random-overwrite bandwidth as snapshots accumulate (CoW fragmentation cost) — **100 snapshots** where the technology allows; ZFS at 128K recordsize pins ~the whole file per snapshot so its default-recordsize layouts run 10, and old-style LVM snapshots amplify every origin write per snapshot so lvm layouts run 8 (both caps are findings, not shortcuts) |
| snapshot create | metadata cost of taking a snapshot |
| snapshot delete + reclaim | delete latency, foreground write bandwidth while background cleaning runs, time until the space actually returns |
| compression | zstd ratio + write throughput on 75%-compressible data |
| reflink | `cp --reflink=always` of a large file |
| degraded + rebuild | fail one device: IO while degraded, then time the rebuild onto a spare |
| snapshot-count scaling | 500 snapshots with no churn between them: create latency at the tail, snapshot-list time, remount time, bulk delete (native-snapshot filesystems) |
| near-full / ENOSPC | on a fresh small array of the same layout: write throughput near 95% and 99% full, then fill to hard ENOSPC — can you still delete (CoW needs free space to delete), and does deleting make the fs writable again? Caveat: btrfs hits its chunk-allocation wall *before* df crosses the target on small devices (1G data chunks are a big fraction of a CI-sized array — on multi-TB disks the same wall sits at 99.9%), so its probes run at the wall; the actual fullness at each probe is recorded in the JSON (`nearfull*_pct`) |
| corruption + scrub | write 2G of garbage onto one device behind the filesystem's back, scrub, verify the data: CoW filesystems detect and repair from checksums; md/lvm only count mismatches and may silently serve the corrupted copy |

Results are published as a dashboard: **<https://bartosz.fenski.pl/modern-fs-benchmark/>**
(charts for the latest run, aging curves, and trends across runs; history lives
on the `results-data` branch).

Every result records the exact tools *and kernel-module* versions tested —
essential for ZFS and bcachefs, which are out-of-tree, where the kernel
version alone doesn't identify what actually ran. Shown in the dashboard
table, stored in the JSON.

Default matrix (4 devices, 2-copy redundancy, plus baselines):

- **ext4 single** — one device, the "what does any of this cost" anchor
- **ext4 on md raid10** — the classic layered stack
- **ext4 on LVM raid10** — layered stack with block-layer CoW snapshots,
  so the snapshot-aging phase is comparable with the native-CoW filesystems
- **xfs single / on md raid10 / on LVM raid10** — the same three stacks again;
  XFS additionally has reflink, unlike ext4
- **btrfs / bcachefs / ZFS single-device** — the CoW filesystems without
  redundancy, head-to-head with ext4/xfs single: the pure cost (and features)
  of CoW itself
- **Encryption variants** — ZFS native per-dataset AES-256-GCM
  (`mirror-enc`), bcachefs native whole-fs ChaCha20/Poly1305
  (`replicas2-enc`), btrfs over one LUKS layer *per device*
  (`raid1-luks` — no native option, so every replica is encrypted
  separately), and ext4 over a single LUKS layer on top of md
  (`md-raid10-luks` — the classic stack encrypts once, above the raid).
  Compression runs on all of them, so encrypt-after-compress vs
  opaque-blocks falls out of the existing zstd phase
- **btrfs** — `-d raid1 -m raid1`
- **ZFS** — striped mirror pairs (raid10-like), at the default 128K recordsize
  and again at `recordsize=8k` — one-variable proof of how much of ZFS's
  small-random-write cost is configuration, not design
- **bcachefs** — `--replicas=2` (kernel module built via DKMS from
  [apt.bcachefs.org](https://apt.bcachefs.org/) since bcachefs left mainline in 6.17)

## How it runs

### CI (GitHub Actions, loop devices)

Every push/2-hourly cron builds each filesystem across 4 loop devices backed by
sparse files, runs the suite, and publishes a results table in the job summary
plus JSON artifacts.

**Interpret CI numbers carefully.** Runners are shared VMs and all "devices"
live on one virtual disk, so absolute MB/s is meaningless and RAID striping
gains are fiction. Matrix jobs also run in parallel, **each on its own
ephemeral VM** — so comparing filesystem A against filesystem B compares two
different machines. Mitigations, from strongest signal to weakest:

1. *Within-job* ratios and shapes (aging curve slope, compression on/off,
   degraded vs healthy) — same VM, same disk, directly meaningful.
2. Every job runs a **host calibration** first (fio on the runner's disk,
   before any filesystem exists). Jobs on VMs below the calibration floor
   (`CALIB_MIN_*`, ~25% of runners' normal disk speed margin) **fail fast
   and are automatically rerun on a fresh runner** (up to 3 attempts) —
   junk numbers from an unlucky VM never enter the results.
3. Cross-filesystem deltas within one run — treat small differences (tens of
   percent) as noise; large ones (2×+) are usually real.
4. Trends over repeated runs (2-hourly cron + every push) average the VM
   lottery out — this is where cross-filesystem conclusions belong.

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

**The plan is bigger than loop devices.** CI is the regression-tracking
harness; the goal is to gather dedicated hardware and run the REAL tests
there — including the tiered topologies these filesystems were built for and
that no publication benchmarks today: NVMe cache/metadata in front of
rotational data disks (bcachefs foreground/background targets, ZFS
special/log/cache vdevs, LVM dm-cache with writeback and writethrough),
mixed-rotational RAID, and how each setup behaves degraded and while
rebuilding. Same suite, same JSON, same dashboard — only the device lists and
topology descriptions change. If you have hardware or topology suggestions,
open an issue.

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

## Ideas, hints, and requests welcome

This suite is deliberately open-ended — if you have opinions on **what to
test and how**, please open an issue or PR:

- workloads that would expose behavior the current phases miss
  (databases, VM images, send/receive, metadata-heavy trees, …)
- extra configurations and tuning you want measured: mount options,
  recordsize/extent knobs, compression algorithms and levels, RAID
  profiles, SLOG/special vdevs, `nodatacow`, …
- fairness problems in the methodology — if a filesystem is being
  measured in a way that misrepresents it, that's a bug here
- additional filesystems or layered stacks (a backend is one small file
  in `scripts/fs/`)

Tuned variants sit next to the defaults in the same matrix (see
`zfs mirror-8k`), so every suggestion becomes a directly comparable row.

## Roadmap

CoW-specific phases (the behaviors nothing mainstream benchmarks):

- [ ] **Clone divergence**: first-write-after-reflink/-snapshot cost — the
      unshare penalty; XFS participates, making it integrated-vs-classic
- [ ] **send/receive**: full + incremental stream throughput (btrfs, ZFS);
      rsync over the classic stack as the contrast; bcachefs: not available
- [ ] **ext4 fscrypt** variant (directory-level encryption — the third model
      next to native and block-layer)

Infrastructure:

- [ ] Kernel matrix: boot mainline kernels in qemu (runners support nested KVM)
      and track behavioral regressions per kernel release
- [ ] Device add/remove/rebalance timing
- [ ] Normalize cross-job comparisons by the calibration anchor in the dashboard
