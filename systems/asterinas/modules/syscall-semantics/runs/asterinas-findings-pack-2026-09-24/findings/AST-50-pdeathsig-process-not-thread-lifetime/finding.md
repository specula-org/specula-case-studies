# AST-50: PDEATHSIG tracks parent-process rather than creating-thread lifetime

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F07, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `prctl`, `exit`, `exit_group`, `clone` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | none (no runtime case was supplied, imported runtime status NOT_RUN) |

## Summary

Asterinas sends the `PR_SET_PDEATHSIG` signal when the whole parent process exits. Linux sends it when the thread that created the child exits, even while other threads of the parent keep running. A child that relies on the signal to notice its creating thread's exit is not signaled until the last parent thread exits.

## Linux contract

[PR_SET_PDEATHSIG(2const)](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html) says, in CAVEATS, that the "parent" is the thread that created the process, so the signal is sent when that thread terminates.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/process/exit.rs::exit_process` calls `send_parent_death_signal(&children)` after moving the children to the reaper. `kernel/core/src/process/exit.rs::send_parent_death_signal` carries the FIXME "the signal should be sent when the POSIX thread that created the child exits, not when the whole process exits", and a second FIXME that `si_pid` is not set.

## Reproduction

There is no runtime reproducer. `case-plan.json` lists AST-50 under `no_complete_attached_probe`. The attachment's `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md` design is: a worker thread forks the child, the child calls `prctl(PR_SET_PDEATHSIG)` and acknowledges over a pipe, the worker exits while the main thread stays alive, and the child waits a bounded time for the signal. The handshake is needed to exclude the legal race where registration happens after the parent thread exited.

## Fix and upstream status

No fix is recorded. The register notes: "No complete handshake-based runtime case supplied". The attachment suggests recording which thread created each child and sending the signal when that thread exits.

No direct match in the searched scope. [#3115](https://github.com/asterinas/asterinas/pull/3115) (MERGED) fixes reparenting and publication races at process exit, not the thread-versus-process lifetime. [#622](https://github.com/asterinas/asterinas/pull/622) (MERGED) added parent-death signal support. [#3098](https://github.com/asterinas/asterinas/pull/3098) (MERGED) sorts prctl commands.

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

No runtime case was supplied and none ran. The attachment says the multi-thread handshake is not in the default suite and that sleep cannot stand in for registration ordering. The gap is already documented in-tree by a FIXME, so upstream likely knows it even though no tracker record matched.
