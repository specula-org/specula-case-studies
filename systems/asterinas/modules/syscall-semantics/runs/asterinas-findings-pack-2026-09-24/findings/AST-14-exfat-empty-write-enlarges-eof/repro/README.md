# AST-14 reproducers

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `test_bugMC-7_exfat_empty_pwrite.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-7_exfat_empty_pwrite.c` | Guest `/init` and test in one static binary |
| `test_bugMC-7_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-7_run.sh` | Original host driver (Docker image `asterinas/dev:0.18.1-20260901`, QEMU/KVM) |
| `empty_write-regression.patch` | `/home/chin39/Documents/play/specula-profile/reports/empty-write-batch-2026-09-16/regression.patch` | Regression test `fs/empty_write` from the fix batch, shared with AST-02 |

## 01b guest test

The binary runs as `/init`. It mounts `/dev/vda` as ext2 at `/ext2` and
`/dev/vdb` as exFAT at `/exfat`, forks, drops to uid 1000, and runs six probes
on a 2-byte seed file:

- T1 exFAT `pwrite64(fd, b, 0, 4096)`, T3 exFAT `pwritev` with an empty iovec
  array at 8192, T4 exFAT `lseek(16384)` then `write(fd, b, 0)`: subject cases.
- T2 ext2 `pwrite64(fd, b, 0, 4096)`: backend control.
- T5 exFAT at EOF and T6 exFAT inside the file: shape controls.

Steps on another tree:

1. `gcc -static -O2 test_bugMC-7_exfat_empty_pwrite.c -o root/init`, create
   `root/{dev,proc,tmp,ext2,exfat}`, pack `root/` as a newc cpio.
2. `truncate -s 128M ext2.img && mkfs.ext2 -F -b 4096 ext2.img` and
   `truncate -s 128M exfat.img && mkfs.exfat -c 4096 exfat.img`.
3. Boot a QEMU direct-boot Asterinas kernel with the cpio as `-initrd`, ext2 as
   the first virtio-blk disk, exFAT as the second. The 01b run booted the
   harness kernel for the pin (`.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`,
   the pin plus passive trace hooks) with `-smp 2`.

Output:

- FAIL on Asterinas: `T1 exfat ... size 2->4096 ... => FILE ENLARGED`, the same
  for T3 and T4, `MC7_SUMMARY t1_exfat=BUG t2_ext2=clean t3_pwritev=BUG t4_lseek_write=BUG ...`,
  and `MC7_RESULT REPRODUCED`.
- PASS: every probe reports `=> no effect`. The Linux reference recorded in the
  01b investigation (host ext4 and tmpfs) kept the size at 2.

## Regression test from the fix batch

`empty_write-regression.patch` applies to `upstream/main` `bc12195df`. It adds
`test/initramfs/src/regression/fs/empty_write/` and registers runs for ramfs,
exFAT buffered and direct (`TEST_DIRECT`), and ext2 buffered and direct. Each
of six scenarios (write and pwrite at offsets 1, 2, and 8192) checks return,
errno, size, allocated blocks, mtime, ctime, and file position. This test has
never been executed (NOT_RUN): the batch stopped at static checks by user
request. Review it before relying on it.

## SMP

Not timing-dependent. The 01b run used `-smp 2`.
