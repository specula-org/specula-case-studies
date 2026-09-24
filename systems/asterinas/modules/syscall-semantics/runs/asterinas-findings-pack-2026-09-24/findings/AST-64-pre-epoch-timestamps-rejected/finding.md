# AST-64: Nonnegative Duration conversion rejects pre-Epoch file timestamps

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F20, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `utimensat` (and `futimens`), `utimes`, `futimesat`, `utime` |
| Upstream | Direct match: open issue [#3746](https://github.com/asterinas/asterinas/issues/3746) "VFS metadata timestamps cannot represent pre-epoch Unix times". Proposals [#3826](https://github.com/asterinas/asterinas/pull/3826) and [#3827](https://github.com/asterinas/asterinas/pull/3827) closed without merge. Related open tracking issue [#3142](https://github.com/asterinas/asterinas/issues/3142) (xfstests gaps). |
| Fix | Unfixed. The two proposals closed unmerged, and no fixed upstream main is inferred. |
| Reproducer | `repro/` (cases `utimens_preepoch` and `utimes_preepoch`, control `utimens_both_omit`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

Asterinas converts explicit file timestamps into an unsigned `Duration`,
which cannot hold a time before 1970. Setting an atime or mtime with a
negative `tv_sec` therefore fails with EINVAL. Archive extractors, backup
restores and test suites that set pre-Epoch times fail on Asterinas where
Linux stores the value.

## Linux contract

[utimensat(2)](https://man7.org/linux/man-pages/man2/utimensat.2.html) and
[utime(2)](https://man7.org/linux/man-pages/man2/utime.2.html) treat the
timestamps as calendar times. EINVAL is for an out-of-range `tv_nsec` or
`tv_usec`, not for a negative `tv_sec`. Whether a pre-Epoch value is stored
depends on the filesystem's timestamp range. The saved Linux 6.18 runs set
`tv_sec = -1` and read it back on both overlayfs and tmpfs.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/utimens.rs::vfs_utimes` converts every
explicit (non-OMIT, non-NOW) `timespec_t` with `Duration::try_from`, and
`kernel/core/src/time/mod.rs::TryFrom<timespec_t> for Duration` returns
EINVAL when `sec < 0`. This covers `utimensat`, `futimens` and `utime`.
`kernel/core/src/syscall/utimens.rs::do_futimesat` separately returns EINVAL
when either `timeval` has `sec < 0`, which covers `utimes` and `futimesat`.
The VFS setters (`Path::set_atime`, `Path::set_mtime`) take `Duration`, so
the storage type cannot represent the value either.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. `utimens_preepoch` sets
both times of an unlinked temporary file to `{-1, 123456789}` with `futimens`
and checks `st_mtim.tv_sec == -1`. `utimes_preepoch` does the same through
the raw `utimes` syscall with `{-1, 0}`. The saved Linux output is
`OBS {"ret":0,"errno":0,"negative_seconds_preserved":true}` for both (PASS).
The negative control `utimens_both_omit` checks that both-OMIT returns 0
early, and Linux printed `OBS {"ret":0,"errno":0}`. By source reading,
Asterinas at the pin would return EINVAL (22) in both probes and FAIL, while
the control would PASS. The cases have not run on Asterinas.

## Fix and upstream status

Issue #3746 tracks exactly this mechanism and is still open. PRs #3826 and
#3827 proposed pre-Epoch support in VFS metadata and were closed without
merge, which is not evidence of a fix. The cited files are byte-identical at
upstream `bc12195df` (the pin's direct child), checked on 2026-09-24 with a
read-only `git diff`. Later upstream commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-64)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F20)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batches `files_abi` and `controls`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F20)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F20)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-utimens_preepoch.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-tmpfs/logs/001-utimes_preepoch.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/README.md` and `matches.json` (AST-64)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- The contract is filesystem-scoped. Compare matched backends and do not
  report an on-disk format's timestamp range as a generic kernel bug.
- The probe checks seconds only, because not every filesystem keeps
  nanoseconds.
- `utimens_both_omit` is a negative control, not a finding.
