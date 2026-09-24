# AST-53: MADV_FREE no-op handling omits mapping-kind validation

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F09, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `madvise` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `madvise_free_shared`, Linux evidence only) |

## Summary

`MADV_FREE` is handled as a no-op hint after a fully-mapped check, so it is accepted on shared anonymous mappings where Linux returns `EINVAL`. The no-op itself is fine. The finding is the missing mapping-kind validation, which a program can observe as success instead of an error.

## Linux contract

[madvise(2)](https://man7.org/linux/man-pages/man2/madvise.2.html) says `MADV_FREE` "can be applied only to private anonymous pages". The saved Linux runs show `MADV_FREE on shared anonymous mapping=-1 errno=22`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/madvise.rs::sys_madvise` takes the `DUMMY_MADVISE` arm for `MADV_FREE`. That arm returns `ENOMEM` if the range is not fully mapped and otherwise returns 0. It never inspects whether the mapping is shared, file-backed or anonymous.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `madvise_free_shared` calls `madvise(MADV_FREE)` on a one-page shared anonymous mapping. It passes when `madvise` returns -1 with errno 22 (`EINVAL`). All five saved Linux executions report PASS, for example `MADV_FREE on shared anonymous mapping=-1 errno=22`. Source prediction for Asterinas at `a5449e62b`, not observed: `madvise` returns 0, so the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The register notes: "A legal optimization no-op is not itself a bug; compare the shared-map validation case". A repair keeps the no-op but rejects `MADV_FREE` with `EINVAL` on mappings that are not private anonymous.

No direct match in the searched scope. [#1132](https://github.com/asterinas/asterinas/pull/1132) (MERGED) implemented MADV_FREE, [#1188](https://github.com/asterinas/asterinas/pull/1188) (MERGED) fixed a panic in it, and [#2766](https://github.com/asterinas/asterinas/pull/2766) (MERGED) made it a permitted no-op hint and removed the earlier implementation. No review of the shared-mapping validation difference was found.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-madvise_free_shared.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static and NOT_RUN. The attachment and the register both say a legal no-op hint is not a bug by itself. The visible effect is a return-value difference on an invalid request, and no security impact is claimed.
