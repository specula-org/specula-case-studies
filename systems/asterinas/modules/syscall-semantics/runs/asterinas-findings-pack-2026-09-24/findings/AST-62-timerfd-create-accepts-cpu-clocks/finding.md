# AST-62: timerfd_create accepts generic CPU clocks outside its Linux domain

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F16, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `timerfd_create` |
| Upstream | Merged upstream fix. Issue [#3823](https://github.com/asterinas/asterinas/issues/3823) (closed) is closed by PR [#3824](https://github.com/asterinas/asterinas/pull/3824), merged 2026-09-14 06:26:49 UTC as upstream `bc12195df4acfb1fc4ae968cf7acf9333ed83435`. |
| Fix | Merged upstream in `bc12195df`, verified by static reading only. No local fix and no runtime test at either commit. |
| Reproducer | `repro/` (cases `timerfd_cpu_process` and `timerfd_cpu_thread`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

At the pin, `timerfd_create` routes the clock ID through the POSIX-timer
helper, which accepts `CLOCK_PROCESS_CPUTIME_ID` and
`CLOCK_THREAD_CPUTIME_ID`. `timerfd_create` therefore returns a timer FD for
two clocks that Linux rejects with EINVAL. Programs that probe clock support
by calling `timerfd_create` get a wrong answer. Upstream has fixed this.

## Linux contract

[timerfd_create(2)](https://man7.org/linux/man-pages/man2/timerfd_create.2.html):
`clockid` must be `CLOCK_REALTIME`, `CLOCK_MONOTONIC`, `CLOCK_BOOTTIME`,
`CLOCK_REALTIME_ALARM` or `CLOCK_BOOTTIME_ALARM`. The saved Linux 6.18 run
returned EINVAL (22) for clock 2 and clock 3.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/timerfd_create.rs::sys_timerfd_create`
passes the raw clock ID to `kernel/core/src/time/timerfd.rs::TimerfdFile::new`,
which calls `kernel/core/src/syscall/timer_create.rs::create_timer`. That
helper serves `timer_create` too, and its match creates profiling timers for
both CPU-time clocks. No timerfd-specific check rejects them.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Cases
`timerfd_cpu_process` and `timerfd_cpu_thread` call
`timerfd_create(clock, TFD_NONBLOCK | TFD_CLOEXEC)` and close any FD that is
unexpectedly returned. The saved Linux output is
`OBS {"clock":2,"accepted":false,"errno":22}` and the same for clock 3 (PASS).
By source reading, Asterinas at the pin would report `"accepted":true` and
FAIL, and upstream `bc12195df` would PASS. Neither commit has been run.

## Fix and upstream status

PR #3824 decodes a typed `ClockId` in `sys_timerfd_create` and whitelists
`CLOCK_REALTIME`, `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` in
`TimerfdFile::new`, which rejects both CPU clocks by static inspection. Its
merge commit `bc12195df` is the direct child of the TLPI pin. Issue #3823
also reports a panic on dynamic (negative) clock IDs, which the TLPI probes
do not cover. The register keeps SOURCE LEAD because no runtime result
exists.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-62)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F16)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `timerfd`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F16)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F16)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-timerfd_cpu_process.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-timerfd_cpu_thread.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/README.md` and `matches.json` (AST-62, including `static_fix_proof`)

## Caveats

- No runtime result exists at the pin or at the fixed upstream commit. When
  testing, state explicitly whether the target is the old pin or fixed
  upstream, and do not swap kernels under one run identity.
- TLPI-v2 classifies this as a parameter-domain difference. Accepting extra
  clock IDs alone does not establish a security defect.
- PR #3824 does not fix AST-19 (timerfd readiness cached after read or
  disarm), which touches the same file.
