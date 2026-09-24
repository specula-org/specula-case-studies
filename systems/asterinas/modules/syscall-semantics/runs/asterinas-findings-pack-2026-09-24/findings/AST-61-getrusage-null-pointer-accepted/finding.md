# AST-61: getrusage accepts a NULL output pointer without copyout error

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F15, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `getrusage` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#2438](https://github.com/asterinas/asterinas/pull/2438) and [#2389](https://github.com/asterinas/asterinas/pull/2389), both merged, neither touches pointer validation. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `rusage_null`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

`getrusage` skips the copyout entirely when the output address is 0 and
returns success. A caller that passes NULL by mistake gets 0 instead of
EFAULT and cannot detect the error. The impact is limited to error
reporting.

## Linux contract

[getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html): EFAULT
is returned when `usage` points outside the accessible address space. The
saved Linux 6.18 run returned `-1` with errno 14 (EFAULT) for a raw
`getrusage(RUSAGE_SELF, NULL)`.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/getrusage.rs::sys_getrusage` validates
`who` with `RusageTarget::try_from`, then wraps the result construction and
`write_val` in `if rusage_addr != 0`, and returns 0 in every case that gets
that far.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `rusage_null` calls
`syscall(SYS_getrusage, RUSAGE_SELF, NULL)`. The saved Linux output is
`raw getrusage(NULL)=-1 errno=14` (PASS). By source reading, Asterinas at the
pin would print `raw getrusage(NULL)=0 errno=0` and FAIL. The case has not
run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to perform the
copyout unconditionally and let the user-space write report EFAULT. The
cited file is byte-identical at upstream `bc12195df` (the pin's direct
child), checked on 2026-09-24 with a read-only `git diff`. Later upstream
commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-61)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F15 split into AST-60 and AST-61)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `files_abi`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F15)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F15)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-rusage_null.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-61)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- Only the NULL address is covered. Non-NULL invalid addresses go through
  `write_val` and were not probed.
- AST-60 (zero accounting fields) is a separate defect in the same function.
- `rusage_null` is a legacy text-only case, so read the text line and the
  RESULT line.
