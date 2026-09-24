# AST-21 reproducer

All files are public-API user programs. None of them needs a kernel change.
The recorded runs used Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`
with `SMP=2`. The bug is a timing boundary, so every program loops many times
and stops at the first bad outcome.

## Files and their sources

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bug6_poll_timeout_race.c` | extracted from `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/changes.patch` (`test/initramfs/src/regression/io/specula/repro/test_bug6_poll_timeout_race.c`, SHA-256 `8700a82b...`) | Round-6 boundary test, 2000 attempts, counts zero-then-readable outcomes |
| `specula_validation.c` | extracted from the same `changes.patch` (`test/initramfs/src/regression/io/specula/specula_validation.c`) | Stage-2 driver. Case `poll_timeout_race` has the same 2000-attempt loop. |
| `test_bugMC-6_poll_timeout_race.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/repro/test_bugMC-6_poll_timeout_race.c` (SHA-256 `aa222dff...`) | Turn-A variant, 20000 attempts, stops at the first reproduction |
| `test_bugMC-6_ordered_timerfd_poll.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-6_ordered_timerfd_poll.c` | Challenger probe with a timestamp oracle (helper sees `POLLIN` at least 0.5 ms before `poll` returns 0) |
| `test_bugMC-6_proc_ordered_timerfd_poll.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-6_proc_ordered_timerfd_poll.c` (SHA-256 `aa86dd2d...`) | Canonical challenger probe with a `/proc` sleep-state oracle |
| `specula-initramfs-plumbing.patch` | `git diff` against a clean export of the pin, built from the plumbing file diffs in `changes.patch` | Packages tests into the initramfs and lets `SPECULA_INIT` choose the init command |

The plumbing patch excludes the run's TLA+ trace instrumentation and the trace
harness `specula_fd_trace.c`. It applies cleanly to the pin.

## Where the files go

1. At the root of an Asterinas tree at the pin, run
   `git apply specula-initramfs-plumbing.patch`.
2. Copy the program you want into
   `test/initramfs/src/regression/io/specula/test_bug6_poll_timeout_race.c`.
   The confirmation runs did exactly this: they placed each MC-6 variant at the
   path of the standalone test (the recorded tree used
   `repro/test_bug6_poll_timeout_race.c` behind a two-line `#include` wrapper)
   and booted it with the command below. The directory `Makefile` builds with
   `-static -lpthread`, which the two probes with a helper thread need.

## How to run

Inside Docker image `asterinas/asterinas:0.18.0-20260702` with
`--privileged --device /dev/kvm`, the tree at the working directory, and
`RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu`:

```sh
make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug6_poll_timeout_race"
```

For the Stage-2 driver, use
`SPECULA_INIT="/test/io/specula/run_validation.sh poll_timeout_race"`.
The recorded round-6 Docker command also mounted a local archive of
`inherit-methods-macro` rev `98f7e3e` and a Cargo config override, because
Cargo could not fetch it in that environment. The turn-A run also set
`VDSO_LIBRARY_DIR=/root/linux_vdso`.

OSDK can reuse a previously built bundle when only the initramfs input changes.
After swapping the test source, check that the guest prints the markers of the
program you intended (for example `MC6B_PROC_*`), and discard runs that print
another program's markers.

On Linux, compile with `-pthread` and run directly.

## Reading the output

| Program | FAIL on Asterinas (bug present) | PASS on Linux |
|---|---|---|
| `test_bug6_poll_timeout_race` | `SPECULA_REGRESSION_FAIL poll_timeout_race: N/2000 timeout returns were immediately readable`, exit 1 (recorded N = 1 to 5) | `SPECULA_REGRESSION_PASS poll_timeout_race` |
| `test_bugMC-6_poll_timeout_race` | `MC6_REPRODUCED attempt=K poll_result=0 revents=0x0 ticks=1`, exit 1 | `MC6_NO_REPRO attempts=20000`, exit 0 |
| `test_bugMC-6_ordered_timerfd_poll` | `MC6B_STRICT_REPRO attempt=K poll_result=0 ticks=1 ready_lead_ns=...`, exit 1 | `MC6B_NO_STRICT_REPRO ...`, exit 0 |
| `test_bugMC-6_proc_ordered_timerfd_poll` | `MC6B_PROC_STRICT_REPRO attempt=K poll_result=0 ticks=1 ready_lead_ns=...`, exit 1 | `MC6B_PROC_NO_STRICT_REPRO attempts=1000 ... boundary_only=0`, exit 0 |

For the `/proc`-ordered probe, the `ready_lead_ns` value is sampled after the
helper's status read and can be negative. The ordering oracle is that the
helper saw `POLLIN` while the poller still reported `S (sleeping)`, not the
timestamp. The counter `boundary_only` counts zero-then-readable results that
lack that ordering proof. Those are not treated as failures because Linux
permits an expiry between the timeout return and the read.

## SMP setting

Use `SMP=2` or more. All recorded Asterinas runs used `SMP=2`. The ordered
probes need a second CPU for the helper thread to observe the sleeping poller.
