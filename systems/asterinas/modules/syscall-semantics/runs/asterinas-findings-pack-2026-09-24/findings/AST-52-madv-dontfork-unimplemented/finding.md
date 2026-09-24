# AST-52: MADV_DONTFORK is not implemented in the reviewed advice handler

| Field | Value |
|---|---|
| Evidence status | UNSUPPORTED |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F09, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `madvise` |
| Upstream | related (dedup `KNOWN_SUPPORT_GAP`, upstream main `bc12195df`): [#2692](https://github.com/asterinas/asterinas/pull/2692), [#2766](https://github.com/asterinas/asterinas/pull/2766) |
| Fix | not-applicable |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `madvise_dontfork`, Linux evidence only) |

## Summary

`madvise(MADV_DONTFORK)` returns `EINVAL` because the handler has no arm for it. Programs that use it get an explicit error. Upstream removed an earlier no-op stub on purpose, so the register tracks this as an unsupported operation, not an implementation bug.

## Linux contract

[madvise(2)](https://man7.org/linux/man-pages/man2/madvise.2.html) defines `MADV_DONTFORK` as "do not make the pages in this range available to the child after a fork(2)". The saved Linux runs show `MADV_DONTFORK on private anonymous mapping=0 errno=0`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/madvise.rs::sys_madvise` matches `MADV_DONTNEED` (calls `vmar.discard_pages`) and the `DUMMY_MADVISE` list, and every other advice returns `EINVAL` ("the madvise behavior is not supported yet"). `DUMMY_MADVISE` does not contain `MADV_DONTFORK`, and its doc comment warns that not every advice can be a no-op.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `madvise_dontfork` calls `madvise(MADV_DONTFORK)` on a one-page private anonymous mapping. It passes when `madvise` returns 0. All five saved Linux executions report PASS, for example `MADV_DONTFORK on private anonymous mapping=0 errno=0`. Source prediction for Asterinas at `a5449e62b`, not observed: `madvise` returns -1 with errno 22 (`EINVAL`), so the case reports FAIL. That result confirms the gap, not a defect.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

Not applicable. The register notes: "#2766 deliberately removed the incorrect DONTFORK stub from #2692; retain unsupported status." A real implementation must mark the VMA so that fork skips it.

Documented unsupported-operation gap. [#2692](https://github.com/asterinas/asterinas/pull/2692) (MERGED) added a `madvise` stub. [#2766](https://github.com/asterinas/asterinas/pull/2766) (MERGED) removed the DONTFORK stub deliberately because a no-op changes program semantics, and recorded the need for a real implementation or a userspace workaround. [#2689](https://github.com/asterinas/asterinas/issues/2689) (CLOSED, TCG QEMU) was reviewed as context.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-madvise_dontfork.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The register status is UNSUPPORTED. The imported runtime status is separately NOT_RUN. The probe only checks that the call is accepted. A no-op implementation would pass it and still be wrong, which is why #2766 removed the stub. A complete test must fork and show the range is absent in the child.
