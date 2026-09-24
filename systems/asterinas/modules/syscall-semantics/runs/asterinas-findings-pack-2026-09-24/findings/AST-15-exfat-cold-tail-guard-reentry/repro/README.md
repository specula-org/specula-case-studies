# AST-15 reproducer

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `test_bugCR-2_exfat_resize_tailclear.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-2_exfat_resize_tailclear.c` | Guest `/init` and test in one static binary |
| `test_bugCR-2_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-2_run.sh` | Original host driver. It hardcodes the 01b run path and Docker image `asterinas/dev:0.18.1-20260805` |

## How to run

The binary runs as `/init` (root). It mounts `/dev/vda` as ext2 at `/ext2` and
`/dev/vdb` as exFAT at `/exfat`, then runs:

- T0: exFAT 100-byte file, tail page cached, extending `pwrite64` of 16 bytes
  at offset 100 (control).
- T1b: the same sequence on ext2 after `umount` and `mount` (control).
- T1: exFAT 100-byte file, `fsync`, `umount`, `mount`, then the extending
  `pwrite64`. A worker thread issues the write and a watchdog waits 10 s.
- T2: `ftruncate(100 -> 50)` between `T2_PROBE_BEGIN` and `T2_PROBE_END`
  markers, used with Specula trace receipts to check the shrink order. It
  arms the recorder with `prctl(0x53504543, ...)`. Without the Specula hooks
  the receipts are missing and only the T2 order check is lost.

Steps on another tree:

1. `gcc -static -O2 -pthread test_bugCR-2_exfat_resize_tailclear.c -o root/init`,
   create `root/{dev,proc,tmp,ext2,exfat}`, pack `root/` as a newc cpio.
2. `truncate -s 128M ext2.img && mkfs.ext2 -q -F -b 4096 ext2.img` and
   `truncate -s 128M exfat.img && mkfs.exfat -c 4096 exfat.img`.
3. Boot a QEMU direct-boot Asterinas kernel with the cpio as `-initrd`, ext2 as
   the first virtio-blk disk, exFAT as the second, `-smp 2`, and an outer
   `timeout` (the 01b driver used 240 s). The 01b run booted the harness kernel
   for the pin (`.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`).

## Reading the output

- FAIL on Asterinas: `T1 exfat uncached-tail extend: pwrite64 DID NOT RETURN within 10s -> kernel thread stuck`
  and `CR2-CLAIM-A: REPRODUCED ...`. QEMU does not power off. The outer
  timeout ends it (exit 124 in 01b).
- PASS: T1 prints `ret=16 errno=0`, like the T0 and T1b controls, and the guest
  powers off. No Linux run was recorded.

## SMP

Not timing-dependent. The 01b run used `-smp 2`.
