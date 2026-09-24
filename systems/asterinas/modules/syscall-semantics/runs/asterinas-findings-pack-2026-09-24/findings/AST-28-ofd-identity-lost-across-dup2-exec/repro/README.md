# AST-28 negative-result test

This test documents why AST-28 is a FALSE POSITIVE. It passed on Asterinas at
pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` with `SMP=2`. A failure on a
newer tree would be a new finding, not a reproduction of AST-28.

## Files and their sources

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bugCR-1_ofd_identity.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-1_ofd_identity.c` | Captured-read, `dup2` replacement, and CLOEXEC exec-cutover checks. Re-executes itself with `--exec-child`. |
| `run_bugCR-1_ofd_identity.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/run_bugCR-1_ofd_identity.sh` | Guest launcher. Execs `/test/test_bugCR-1_ofd_identity`. |

## Where the files go

Build the test as a static binary with pthreads (for example
`cc -O2 -static -pthread test_bugCR-1_ofd_identity.c -o test_bugCR-1_ofd_identity`)
and place it at `/test/test_bugCR-1_ofd_identity` in the guest initramfs,
together with `run_bugCR-1_ofd_identity.sh` at `/test/`. The exec-cutover check
re-executes `argv[0]`, so start the binary by its absolute path.

## How to run

The recorded run built the static guest binary, packed it into an initramfs,
and booted it in a local KVM guest with the checked-out local OSDK, the pinned
`nightly-2026-07-21` toolchain, and `SMP=2` (which the repository's QEMU
argument generator expands to `-smp 2`). The exact launch command is not
recorded in full in the retained logs. On Linux, run the binary directly.

## Reading the output

The program prints literal `\n` sequences instead of newlines because its
format strings escape them.

| Result | Output |
|---|---|
| Recorded on Asterinas at the pin (expected on Linux) | `CAPTURE L0 old=16 raced_ebadf=0 raced_new=0 errors=0`, `CAPTURE L1 old=16 raced_ebadf=0 raced_new=0 errors=0`, `DUP-REPLACE PASS ...`, `EXEC-CUTOVER PASS closed=100 kept=101`, `CR-1 RESULT: PASS (captured and surviving descriptors kept their OFDs)`, exit 0 |
| Test failure | a `CR-1 FAIL: ...` line on stderr and exit 1 |

The exit status alone is not enough. The program exits 1 only for setup
errors, a reader result that is neither pipe A, pipe B, nor `EBADF`, no
captured sample at Level 1, or a failed `dup2` or exec check. It does not fail
when `raced_new` is nonzero. `raced_new` counts reads that returned pipe B's
byte, and `raced_ebadf` counts reads that failed with `EBADF`. Either can be a
legitimate outcome when the reader had not yet looked up the descriptor before
the close, so a nonzero `raced_new` needs ordering analysis before it is called
wrong-object delivery. The recorded run had `raced_new=0` at both levels.

## SMP setting

The recorded Asterinas run used `SMP=2`. The captured-read check needs a second
thread and benefits from a second CPU.
