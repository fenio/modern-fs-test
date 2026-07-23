# modern-fs-benchmark

Continuous benchmarks for **multi-device, copy-on-write filesystems** — btrfs,
ZFS, bcachefs — measuring the things single-device ext4-style benchmarks
(Phoronix et al.) never touch: redundancy layouts, snapshot aging and scaling,
transparent compression, encryption (native vs LUKS), reflinks, fsync tail
latency, degraded operation and rebuild, corruption self-healing, and
near-full/ENOSPC behavior — with ext4/xfs over md/LVM as the classic-stack
baselines.

## Why

Classic filesystem benchmarks run fio on one device with default mkfs options.
That says nothing about what modern filesystems are actually deployed for.
This suite benchmarks the *machinery*:

| Phase | What it measures |
|---|---|
| host calibration | fio on the runner's own disk *before* any filesystem exists — a VM-noise anchor |
| seq / rand write, rand read | baseline throughput on the chosen redundancy layout |
| trivial-op latency under load | "how long until my prompt comes back": a 4k write+fsync every 200ms (shell history, editor swap), p99 and worst case — idle, then while a 1M streaming writer floods the filesystem; CoW commit storms live here |
| source-tree ops | create / cold `cp -r` / `rm -rf` of a 20k-small-file tree — the "copy a kernel tree" test |
| large-directory scalability | create 100k empty files in one directory, enumerate names cold, stat every entry cold and warm, then delete — directory indexing and inode-cache behavior that tree-shaped workloads miss (`LARGEDIR_FILES=1000000` reproduces the [million-file variant](https://paste.sr.ht/~arya_elfren/31e435822ca401cdf4c64de8d13c45f56973ec0f)) |
| parallel random read | same cold-cache read with 4 concurrent threads — a mirror can only serve from both copies under concurrency, so this is where replica read-scaling shows (on real hardware; CI loop devices share one disk and physically can't) |
| fsync tail latency | p99 / p99.9 fdatasync completion latency from the random-write phase — CoW transaction commits (ZFS txg, btrfs commit interval) spike periodically in ways the IOPS average hides |
| snapshot aging | random-overwrite bandwidth as snapshots accumulate (CoW fragmentation cost) — **100 snapshots** where the technology allows; ZFS at 128K recordsize pins ~the whole file per snapshot so its default-recordsize layouts run 10, and old-style LVM snapshots amplify every origin write per snapshot so lvm layouts run 8 (both caps are findings, not shortcuts) |
| snapshot create | metadata cost of taking a snapshot |
| snapshot delete + reclaim | delete latency, foreground write bandwidth while background cleaning runs, time until the space actually returns |
| compression | zstd ratio + write throughput on 75%-compressible data |
| reflink | `cp --reflink=always` of a large file |
| clone divergence | the unshare penalty: the same 4k-overwrite workload into a plain file, a fresh reflink clone (btrfs/bcachefs/xfs), and a freshly-snapshotted file (CoW filesystems and LVM) |
| degraded + rebuild | fail one device: IO while degraded, then time the rebuild onto a spare |
| snapshot-count scaling | 500 snapshots with no churn between them: create latency at the tail, snapshot-list time, remount time, bulk delete (native-snapshot filesystems) |
| near-full / ENOSPC | on a fresh small array of the same layout: write throughput near 95% and 99% full, then fill to hard ENOSPC — can you still delete (CoW needs free space to delete), and does deleting make the fs writable again? Caveat: btrfs hits its chunk-allocation wall *before* df crosses the target on small devices (1G data chunks are a big fraction of a CI-sized array — on multi-TB disks the same wall sits at 99.9%), so its probes run at the wall; the actual fullness at each probe is recorded in the JSON (`nearfull*_pct`) |
| corruption + scrub | write 2G of garbage onto one device behind the filesystem's back, scrub, verify the data: CoW filesystems detect and repair from checksums; md/lvm only count mismatches and may silently serve the corrupted copy |

Results are published as a dashboard: **<https://bartosz.fenski.pl/modern-fs-benchmark/>**
— per-metric charts sorted best-first, aging curves, and trends across runs,
filterable by filesystem family and layout class (e.g. "btrfs vs bcachefs,
multi-device only"), with linear/log scale switching and a sortable table.
Run history lives on the `results-data` branch.

Every result records the exact tools *and kernel-module* versions tested —
essential for ZFS and bcachefs, which are out-of-tree, where the kernel
version alone doesn't identify what actually ran. Shown in the dashboard
table, stored in the JSON.

Default matrix — 26 configurations (4 devices, plus baselines; the
authoritative list is the matrix in `.github/workflows/bench.yml`):

- **ext4 single** — one device, the "what does any of this cost" anchor
- **ext4 on md raid10** — the classic layered stack
- **ext4 on LVM raid10** — layered stack with block-layer CoW snapshots,
  so the snapshot-aging phase is comparable with the native-CoW filesystems
- **xfs single / on md raid10 / on LVM raid10** — the same three stacks again;
  XFS additionally has reflink, unlike ext4
- **btrfs / bcachefs / ZFS single-device** — the CoW filesystems without
  redundancy, head-to-head with ext4/xfs single: the pure cost (and features)
  of CoW itself. btrfs uses `-m single`: mkfs defaults to DUP metadata on a
  single device, which would double its metadata writes vs every other
  single-device row (community catch)
- **Encryption variants** — ZFS native per-dataset AES-256-GCM
  (`mirror-enc`), bcachefs native whole-fs ChaCha20/Poly1305
  (`replicas2-enc`), btrfs over one LUKS layer *per device*
  (`raid1-luks` — no native option, so every replica is encrypted
  separately), and ext4 over a single LUKS layer on top of md
  (`md-raid10-luks` — the classic stack encrypts once, above the raid).
  Compression runs on all of them, so encrypt-after-compress vs
  opaque-blocks falls out of the existing zstd phase
- **btrfs** — `-d raid1 -m raid1`
- **Single-parity** — zfs `raidz1`, plus `raidz1-enc` with native encryption
  on top (community request)
- **Dual-parity (raid6-class)** — zfs `raidz2` (and `raidz2-enc`,
  community request), btrfs `-d raid6 -m raid1c3`
  (parity metadata is discouraged — write hole), ext4 on md raid6, and
  bcachefs `--erasure_code --replicas=3` (stable since 1.37; write-hole-free
  by design — writes replicate first, background reconcile stripes them)
  (community request, incl. the correction that EC is no longer experimental)
- **xfs on a ZFS zvol** — the Franken-stack people actually run: XFS
  semantics on top; ZFS snapshots (fsfreeze-consistent), self-healing,
  and compression underneath (community request)
- **xfs on LVM raid10 + dm-integrity** (`--raidintegrity y`) — per-sector
  checksums give the classic stack detection AND correction: the fairest
  classic-vs-CoW comparison in the corruption phase, with the performance
  tax quantified (community request)
- **ZFS** — striped mirror pairs (raid10-like), at the default 128K recordsize
  and again at `recordsize=8k` — one-variable proof of how much of ZFS's
  small-random-write cost is configuration, not design
- **bcachefs** — `--replicas=2` (kernel module built via DKMS from
  [apt.bcachefs.org](https://apt.bcachefs.org/) since bcachefs left mainline in 6.17)

  If you want to try bcachefs as a working storage system rather than just
  benchmark it, [NASty](https://github.com/nasty-project/nasty) is a NixOS-based
  NAS appliance built around it and a practical place to start.

## The point is data integrity, not the winner's podium

Benchmark charts invite "which is fastest". For long-term storage that is
the wrong question — the right one is **which stack tells you the truth
about your data**, and it's why this suite exists (the corruption phase
re-proves it every couple of hours):

- **ext4/xfs on md or LVM raid — the default "safe" Linux setup — has no
  data checksums.** Raid protects against a *missing* disk, not a *lying*
  one: when a copy goes bad (disk firmware, cable, controller, bad RAM,
  power cut mid-write), the array cannot tell which copy is right. In our
  corruption test these stacks return garbage to the application **with no
  error whatsoever** — reads succeed, exit codes are 0, and the damage
  propagates into backups silently. A scrub *counts* mismatches; it cannot
  say which side is correct.
- **btrfs, ZFS, and bcachefs verify every read against checksums** and,
  given any redundancy, repair the bad copy on the fly. Every corruption
  run so far: all injected errors detected, all repaired, file contents
  intact — including under native encryption and on parity layouts.
- **The classic stack *can* buy the same guarantee** — LVM raid with
  `--raidintegrity y` (dm-integrity) is the first classic layout to pass
  our corruption phase — but almost nobody runs it, and the performance
  tax is measurable (that's the `xfs/lvm-raid10-int` row).

Speed matters and we measure it honestly. But if you keep data you care
about — photos, archives, the family's one copy of anything — on a
non-checksumming stack, no benchmark number compensates for corruption you
won't discover until years later. That risk is invisible in every classic
filesystem benchmark; here it's a first-class result
(*corruption + scrub* on the dashboard).

## How it runs

### CI (GitHub Actions, loop devices)

Every push/2-hourly cron builds each filesystem across 4 loop devices backed by
sparse files, runs the suite, and publishes a results table in the job summary
plus JSON artifacts. Each job's artifact also contains a **full command trace**
(`raw/<config>-trace.log`) — every command executed, arguments fully expanded,
with source file and line — so "what exactly was run" is never a question.
(`BENCH_TRACE=1` mirrors it into the live log instead.)

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

For an unmanaged hardware run, invoke `scripts/run-bench.sh` directly with
`BENCH_DEVICES`, `BENCH_SPARE_DEVICE`, and `BENCH_WIPE=1`. The dedicated
self-hosted GitHub workflow instead requires the NixOS module below; it never
accepts device paths from workflow inputs. Workload sizes can be adjusted with
`SEQ_SIZE`, `AGING_SIZE`, `AGING_ITERS`, and the other documented environment
variables. CI defaults are sized for 4×16 GB loop files.

#### NixOS / deploy-rs

This repository is also a flake with a reusable NixOS module and benchmark
package. Cluster configurations can import `nixosModules.modern-fs-benchmark`;
the module installs a dedicated Actions
runner, the filesystem tools and matching out-of-tree modules for the
cluster-selected kernel, and a restricted root wrapper with fixed device paths.
It deliberately does not select a kernel or configure machine-wide boot,
networking, users, or partitioning.

```nix
{
  inputs.modern-fs-benchmark.url =
    "github:fenio/modern-fs-benchmark";

  # In the target node's modules list:
  services.modern-fs-benchmark = {
    enable = true;
    repository = "https://github.com/fenio/modern-fs-benchmark";
    tokenFile = "/run/secrets/modern-fs-benchmark-runner";
    runnerName = "farm3";
    runnerLabels = [ "fs-benchmark" ];
    devices = [
      "/dev/disk/by-partlabel/fsbench-nvme0-a"
      "/dev/disk/by-partlabel/fsbench-nvme1-a"
      "/dev/disk/by-partlabel/fsbench-nvme0-b"
      "/dev/disk/by-partlabel/fsbench-nvme1-b"
    ];
    spareDevice = "/dev/disk/by-partlabel/fsbench-nvme0-spare";
    zfsSingleDevice = "/dev/disk/by-partlabel/fsbench-nvme0-zfs-single";
  };
}
```

The four member devices and spare must each be exactly 16 GiB. The dedicated
`zfsSingleDevice` must be exactly 32 GiB, matching the hosted-runner matrix.
For an unregistered manual run, the same immutable package is available as
`nix run .#manual -- <fs> <layout>`; provide the documented `BENCH_*`
environment variables and run it as root.
Set `BENCH_HARDWARE_RANDOM_SCALING=1` to include the optional 8- and 16-worker
random read/write measurements and the 4/8/16-worker shard-aware write series
that the managed hardware wrapper enables.

The master cluster flake owns the node assignment and deploy-rs deployment, so
the runner can move to another machine without changing benchmark code. The
dedicated `bench-real-hw.yml` workflow targets the `fs-benchmark` label and
uses only the module's fixed devices. It publishes hardware history to
`results-real-hw` and the dashboard under `/real-hw/`; the existing `bench.yml`
workflow remains hosted-only and continues publishing `results-data` at the
root dashboard. Hardware runs can be dispatched manually. The weekly schedule
is enabled only when the repository variable `ENABLE_HARDWARE_BENCHMARKS` is
set to `true`. The token file should contain a fine-grained PAT because
ephemeral runners re-register after every job.

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
scripts/run-bench.sh       orchestrates the phases, emits results/result-<fs>-<layout>.json
scripts/lib/common.sh      device layer (loop files or BENCH_DEVICES), LUKS helpers,
                           corruption injection, fio helpers, default fs hooks
scripts/lib/layered.sh     shared md/LVM assembly, snapshots, degrade/repair (ext4 + xfs)
scripts/fs/<fs>.sh         per-filesystem backend
scripts/install-deps.sh    Debian/Ubuntu package setup per filesystem
scripts/summarize.sh       JSON results → markdown table (job summaries)
scripts/make-dashboard.py  results history → the static dashboard page
scripts/audit-results.py   anomaly scan over the results history — impossible
                           orderings, self-healing failures, ENOSPC regressions,
                           unexpected nulls (daily via the results-audit workflow)
scripts/result-schema.json machine-readable result keys, types, capabilities, and display metadata
scripts/result_schema.py   shared result schema loading and validation
scripts/validate-result.py validates result JSON against that contract
```

Result documents carry `schema_version`; historical unversioned documents are
treated as version 1 so new metrics do not invalidate the stored history.

Adding a filesystem = one file in `scripts/fs/` implementing `fs_setup`,
`fs_snapshot`, and `fs_teardown`; everything else (`fs_setup_compression`,
`fs_compress_ratio`, `fs_snapshot_delete_all`, `fs_remount`, `fs_snap_list`,
`fs_snapscale_delete`, `fs_degrade`, `fs_rebuild`, `fs_scrub`, `fs_version`,
`fs_drop_caches`, `fs_free_bytes`) has safe defaults in `lib/common.sh` and is
optional — unimplemented hooks simply record null for their metrics.

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

- [ ] **send/receive**: full + incremental stream throughput (btrfs, ZFS);
      rsync over the classic stack as the contrast; bcachefs: not available
- [ ] **Partial device loss**: device disappears briefly and returns — md
      write-intent bitmaps, ZFS delta resilver, bcachefs journal catch-up;
      a different (and common) recovery scenario than full-device rebuild
- [ ] **lvm-thin layouts**: our lvm rows use old-style snapshots, which are
      the known-bad strawman — thin pools are what modern LVM users run, with
      proper CoW snapshots that should survive the aging and snapshot-scaling
      phases at full count. Next up.
- [ ] **"The Tower"**: ext4/xfs on lvm-thin on dm-vdo on LUKS on raid on
      dm-integrity — the full feature-parity classic stack (checksums +
      redundancy + encryption + compression/dedup + CoW snapshots from five
      dm layers), versus the integrated filesystems that do it in one.
      Requested with a 😜 but taken seriously: dm-vdo is mainline since 6.9
      and thin-on-VDO is a documented configuration.
- [ ] **Stratis** (XFS on dm-thin/dm-integrity/dm-crypt, managed) — arguably
      the closest classic-stack analogue to btrfs (community suggestion)
- [ ] **NVMe cache tiers** (community request): bcachefs
      foreground/background targets, ZFS special/log/cache vdevs, LVM
      dm-cache — needs real mixed hardware; on CI loop devices both "tiers"
      are the same cloud SSD, so an honest cache benchmark is impossible
      there (see *Real hardware* above)
- [ ] **ext4 fscrypt** variant (directory-level encryption — the third model
      next to native and block-layer)

Infrastructure:

- [ ] Kernel matrix: boot mainline kernels in qemu (runners support nested KVM)
      and track behavioral regressions per kernel release
- [ ] Device add/remove/rebalance timing
- [ ] btrfs/raid1-luks degraded phase (loop-detach can't fail a dm-crypt
      mapper — needs the dm-error wrapper trick the lvm layouts use)
- [ ] Parse bcachefs scrub found/repaired counts (verdict via md5 works;
      the counts aren't in 1.38-tools output)
- [ ] Normalize cross-job comparisons by the calibration anchor in the dashboard

## License

Copyright 2026 Bartosz Fenski.

Source code, configuration, workflows, and documentation are licensed under the
[Apache License 2.0](LICENSE). Published benchmark result datasets, including
the `results-data` and `results-real-hw` history branches, are licensed under
[Creative Commons Attribution 4.0 International](LICENSE-DATA).
