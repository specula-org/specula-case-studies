# AST-67: Expired clock_nanosleep fast path bypasses clock validation

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F23, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `clock_nanosleep` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#3147](https://github.com/asterinas/asterinas/pull/3147) (CPU-clock errno), [#3296](https://github.com/asterinas/asterinas/pull/3296) (unknown flag bits panic), [#2389](https://github.com/asterinas/asterinas/pull/2389) (SCML docs), all merged, none reorders the check. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `clock_nanosleep_rawpast`, control `libc_clock_error`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

`clock_nanosleep` with TIMER_ABSTIME and a deadline already in the past
returns 0 before it checks whether the clock supports sleeping. For
`CLOCK_MONOTONIC_RAW` the call therefore succeeds, where Linux fails with
EOPNOTSUPP. A program that probes sleep support with an expired deadline gets
the wrong answer.

## Linux contract

[clock_nanosleep(2)](https://man7.org/linux/man-pages/man2/clock_nanosleep.2.html)
fails with ENOTSUP when the kernel does not support sleeping against the
clock. ENOTSUP equals EOPNOTSUPP (95) on x86-64 Linux. The saved Linux 6.18
run returned `-1` with errno 95 for the raw syscall with
`CLOCK_MONOTONIC_RAW`, TIMER_ABSTIME and deadline `{0, 1}`.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/nanosleep.rs::do_clock_nanosleep` first
calls `kernel/core/src/syscall/clock_gettime.rs::read_clock`, which supports
`CLOCK_MONOTONIC_RAW`. For an absolute request earlier than the current time
it returns `Ok(0)` immediately. Only after that does it match the clock ID
and return EOPNOTSUPP for `CLOCK_THREAD_CPUTIME_ID`, `CLOCK_MONOTONIC_RAW`
and the two coarse clocks. An expired absolute request never reaches that
match.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case
`clock_nanosleep_rawpast` checks that the raw clock is past 1 ns and then
calls `syscall(SYS_clock_nanosleep, CLOCK_MONOTONIC_RAW, TIMER_ABSTIME,
{0, 1}, NULL)`. The saved Linux output is `OBS {"ret":-1,"errno":95}` (PASS).
The negative control `libc_clock_error` calls the glibc wrapper with a
relative sleep, and Linux printed `OBS {"library_ret":95,"errno_after":0}`.
By source reading, Asterinas at the pin would print `OBS {"ret":0,"errno":0}`
and FAIL, while the relative-sleep control reaches the EOPNOTSUPP arm and
would PASS. The cases have not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to validate the
clock for sleeping before the no-wait fast path. The cited files are
byte-identical at upstream `bc12195df` (the pin's direct child), checked on
2026-09-24 with a read-only `git diff`. Later upstream commits were not
checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-67)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F23)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batches `signals_vm` and `controls`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F23)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F23)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-clock_nanosleep_rawpast.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-libc_clock_error.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-67)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- Keep the raw syscall convention (`-1` and errno) apart from the glibc
  convention (a positive error number as the return value). The control
  exists for that reason and is not a finding.
- Only `CLOCK_MONOTONIC_RAW` is probed. The same ordering applies to the other
  clocks in the EOPNOTSUPP arm, which no probe covers.
