# AST-05 extra: 01b CR-1 (sequential over-delivery past the returned count)

01b run `20260908-150910-0a8c`, finding CR-1, native verdict REPRODUCED at pin
`604948581512d83734377974d4c34adb4530f2d7`. The id-map maps 01b CR-1 to both
AST-05 and AST-25: "AST-05 reproduced syscall effect; AST-25 latent contract
follow-up is SOURCE LEAD." This reproducer demonstrates the AST-05 effect only.
The AST-25 entry (PageCache/VmIo no-short-read contract) has no reproducer of
its own and cites this test by path.

## Files and origin

| File | Copied from |
|---|---|
| `test_bugCR-1_vmo_overdelivery.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-1_vmo_overdelivery.c` |
| `test_bugCR-1_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-1_run.sh` (host driver, image `asterinas/dev:0.18.1-20260901`) |

## What it tests

The binary is the guest `/init`. It mounts `/dev/vda` ext2 at `/ext2` and
`/dev/vdb` exFAT at `/exfat`, forks, drops to uid 1000, and on ramfs, ext2, and
exFAT writes 100 bytes, fills an 8192-byte buffer with `0x5A`, and runs
`pread(fd, buf, 8192, 0)`, `pread` at offset 4096 (EOF), and `read`. It also
runs an exFAT donor/victim probe for stale data.

## How to run

Compile with `gcc -static -O2`, place it at `/init` in a newc cpio with
`dev`, `proc`, `tmp`, create fresh 128 MiB ext2 (`-b 4096`) and exFAT
(`-c 4096`) images, and boot with ext2 as the first virtio-blk disk and exFAT as
the second. The 01b run booted the harness kernel for the pin
(`.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`,
pin plus passive trace hooks) with `-smp 2`.

## Output

- FAIL on Asterinas at the pin:
  `CR1|ramfs/small/pread@0|ret=100 clobbered_beyond_ret=3996 ...`,
  `CR1|exfat/small/pread@eof4096|ret=0 clobbered_beyond_ret=3996 ... ANOMALY`,
  `CR1|end|anomalies=7`.
- PASS: every line reports `clobbered_beyond_ret=0 ... clean`, as ext2 did in
  the same guest. No Linux run was recorded.
- The over-delivered bytes were zeros at the pin. No stale-data leak was
  observed.

## SMP

Sequential. The 01b run used `-smp 2`.
