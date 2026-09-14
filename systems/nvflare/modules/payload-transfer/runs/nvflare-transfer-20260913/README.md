# NVFlare payload transfer

Run `nvflare-transfer-20260913` covers streamed-payload receiver completion, cancellation, settlement, source lifetime, and timeouts at revision `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Results

| Finding | Status |
| --- | --- |
| MC-1 | REPRODUCED |
| MC-2 | REPRODUCED |
| CR-2 | REPRODUCED |
| CR-4 | REPRODUCED: diagnostic only |
| CR-5 | FALSE POSITIVE |

The run identifies four bugs. See the [confirmation report](confirmed-bugs.md) and [system overview](../../../../overview.md).

## Artifacts

- [Guidance](guidance.md), [analysis](analysis-report.md), and [modeling brief](modeling-brief.md).
- [Reference model](spec/base.tla), [MC wrapper](spec/MC.tla), [Trace wrapper](spec/Trace.tla), and [instrumentation mapping](spec/instrumentation-spec.md).
- [Harness report](harness/REPORT.md), [trace replay receipts](spec/output/round1-traces/results.json), and [validation report](spec/validation-report.md).
- [Validation review](spec/review-validation.md), [test sources](repro), and [confirmation records](confirmation).
- [Run metadata](run.json) and [file inventory](.record/files.tsv).

All 16 recorded implementation traces replayed successfully; original and normalized files represent the same scenarios. Three hunt counterexamples support two MC mechanisms. Main and budget-focused searches ended on their time budgets. Budget-candidate snapshots, time sampling, and monitor decisions still need source/model alignment.

MC-1 requires controlled executor failure. MC-2 affects source progress while the final receipt remains failed. CR-2 used in-process transport. CR-4 affects warning text while budget enforcement and final outcomes remain correct. Scripts and receipts retain their original workspace paths; source worktrees, environments, runtime transcripts, and TLC scratch state are excluded.
