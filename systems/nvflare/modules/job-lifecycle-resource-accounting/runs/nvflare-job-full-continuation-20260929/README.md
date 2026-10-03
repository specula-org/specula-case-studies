# NVFlare job lifecycle: full run and continuation

This record follows the full experiment started on 2026-09-25 and its continuation from 2026-09-26, at NVFlare `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. It covers the default local-process job lifecycle and resource accounting. The companion [Lite run](../nvflare-job-lite-20260925/README.md) used the same source revision.

## Results

The original [confirmation report](confirmed-bugs.md) contains 39 dispositions: 38 REPRODUCED and one FALSE POSITIVE. These are report entries, not 38 independent new bugs. The [reconciliation ledger](review/findings.md) preserves every ID, four explicit overlap groups, three direct matches to earlier findings, and remaining evidence limits. No combined new-bug total is asserted.

Confirmation and classification each exited successfully. The retained pipeline [summary](summary.md) still says Incomplete: final pipeline reporting did not complete. The [severity report](bug-severity.md) is the original classification; its ratings are not independent severity adjudications.

## Evidence

- [Analysis](analysis-report.md), [modeling brief](modeling-brief.md), and [takeover review](takeover-review.md).
- [Reference model](spec/base.tla), [MC wrapper](spec/MC.tla), [trace wrapper](spec/Trace.tla), [continuation audit](spec/continuation-audit.md), and [changelog](spec/changelog.md).
- [Harness](harness), 32 final [implementation traces](traces), and [saved checking outputs](spec/output).
- [Reproduction sources](repro), per-finding [confirmation evidence](confirmation), and [execution provenance](provenance).
- [Run metadata](run.json) and the complete inventory of this curated payload in [.record/files.tsv](.record/files.tsv).

The final C8 model-checking run was budget-limited and retained unexplored work. Its successful trace replays and bounded checks do not prove unbounded safety. Reproductions range from public interfaces to controlled component schedules and injected failures; the ledger records the important differences. Later confirmation sessions consulted upstream discussions, so the complete experiment is not a blind-discovery evaluation.

## Reproduction

Three component cases have a portable [runner](repro/run_component.py): CR-4, CR-7, and CR-24. Use Python 3.12 or later in an environment containing the pinned NVFlare revision's dependencies:

```sh
python repro/run_component.py --source-repo /path/to/NVFlare CR-4
```

The runner exports the pinned revision into a temporary directory and relocates only the selected test's original source-path literal in memory. It does not modify product logic or the archived test. A zero exit status means the test's recorded phenomenon and controls were observed; CR-24 still uses a deterministic thread scheduling shim, not an uncontrolled deployment.

Other scripts and original reports retain historical workspace paths. Source checkouts, environments, credentials, runtime conversation transcripts, and TLC scratch state are excluded. See [archive notes](review/archive-notes.md) for exclusions and lineage.
