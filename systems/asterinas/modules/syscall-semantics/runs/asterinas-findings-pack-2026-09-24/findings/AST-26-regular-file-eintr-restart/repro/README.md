# AST-26 negative probe

This entry is a FALSE POSITIVE. The probe below is kept so a new report of
"regular-file restart replays committed progress" can be checked quickly.

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `test_bugCR-1_restart_progress_provenance.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugCR-1_restart_progress_provenance.c` | Probe, same binary on Linux and Asterinas |
| `test_bugCR-1_restart_progress_provenance.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugCR-1_restart_progress_provenance.sh` | Original driver: Linux control on the host, pristine-kernel guest run |
| `specula-initramfs-plumbing.patch` | `git diff` of the 01a run's `source/` build plumbing against the pin | Adds `SPECULA_INIT` and packs `test/initramfs/src/regression/io/specula/` into `/test/io/specula/`. No kernel code. |

## How to run

Usage of the binary:

- `--ctrl`: pipe controls. With `SA_RESTART` a blocked pipe `read` must be
  restarted (`verdict=RESTARTED`). Without it the read fails with `EINTR`.
- `<dir> <label> [direct|sync]`: signal storm against 256 KiB regular-file
  reads and writes, then `O_APPEND` and shared-offset accounting checks.

The 01a guest script ran `--ctrl`, then `/tmp ramfs`, `/ext2 ext2`,
`/ext2 ext2direct direct`, and `/ext2 ext2sync sync`. The driver expects the
removed `confirmation/CR-1/worktree`. To rerun on a tree at the pin, apply
`specula-initramfs-plumbing.patch`, copy the C file into
`test/initramfs/src/regression/io/specula/cr1_restart_progress.c`, write a
`run_cr1.sh` with the five calls above, and run inside
`asterinas/dev:0.18.1-20260805`:
`make kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1`
then
`make run_kernel SMP=2 CONSOLE=ttyS0 ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 SPECULA_INIT=/test/io/specula/run_cr1.sh`.
On Linux, `gcc -O2 -pthread` the file and run the same arguments on a tmpfs or
ext4 directory.

## Reading the output

- Expected on both Asterinas (at the pin) and Linux:
  `CR1_CTRL_PIPE restart=1 ... verdict=RESTARTED`,
  `CR1_CTRL_PIPE restart=0 ... errno=4 ... verdict=EINTR`, and for every
  regular-file section `wr_eintr=0 rd_eintr=0 ... verdict=UNINTERRUPTIBLE`,
  `verdict=NO_REPLAY`, `verdict=NO_DOUBLE_ADVANCE`.
- A regression that would revive the candidate: any regular-file section with
  `wr_eintr>0` or `rd_eintr>0`, or an `APPEND`/`OFFSET` line where size or
  offset exceeds `returned`.
- If the pipe control does not print `RESTARTED`, the regular-file negatives
  prove nothing.

## SMP

The 01a guest used SMP=2. The probe uses a separate signal-storm thread.
