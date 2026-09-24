# AST-18 reproducer

All files are public-API user programs. None of them needs a kernel change.
The recorded runs used Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`
with `SMP=2`.

## Files and their sources

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bug4_epoll_dead_interest.c` | extracted from `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/changes.patch` (`test/initramfs/src/regression/io/specula/repro/test_bug4_epoll_dead_interest.c`) | Standalone regression (round 6). Parses the exact `tfd:` number. |
| `specula_validation.c` | extracted from the same `changes.patch` (`test/initramfs/src/regression/io/specula/specula_validation.c`) | Stage-2 multi-case driver. Case `dead_interest` is this finding (round 5). |
| `test_bugMC-3_dead_interest.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-3_dead_interest.c` | Confirmation turn A program. It is written to run as the guest init process: it mounts `/proc`, prints to `/dev/ttyS0`, and powers the machine off. It reports any `tfd:` line, not only the closed number. |
| `specula-initramfs-plumbing.patch` | `git diff` against a clean export of the pin, built from the plumbing file diffs in `changes.patch` | Packages the tests into the initramfs and lets `SPECULA_INIT` choose the init command |

The plumbing patch excludes the run's TLA+ trace instrumentation and the trace
harness `specula_fd_trace.c`. It applies cleanly to the pin.

## Where the files go

1. At the root of an Asterinas tree at the pin, run
   `git apply specula-initramfs-plumbing.patch`.
2. Copy `test_bug4_epoll_dead_interest.c` and `specula_validation.c` into
   `test/initramfs/src/regression/io/specula/`. Each top-level `.c` there is
   built statically into `/test/io/specula/<name>`.
3. `test_bugMC-3_dead_interest.c` is not meant for that directory. Build it as
   a static binary and boot it as init if you want to repeat turn A. The exact
   turn-A boot command is not recorded in full in the retained logs.

## How to run

Recorded round-6 command, inside Docker image
`asterinas/asterinas:0.18.0-20260702` with `--privileged --device /dev/kvm`,
the tree at `/root/asterinas`, and
`RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu`:

```sh
make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug4_epoll_dead_interest"
```

For the Stage-2 driver, use
`SPECULA_INIT="/test/io/specula/run_validation.sh dead_interest"`.
The recorded Docker command also mounted a local archive of
`inherit-methods-macro` rev `98f7e3e` and a Cargo config override, because
Cargo could not fetch it in that environment.

On Linux, compile and run `test_bug4_epoll_dead_interest.c` directly.

## Reading the output

| Program | FAIL on Asterinas (bug present) | PASS on Linux |
|---|---|---|
| `test_bug4_epoll_dead_interest` | `SPECULA_REGRESSION_FAIL dead_interest: closed file remains in epoll interest list`, exit 1 | `SPECULA_REGRESSION_PASS dead_interest`, exit 0 |
| `specula_validation dead_interest` | `SPECULA_REGRESSION_FAIL dead_interest: closed file remains in epoll interest list (errno=0)` | `SPECULA_REGRESSION_PASS dead_interest` |
| `test_bugMC-3_dead_interest` (as init) | prints the fdinfo, then `MC-3: REPRODUCED stale interest remains after final close` and powers off with status 0 | `MC-3: NOT REPRODUCED no stale interest remains`, status 1 |

Note the inverted exit status of `test_bugMC-3_dead_interest`: status 0 means
the bug was observed.

If the standalone test exits 1 without printing, the initial fdinfo check or
the close failed. That is a setup failure.

## SMP setting

All recorded Asterinas runs used `SMP=2`. The sequence is single-threaded.
