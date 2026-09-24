# AST-13 reproducer

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `test_bugMC-5_exfat_regrown_hole.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_exfat_regrown_hole.c` | Guest test, runs on `/ext2`, `/ramfs`, `/exfat` |
| `test_bugMC-5_init.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_init.c` | Guest `/init`: mounts `/dev/vda` as ext2 at `/ext2` and `/dev/vdb` as exFAT at `/exfat`, runs `/test_mc5` as uid 1000 |
| `test_bugMC-5_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_run.sh` | Original host driver (Docker image `asterinas/dev:0.18.1-20260901`, QEMU/KVM) |

## How to run

The original driver expects the 01b run layout and boots the harness kernel
`.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf` (the
pin plus passive trace hooks). On another tree:

1. `gcc -static -O2 test_bugMC-5_exfat_regrown_hole.c -o root/test_mc5` and
   `gcc -static -O2 test_bugMC-5_init.c -o root/init`.
2. Create `root/{dev,proc,tmp,ramfs,ext2,exfat}` and pack `root/` as a newc cpio.
3. Create fresh images: `truncate -s 128M ext2.img && mkfs.ext2 -F -b 4096 ext2.img`
   and `truncate -s 128M exfat.img && mkfs.exfat -c 4096 exfat.img`. The exFAT
   image must be fresh so the subject file owns the lowest free clusters.
4. Boot a QEMU direct-boot Asterinas kernel with the cpio as `-initrd`, the ext2
   image as the first virtio-blk disk and the exFAT image as the second. The
   01b run used `-smp 2`.

## Reading the output

- FAIL on Asterinas: `[exfat] hole page 0: 4096/4096 non-zero bytes, seed-'A' match: FULL`,
  `[exfat] MC5_RESULT BUG ...`, `MC5_SUMMARY ext2=0 ramfs=0 exfat=1`, and
  `MC5_VERDICT REPRODUCED ...`.
- Correct behavior: every backend prints `MC5_RESULT CLEAN hole reads as zeros (correct)`,
  as ext2 and ramfs did in the same guest. No Linux run was recorded.

## SMP

Not timing-dependent. The 01b run used `-smp 2`.
