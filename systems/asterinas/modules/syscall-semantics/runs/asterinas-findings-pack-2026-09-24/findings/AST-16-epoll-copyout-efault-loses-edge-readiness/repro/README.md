# AST-16 reproducer

All files are public-API user programs. None of them needs a kernel change.
The recorded runs used Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`
with `SMP=2`.

## Files and their sources

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bug1_epoll_efault_et.c` | extracted from `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/changes.patch` (`test/initramfs/src/regression/io/specula/repro/test_bug1_epoll_efault_et.c`), byte-identical to `.specula-output/repro/test_bugMC-1_epoll_efault_et.c` | Main standalone regression (round 6 and confirmation turn A) |
| `test_bugMC-1_challenger.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-1_challenger.c` | Confirmation challenger with LT and successful-ET controls |
| `specula_validation.c` | extracted from the same `changes.patch` (`test/initramfs/src/regression/io/specula/specula_validation.c`) | Stage-2 multi-case driver. Case `copyout_et` is this finding (round 5). |
| `specula-initramfs-plumbing.patch` | `git diff` against a clean export of the pin, built from the file diffs in `changes.patch` for `Makefile`, `test/initramfs/Makefile`, `test/initramfs/nix/{default,initramfs}.nix`, `test/initramfs/nix/specula/default.nix`, and `test/initramfs/src/regression/io/specula/{Makefile,run_bug.sh,run_validation.sh}` | Build plumbing that packages the tests into the initramfs and lets `SPECULA_INIT` choose the init command |

The plumbing patch excludes the run's TLA+ trace instrumentation
(`kernel/core/src/tla_trace.rs` and its hooks in `lib.rs`, `events/epoll/file.rs`,
`syscall/{close,dup,eventfd,fcntl,prctl,signalfd}.rs`) and the trace harness
`specula_fd_trace.c`. The reproducer does not need them. It applies cleanly to
the pin (`git apply --check`).

## Where the files go

1. Apply the plumbing patch at the root of an Asterinas tree at the pin:
   `git apply specula-initramfs-plumbing.patch`.
2. Copy `test_bug1_epoll_efault_et.c` (and optionally `specula_validation.c`
   and `test_bugMC-1_challenger.c`) into
   `test/initramfs/src/regression/io/specula/`. The directory `Makefile`
   builds every top-level `.c` there with `-static -lpthread` into
   `/test/io/specula/<name>` in the guest. The recorded tree kept the test body
   under `repro/` and used a two-line top-level wrapper that only did
   `#include "repro/test_bug1_epoll_efault_et.c"`, which yields the same binary
   name.

## How to run

The recorded round-6 run used the Docker image
`asterinas/asterinas:0.18.0-20260702`, `--privileged --device /dev/kvm`, the
tree mounted at `/root/asterinas`, and
`RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu`:

```sh
make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug1_epoll_efault_et"
```

For the Stage-2 driver, use
`SPECULA_INIT="/test/io/specula/run_validation.sh copyout_et"`.

In that environment Cargo could not fetch `inherit-methods-macro` rev
`98f7e3e`, so the recorded Docker command also mounted a local archive of that
revision and a Cargo config override. This was an environment workaround, not a
source change.

The challenger ran `test_bugMC-1_challenger.c` as a static binary injected
into the initramfs of a sealed SMP=2 ISO. Only the test binary changed, and the
kernel SHA-256 (`1481841a...`) matched the artifact used by turn A. The exact
boot command is not recorded.

On Linux, compile and run any of the C files directly, for example
`cc -O2 test_bug1_epoll_efault_et.c -o t && ./t`. The exact host compiler flags
of the recorded controls are not recorded.

## Reading the output

| Program | FAIL on Asterinas (bug present) | PASS on Linux |
|---|---|---|
| `test_bug1_epoll_efault_et` | `SPECULA_REGRESSION_FAIL copyout_et: ready event was not retained after EFAULT`, exit 1 | `SPECULA_REGRESSION_PASS copyout_et`, exit 0 |
| `specula_validation copyout_et` | `SPECULA_REGRESSION_FAIL copyout_et: ready event was not retained after EFAULT (errno=0)` | `SPECULA_REGRESSION_PASS copyout_et` |
| `test_bugMC-1_challenger` | `MC1_CASE name=edge_after_efault ... second=0 ... unread=1` then `MC1_CHALLENGER_FAIL` | all three cases pass, then `MC1_CHALLENGER_PASS` |

If the first `epoll_wait` does not return `-1/EFAULT`, the standalone test exits
with failure and prints nothing. That is a setup failure, not the bug.

## SMP setting

All recorded Asterinas runs used `SMP=2`. The bug is deterministic and
single-threaded, so the CPU count is not expected to matter, but only `SMP=2`
was recorded.
