# AST-60: getrusage leaves maintained resource-accounting fields zero

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F15, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `getrusage` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#2438](https://github.com/asterinas/asterinas/pull/2438) (RUSAGE_CHILDREN), [#814](https://github.com/asterinas/asterinas/pull/814) (wait4 rusage), [#2389](https://github.com/asterinas/asterinas/pull/2389) (SCML docs), all merged, none fills the remaining fields. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `rusage_accounting`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

`getrusage` fills only the user and system CPU times. Every other field,
including ones Linux maintains such as peak RSS, minor and major faults and
context switches, is returned as zero. Tools that report memory peaks or
fault counts from `getrusage`, such as `/usr/bin/time -v`, would show zeros
on Asterinas.

## Linux contract

[getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html): Linux
maintains `ru_utime`, `ru_stime`, `ru_maxrss`, `ru_minflt`, `ru_majflt`,
`ru_inblock`, `ru_oublock`, `ru_nvcsw` and `ru_nivcsw`. The man page marks
`ru_ixrss`, `ru_idrss`, `ru_isrss`, `ru_nswap`, `ru_msgsnd`, `ru_msgrcv` and
`ru_nsignals` as unmaintained, so zeros there are correct. The saved Linux
6.18 run reported `maxrss=8636 KiB minflt=2060` after touching 8 MiB of
anonymous memory.

## Asterinas behavior

At the pin, every arm of `kernel/core/src/syscall/getrusage.rs::sys_getrusage`
(RUSAGE_SELF, RUSAGE_THREAD and RUSAGE_CHILDREN) builds `rusage_t` with only
`ru_utime` and `ru_stime` and fills the rest with `..Default::default()`.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `rusage_accounting`
maps and touches 8 MiB of private anonymous memory, calls
`getrusage(RUSAGE_SELF)` and passes when `ru_maxrss > 0` and
`ru_minflt > 0`. The saved Linux output is
`after touching 8 MiB: maxrss=8636 KiB minflt=2060 majflt=0 nvcsw=0` (PASS).
By source reading, Asterinas at the pin would print zeros and FAIL. The case
has not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to maintain each
field Linux defines and not report unimplemented counters as measured zeros.
The cited file is byte-identical at upstream `bc12195df` (the pin's direct
child), checked on 2026-09-24 with a read-only `git diff`. Later upstream
commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-60)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F15 split into AST-60 and AST-61)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `files_abi`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F15)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F15)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-rusage_accounting.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-60)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- Compare only fields Linux maintains. The probe asserts only `ru_maxrss` and
  `ru_minflt`, and does not compare exact counts.
- AST-61 (NULL output pointer) is a separate path in the same function.
- Whether `wait4` rusage has the same gap was not reviewed.
- `rusage_accounting` is a legacy text-only case, so read the text line and
  the RESULT line.
