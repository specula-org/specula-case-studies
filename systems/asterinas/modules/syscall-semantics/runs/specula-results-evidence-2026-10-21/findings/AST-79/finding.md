# AST-79 — A cross-bucket requeued waiter's timeout cleanup misses its entry, and the stranded entry strands a live waiter

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-10-04 to 2026-10-10 |
| Date basis | campaign window |

A cross-bucket REQUEUE moves a futex waiter, but timeout cleanup still searches the original bucket. The missed entry can produce a success result instead of ETIMEDOUT and remain in the destination queue. A later migration can spend its quota on that dead entry and strand a live waiter. Upstream issue #3964 covers the cleanup mechanism, superseding the native report's NEW label.

GLM-5.3 reproduced wrong timeout cleanup and later live-waiter stranding. Upstream #3964 covers the cleanup mechanism; the native NEW label is superseded.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| Futex / MC-1 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-1/verdict.json) · [report](../../evidence/native-runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
