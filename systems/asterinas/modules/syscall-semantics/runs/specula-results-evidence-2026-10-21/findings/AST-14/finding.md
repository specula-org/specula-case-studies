# AST-14 — Empty exFAT writes enlarge EOF and may allocate clusters

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Fixed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-09-08 to 2026-09-09 |
| Date basis | campaign window |

Historical reproduction covers buffered I/O. PR #3875 now addresses ramfs/exFAT empty writes; the original metadata predates this upstream association.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-14-exfat-empty-write-enlarges-eof/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| 01b / MC-7 | Kimi-K3 / pi | [verdict](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/verdict.json) · [report](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `complete_merged_fix` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

[Upstream repair reference](https://github.com/asterinas/asterinas/pull/3875).

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
