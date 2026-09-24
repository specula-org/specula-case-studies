# AST-06: Failed append advances the shared file offset

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding MC-7 (former catalog alias RF-06), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | `write`, `writev` |
| Upstream | Open PR covers it by inspection: [#3481](https://github.com/asterinas/asterinas/pull/3481) "Fix inode append and memfd seal races", head `d4d1cd3a2`, open on 2026-09-24. |
| Fix | PR #3481 (third-party). Not merged and not runtime-tested here. Historical local fix in the 01a v5 `fixes.patch`, not rebased and not submitted. |
| Reproducer | repro/ (runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

A `write()` on an `O_APPEND` regular file whose source buffer faults at byte
zero returns `-1`/`EFAULT`, but it leaves the shared open file description's
offset at EOF. Every later `read()` or `lseek(SEEK_CUR)` through that
description, including a `dup`ed descriptor, starts from the wrong place until
someone seeks explicitly: reads return EOF where Linux returns the file's
bytes. Any unprivileged process that appends from a partly unmapped buffer
triggers it.

## Linux contract

write(2): a write that fails must not move the file offset, and offset
movement follows committed progress. Linux resolves the append position in a
local `kiocb` and publishes it to `f_pos` only on a nonnegative return (the
catalog description cites `fs/read_write.c:727-744`). The Linux 7.1.9 control
(ext4 and tmpfs, 2026-09-02) printed `off_after=0` for the failed append and
`bugs=0` on both filesystems.

## Asterinas behavior

At pin `604948581`,
`kernel/core/src/fs/file/inode_handle.rs::InodeHandle::write` (the `FileLike`
impl, lines 309-319) runs `*offset = self.path().size();` for `O_APPEND` and
then `let len = file_ops.write_at(*offset, reader, status_flags)?;`. When the
write fails, the assignment has already happened and only `*offset += len` is
skipped. On main `29b0f4bcf` the same assignment sits at line 321 (static check,
2026-09-02).

## Reproduction

`repro/repro.c` (01a MC-7, byte-identical to the run's
`test_bugMC-7_append_offset_on_fault.c`) runs four cases on a directory
argument (default `/tmp`):

- A `append_zero_fault`: `O_APPEND` write that faults at byte zero (the bug).
- B `plain_zero_fault`: the same write without `O_APPEND`, a negative control
  that must leave the offset at 0 on both kernels.
- C `append_success`: a successful append, which must move the offset on both
  kernels.
- D `append_prefix_fault`: an append that faults after one page.

It prints `MC7_BUG` lines for each violation and `MC7_END dir=<dir> bugs=<n>`.

Recorded on 2026-09-02 at the pin (SMP=2): `bugs=2` on `/ext2` and on `/tmp`
(ramfs). Case A left the offset at 4096 after `rc=-1 errno=14`, and on ext2 the
`dup`ed descriptor then read 0 bytes. Cases B and C passed. Linux printed
`bugs=0` on ext4 and tmpfs.

## Fix and upstream status

- Upstream dedup (2026-09-14): `OPEN_PR_COVERS`. In PR #3481 the fallible
  filesystem write runs before the shared-offset assignment, which covers the
  zero-progress failed-append offset mutation by inspection. The PR also
  rewrites ramfs `write_at`. Its effect on AST-02 was not verified. It was
  still open on 2026-09-24 with head `d4d1cd3a22ac68b2e56821f42f867cd4548b6cd6`.
- Historical local fix in the 01a v5 `fixes.patch`: resolve the append position
  locally and publish it only after nonnegative progress. A/B at the pin:
  `bugs=2` before, `bugs=0` after on both backends. Patch path:
  `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z.fixes.patch`.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-06-append-offset-on-fault/description.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-7/`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-7_append_offset_on_fault.c`
- `/home/chin39/Documents/play/specula-profile/reports/patch-validation-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/asterinas-604948581-guest-transcript.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/linux-7.1.9-AST-06-ext4.txt` and `linux-7.1.9-AST-06-tmpfs.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/README.md` ("Upstream status")
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-06`)

## Caveats

- Sources disagree about PR #3481. The catalog description and the 2026-08
  promotion audit say AST-06 is distinct from #3481, which they read as a fix
  for concurrent append placement races. The 2026-09-02 validation, the
  2026-09-14 dedup, and the register say #3481 covers AST-06 as a side effect,
  because its fallible write now precedes the offset update. This record follows
  the register. The coverage is static only.
- Case D (a fault after a committed page) also returns `-1`/`EFAULT` on
  Asterinas where Linux returns a short write. That part is the AST-01
  mechanism. On ramfs, case A also grows the file, which is AST-02.
- The Linux control ran on ext4 and tmpfs with a separately compiled binary.
- `repro/run.sh` compiles inside the guest with `cc`. The stock initramfs has no
  compiler. See `docs/running-reproducers.md`.
