# AST-14: Empty exFAT writes enlarge EOF and may allocate clusters

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01b `20260908-150910-0a8c` (target `asterinas-syscall-buffered-file-size-read-consistency`), finding MC-7, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | 2026-09-16 backend source audit at `bc12195df` (static only): the exFAT direct-I/O path `ExfatInode::write_direct_at` has the same missing guard. No runtime verdict. |
| Syscalls | `pwrite64`, `pwritev` (empty iovec array), `write` after `lseek` |
| Upstream | none (NO_DIRECT_MATCH). Reviewed, not matching: #3603 (closed unmerged exFAT refactor), #3481 (open, inode append and memfd seal races) |
| Fix | fix-pending-validation: buffered and direct guards applied, uncommitted, in `/home/chin39/Documents/asterinas-ast02-empty-write` (branch `fix/ramfs-empty-write`, base `bc12195df`). Static checks passed. Runtime was deferred by the user. |
| Reproducer | repro/ (runtime REPRODUCED at 604948581 for buffered I/O, SMP=2, single-threaded) |

## Summary

A zero-length write to an exFAT file at an offset beyond EOF returns 0 but
publishes the offset as the new file size and, when the offset crosses a
cluster boundary, allocates clusters. The enlarged range reads back as zeros.
An unprivileged process triggers it with `pwrite64(fd, buf, 0, off)`, with an
empty-iovec `pwritev`, or with `lseek` plus `write(fd, buf, 0)`.

## Linux contract

write(2): "If count is zero and fd refers to a regular file, then write() may
return a failure status if one of the errors below is detected. If no errors
are detected, or error detection is not performed, 0 is returned without
causing any other effect." The 01b confirmation ran a Linux reference on the
host (ext4 and tmpfs): `pwrite ret=0 size_after=2`. ext2 in the same Asterinas
tree guards `write_len == 0` explicitly.

## Asterinas behavior

At the pin, `kernel/core/src/fs/fs_impls/exfat/inode.rs::ExfatInode::write_at`
has no early return for `write_len == 0`. With `offset > file_size`,
`new_size = offset + 0` exceeds `file_size`, so the extension path runs:
`ExfatInodeInner::resize` allocates clusters, `PageCache::resize` enlarges the
cache bound, the empty copy does nothing, and `inner.size = new_size` publishes
the caller's offset. The syscall layers do not guard it either:
`kernel/core/src/syscall/pwrite64.rs::sys_pwrite64` and
`kernel/core/src/fs/file/inode_handle.rs::InodeHandle::write_at` pass the empty
reader through, and `kernel/core/src/syscall/pwritev.rs::do_sys_pwritev` probes
an empty iovec array with a zero-length `write_at(offset)` to get the right
errno for unsupported files. That probe alone extends an exFAT file.

Observed at the pin (01b MC-7, uid 1000, 2-byte seed file):

```
T1 exfat pwrite64(fd,b,0,4096): ret=0 errno=0 size 2->4096 blocks 8->8 ... => FILE ENLARGED
T2 ext2  pwrite64(fd,b,0,4096): ret=0 errno=0 size 2->2 blocks 8->8 ... => no effect
T3 exfat pwritev empty-iov @8192: ret=0 errno=0 size 2->8192 blocks 8->16 ... => FILE ENLARGED
T4 exfat lseek+write(0) @16384: ret=0 errno=0 size 2->16384 blocks 8->32 ... => FILE ENLARGED
T5 exfat pwrite64(fd,b,0,@EOF): ret=0 errno=0 size 2->2 ... => no effect
T6 exfat pwrite64(fd,b,0,1)  : ret=0 errno=0 size 2->2 ... => no effect
MC7_RESULT REPRODUCED
```

The direct path `ExfatInode::write_direct_at` also lacks the guard. Its
alignment check is `is_block_aligned(off) = off.is_multiple_of(PAGE_SIZE)`, and
0 passes it, so an aligned offset beyond EOF reaches the extension code. That
path is a static observation only.

## Reproduction

`repro/test_bugMC-7_exfat_empty_pwrite.c` is a static guest `/init` that mounts
ext2 and exFAT fixtures and runs T1 to T6 as uid 1000 (Level 0). The fix batch
also added a regression test, copied as `repro/empty_write-regression.patch`,
which has not been executed. See `repro/README.md`.

## Fix and upstream status

Register: "Buffered/direct guards applied, FIX_PENDING_VALIDATION; static checks
passed, runtime deferred by user; historical confirmation covers buffered I/O."
The guards return `Ok(0)` for an empty reader after the directory check and
before any size, allocation, or timestamp change, in both `write_at` and
`write_direct_at` (the direct guard precedes the alignment check). The
changes are six uncommitted files in the worktree above, with a proposed
separate exFAT commit. Patches:
`/home/chin39/Documents/play/specula-profile/reports/empty-write-batch-2026-09-16/exfat-fix.patch`
and `/home/chin39/Documents/play/specula-profile/reports/empty-write-batch-2026-09-16/series/02-exfat.patch`. No kernel build, before/after run, Linux
matrix, or independent review has run for the batch. matches.json:
NO_DIRECT_MATCH, upstream fix status NOT_ESTABLISHED.

## Evidence

- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md (Entry 7)
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/investigation.md
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/verdict.json
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/repro-guest.log
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s4_empty_exfat_bfs1.out
- /home/chin39/Documents/play/specula-profile/reports/empty-write-batch-2026-09-16/README.md
- /home/chin39/Documents/play/specula-profile/reports/empty-write-batch-2026-09-16/remediation.json
- /home/chin39/Documents/play/specula-profile/reports/ast-02-empty-write-2026-09-14/related-filesystems-2026-09-16.md
- /home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md

## Caveats

- The historical reproduction covers buffered I/O only. Direct-path
  consequences are unconfirmed.
- The 01b confirmation text says "O_DIRECT's block-alignment check already
  rejects `len == 0`". The pin source and the 2026-09-16 backend audit
  disagree: 0 is page-aligned, so an aligned offset passes. This entry follows
  the source and the audit.
- AST-02 (ramfs) has the same missing guard. It is a separate entry and shares
  the fix batch and the regression test. AST-72 (virtiofs direct empty write)
  is also separate.
- The fix batch is uncommitted and runtime-unvalidated.
