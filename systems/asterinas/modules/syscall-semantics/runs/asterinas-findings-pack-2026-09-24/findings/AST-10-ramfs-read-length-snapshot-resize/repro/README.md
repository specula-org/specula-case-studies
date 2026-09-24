# AST-10 reproducers

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `test_bugMC-1_ramfs_saved_count.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-1_ramfs_saved_count.c` | Guest test (grow, shrink, shared-offset schedules) |
| `test_bugMC-1_init.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-1_init.c` | Guest `/init`: mounts `/dev` and `/proc`, creates `/ramfs`, runs the test as uid 1000, powers off |
| `test_bugMC-1_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-1_run.sh` | Original host driver (Docker image `asterinas/dev:0.18.1-20260805`, QEMU/KVM) |
| `read_truncate_race-regression.patch` | `git -C /home/chin39/Documents/asterinas-dev diff d007cbb62^ d007cbb62` | PR #3778 regression test `fs/read_truncate_race` |

## Running the 01b guest test

The original driver expects the 01b run layout: it mounts the run directory at
`/work` and boots the prebuilt harness kernel
`.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`. That
kernel is the pin `604948581` plus passive TLA+ trace hooks that do nothing
unless armed through `prctl`. This test never arms them.

To run it on another tree:

1. Build an Asterinas kernel ELF for QEMU direct boot (the harness used
   `cargo osdk build --release --boot-method qemu-direct` inside
   `asterinas/dev:0.18.1-20260901` with `RUSTUP_TOOLCHAIN=nightly-2026-07-21`).
2. Build the guest programs statically:
   `gcc -static -O2 -pthread test_bugMC-1_ramfs_saved_count.c -o root/test_mc1`
   and `gcc -static -O2 test_bugMC-1_init.c -o root/init`.
3. Create `root/{dev,proc,tmp,ramfs}` and pack `root/` as a newc cpio.
4. Boot with `-smp 2` (the test pins threads to CPUs 0 and 1) and pass the cpio
   with `-initrd` and `rdinit=/init`. The file under test lives on the
   initramfs root, which is ramfs.

Output:

- FAIL on Asterinas: `MC1_REPRO scenario=shrink ... read_ret=4096 ... delivered=0 ... hit=1`,
  and the final line `MC1_RESULT BUG_TRIGGERED`.
- Expected on a correct kernel: no `hit=1` lines and no `BUG_TRIGGERED`. The
  01b confirmation did not record a Linux run of this program.

The shrink hit is the AST-10 witness. A grow hit (`delivered=8192` with
`read_ret=4096`) also depends on AST-05's unlimited writer.

## Running the regression test

`read_truncate_race-regression.patch` adds `test/initramfs/src/regression/fs/read_truncate_race/`
and registers it in `fs/Makefile` and `fs/run_test.sh`. It was written on top
of PR #3778's earlier commits (`fs/read_eof` is registered next to it), so
apply it to a tree that already has the `read_eof` test, or fix the one-line
context in `fs/Makefile` by hand. Run `make run_kernel AUTO_TEST=regression SMP=4`
(fs suite). The test skips on one CPU. Without the lock-before-sizing fix it
reports `test_read_never_reports_unwritten_bytes ... 1 tests failed`, as in
`/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/wip-2026-09-11/wip-nolock.out`.

## SMP

Two or more CPUs are required. SMP=1 does not exercise the race.
