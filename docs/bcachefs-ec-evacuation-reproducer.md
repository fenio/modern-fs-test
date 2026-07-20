# bcachefs EC evacuation stall reproducer

## Observed failure

The benchmark intermittently stalls while replacing one member of a four-device
bcachefs EC filesystem. The exact command is:

```sh
bcachefs device evacuate /dev/loop1
```

The command normally migrates about 3.48 GiB and finishes in roughly one minute.
On failing runs it reaches a small remainder, then reports the same value until
the 60-minute GitHub Actions job timeout:

- 332 KiB remaining for 2,802 samples
- 584 KiB remaining for 2,807 samples
- 900 KiB remaining for 2,775 samples

The host calibration is normal on these attempts. The filesystem uses bcachefs
tools and module 1.38.8 on kernel 7.0.0-1009-azure.

Examples:

- [run 29724829904, attempt 1](https://github.com/fenio/modern-fs-benchmark/actions/runs/29724829904/job/88295417320)
- [run 29724829904, attempt 2](https://github.com/fenio/modern-fs-benchmark/actions/runs/29724829904/job/88307306495)
- [run 29696521649, timed-out attempt](https://github.com/fenio/modern-fs-benchmark/actions/runs/29696521649/job/88220237414)
- [run 29716072546, successful control](https://github.com/fenio/modern-fs-benchmark/actions/runs/29716072546/job/88273318813)

The closest known report is
[koverstreet/bcachefs#1182](https://github.com/koverstreet/bcachefs/issues/1182),
where EC reconcile wedges after stripe-buffer memory exceeds its limit and
moving contexts stop making progress. Existing benchmark artifacts prove the
blocking command but do not contain enough kernel state to establish that both
failures have the same cause.

## Reduced reproduction result

The first four-attempt run of the standalone case reproduced the stall once:

- [workflow run 29740996573](https://github.com/fenio/modern-fs-benchmark/actions/runs/29740996573)
- [failed attempt](https://github.com/fenio/modern-fs-benchmark/actions/runs/29740996573/job/88347471981)
- [diagnostic artifact](https://github.com/fenio/modern-fs-benchmark/actions/runs/29740996573/artifacts/8460769148)

Three identical attempts completed successfully. The fourth moved 3.97 GiB in
about 90 seconds, reached exactly 2.69 MiB, then remained unchanged until the
10-minute command timeout.

The live diagnostic snapshot showed:

- bcachefs tools and module 1.38.8 on kernel 7.0.0-1009-azure
- the reconcile thread in uninterruptible sleep in
  `__bch2_closure_sync_timeout` from `do_reconcile`
- two `reconcile_work` moving contexts with zero bytes and zero IO in flight
- the evacuating member retaining 708 KiB user data and 2 MiB parity
- 789 MiB pending EC reconcile and 708 KiB high-priority replica work
- one 2+2 stripe in flight
- only 4 MiB of 799 MiB EC stripe-buffer memory in use

The last point does not match the stripe-buffer exhaustion reported in issue
#1182. This may be a different reconcile/evacuation forward-progress bug, or a
second path to the same closure wait. The captured artifact is intended to let
upstream distinguish those cases.

Two attempted pre-degrade `bcachefs reconcile wait` controls were discarded:
[run 29746041465](https://github.com/fenio/modern-fs-benchmark/actions/runs/29746041465)
and [run 29748213670](https://github.com/fenio/modern-fs-benchmark/actions/runs/29748213670).
The remaining normal-priority EC work was tied to an open stripe and the
reconcile thread was deliberately rate-limited on the write IO clock. Those
timeouts occurred before any member was offlined, but do not establish an
independent reconcile bug or a safe barrier before device loss.

## Standalone reproducer

The script creates five disposable 16 GiB sparse loop devices, formats four as
a 2+2 EC filesystem with replicas=3, generates sequential and 4 KiB random
write churn, offlines one member, writes and reads while degraded, adds the
fifth loop as a spare, and evacuates the original member.

It never accepts or modifies real block devices.

```sh
sudo scripts/install-deps.sh bcachefs
sudo OUTPUT_DIR="$PWD/repro-output" \
  scripts/repro-bcachefs-ec-evacuate.sh
```

Expected success: evacuation completes in about one minute.

Observed failure signature: evacuation drops below 1 MiB remaining and makes
no further progress. The default command timeout is 12 minutes, with a live
diagnostic snapshot after three minutes.

Timeout override:

```sh
sudo BCACHEFS_EVAC_DIAG_AFTER=60 BCACHEFS_EVAC_TIMEOUT=5m \
  OUTPUT_DIR="$PWD/repro-fast" \
  scripts/repro-bcachefs-ec-evacuate.sh
```

The manual `reproduce-bcachefs-ec-evacuation` workflow runs four independent
attempts and uploads each diagnostic bundle even when evacuation times out.

The full workload that originally exposed the failure remains available as a
control:

```sh
sudo DEV_SIZE=16G AGING_ITERS=100 AGING_IO=64M SNAPSCALE_COUNT=500 \
  RESULTS_DIR="$PWD/results" scripts/run-bench.sh bcachefs ec
```

## Captured evidence

Each attempt records:

- kernel, tools, and module versions
- fio seed, churn, and degraded-I/O JSON
- full evacuation progress
- `bcachefs fs usage -a -h`
- `bcachefs reconcile status`
- `reconcile_status`
- `internal/moving_ctxts`
- `internal/new_stripes`
- `internal/alloc_debug`, when available
- `ec_stripe_buf_limit` and `move_bytes_in_flight`
- IO and memory pressure
- bcachefs process stacks
- SysRq blocked-task report and `dmesg` on a stall

## Upstream report draft

> bcachefs 1.38.8 intermittently stops making progress during device
> evacuation on a four-device 2+2 EC filesystem. The test offlines one member,
> performs 30 seconds of 4 KiB random writes and reads while degraded, brings
> the member online, adds a fifth device, then evacuates the original member.
> The standalone case reproduced on its first four-attempt run: three attempts
> passed and one moved 3.97 GiB, stopped at exactly 2.69 MiB, and timed out after
> ten minutes. At the stall, bch-reconcile was in D state in
> __bch2_closure_sync_timeout from do_reconcile; moving contexts showed no IO in
> flight; the member retained 708 KiB user data plus 2 MiB parity. Unlike issue
> #1182, internal/new_stripes showed only 4 MiB of 799 MiB stripe-buffer memory
> in use. The attached bundle includes usage, reconcile status, new_stripes,
> moving contexts, blocked tasks, pressure, and the kernel log.
