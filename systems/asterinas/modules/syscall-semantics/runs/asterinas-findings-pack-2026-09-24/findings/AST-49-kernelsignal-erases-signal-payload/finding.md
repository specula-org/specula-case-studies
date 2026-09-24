# AST-49: Generic KernelSignal construction erases source-specific signal payload

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F06, F18, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `exit`, `exit_group`, `timer_create`, `timer_settime`, `rt_sigtimedwait`, `rt_sigaction` |
| Upstream | partial (dedup `PARTIAL_MATCH`, upstream main `bc12195df`): [#2913](https://github.com/asterinas/asterinas/issues/2913) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `sigchld_payload`, `posix_timer_payload`, Linux evidence only) |

## Summary

Child-exit `SIGCHLD` and POSIX timer signals are both built as a generic `KernelSignal`, whose `siginfo_t` has `si_code = SI_KERNEL` and zeroed fields. A parent that reads `SIGCHLD` with `sigwaitinfo` or `SA_SIGINFO` cannot see `CLD_EXITED`, the child PID or the exit status. A program with several timers on one signal cannot tell them apart by `si_value`.

## Linux contract

[sigaction(2)](https://man7.org/linux/man-pages/man2/sigaction.2.html) specifies that `SIGCHLD` fills `si_pid`, `si_uid`, `si_status`, `si_utime` and `si_stime`, with `si_code` such as `CLD_EXITED`. [timer_create(2)](https://man7.org/linux/man-pages/man2/timer_create.2.html) delivers `SIGEV_SIGNAL` notifications with `si_code = SI_TIMER` and `si_value` equal to `sigev_value`. The saved Linux runs show `SIGCHLD=17 code=1 pid=<child> expected_pid=<child> status=37` and `OBS {"signal_matches":true,"code":-2,"value":79225,"errno":0}` (`SI_TIMER` is -2 and 79225 is 0x13579).

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/process/exit.rs::send_child_death_signal` enqueues `KernelSignal::new(exit_signal)` on the parent. `kernel/core/src/process/signal/signals/kernel.rs::KernelSignal::to_info` returns `siginfo_t::new(self.num, SI_KERNEL)`, and `kernel/core/src/process/signal/c_types.rs::siginfo_t::new` sets `siginfo_fields_t::zero_fields()`. `kernel/core/src/syscall/timer_create.rs::sys_timer_create` builds `KernelSignal::new(SigNum::try_from(signo as u8)?)` for `SIGEV_SIGNAL` and `SIGEV_THREAD_ID` and never stores `sigev_value`.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `sigchld_payload` blocks `SIGCHLD`, forks a child that calls `_exit(37)`, and waits for the signal with `sigtimedwait` (2 s). It passes when the signal is `SIGCHLD` with `si_code == CLD_EXITED`, `si_pid` equal to the child and `si_status == 37`. All five saved Linux executions report PASS, for example `SIGCHLD=17 code=1 pid=668 expected_pid=668 status=37` (5 distinct lines, because PIDs or timings vary). Source prediction for Asterinas at `a5449e62b`, not observed: `si_code` is `SI_KERNEL` and `si_pid`/`si_status` are 0, so the case reports FAIL.

Case `posix_timer_payload` blocks `SIGRTMIN`, creates a `CLOCK_MONOTONIC` timer with `SIGEV_SIGNAL` and `sival_int = 0x13579`, arms it for 10 ms, and waits with `sigtimedwait` (1 s). It passes when the signal matches, `si_code == SI_TIMER` and `si_value.sival_int == 0x13579`. All five saved Linux executions report PASS, for example `OBS {"signal_matches":true,"code":-2,"value":79225,"errno":0}`. Source prediction for Asterinas at `a5449e62b`, not observed: `si_code` is `SI_KERNEL` and `value` is 0, so the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The register notes: "Open #2913 overlaps the POSIX timer payload family; SIGCHLD/value deltas remain separate." The attachment suggests a child-status signal type filled per the Linux `siginfo_t` layout, and a timer signal type that keeps `sigev_value` and overrun information.

Partial: [#2913](https://github.com/asterinas/asterinas/issues/2913) (OPEN, "POSIX timer signals do not populate `siginfo_t` with `si_timerid` and `si_overrun`") acknowledges that the generic KernelSignal loses POSIX timer information. The SIGCHLD payload and the exact `si_value`/`SI_TIMER` observations extend that scope. [#3819](https://github.com/asterinas/asterinas/issues/3819) (OPEN) and [#3820](https://github.com/asterinas/asterinas/pull/3820) (OPEN) concern the signalfd sender PID for user-generated signals and were excluded.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-sigchld_payload.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-posix_timer_payload.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static and NOT_RUN. It merges two attachment groups, F06 and F18, that share the generic-signal-payload root cause and count as one entry. A correct `waitpid` status does not show that the `SIGCHLD` payload is correct. #2913 covers `si_timerid` and `si_overrun`, but not the SIGCHLD fields or `si_value`. `exit.rs::send_parent_death_signal` uses the same `KernelSignal` and carries a FIXME about `si_pid` (see AST-50).
