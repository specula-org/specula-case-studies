# AST-05 extra: 01b MC-2 (exFAT reads copy beyond the reported prefix)

01b run `20260908-150910-0a8c`, finding MC-2, native verdict REPRODUCED at pin
`604948581512d83734377974d4c34adb4530f2d7`. The id-map maps 01b MC-2 to AST-05
("Same tracked mechanism"). The 01b confirmation recorded it as KNOWN, citing
the open PR asterinas/asterinas#3778.

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-2_exfat_read_past_prefix.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-2_exfat_read_past_prefix.c` |
| `test_bugMC-2_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-2_run.sh` (host driver) |
| `init_mc2.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/init_mc2.c` (guest `/init`: mounts `/dev/vda` ext2 at `/ext2`, `/dev/vdb` exFAT at `/exfat`, runs `/repro` as uid 1000) |
| `guest_build.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/guest_build.sh` (in-container build of binaries, cpio, and fresh images) |
| `guest_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/guest_run.sh` (in-container QEMU boot, `-smp 2`) |

## What it tests

- Part B (Level 0, sequential): `pread`/`read` across and at EOF on exFAT,
  ramfs, and ext2 with a sentinel-filled buffer. exFAT and ramfs store bytes
  past the returned count, including a 0-byte return at EOF. ext2 stays clean.
- Part A (Level 1, two pinned threads with a TSC rendezvous): `pread64(fd, buf, 8192, 0)`
  loops against an extending `pwrite64(fd, buf, 2 MiB, 4096)` on a 4096-byte
  file. A read landing in exFAT's write-preparation window returns 4096 while
  storing zeros into `buf[4096..8192)`.

## How to run

The scripts assume the 01b run layout mounted at `/work` in
`asterinas/dev:0.18.1-20260805` and boot the harness kernel for the pin
(`.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`, the
pin plus passive trace hooks). Elsewhere: compile `test_bugMC-2_exfat_read_past_prefix.c`
with `-static -pthread` as `/repro` and `init_mc2.c` with `-static` as `/init`,
create `root/{dev,proc,tmp,ramfs,ext2,exfat}`, pack a newc cpio, make fresh
128 MiB ext2 (`-b 4096`) and exFAT (`-c 4096`) images, and boot with `-smp 2`,
ext2 as the first virtio-blk disk and exFAT as the second.

## Output

- FAIL on Asterinas at the pin: `MC2_B backend=exfat pread-at-eof off=2 ret=0 clobbered_past_ret=4094 ... VULNERABLE`,
  `MC2_A_HIT backend=exfat ... ret=4096 clobbered=4096`, `MC2_RESULT exfat_hits=26 ext2_control_hits=0`,
  `MC2_END BUG_REPRODUCED`.
- PASS: `clobbered_past_ret=0` for every backend and no `MC2_A_HIT` lines, as
  ext2 showed in the same guest. No Linux run was recorded. The Part B shape
  matches the Linux comparison table in PR #3778.

## SMP

Part A needs two CPUs (`-smp 2`). Part B is sequential.
