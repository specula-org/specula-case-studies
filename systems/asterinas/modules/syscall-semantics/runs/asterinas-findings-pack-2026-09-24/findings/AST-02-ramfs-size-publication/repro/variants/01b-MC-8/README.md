# AST-02 extra: 01b MC-8 (ramfs zero-progress failed write publishes the extent)

01b run `20260908-150910-0a8c`, finding MC-8, native verdict REPRODUCED at pin
`604948581512d83734377974d4c34adb4530f2d7`. The id-map maps 01b MC-8 to AST-02
("Same tracked mechanism"). It is the same mechanism as 01a Entry 4, whose
historical v5 patch has A/B evidence.

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-8_ramfs_efault_extent.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-8_ramfs_efault_extent.c` |
| `test_bugMC-8_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-8_run.sh` (host driver, image `asterinas/dev:0.18.1-20260901`) |

## What it tests

The binary is the guest `/init`. On a ramfs file of size 2 it calls
`pwrite(fd, bad, 2, 2)` where `bad` is a `PROT_NONE` mapping, so the copy
faults before any byte moves. It then checks `fstat` and reads the file. It
repeats the sequence on ext2 (`/dev/vda` mounted at `/mnt_ext2`) as a control.

## How to run

Compile with `gcc -static -O2`, place it at `/init` in a newc cpio with `dev`,
`proc`, `tmp`, attach an ext2 image as the first virtio-blk disk (the 01b run
reused the harness `ext2.img`, and a fresh `mkfs.ext2 -b 4096` image works), and
boot a QEMU direct-boot Asterinas kernel with `-smp 2`. The 01b run booted the
harness kernel for the pin (pin plus passive trace hooks).

## Output

- FAIL on Asterinas at the pin:
  `[ramfs] pwrite(PROT_NONE buf, 2, off=2) = -1 errno=14 (Bad address)`,
  `[ramfs] size after failed write = 4 | pread(4, off=0) = 4 bytes = 68 69 00 00`,
  `MC8_RESULT: BUG PRESENT ...`.
- PASS: size stays 2 after the failed write, as the ext2 control printed in the
  same guest (`MC8_CONTROL_EXT2: SIZE UNCHANGED`). No separate Linux run was
  recorded for MC-8. Linux's `generic_perform_write` advances `i_size` only for
  copied bytes.

Scope: this witness covers zero progress only. Partial-progress faults
(bytes copied, then a fault) were outside MC-8's scope.

## SMP

Not timing-dependent. The 01b run used `-smp 2`.
