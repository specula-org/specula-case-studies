# AST-24 reproducers (mechanism observed, harm masked)

## Files and origin

All files except the plumbing patch are copied from
`/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/`.

| File | Role |
|---|---|
| `test_bugMC-6_direct_write_pending_bio.c` | Turn-1 test, cases A to G. Argument: target directory (default `/ext2`) |
| `test_bugMC-6_direct_write_pending_bio.sh` | Turn-1 driver: Linux control on the host, then the Asterinas guest |
| `test_bugMC-6_extend_rollback_free.c` | Debater test, cases H, H2, J, J2 (extending write, rollback frees blocks under the live BIO). Arguments: directory and mode (`full`) |
| `test_bugMC-6_extend_rollback_free.sh` | Debater driver. It also mounts `/dev/nvme0n1` at `/nvme` when present |
| `specula-initramfs-plumbing.patch` | `git diff` of the 01a run's `source/` build plumbing against the pristine pin: adds `ENABLE_SPECULA_TRACE`/`SPECULA_INIT` to the top-level `Makefile`, a Nix derivation that packs `test/initramfs/src/regression/io/specula/` into `/test/io/specula/`, and that directory's `Makefile`. No kernel code. |

## What the tests measure

- A, B: a two-run `O_DIRECT` `pwrite(fd, buf, 8192, 0)` whose buffer's third
  page is `PROT_NONE`. On Asterinas the call returns `EFAULT` and 4096 bytes are
  published afterwards (`VERDICT=COMMIT_WITHOUT_REPORT`).
- C: the same buffer on a contiguously allocated file. Asterinas publishes
  nothing (`NO_PUBLICATION`), which proves A/B's bytes came from the
  already-submitted first run.
- D to G: 64 rounds each looking for the orphaned write landing late or
  clobbering a later successful write. All `NOT_OBSERVED` at the pin.
- J, J2: extending write with non-adjacent new blocks, so `rollback_write`
  frees blocks while run 1's BIO is live and another file claims one. All
  `clobbered=0` at the pin. H and H2 show that on a merely fragmented volume a
  two-block allocation is still contiguous and forms no orphan.

## How to run

The drivers were written for the run layout and expect
`confirmation/MC-6/worktree`, which no longer exists. To rerun on a tree at the
pin (or later):

1. Apply `specula-initramfs-plumbing.patch`. It applies cleanly to
   `604948581512d83734377974d4c34adb4530f2d7`. Leave the kernel pristine.
2. Copy the C files into `test/initramfs/src/regression/io/specula/` and write a
   small `run_mc6.sh` there that calls the built binaries on `/ext2` (the
   drivers show the exact scripts in their heredocs).
3. Build and boot inside `asterinas/dev:0.18.1-20260805` with toolchain
   `nightly-2026-07-21`:
   `make kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1`
   then
   `make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 SPECULA_INIT=/test/io/specula/run_mc6.sh`.
   The default QEMU configuration mounts ext2 at `/ext2` and attaches an NVMe
   ext2 device (`/dev/nvme0n1`).
4. For the Linux control, compile each C file on the host with
   `gcc -O2 -lpthread` and pass a directory on ext4.

Without the plumbing, the binaries can also run from any init as long as
`/ext2` is an ext2 mount that supports `O_DIRECT`.

## Reading the output

- Mechanism present (Asterinas at the pin): cases A and B print
  `VERDICT=COMMIT_WITHOUT_REPORT` and case C prints `VERDICT=NO_PUBLICATION`.
- Harm, if it ever appears: D prints `late_publication>0`, or E/F/G/J/J2 print
  `clobbered>0`. At the pin every such case printed `NOT_OBSERVED` or
  `clobbered=0`, which is why the verdict is MASKED.
- Linux ext4 prints `COMMIT_WITHOUT_REPORT` for A, B, and C, and never shows
  late publication, because `iomap_dio_rw` waits for all submitted BIOs.

A fix that drains the batch on error (for example `Drop` for `IoBatch` calling
`wait_all()`) would keep A/B/C unchanged in return value but must make the first
run's completion happen before the syscall returns.

## SMP

The drivers use SMP=2. The masking comes from single-worker FIFO device queues,
not from CPU count.
