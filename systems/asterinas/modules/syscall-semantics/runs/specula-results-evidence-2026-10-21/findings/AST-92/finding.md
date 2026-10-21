# AST-92 — waitid without WEXITED consumes an exited child

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `outcome_only_runtime_observation` |
| Tracker status (2026-10-21) | Blank |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-10-05 to 2026-10-10 |
| Date basis | campaign window; exact discovery date unknown |

A waitid call without WEXITED consumes an exited child in the retained sequential outcome comparison. The collector recorded per-call differences, but run completion remained inconclusive. There is no native confirmation verdict or implementation trace.

Outcome-only sequential mismatch with Linux controls; no native confirmation verdict or implementation trace. Harness review remained NOT_APPROVED with an accepted residual.

## Outcome evidence

[Wait/reap result and limitations](../../evidence/workspace/reports/flock-wait-handoff-2026-10-05/wait-reap/result.md).

The harness review remained NOT_APPROVED with an accepted residual. Per-call outcome differences do not establish a completed pipeline or concurrent protocol validation.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
