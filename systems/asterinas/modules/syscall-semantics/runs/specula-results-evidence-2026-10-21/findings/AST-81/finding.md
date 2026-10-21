# AST-81 — Same-bucket FUTEX_REQUEUE moves a waiter when the migration quota is zero

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-10-04 to 2026-10-10 |
| Date basis | campaign window |

The same-bucket REQUEUE path can move one waiter before enforcing a zero migration quota. This migration-count defect is separate from AST-80's conversion of the wake quota.

GLM-5.3 reproduced a same-bucket migration despite a zero move quota; separate from zero-wake normalization.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| Futex / MC-3 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/verdict.json) · [report](../../evidence/native-runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
