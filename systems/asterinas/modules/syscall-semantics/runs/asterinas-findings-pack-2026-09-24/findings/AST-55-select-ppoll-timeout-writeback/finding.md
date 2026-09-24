# AST-55: Raw select/ppoll omit remaining-timeout writeback

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F11, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `select`, `ppoll`, `pselect6` |
| Upstream | partial (dedup `PARTIAL_MATCH`, upstream main `bc12195df`): [#2025](https://github.com/asterinas/asterinas/pull/2025) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `select_timeout`, `ppoll_timeout`, Linux evidence only) |

## Summary

Raw `select` and `ppoll` leave the caller's timeout unchanged after waiting. Linux writes back the time not slept. Programs and runtimes that issue the syscalls directly and reuse the timeout in a loop can wait longer than intended. The glibc `ppoll` wrapper hides the update on Linux, so libc users of `ppoll` see no difference.

## Linux contract

[select(2)](https://man7.org/linux/man-pages/man2/select.2.html) says that on Linux `select()` modifies `timeout` to reflect the time not slept. [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html) says the raw `ppoll` syscall modifies its timeout argument and the glibc wrapper hides this with a local copy. The saved Linux runs show `raw select=0 remaining=0.000000` and `raw ppoll=0 remaining=0.000000000`, and the control `libc_ppoll_timeout` shows `timeout_unchanged:true`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/select.rs::sys_select` reads the `timeval`, converts it to `Duration`, and calls `do_sys_select`, which writes back only the fd sets and carries a FIXME that Linux modifies the timeout. `kernel/core/src/syscall/ppoll.rs::sys_ppoll` reads the `timespec`, calls `do_sys_poll`, and ends with a TODO to write back the remaining time.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `select_timeout` calls raw `select(0, NULL, NULL, NULL, {0, 20000})` and prints the timeout afterwards. It passes when `select` returns 0 and the timeout reads `0.000000`. All five saved Linux executions report PASS, for example `raw select=0 remaining=0.000000`. Source prediction for Asterinas at `a5449e62b`, not observed: the timeout still reads `0.020000`, so the case reports FAIL.

Case `ppoll_timeout` calls raw `ppoll(NULL, 0, {0, 20000000}, NULL, 8)` and prints the timeout afterwards. It passes when `ppoll` returns 0 and the timeout reads `0.000000000`. All five saved Linux executions report PASS, for example `raw ppoll=0 remaining=0.000000000`. Source prediction for Asterinas at `a5449e62b`, not observed: the timeout still reads `0.020000000`, so the case reports FAIL.

Negative control `libc_ppoll_timeout` calls the glibc `ppoll(NULL, 0, {0, 20000000}, NULL)` wrapper. This is a negative control, not a finding probe. It passes when `ppoll` returns 0 and the timeout is unchanged. All five saved Linux executions report PASS, for example `OBS {"ret":0,"errno":0,"timeout_unchanged":true}`. Source prediction for Asterinas at `a5449e62b`, not observed: PASS on both systems, because glibc hides the update. A FAIL here would point at the harness or libc, not at AST-55.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The register notes: "Missing raw ppoll writeback is explicitly documented in merged PR #2025; select coverage and runtime confirmation remain separate." The in-tree TODO in `sys_ppoll` says the writeback "cannot be readily achieved given how our internal synchronization primitives such as `Pause` and `WaitTimeout` work". The attachment suggests keeping the deadline and writing back the remaining time on the return paths Linux defines, including signals and personality.

Partial: [#2025](https://github.com/asterinas/asterinas/pull/2025) (MERGED 2025-04-21, "Add syscall ppoll") and [its review](https://github.com/asterinas/asterinas/pull/2025#discussion_r2051402867) explicitly record the missing raw ppoll writeback. The merge kept the gap, so this is public documentation, not a fix. The select half has no match. [#2122](https://github.com/asterinas/asterinas/issues/2122) (CLOSED) concerns wait duration and [#2734](https://github.com/asterinas/asterinas/pull/2734) (MERGED) is SCML coverage.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-select_timeout.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-ppoll_timeout.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-libc_ppoll_timeout.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static and NOT_RUN. A libc `ppoll` that leaves the timeout unchanged is correct and is used here as the negative control `libc_ppoll_timeout`. `STICKY_TIMEOUTS` is a separate personality setting. The `select.rs` FIXME claims the glibc wrapper also hides the select update. The attachment has no libc select control, so that claim was not checked. `sys_pselect6` shares `do_sys_select` and also does not write back its `timespec` (source reading for this package, not recorded by the attachment, no probe).
