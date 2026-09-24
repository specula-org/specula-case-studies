# AST-17 reproducer

All files are public-API user programs. None of them needs a kernel change.
The recorded runs used Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`
with `SMP=2`.

## Files and their sources

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bug2_epoll_efault_oneshot.c` | extracted from `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/changes.patch` (`test/initramfs/src/regression/io/specula/repro/test_bug2_epoll_efault_oneshot.c`) | Standalone regression (round 6) |
| `specula_validation.c` | extracted from the same `changes.patch` (`test/initramfs/src/regression/io/specula/specula_validation.c`) | Stage-2 multi-case driver. Case `copyout_oneshot` is this finding, and it is what confirmation turn A ran. |
| `test_bugMC-2_challenge.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_challenge.c` | Challenger Linux control. On failure it also rearms with `EPOLL_CTL_MOD` to show the eventfd value was not consumed. |
| `test_bugMC-2_oneshot_efault.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_oneshot_efault.sh` | Recorded wrapper for turn A. Kept as a record of the command. Its `target_repo` points to a confirmation worktree that no longer exists. |
| `specula-initramfs-plumbing.patch` | `git diff` against a clean export of the pin, built from the plumbing file diffs in `changes.patch` | Packages the tests into the initramfs and lets `SPECULA_INIT` choose the init command |

The plumbing patch excludes the run's TLA+ trace instrumentation
(`kernel/core/src/tla_trace.rs` and its hooks) and the trace harness
`specula_fd_trace.c`. It applies cleanly to the pin (`git apply --check`).

## Where the files go

1. At the root of an Asterinas tree at the pin, run
   `git apply specula-initramfs-plumbing.patch`.
2. Copy `test_bug2_epoll_efault_oneshot.c` and `specula_validation.c` into
   `test/initramfs/src/regression/io/specula/`. Every top-level `.c` there is
   built statically into `/test/io/specula/<name>`. The recorded tree kept the
   standalone body under `repro/` behind a two-line `#include` wrapper, which
   gives the same binary name.

## How to run

Recorded round-6 command, inside Docker image
`asterinas/asterinas:0.18.0-20260702` with `--privileged --device /dev/kvm`,
the tree at `/root/asterinas`, and
`RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu`:

```sh
make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug2_epoll_efault_oneshot"
```

Confirmation turn A ran the Stage-2 driver through the wrapper script, which
executes this inside the same image:

```sh
SMP=2 SPECULA_INIT="/test/io/specula/run_validation.sh copyout_oneshot" make run_kernel
```

The recorded round-6 Docker command also mounted a local archive of
`inherit-methods-macro` rev `98f7e3e` and a Cargo config override, because
Cargo could not fetch it in that environment.

Linux control, as recorded by the challenger:

```sh
cc -std=c11 -Wall -Wextra -Werror test_bugMC-2_challenge.c -o mc2 && timeout 30s ./mc2
```

## Reading the output

| Program | FAIL on Asterinas (bug present) | PASS on Linux |
|---|---|---|
| `test_bug2_epoll_efault_oneshot` | `SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT`, exit 1 | `SPECULA_REGRESSION_PASS copyout_oneshot` |
| `specula_validation copyout_oneshot` | `SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT (errno=0)` | `SPECULA_REGRESSION_PASS copyout_oneshot` |
| `test_bugMC-2_challenge` | `MC2_REPRO first=-1/EFAULT retry=0 rearm=1 token=...`, exit 1 (not run on Asterinas in the record) | `MC2_CONTROL_PASS first=-1/EFAULT retry=1 token=4d43325f45464155`, exit 0 |

The wrapper script exits 1 when it sees the FAIL marker, 0 on PASS, and 2 when
neither marker appears.

## SMP setting

All recorded Asterinas runs used `SMP=2`. The sequence is single-threaded.
