# AST-51: msync MS_SYNC discards inode synchronization errors

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F08, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `msync` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | none (no runtime case was supplied, imported runtime status NOT_RUN) |

## Summary

`msync(MS_SYNC)` calls `inode.sync(SyncMode::Full)` and discards the result, then returns 0. When writeback fails, the caller is told the mapped data is synchronized. Programs that use `msync` as a durability point are affected only when the backing store reports an error.

## Linux contract

[msync(2)](https://man7.org/linux/man-pages/man2/msync.2.html) defines `MS_SYNC` as a request for an update that waits for it to complete. The attachment cites Linux `mm/msync.c`, which returns the error from `vfs_fsync_range` to user space.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/msync.rs::sys_msync` collects the inodes of the mapped range and builds `task_fn`, which runs `let _ = inode.sync(SyncMode::Full);` per inode. With `MS_SYNC` it calls `task_fn()` inline, otherwise it spawns a thread. In both cases it returns `Ok(SyscallReturn::Return(0))`.

## Reproduction

There is no runtime reproducer. `case-plan.json` lists AST-51 under `no_complete_attached_probe`. The attachment's `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md` requires a writeback fault on a disposable filesystem or block device inside a throwaway VM. The test must separate three facts: the fault was injected, the error reached `inode.sync`, and `msync` still returned 0. Never use a real user disk as the fault device.

## Fix and upstream status

No fix is recorded. The register notes: "No writeback fault-injection case; no demonstrated data loss". The attachment's repair direction is to propagate the error on the synchronous path and to handle the asynchronous path according to its own ABI.

No direct match in the searched scope. [#2154](https://github.com/asterinas/asterinas/pull/2154) (MERGED) introduced msync, [#2333](https://github.com/asterinas/asterinas/pull/2333) (MERGED) documents mm syscall limitations, and [#2766](https://github.com/asterinas/asterinas/pull/2766) (MERGED) fixes mm error codes. The dedup notes that upstream main `bc12195df` still uses `let _ = inode.sync(...)`.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/source-check.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/inputs/asterinas_tlpi_audit_v2.zip`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md`

## Caveats

No disk fault injection ran. The attachment does not claim observed data loss. Syncing more pages than requested, which the in-tree TODO mentions, is not this finding.
