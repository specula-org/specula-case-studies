# NVFlare job lifecycle and resource accounting

Run `nvflare-job-lifecycle-20260914` covers job admission, startup, termination, and resource ownership across sites at revision `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

## Results

| Finding | Status |
| --- | --- |
| MC-2 | REPRODUCED |
| MC-3 | REPRODUCED |
| MC-4 | REPRODUCED |
| CR-1 | REPRODUCED |
| CR-4 | FALSE POSITIVE |
| CR-5 | REPRODUCED |

The run records five bugs affecting allocation ownership, acknowledged cancellation, terminal job status, inherited GPU bindings, and continued scheduling after storage failure. See the [confirmation report](confirmed-bugs.md) and [system overview](../../../../overview.md).

## Artifacts

- [Guidance](guidance.md), [analysis](analysis-report.md), and [modeling brief](modeling-brief.md).
- [Reference model](spec/base.tla), [MC wrapper](spec/MC.tla), [Trace wrapper](spec/Trace.tla), and [instrumentation mapping](spec/instrumentation-spec.md).
- [Harness results](harness/RESULTS.md), [final trace replays](spec/output/traces-r5/summary.json), and [model-checking receipts](spec/output/run-coverage.json).
- [Validation review](spec/review-validation.md), [coverage limits](spec/validation/priority-coverage.md), [test sources](repro), and [confirmation records](confirmation).
- [Run metadata](run.json) and [file inventory](.record/files.tsv).

All four recorded traces replayed successfully: 1,353 semantic events and 94 of 125 action types. Standard BFS reached its 30-minute budget without a reported violation; targeted hunts produced three safety counterexamples. One failed simulation is preserved as tooling-error evidence; its retry used the documented [eager-evaluation workaround](spec/validation/eager-execution.md) with four passing control replays. These are bounded checks within the documented harness scope.

MC-2 and CR-5 use controlled cleanup-thread or status-storage failures. MC-3, MC-4, and CR-1 use controlled timing. GPU findings establish allocation or inherited-binding mismatches without measuring physical GPU contention or workload damage.

Scripts and receipts retain their original workspace paths. Source worktrees, environments, runtime transcripts, generated replay binaries, and TLC scratch state are excluded. This archive does not constitute an additional reproduction run.
