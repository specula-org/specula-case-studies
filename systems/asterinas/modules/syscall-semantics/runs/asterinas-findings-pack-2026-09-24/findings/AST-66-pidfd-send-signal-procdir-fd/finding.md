# AST-66: pidfd_send_signal rejects the /proc/PID directory-FD form

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F22, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `pidfd_send_signal` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#2866](https://github.com/asterinas/asterinas/issues/2866) (closed pidfd parity issue), [#2912](https://github.com/asterinas/asterinas/pull/2912) (adds the syscall) and [#3360](https://github.com/asterinas/asterinas/pull/3360) (NULL siginfo fix), both merged. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `pidfd_procdir`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

`pidfd_send_signal` accepts only FDs created as pidfds. An FD obtained by
opening a `/proc/PID` directory, which Linux also accepts, fails with EBADF.
Programs that signal a process through its `/proc` directory FD cannot do so
on Asterinas.

## Linux contract

[pidfd_send_signal(2)](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html):
the `pidfd` argument may be obtained by opening a `/proc/pid` directory, by
`pidfd_open(2)`, or through `CLONE_PIDFD`. The saved Linux 6.18 run sent
signal 0 through an FD from `open("/proc/self", O_DIRECTORY)` and got 0.

## Asterinas behavior

At the pin,
`kernel/core/src/syscall/pidfd_send_signal.rs::get_target_from_pidfd`
resolves any FD other than the two `PIDFD_SELF_*` constants by
`file.downcast_ref::<PidFile>()` and returns EBADF when the downcast fails.
The code carries a FIXME that cites the man page and states that Linux also
accepts a `/proc/pid` directory FD.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `pidfd_procdir` opens
`/proc/self` with `O_RDONLY | O_DIRECTORY | O_CLOEXEC` and calls the raw
`pidfd_send_signal(fd, 0, NULL, 0)`. The saved Linux output is
`OBS {"ret":0,"errno":0}` (PASS). By source reading, Asterinas at the pin
would print `OBS {"ret":-1,"errno":9}` (EBADF) and FAIL. The case has not
run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to accept the
`/proc/PID` directory object in this syscall and handle the target's exit
lifetime correctly. The cited file is byte-identical at upstream `bc12195df`
(the pin's direct child), checked on 2026-09-24 with a read-only `git diff`.
Later upstream commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-66)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F22)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `signals_vm`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F22)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F22)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-pidfd_procdir.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-66)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- The register calls this a candidate FD-kind compatibility gap. The
  supported scope and the runtime behavior remain to be checked, and the
  in-code FIXME shows the gap is known to the authors.
- The claim is limited to this syscall. It does not say a `/proc/PID` FD must
  work for every pidfd operation.
- The probe needs `/proc/self` to open as a directory in the guest. A setup
  failure there is not evidence either way.
- AST-63 is a different defect in the same file.
