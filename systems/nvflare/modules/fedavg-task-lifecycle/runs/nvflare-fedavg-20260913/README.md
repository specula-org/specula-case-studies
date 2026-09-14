# NVFlare FedAvg task lifecycle

Run `nvflare-fedavg-20260913` covers FedAvg contribution handling and the WFCommServer task/result lifecycle at revision `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Results

| Finding | Status |
| --- | --- |
| MC-1 | REPRODUCED |
| CR-1 | DROPPED: known and fixed |
| CR-2 | REPRODUCED |
| CR-4 | FALSE POSITIVE |
| CR-5 | FALSE POSITIVE |

The run identifies two bugs: partial aggregation after contribution rejection, and retained duplicate results after completed-task cache eviction. See the [confirmation report](confirmed-bugs.md) and [system overview](../../../../overview.md).

## Artifacts

- [Guidance](guidance.md), [analysis](analysis-report.md), and [modeling brief](modeling-brief.md).
- [Reference model](spec/base.tla), [MC wrapper](spec/MC.tla), [Trace wrapper](spec/Trace.tla), and [instrumentation mapping](spec/instrumentation-spec.md).
- [Harness results](harness/RESULTS.md), [trace replay receipts](spec/output/trace-round1/summary.json), and [model-checking coverage](spec/output/model-checking-coverage.md).
- [Validation review](spec/review-validation.md), [test sources](repro), and [confirmation records](confirmation).
- [Run metadata](run.json) and [file inventory](.record/files.tsv).

All 24 recorded traces replayed successfully. Standard BFS ended on its 30-minute budget; focused hunts identified one MC mechanism. Watch-list observation, clock/lock boundaries, and failed-client reset still need source/model alignment. MC-1 uses a controlled lazy tensor materialization failure; CR-2 establishes result retention without duplicate aggregation.

Scripts and receipts retain their original workspace paths. Source worktrees, environments, runtime transcripts, and TLC scratch state are excluded.
