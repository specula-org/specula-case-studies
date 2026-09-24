# AST-47: openat FD insertion omits the stored RLIMIT_NOFILE limit

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F04, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `openat`, `open`, `creat`, `setrlimit`, `prlimit64` |
| Upstream | partial (dedup `PARTIAL_MATCH`, upstream main `bc12195df`): [#2841](https://github.com/asterinas/asterinas/issues/2841) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `nofile_limit`, Linux evidence only) |

## Summary

`openat` inserts the new file into the descriptor table without checking the soft `RLIMIT_NOFILE`. A process that lowered its limit, or a supervisor that set one for it, can still open new descriptors where Linux returns `EMFILE`.

## Linux contract

[getrlimit(2)](https://man7.org/linux/man-pages/man2/getrlimit.2.html) defines `RLIMIT_NOFILE` as one greater than the largest descriptor number the process may open, and says attempts to exceed it fail with `EMFILE`. Existing descriptors stay valid when the limit is lowered. The saved Linux runs show `RLIMIT_NOFILE soft=0: openat=-1 errno=24`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/open.rs::sys_openat` ends with `file_table_locked.insert(file_handle.clone(), fd_flags)`. `kernel/core/src/fs/file/file_table.rs::FileTable::insert` puts the entry into the table and only comments that "Resource limits guarantee the table never exceeds `i32::MAX` entries". `kernel/core/src/syscall/prlimit64.rs::do_prlimit64` stores the limit. At the pin, `syscall/dup.rs` and `syscall/poll.rs` read `RLIMIT_NOFILE`, so enforcement is per caller.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `nofile_limit` lowers the soft `RLIMIT_NOFILE` of the case's child process to 0, keeps its already open stdout, and calls raw `openat` on `/dev/null`. It passes when `openat` returns -1 with errno 24 (`EMFILE`). All five saved Linux executions report PASS, for example `RLIMIT_NOFILE soft=0: openat=-1 errno=24`. Source prediction for Asterinas at `a5449e62b`, not observed: `openat` returns a descriptor, so the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The register notes: "Open tracking issue #2841 includes NOFILE; openat-specific coverage remains to verify." The attachment suggests checking the limit where the descriptor is allocated under the table lock, so every caller is covered.

Partial: [#2841](https://github.com/asterinas/asterinas/issues/2841) (OPEN, "Enforce the process resource limit check") explicitly tracks RLIMIT_NOFILE enforcement. [#2906](https://github.com/asterinas/asterinas/pull/2906) (MERGED) fixes `dup3` only, [#2783](https://github.com/asterinas/asterinas/pull/2783) (MERGED) caps configured limits, and [#2749](https://github.com/asterinas/asterinas/issues/2749) (OPEN) is RLIMIT_STACK. None establishes enforcement on the openat insertion path.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/metadata.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-nofile_limit.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The attachment confirms only the reviewed openat path and says other rlimits cannot be inferred to be unenforced. Other descriptor-creating syscalls (pipe, socket, accept, and so on) were not assessed. The finding is static and NOT_RUN.
