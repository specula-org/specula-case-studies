# AST-20 reproducer

All files are public-API user programs. None of them needs a kernel change.
The recorded runs used Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`
with `SMP=2`.

## Files and their sources

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bug5_signalfd_mask_transition.c` | extracted from `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/changes.patch` (`test/initramfs/src/regression/io/specula/repro/test_bug5_signalfd_mask_transition.c`) | Standalone regression (round 6). Level-triggered, signal queued after `EPOLL_CTL_ADD`. |
| `specula_validation.c` | extracted from the same `changes.patch` (`test/initramfs/src/regression/io/specula/specula_validation.c`) | Stage-2 multi-case driver. Case `signalfd_mask_transition` is this finding (round 5). |
| `test_bugMC-5_signalfd_mask_transition.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-5_signalfd_mask_transition.c` | Confirmation turn A. Adds a direct read and a fresh-signal control after the timeout. |
| `test_bugMC-5_signalfd_mask_transition.nix`, `.sh` | same directory | Turn-A build (Nix initramfs) and launcher (`cargo osdk run` with `SMP=2`, program as init) |
| `test_bugMC-5_exact_counterexample.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-5_exact_counterexample.c` | Challenger. Queues the signal before `EPOLL_CTL_ADD`, uses `EPOLLET`, adds a direct `poll` check. |
| `test_bugMC-5_exact_counterexample.nix`, `.sh` | same directory | Challenger build and launcher |
| `specula-initramfs-plumbing.patch` | `git diff` against a clean export of the pin, built from the plumbing file diffs in `changes.patch` | Packages tests into the initramfs, lets `SPECULA_INIT` choose init, and makes `initramfs.nix` accept the `specula` argument that the MC-5 `.nix` files pass |

A hand-written x86-64 assembly variant,
`/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-5_signalfd_mask_transition.S`,
is listed in the verdict artifacts but is not part of the recorded result and
is not copied here.

The plumbing patch excludes the run's TLA+ trace instrumentation and the trace
harness `specula_fd_trace.c`. It applies cleanly to the pin.

## Where the files go

1. At the root of an Asterinas tree at the pin, run
   `git apply specula-initramfs-plumbing.patch`.
2. Copy `test_bug5_signalfd_mask_transition.c` and `specula_validation.c` into
   `test/initramfs/src/regression/io/specula/`. Each top-level `.c` there is
   built statically into `/test/io/specula/<name>`.
3. The MC-5 `.nix` files take `sourceRepo` (default: a confirmation worktree
   path that no longer exists) and build an initramfs that installs the program
   at `/test/io/mc5/<name>`. Pass `--arg sourceRepo /path/to/asterinas` with the
   plumbing patch applied. The `.sh` launchers also hard-code the old run paths
   in `repo=` and `repro_dir=`. Edit those two variables before use.

## How to run

Recorded round-6 command, inside Docker image
`asterinas/asterinas:0.18.0-20260702` with `--privileged --device /dev/kvm`,
the tree at `/root/asterinas`, and
`RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu`:

```sh
make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug5_signalfd_mask_transition"
```

For the Stage-2 driver, use
`SPECULA_INIT="/test/io/specula/run_validation.sh signalfd_mask_transition"`.
The recorded Docker command also mounted a local archive of
`inherit-methods-macro` rev `98f7e3e` and a Cargo config override, because
Cargo could not fetch it in that environment.

Challenger command, as recorded in `confirmation/MC-5/reproduction.md` (the
temporary directories held a local OSDK build, a Cargo home, and a checkout of
the Linux vDSO tree that the launcher requires through `VDSO_LIBRARY_DIR`):

```sh
env MC5_OSDK_BIN_DIR=<osdk bin dir> MC5_QEMU_BIN_DIR=<qemu 11.0.3 bin dir> \
  MC5_RUSTUP_TOOLCHAIN=nightly-2026-07-21 MC5_OVMF=off \
  MC5_CARGO_TARGET_DIR=<target dir> CARGO_HOME=<cargo home> \
  VDSO_LIBRARY_DIR=<linux_vdso dir> \
  timeout 35m bash test_bugMC-5_exact_counterexample.sh
```

On Linux, compile and run any of the C files directly.

## Reading the output

| Program | FAIL on Asterinas (bug present) | PASS on Linux |
|---|---|---|
| `test_bug5_signalfd_mask_transition` | `SPECULA_REGRESSION_FAIL signalfd_mask_transition: mask update did not publish pending signal readiness`, exit 1 | `SPECULA_REGRESSION_PASS signalfd_mask_transition` |
| `specula_validation signalfd_mask_transition` | the same FAIL text with ` (errno=...)` appended | `SPECULA_REGRESSION_PASS signalfd_mask_transition` |
| `test_bugMC-5_signalfd_mask_transition` | `MC5_POSTUPDATE_EPOLL_WAIT=0`, `MC5_PENDING_SIGNAL_READ signo=10`, `MC5_CONTROL_POSTQUEUE_EPOLL_WAIT=1`, `MC5_REPRODUCED ...`, exit 1 | `MC5_POSTUPDATE_EPOLL_WAIT=1 events=0x1`, `MC5_NO_FAILURE ...`, exit 0 |
| `test_bugMC-5_exact_counterexample` | `MC5_CE_POSTUPDATE_EPOLL_WAIT=0`, `MC5_CE_DIRECT_POLL=1`, `MC5_CE_REPRODUCED ...`, exit 1 | `MC5_CE_POSTUPDATE_EPOLL_WAIT=1 events=0x1`, `MC5_CE_NO_FAILURE ...`, exit 0 |

When an MC-5 program runs as guest init, its nonzero exit makes the kernel
report an init-exit failure. That report is expected and is not the symptom.
A line starting with `MC5_FAIL step=` or `MC5_CE_FAIL step=` means a setup step
failed or the fresh-signal control did not wake epoll.

## SMP setting

All recorded Asterinas runs used `SMP=2` (`tools/qemu_args.sh` expands it to
`-smp 2`). The sequence is single-threaded.
