# AST-11 reproducers

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `write_race-regression.patch` | `git -C /home/chin39/Documents/asterinas-dev diff 864356cec 3ece54702` | Test-only patch adding `fs/write_race` (no kernel change) |
| `guest_mc3.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/guest_mc3.c` | 01b guest program, runs as `/init` |
| `test_bugMC-3_exfat_stale_prepare.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-3_exfat_stale_prepare.sh` | Original 01b host runner (expects a running container named `specula-mc3`) |
| `mc3-l3-timing-hook.patch` | `git diff` from the pristine pin to `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/kernelhook` | Kernel-side timing hook for the exact 01b schedules |

The original hand-written hook description and its applier are at
`.specula-output/repro/mc3-kernel-hook.patch` and `.specula-output/repro/apply_mc3_hook.py`
in the same run. They are not a `git apply`-able patch, so they were not copied.

## Preferred: `fs/write_race` regression test

`write_race-regression.patch` applies to `upstream/main` `bc12195df` (it was
generated against the fix commit, and it touches only `test/`). It adds
`test/initramfs/src/regression/fs/write_race/`, registers it in `fs/Makefile`,
and calls it from `fs/run_test.sh`. Each of 2000 rounds empties a file and then
releases an 8 KiB writer and a 4 KiB writer at offset 0 together on `/tmp`,
`/ext2`, and `/exfat`. After both writes the file must be 8 KiB long and fully
written.

Run the fs regression suite with at least two CPUs, for example
`make run_kernel AUTO_TEST=regression SMP=4` with the suite filtered to `fs`.

- FAIL on an unfixed Asterinas: the `/exfat` case reports bad rounds (65 and 93
  of 2000 in runs V1 and V2 on `bc12195df`, SMP=4) and the test fails.
- PASS: 0 bad rounds on all three file systems. The Linux host control gave 0
  bad rounds on `/tmp`.
- With one CPU, or when both writers land on one CPU, the test prints
  `skipped:` instead of running.

## Exact 01b schedules: `guest_mc3.c` with the Level 3 hook

The race window did not open without help at the pin: 500 timing-assisted
trials on an unpatched kernel printed `MC3_VERDICT L1 not_triggered trials=500`.
The 01b confirmation therefore added a timing-only hook.

`mc3-l3-timing-hook.patch` applies to a pristine tree at
`604948581512d83734377974d4c34adb4530f2d7`. It contains the Specula TLA+ trace
instrumentation (`kernel/core/src/tla_trace.rs` and its call sites) because the
hook lives in that recorder: it adds `mc3_iters` to the per-thread recorder, a
`prctl(0x53504551, 1, iters)` control, and a `crate::tla_trace::mc3_release_hook()`
busy-wait in `ExfatInode::write_at` right after the preparation lock is
released. The instrumentation is passive unless armed through `prctl`, and the
hook is disarmed by default. It changes timing only.

1. Apply the patch to the pin and build a QEMU direct-boot kernel ELF. The 01b
   build used `asterinas/dev:0.18.1-20260901`. Do not place the tree in a
   directory whose name contains `src/`: the component-system path heuristic
   panicked on `kernel-src`, which is why the 01b tree is named `kernelhook`.
2. Build `guest_mc3.c` statically with `-pthread` three ways:
   `-DMC3_MODE=1` (L1, unpatched kernel, 500 trials), `-DMC3_MODE=3` (L3, CE
   order), `-DMC3_MODE=4` (L3R, regression order). The exact gcc flags used in
   01b were not recorded. The source needs only `-static -pthread`.
3. Put the binary at `/init` in a newc cpio with `dev`, `proc`, `tmp` directories.
4. Create a 128 MiB exFAT image with `mkfs.exfat -c 4096` and attach it as the
   first virtio-blk disk. The program mounts `/dev/vda` at `/exfat`.
5. Boot with `-smp 2` (threads pin to CPUs 0 and 1).

Output:

- L3 FAIL: `MC3_RESULT {... "t1_ret":4096, ... "size_after":12288, "read_ret":4096, "read_bytes_changed":0, ... "CHECK3_read_overreport_sentinel_survives":1, "CHECK4_persistent_false_success":1}`
  followed by `MC3_VERDICT L3 BUG_TRIGGERED`.
- L3R FAIL: `"size_after":8192, ... "CHECK1_size_regressed_below_completed_write":1`
  followed by `MC3_VERDICT L3R BUG_TRIGGERED`.
- A fixed kernel prints `not_triggered` for both. No Linux run of this guest
  program was recorded. The hook does not exist on Linux.

The original runner `test_bugMC-3_exfat_stale_prepare.sh` shows the exact QEMU
command line used in 01b.

## SMP

Both reproducers need two or more CPUs. The 01b guest used `-smp 2`. The
regression evidence used SMP=4.
