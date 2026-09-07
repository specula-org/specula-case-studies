# vsr-rs: Third Run

This record preserves the 2026-09-06 targeted run against
[`penberg/vsr-rs@3ac0104`](https://github.com/penberg/vsr-rs/tree/3ac0104a567092139534c9022205d02281a2da41).
It completed at 10:57:29 UTC with **1 new reproduced bug**.

## Results

| Reference | Result | Finding |
| --- | --- | --- |
| CR-1 | REPRODUCED | EOF after an exact prefix of a primary-generated kvstore `PREPARE` frame can commit a shortened `PUT` value. |
| CR-2 | FALSE POSITIVE | The tested excluding-primary view change and rolling recovery preserved committed order. |
| CR-3 | MASKED | Reordered recovery responses can install stale internal state, but current higher-view commit and state-transfer traffic repaired it before a client-visible inconsistency. |
| CR-4 | FALSE POSITIVE | Partial output publication before crash behaved as allowed transport loss; recovery and client resend preserved order and regenerated the reply. |
| CR-5 | FALSE POSITIVE | With fair idle calls and healthy-majority delivery, timers and retries moved past an unavailable primary and completed pending requests. |

The reproduced CR-1 finding contributes to the [system overview](../../../../overview.md)
as case-study CR-4, because CR-1 through CR-3 in the overview refer to the
second-run reproduced findings.

## Artifacts

- [Confirmation report](confirmed-bugs.md) and [per-finding investigations](confirmation/)
- [Original reproducers](repro/) and [portable reproduction instructions](../../../../repro/README.md)
- [Severity report](bug-severity.md)
- [Analysis](analysis-report.md) and [modeling brief](modeling-brief.md)
- [Model-checking and trace report](spec/bug-report.md), [validation results](spec/validation-results.md),
  [validation status](spec/validation-status.json), and [raw checking outputs](spec/output/)
- [Harness guide](harness/INSTRUMENTATION.md), [pipeline summary](pipeline-summary.md),
  [run identity](run.json), [record manifest](.record/manifest.json), and
  [file hashes](.record/files.tsv)

Trace validation passed 7 of 7 implementation traces. The broader `MC.cfg`
search reached the configured 30-minute deadline with an unexplored queue, so
model checking was **incomplete** and hunting did not start. This run contributes
one reproduced code-review/integration finding, not a TLC counterexample.

This is a curated evidence subset. Build products, source worktrees, process and
resume state, large frame captures, and TLC state databases are excluded.
Selected output artifacts retain their directory structure at the run root.
