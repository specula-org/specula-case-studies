# vsr-rs: Second Run

This record preserves the 2026-09-05 run against
[`penberg/vsr-rs@3ac0104`](https://github.com/penberg/vsr-rs/tree/3ac0104a567092139534c9022205d02281a2da41).
It completed at 20:16:37 UTC with **3 new reproduced bugs**.

## Results

| Reference | Result | Finding |
| --- | --- | --- |
| CR-1 | REPRODUCED | An existing invalid view file selects fresh initialization for a reused replica identity. |
| CR-2 | REPRODUCED | The accepted singleton configuration never commits its self-quorum request. |
| CR-3 | REPRODUCED | A non-reading peer blocks the shared kvstore sender and delays healthy destinations. |
| CR-4 | ENV_LIMITED | View-file rename has no parent-directory fsync; stale restart after filesystem failure was not reproduced. |
| CR-5 | MASKED | A repeated recovery nonce admits stale responses; current Commit/GetState/NewState traffic repairs the observed stale state. |
| CR-6 | FALSE POSITIVE | Simulator observer omissions are assurance gaps without a reproduced current failure. |

Only CR-1 through CR-3 contribute to the [system overview](../../../../overview.md)
and its three-bug count. CR-1 combines a real startup test with a separate
public-API consequence test. CR-3 demonstrates a finite delay under a stopped
backup; an indefinite outage was not measured. The original severity report's
summary says two severity-bearing findings, while its per-entry table has five;
that inconsistent summary is retained as original evidence and is not used for
the public count or tracker notes.

## Artifacts

- [Confirmation report](confirmed-bugs.md) and [per-finding investigations](confirmation/)
- [Portable reproduction instructions](../../../../repro/README.md)
- [Original reproducers](repro/) and [severity report](bug-severity.md)
- [Analysis](analysis-report.md) and [modeling brief](modeling-brief.md)
- [Model-checking and trace report](spec/bug-report.md), [validation review](spec/review-validation.md),
  [machine-readable results](spec/output/validation-results.json), and [raw checking logs](spec/output/)
- [Harness](harness/), [captured traces](traces/), and [source manifest](evidence/source-manifest.json)
- [Pipeline summary](pipeline-summary.md), [run identity](run.json),
  [record manifest](.record/manifest.json), and [file hashes](.record/files.tsv)

Four implementation traces with 186 events replayed successfully. Baseline
hunting completed at 74,772,829 distinct states within its finite constraints;
the broader `MC.cfg` search timed out with unexpanded states. No general safety
or liveness proof is claimed. The three reproduced bugs followed independent
code-review handoffs, outside the conforming-library model's assumptions.

This is a curated evidence subset. Build products, source worktrees, process and
resume state, and TLC state databases are excluded. Selected `.specula-output`
artifacts retain their directory structure at the run root. Original evidence
retains historical paths and upstream statuses; use the system overview for
the later upstream check and the portable reproduction directory for reruns.
