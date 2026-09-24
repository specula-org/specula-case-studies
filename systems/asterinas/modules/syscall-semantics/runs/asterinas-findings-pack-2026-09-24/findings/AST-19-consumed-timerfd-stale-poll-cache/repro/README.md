# AST-19 reproducer

All files are public-API user programs. None of them needs a kernel change.
The recorded runs used Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`
with `SMP=2`.

## Files and their sources

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bug3_timerfd_cache.c` | extracted from `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/changes.patch` (`test/initramfs/src/regression/io/specula/repro/test_bug3_timerfd_cache.c`) | Standalone regression (round 6). 1 ms one-shot timer, one poll, read, then `poll(0)`. |
| `specula_validation.c` | extracted from the same `changes.patch` (`test/initramfs/src/regression/io/specula/specula_validation.c`) | Stage-2 multi-case driver. Case `timerfd_cache` is this finding (round 5). |
| `test_bugMC-4_timerfd_cache.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/repro/test_bugMC-4_timerfd_cache.c` | Confirmation turn A. 100 ms timer, explicit cache-priming poll, three post-read polls. |
| `test_bugMC-4_guest-init.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/repro/test_bugMC-4_guest-init.sh` | Guest init script for turn A. Expects the static binary at `/test_bugMC-4_timerfd_cache.guest`. |
| `test_bugMC-4_challenge.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-4_challenge.c` | Challenger. 100 ms timer, read, then a 75 ms poll and a `poll(0)`. |
| `test_bugMC-4_challenge-init.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-4_challenge-init.sh` | Guest init script for the challenger. Expects `/test_bugMC-4_challenge.guest`. |
| `specula-initramfs-plumbing.patch` | `git diff` against a clean export of the pin, built from the plumbing file diffs in `changes.patch` | Packages the `test/initramfs/src/regression/io/specula/` tests into the initramfs and lets `SPECULA_INIT` choose the init command |

The plumbing patch excludes the run's TLA+ trace instrumentation and the trace
harness `specula_fd_trace.c`. It applies cleanly to the pin.

## Where the files go

1. At the root of an Asterinas tree at the pin, run
   `git apply specula-initramfs-plumbing.patch`.
2. Copy `test_bug3_timerfd_cache.c` and `specula_validation.c` into
   `test/initramfs/src/regression/io/specula/`. Each top-level `.c` there is
   built statically into `/test/io/specula/<name>`.
3. The MC-4 programs were run as standalone static binaries placed at the
   initramfs root and started by the matching `*-init.sh` script as init.

## How to run

Recorded round-6 command, inside Docker image
`asterinas/asterinas:0.18.0-20260702` with `--privileged --device /dev/kvm`,
the tree at `/root/asterinas`, and
`RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu`:

```sh
make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug3_timerfd_cache"
```

For the Stage-2 driver, use
`SPECULA_INIT="/test/io/specula/run_validation.sh timerfd_cache"`.
The recorded Docker command also mounted a local archive of
`inherit-methods-macro` rev `98f7e3e` and a Cargo config override, because
Cargo could not fetch it in that environment.

Challenger commands, as recorded in `challenge_B.md`. `REPRO` is the run's
`.specula-output/repro` directory. The ISO boots the pinned kernel with the
initramfs `test_bugMC-4_challenge-smp2.cpio` built for this test, whose init
script is `test_bugMC-4_challenge-init.sh`.

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror test_bugMC-4_challenge.c -o test_bugMC-4_challenge.host
timeout 10s ./test_bugMC-4_challenge.host

timeout 3m docker run --rm --privileged --network=none --device /dev/kvm \
  -v "$REPRO:/root/repro:ro" asterinas/asterinas:0.18.0-20260702 \
  /usr/local/qemu/bin/qemu-system-x86_64 \
  -cpu Icelake-Server,+x2apic -machine q35,kernel-irqchip=split \
  -smp 2 -m 8G -bios /root/ovmf/release/OVMF.fd -accel kvm \
  -boot order=d -cdrom /root/repro/test_bugMC-4_challenge-smp2.iso \
  -nographic -display none -monitor none -serial stdio -nic none -no-reboot \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

The ISO itself is not copied here (binary). It is at
`/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-4_challenge-smp2.iso`.
The exact turn-A boot command is not recorded in the retained logs.

## Reading the output

| Program | FAIL on Asterinas (bug present) | PASS on Linux |
|---|---|---|
| `test_bug3_timerfd_cache` | `SPECULA_REGRESSION_FAIL timerfd_cache: consumed timerfd remained readable`, exit 1 | `SPECULA_REGRESSION_PASS timerfd_cache`, exit 0 |
| `specula_validation timerfd_cache` | `SPECULA_REGRESSION_FAIL timerfd_cache: consumed timerfd remained readable (errno=0)` | `SPECULA_REGRESSION_PASS timerfd_cache` |
| `test_bugMC-4_timerfd_cache` | `MC4_BUG_TRIGGERED stale_polls=3 while_read_is_EAGAIN`, **exit 0** | `MC4_EXPECTED_NO_STALE_READINESS stale_polls=0`, **exit 1** |
| `test_bugMC-4_challenge` | `MC4B_BUG_TRIGGERED timed_poll_reported_readiness_then_read_eagain`, **exit 0** | `MC4B_NO_STALE_READINESS timed_poll=0 zero_poll=0`, **exit 1** |

The two MC-4 programs use inverted exit codes: 0 means the bug was observed.
Exit 2 from them means a setup step failed. The challenger's QEMU process
exits 33 after the guest's debug-exit shutdown. That value is not the test
result.

## SMP setting

All recorded Asterinas runs used `SMP=2`. The sequence is single-threaded.
`Pollee::poll_with` installs its cache with `compare_exchange_weak`, so a test
that does not prime the cache with an extra poll may not fail on every run.
