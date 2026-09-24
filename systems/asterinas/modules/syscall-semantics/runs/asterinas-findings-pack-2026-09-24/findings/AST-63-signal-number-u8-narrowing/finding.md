# AST-63: Signal number is narrowed to u8 before validation

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F19, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `timer_create`, `pidfd_send_signal` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#3121](https://github.com/asterinas/asterinas/pull/3121) and [#3112](https://github.com/asterinas/asterinas/issues/3112) (clone exit-signal panic), [#3376](https://github.com/asterinas/asterinas/pull/3376) (pidfd signal 0), [#3360](https://github.com/asterinas/asterinas/pull/3360) (pidfd NULL siginfo), [#2912](https://github.com/asterinas/asterinas/pull/2912) (adds pidfd_send_signal), [#1199](https://github.com/asterinas/asterinas/issues/1199) (timer_create unwrap panic), [#3841](https://github.com/asterinas/asterinas/pull/3841) (open, F_SETOWN SIGIO). None covers the narrowing. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (cases `timer_create_bad_signal` and `pidfd_bad_signal`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

`timer_create` and `pidfd_send_signal` cast the caller's signal number to
`u8` before validating it. An out-of-range number such as 266 (256 + SIGUSR1)
wraps to 10 and is accepted as SIGUSR1, where Linux fails with EINVAL. A
caller that passes a corrupted or unchecked signal number gets a different,
valid signal delivered instead of an error.

## Linux contract

[timer_create(2)](https://man7.org/linux/man-pages/man2/timer_create.2.html)
returns EINVAL when `sigev_signo` is invalid, and
[pidfd_send_signal(2)](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html)
returns EINVAL when `sig` is not a valid signal. The value 266 is inside the
C `int` range but is not a signal number. The saved Linux 6.18 run returned
EINVAL (22) for both calls.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/timer_create.rs::sys_timer_create` builds
the expiry signal with `SigNum::try_from(signo as u8)` in both the
SIGEV_SIGNAL and SIGEV_THREAD_ID arms, where `signo` is the `i32`
`sigev_signo`. `kernel/core/src/syscall/pidfd_send_signal.rs::sys_pidfd_send_signal`
receives `sig_num: u64` and calls `SigNum::try_from(sig_num as u8)` for any
nonzero value. The cast discards the high bits, so validation sees only the
low byte.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. `timer_create_bad_signal`
calls `timer_create(CLOCK_MONOTONIC)` with SIGEV_SIGNAL and signal 266, and
deletes the timer without arming it if the call succeeds. `pidfd_bad_signal`
opens a pidfd for itself, blocks SIGUSR1 and calls
`pidfd_send_signal(fd, 266, NULL, 0)`. The saved Linux output is
`OBS {"accepted":false,"errno":22}` for both (PASS). By source reading,
Asterinas at the pin would report `"accepted":true` for both and FAIL. The
cases have not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to decode the
Linux ABI type first, validate the full value range, and only then narrow to
the internal type. The upstream cross-check found both casts still present
at `bc12195df`, and a read-only `git show` on 2026-09-24 confirmed the two
`signo as u8` casts in `timer_create.rs` there. `pidfd_send_signal.rs` is
byte-identical between the pin and `bc12195df`.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-63)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F19)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `signals_vm`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F19)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F19)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-timer_create_bad_signal.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-pidfd_bad_signal.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-63)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- The claim is not a blanket rule about high register bits. Linux itself may
  truncate a 64-bit register to `int` for some arguments. The defect is that
  an in-range `int` that is not a signal number becomes a valid signal.
- AST-49 (TLPI F06/F18) covers the lost payload of the same
  `KernelSignal::new(..)` construction in `sys_timer_create`. AST-66 covers a
  different gap in `pidfd_send_signal.rs`. Keep them apart.
