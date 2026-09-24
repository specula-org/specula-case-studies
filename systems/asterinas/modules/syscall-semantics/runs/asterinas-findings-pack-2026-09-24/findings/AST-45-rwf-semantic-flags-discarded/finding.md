# AST-45: Accepted RWF semantic flags are discarded before I/O

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F03, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `preadv2`, `pwritev2` |
| Upstream | partial (dedup `PARTIAL_MATCH`, upstream main `bc12195df`): [#3142](https://github.com/asterinas/asterinas/issues/3142), [#3729](https://github.com/asterinas/asterinas/pull/3729) |
| Fix | unfixed (related open work: [#3729](https://github.com/asterinas/asterinas/pull/3729), partial) |
| Reproducer | none (no runtime case was supplied, imported runtime status NOT_RUN) |

## Summary

`preadv2` and `pwritev2` accept `RWF_DSYNC`, `RWF_SYNC`, `RWF_NOWAIT` and `RWF_HIPRI`, then drop them before the file operation. A caller that asks for per-write durability or for a non-blocking read gets success without that guarantee. Any program that passes these flags is affected.

## Linux contract

[readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html) defines `RWF_DSYNC` and `RWF_SYNC` as per-call equivalents of `O_DSYNC` and `O_SYNC`, and `RWF_NOWAIT` as "do not wait for data which is not immediately available", returning `EAGAIN`. `RWF_HIPRI` is a polling hint.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/preadv.rs::sys_preadv2` and `kernel/core/src/syscall/pwritev.rs::sys_pwritev2` parse the flags with `RWFFlag::from_bits`. When `offset == -1` they call `do_sys_readv`/`do_sys_writev`, which take no flags. Otherwise they call `do_sys_preadv`/`do_sys_pwritev`, whose `_flags: RWFFlag` parameter is never read. `do_sys_pwritev` carries `// TODO: Implement flags support`.

## Reproduction

There is no runtime reproducer. `case-plan.json` lists AST-45 under `no_complete_attached_probe`. The attachment's `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md` sketches the two needed designs. For RWF_NOWAIT, construct a page or lock that must be waited on and distinguish a cache hit from a refused wait. For RWF_SYNC and RWF_DSYNC, inject a writeback fault on a disposable backend and show that the error or durability point comes from the same writeback layer.

## Fix and upstream status

No complete fix exists. Open PR #3729 covers RWF_NOWAIT for ext2 only and states that other RWF flags remain ignored. The register notes: "#3142/#3729 track NOWAIT; SYNC/DSYNC remain explicitly deferred in #3729 discussion." The attachment's repair direction is to pass each semantic flag down to the file operation and to report an error for any guarantee that cannot be provided.

Partial: [#3142](https://github.com/asterinas/asterinas/issues/3142) (OPEN, xfstests gap tracking) and [#3729](https://github.com/asterinas/asterinas/pull/3729) (OPEN, RWF_NOWAIT for ext2 buffered and direct I/O) track NOWAIT. The #3729 review ([discussion](https://github.com/asterinas/asterinas/pull/3729#discussion_r3811052190), [author follow-up](https://github.com/asterinas/asterinas/pull/3729#issuecomment-5481435963)) keeps the ignored SYNC/DSYNC bits as future work. [#3359](https://github.com/asterinas/asterinas/pull/3359) (MERGED) corrected the error for invalid RWF bits and is related only.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md`

## Caveats

No attached probe tests these flags. `pwritev2_append` covers only RWF_APPEND (AST-46). The attachment's UNTESTED.md says RWF_NOWAIT needs a page or lock that is known to wait, and SYNC/DSYNC needs writeback fault injection on a disposable backend. A fast or successful cached write does not prove either semantic. Dropping `RWF_HIPRI` alone is a hint and is not claimed as a defect.
