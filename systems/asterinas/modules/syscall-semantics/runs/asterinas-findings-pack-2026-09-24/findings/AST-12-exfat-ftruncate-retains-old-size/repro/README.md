# AST-12 reproducer

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `test_bugMC-4_exfat_resize.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh` | Self-contained host script: embeds the guest C source, builds images, boots QEMU |

The script writes the guest program to `work_mc4/test.c` next to itself. A
generated copy from the 01b run is at `.specula-output/repro/work_mc4/test.c`
in the same run directory.

## How to run

The script was written for the original host. Before running elsewhere:

- Set `QEMU` to a `qemu-system-x86_64` binary, `MKFS_EXFAT` to `mkfs.exfat`
  (exfatprogs), and `GLIBC_STATIC` to a directory holding a static `libc.a`, or
  edit the `gcc` line to use any toolchain that can link statically. `mkfs.ext2`
  must be on `PATH`.
- Set `KERNEL` (edit the script) to an Asterinas kernel ELF built for QEMU
  direct boot. The 01b run used the harness build of the pin at
  `.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`.

The guest runs as `/init` (root), mounts `/dev/vda` as ext2 and `/dev/vdb` as
exFAT (4096-byte clusters, 128 MiB images), and runs six cases. It calls
`prctl(0x53504543, ...)` and `prctl(0x53504544, ...)` to arm and drain the
Specula trace recorder. On a kernel without the Specula hooks those calls fail
harmlessly and only the receipt lines disappear.

QEMU runs with `-enable-kvm -smp 2`. The test itself is single-threaded.

## Reading the output

- FAIL on Asterinas at the pin: `MC4BUG  /exfat/mc4a: ftruncate(1) succeeded but st_size=0`
  and similar lines for `mc4a2`, `mc4b`, `mc4c`, ending in `MC4VERDICT BUG bugs=8`.
- Correct behavior (the ext2 control in the same guest): `st_size` and the
  `pread` count equal the `ftruncate` length, and the final line reads
  `MC4VERDICT CLEAN bugs=0` once exFAT is fixed. No Linux run was recorded. On
  Linux the same program reports the requested sizes by the ftruncate(2)
  contract.

## SMP

Not timing-dependent. The 01b run used `-smp 2`. One CPU should behave the same.
