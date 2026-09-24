# AST-02 extra: 01b MC-6 (ramfs zero-count positional write enlarges the file)

01b run `20260908-150910-0a8c`, finding MC-6, native verdict REPRODUCED at pin
`604948581512d83734377974d4c34adb4530f2d7`. The id-map maps 01b MC-6 to AST-02.
It is not a new 01b discovery: the 01a AST-02 record (Entry 4) already covers
zero-length `pwrite` past EOF.

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-6_ramfs_empty_pwrite.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-6_ramfs_empty_pwrite.c` |
| `test_bugMC-6_init.c` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-6_init.c` (guest `/init`: creates `/ramfs`, runs `/test_mc6` as uid 1000) |
| `test_bugMC-6_run.sh` | `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-6_run.sh` (host driver, image `asterinas/dev:0.18.1-20260805`) |
| `fix-mc6-ramfs-zero-count-pwrite.patch` | `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/fix-mc6-ramfs-zero-count-pwrite.patch` (historical fix at the pin) |
| `verify-mc6-fix.sh` | `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/fixval/verify-mc6-fix.sh` (historical A/B driver that expects a patched build under `/tmp/mc6-fixval`) |

## What it tests

On a ramfs file of size 2: `pwrite64(fd, buf, 0, 1)` (inside, control),
`pwrite64(fd, buf, 0, 4)` (beyond EOF, subject), `pread(fd, b, 2, 2)` at the old
EOF, and an empty `write` on the shared offset.

## How to run

Compile both C files statically, create `root/{dev,proc,tmp,ramfs}`, pack a
newc cpio, and boot a QEMU direct-boot Asterinas kernel with it as `-initrd`
and `-smp 2`. The file lives on the initramfs root, which is ramfs. The 01b run
booted the harness kernel for the pin (pin plus passive trace hooks). The
program also runs on Linux: the 01b confirmation ran the same binary on host
tmpfs (`/dev/shm`) and ext4 (`/tmp`).

## Output

- FAIL on Asterinas at the pin:
  `MC6_REPRO empty_pwrite_beyond_eof ret=0 errno=0 size_after=4 (expect ret=0 size=2)`,
  `MC6_REPRO hole_read_at_eof ret=2 ...`, `MC6_RESULT BUG_TRIGGERED`.
- PASS (Linux tmpfs and ext4, and the patched kernel in the historical A/B):
  `size_after=2`, `hole_read_at_eof ret=0`, `MC6_RESULT OK`.
- `MC6_EXIT 0` appears in both cases. Use the `MC6_RESULT` marker, not the exit
  line.

Historical A/B (QEMU/KVM, SMP=2): baseline `MC6_RESULT BUG_TRIGGERED` with size
2 -> 4, and patched `MC6_RESULT OK` with size 2. Logs:
`/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/fixval/mc6-baseline-guest.log` and
`/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/fixval/mc6-patched-guest.log`. The current repair for AST-02 is the 2026-09-16
empty-write batch at `bc12195df` (FIX_PENDING_VALIDATION), not this historical
patch.

## SMP

Not timing-dependent. The 01b run used `-smp 2`.
