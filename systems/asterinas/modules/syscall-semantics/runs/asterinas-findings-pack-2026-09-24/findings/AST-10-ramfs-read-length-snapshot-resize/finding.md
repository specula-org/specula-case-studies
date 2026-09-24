# AST-10: ramfs snapshots read length before serializing with resize

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01b `20260908-150910-0a8c` (target `asterinas-syscall-buffered-file-size-read-consistency`), finding MC-1, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | Earlier read-fix review of PR #3778 (reviewer thread asking to lock `page_cache` before reading the size). That review is not a run and has no run verdict. |
| Syscalls | `read`, `pread64` (observers); `ftruncate`, `pwrite64` (competitors) |
| Upstream | open-pr: https://github.com/asterinas/asterinas/pull/3778 (OPEN_PR_COVERS, head `d007cbb62`, not merged) |
| Fix | PR #3778 includes the lock-before-sizing commit. The local branch `fix/ramfs-read-past-eof` in `/home/chin39/Documents/asterinas-dev` has `16e1bcaa6` (fix) and `d007cbb62` (test). Exact 01b schedules not rerun on the fixed tree. |
| Reproducer | repro/ (runtime REPRODUCED at 604948581, SMP=2) |

## Summary

`RamInode::read_at` computes the read length from the file size before it takes
the page-cache lock, then returns that saved length whatever the copy actually
delivered. A concurrent `ftruncate` can shrink the cache in that gap, so `read`
or `pread64` returns 4096 while copying 0 bytes, and `read` advances the shared
file offset past data it never delivered. Any unprivileged process that reads a
ramfs file while another thread truncates or extends it can observe this.

## Linux contract

read(2) and pread(2): on success the return value is the number of bytes read
into the buffer, and `read` advances the file position by that number. A read
that races a truncate or an extending write may legitimately see either the old
or the new size, but the returned count must equal the bytes stored in the
buffer. The 01b confirmation did not record a Linux control run for this race.
The 2026-09-11 WIP run and the PR #3778 test `fs/read_truncate_race` encode the
same contract ("a returned count must cover only bytes actually copied").

## Asterinas behavior

At the pin, `kernel/core/src/fs/fs_impls/ramfs/fs.rs::RamInode::read_at` (the
`FileOps` impl) calls `self.size()`, which takes and drops the metadata lock,
computes `read_len`, and only then calls `page_cache.lock().read(offset, writer)`.
`kernel/core/src/vm/page_cache/vmo/mod.rs::Vmo::read` clamps the copy to the
VMO's current page-aligned capacity and returns `Ok(())` with no byte count, so
`read_at` still returns the stale `read_len`.
`kernel/core/src/fs/fs_impls/ramfs/fs.rs::RamInode::resize` (called by
`ftruncate`) and `RamInode::write_at` both run under the page-cache lock and can
land between the size snapshot and the copy. `kernel/core/src/fs/file/inode_handle.rs::InodeHandle::read`
then advances the shared offset by the returned count.

Observed schedules (01b MC-1, 4096-byte file, 8192-byte read):

- Shrink: `pread(fd, buf, 8192, 0)` against `ftruncate(fd, 0)` returned 4096
  with 0 bytes delivered.
- Grow: `pread(fd, buf, 8192, 0)` against `pwrite(fd, buf, 8192, 2048)` returned
  4096 with 8192 bytes delivered, including the writer's payload.
- Shared offset: `read(2)` returned 4096 with 0 or 8192 bytes delivered and the
  file position advanced to 4096, in 228 of 5000 trials.

## Reproduction

`repro/test_bugMC-1_ramfs_saved_count.c` runs the grow, shrink, and
shared-offset schedules on two pinned threads with a TSC rendezvous (Level 1,
timing help only, no kernel patch). It needs two vCPUs. The 01b run booted the
harness-built kernel for the pin under QEMU/KVM with `-smp 2` and printed
`MC1_RESULT BUG_TRIGGERED`. `repro/read_truncate_race-regression.patch` is the
PR #3778 regression test (`fs/read_truncate_race`, eight writers, 20000 reads)
and is the preferred check for a fix. See `repro/README.md`.

## Fix and upstream status

The register records: "Open PR #3778 at d007cbb62 includes lock-before-sizing;
exact 01b schedule validation remains pending." matches.json classifies AST-10 as
OPEN_PR_COVERS with upstream fix status OPEN_PR_STATIC_COVERAGE. The fix commit
`16e1bcaa6` ("Serialize ramfs reads with resizing") takes the page-cache lock
before reading the size and holds it through the copy. On 2026-09-11 the WIP
tree (`scratch/wip-check` `d1c027870`, SMP=4) passed
`test_read_never_reports_unwritten_bytes`, and the variant without the lock
failed it. That is family-level evidence on a later base, not a rerun of the
01b MC-1 schedules.

## Evidence

- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md (Entry 1)
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/investigation.md
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/verdict.json
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/repro-guest.log
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s1_ramfs_bfs1.out
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/traces/ramfs-2-2.ndjson
- /home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md
- /home/chin39/Documents/play/specula-profile/references/pr-3778-handoff.md
- /home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/wip-2026-09-11/wip-check.out
- /home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/wip-2026-09-11/wip-nolock.out

## Caveats

- AST-10 is distinct from AST-05. AST-05 is the unlimited writer that copies
  past the returned EOF prefix. AST-10 is the stale length snapshot. The grow
  schedule's over-delivery (8192 delivered, 4096 returned) needs AST-05's
  unlimited writer too. The PR #3778 handoff records that "a grow never clamps"
  the copy, so the shrink schedule (returned 4096, delivered 0) is the
  AST-10-specific witness. This split is inferred from the source and the
  handoff, not from a separate run.
- The confirmation used two vCPUs and userspace timing assistance (Level 1).
- The kernel that ran was the Specula harness build of the pin with passive TLA+
  trace hooks. The confirmation verified the three cited files were
  byte-identical to the pin apart from the hooks.
- Commit ids for the fix changed across records. handoff-01b.md names
  `042ff520c`, `16e1bcaa6`, `17234066b`, `d007cbb62` (the current branch).
  pr-3778-handoff.md names the 2026-09-08 series `58ccd4470`/`690a8651f` and a
  later WIP rebuild. The register and matches.json cite PR head `d007cbb62`.
