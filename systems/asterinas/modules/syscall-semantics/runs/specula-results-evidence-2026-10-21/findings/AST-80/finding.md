# AST-80 — FUTEX_REQUEUE converts a zero wake quota to one

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-10-04 to 2026-10-10 |
| Date basis | campaign window |

The REQUEUE syscall path applies the wake-count normalization used by WAKE, converting a zero wake quota into one. The reproduction observes a waiter being awakened even when the caller requested no wakeups. This is the second mechanism described in upstream issue #3964.

GLM-5.3 reproduced waking one waiter despite a zero wake quota. The second part of upstream #3964 reports this mechanism.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| Futex / MC-2 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/verdict.json) · [report](../../evidence/native-runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
