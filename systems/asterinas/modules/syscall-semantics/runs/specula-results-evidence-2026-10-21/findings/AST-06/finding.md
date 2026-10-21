# AST-06 — Failed append advances the shared file offset

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-08-23 to 2026-08-24 |
| Date basis | campaign window |

Reported zero-progress append fault changes the shared offset. The supplied upstream audit associates the mechanism with the earlier PR #3481; coverage was checked statically.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-06-append-offset-on-fault/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| 01a / MC-7 | Claude Opus 5 / Claude Code | [verdict](../../evidence/native-runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-7/verdict.json) · [report](../../evidence/native-runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
