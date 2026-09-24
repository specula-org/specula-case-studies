# AST-46: RWF_APPEND is not supported by the reviewed vectored-I/O flags

| Field | Value |
|---|---|
| Evidence status | UNSUPPORTED |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F03, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `pwritev2` |
| Upstream | related (dedup `KNOWN_SUPPORT_GAP`, upstream main `bc12195df`): [#3359](https://github.com/asterinas/asterinas/pull/3359), [#3729](https://github.com/asterinas/asterinas/pull/3729) |
| Fix | not-applicable |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `pwritev2_append`, Linux evidence only) |

## Summary

`pwritev2` rejects `RWF_APPEND` with `EOPNOTSUPP` because the flag is missing from the accepted bit set. Programs that use the per-call append flag get an explicit error. The register tracks this as an unsupported operation, not as an implementation bug.

## Linux contract

[readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html) defines `RWF_APPEND` (since Linux 4.16) as a per-call `O_APPEND`, and the offset argument does not affect where the data lands. The saved Linux runs show `raw pwritev2(RWF_APPEND, offset=0)=1 errno=0 file-size-read=2 data=AB`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/pwritev.rs::sys_pwritev2` calls `RWFFlag::from_bits(flags)` and returns `EOPNOTSUPP` ("unsupported flags") when it yields `None`. `RWFFlag` in the same file defines `RWF_DSYNC`, `RWF_HIPRI`, `RWF_SYNC` and `RWF_NOWAIT` only. `kernel/core/src/syscall/preadv.rs` has the same bit set.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `pwritev2_append` writes `A` to a temporary file, then calls raw `pwritev2` with offset 0 and `RWF_APPEND` to write `B`, and reads back 2 bytes. It passes when `pwritev2` returns 1 and the file reads `AB`. All five saved Linux executions report PASS, for example `raw pwritev2(RWF_APPEND, offset=0)=1 errno=0 file-size-read=2 data=AB`. Source prediction for Asterinas at `a5449e62b`, not observed: `pwritev2` returns -1 with errno 95 (`EOPNOTSUPP`) and the file holds only `A`, so the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

Not applicable. The register classifies this as "Static EOPNOTSUPP coverage gap; not a confirmed implementation bug". Supporting the flag would add `RWF_APPEND` to `RWFFlag` and perform the write at end of file under the same serialization as `O_APPEND`.

Documented unsupported-operation gap. [#3359](https://github.com/asterinas/asterinas/pull/3359) (MERGED) corrected the error code for unsupported RWF bits and did not add APPEND support. [#3729](https://github.com/asterinas/asterinas/pull/3729) (OPEN) adds RWF_NOWAIT for ext2 only. No reviewed upstream work implements RWF_APPEND.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-pwritev2_append.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The register status is UNSUPPORTED. The imported runtime status is separately NOT_RUN. A Linux difference caused by an explicitly unsupported flag is a coverage gap and must not be promoted to a bug without a violated supported contract.
