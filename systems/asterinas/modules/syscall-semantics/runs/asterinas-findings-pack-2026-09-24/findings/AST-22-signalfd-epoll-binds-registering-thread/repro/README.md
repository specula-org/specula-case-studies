# AST-22 reproducer

All three C programs are public-API user programs (pthread, signal, signalfd,
epoll, pipe, read). None of them needs a kernel change. The recorded runs used
Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` with `-smp 2`.

## Files and their sources

All files come from
`/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/`,
except the plumbing patch.

| File | Role |
|---|---|
| `test_bugCR-4_thread_registration.c` | Main probe. Thread A registers the signalfd, then `pthread_kill`s thread B, then B waits and reads. Eight iterations, stops at the first miss. |
| `test_bugCR-4_registration_actor_control.c` | Control. Only the `epoll_ctl` caller changes: B registers. Expected to pass on Asterinas. |
| `test_bugCR-4_preexisting_waiter.c` | Control. B exists before A registers, then the original A-registers/B-waits split. Expected to fail on Asterinas. |
| `test_bugCR-4_thread_registration.nix`, `test_bugCR-4_registration_actor_control.nix`, `test_bugCR-4_preexisting_waiter.nix` | Build a static binary with `-std=c11 -O2 -Wall -Wextra -Werror -pthread -static` and pack it into a cpio through the tree's `test/initramfs/nix/initramfs.nix` (`specula = test;`). |
| `test_bugCR-4_thread_registration.sh` | Recorded launcher: builds the initramfs, a local `cargo-osdk`, and the kernel, then boots QEMU with `-smp 2` and maps the result string to an exit code. |
| `test_bugCR-4_pinned_cargo.sh` | Cargo shim used by the launcher to force `nightly-2026-07-21` and seed the OSDK base crate's `Cargo.lock`. It hard-codes the original host's paths. |
| `specula-initramfs-plumbing.patch` | `git diff` against a clean export of the pin, built from the plumbing file diffs in the run's `changes.patch`. Only its `test/initramfs/nix/initramfs.nix` change (the `specula` argument) is needed by the `.nix` files here. |

The `.nix` files and both shell scripts hard-code a `sourceRoot`/`source_root`
path to a confirmation worktree that no longer exists, and the launcher
expects prebuilt artifacts beside it (a Linux vDSO tree and an OSDK target
directory). Treat them as a record of the recorded procedure and edit the
paths before reuse.

## Where the files go

1. At the root of an Asterinas tree at the pin, run
   `git apply specula-initramfs-plumbing.patch`, or apply only its
   `test/initramfs/nix/initramfs.nix` hunk.
2. Point `sourceRoot` in the `.nix` files at that tree and build the cpio with
   `nix-build --no-out-link test_bugCR-4_thread_registration.nix`.
   The binary lands at `/test/test_bugCR-4_thread_registration` in the guest.
3. Alternatively, build the C file statically with the flags above and put it
   in any initramfs. The test needs no files other than the binary.

## How to run

Challenger replay, as recorded in `confirmation/CR-4/challenge_B.md`, using the
already built kernel and initramfs:

```sh
timeout 3m qemu-system-x86_64 \
  -kernel <osdk target>/x86_64-unknown-none/debug/asterinas-osdk-bin \
  -initrd test_bugCR-4_thread_registration-v2.cpio \
  -append 'SHELL=/bin/sh LOGNAME=root HOME=/ USER=root PATH=/bin:/benchmark init=/init loglevel=error earlycon console=ttyS0 -- sh -l -c /test/test_bugCR-4_thread_registration' \
  -accel kvm -cpu host -machine q35,kernel-irqchip=split -smp 2 -m 1G \
  -no-reboot -nographic -display none -serial stdio -monitor none \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

The kernel was built with
`cargo osdk build --boot-method qemu-direct --grub-boot-protocol multiboot2 --initramfs <cpio> --kcmd-args='loglevel=error' --kcmd-args='earlycon' --kcmd-args='console=ttyS0' --init-args='-c /test/test_bugCR-4_thread_registration'`
from `kernel/` with `VDSO_LIBRARY_DIR` set, as in the launcher script. The
controls used the same kernel with their own cpio and program path.

Linux control, as recorded:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror -pthread test_bugCR-4_thread_registration.c -o cr4
timeout 15s ./cr4
```

## Reading the output

| Program | FAIL on Asterinas (bug present) | PASS on Linux |
|---|---|---|
| `test_bugCR-4_thread_registration` | `CR4 iteration=0 epoll_rc=0 ... epoll_retry_rc=0 ... read_rc=128 ... signo=10 outcome=42` and `CR4_RESULT=PERSISTENT_MISS: ...` | eight lines with `epoll_rc=1 epoll_events=0x1`, then `CR4_RESULT=NO_MISS: ...` |
| `test_bugCR-4_preexisting_waiter` | `CR4_PREEXISTING ... outcome=42` and `CR4_PREEXISTING_RESULT=PERSISTENT_MISS` | not recorded on Linux |
| `test_bugCR-4_registration_actor_control` | passes on Asterinas: `CR4_CONTROL ... epoll_rc=1 ... outcome=0` and `CR4_CONTROL_RESULT=REGISTRATION_ACTOR_OK` | not recorded on Linux |

`CR4_RESULT=DELAYED_WAKEUP` would mean the second wait saw the event. The
launcher exits 42 for `PERSISTENT_MISS`, 43 for `DELAYED_WAKEUP`, and 0 for
`NO_MISS`. The direct-QEMU exit status comes from the debug-exit device and is
not the test result.

## SMP setting

All recorded Asterinas runs used `-smp 2`. The test needs two threads, and the
controls show that the result depends on which thread registered, not on
thread-creation timing.
