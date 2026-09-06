# vsr-rs: First Run

This record preserves the 2026-09-05 run against
[`penberg/vsr-rs@3ac0104`](https://github.com/penberg/vsr-rs/tree/3ac0104a567092139534c9022205d02281a2da41).
It completed at 16:29:56 UTC with **no new reproduced bugs**.

## Results

The [confirmation report](confirmed-bugs.md) contains four dispositions:

| Reference | Result | Finding |
| --- | --- | --- |
| CR-1 | FALSE POSITIVE | Historical promises across state replacement and recovery held in the tested public-API schedules. |
| CR-2 | FALSE POSITIVE | Request identity, application replay, and reply reconstruction held under the documented client contract. |
| CR-3 | FALSE POSITIVE | The tested service and recovery schedules made progress. |
| CR-4 | DROPPED | Restart-time client-ID reuse duplicates upstream issue #9. |

The second run uses its own CR identifiers; its CR-1 through CR-3 are different
findings. See the [system overview](../../../../overview.md) for the combined count.

## Artifacts

- [Analysis](analysis-report.md) and [modeling brief](modeling-brief.md)
- [Model-checking report](spec/bug-report.md) and [specifications](spec/)
- [Harness](harness/) and [captured traces](traces/)
- [Per-finding investigations](confirmation/) and [original reproducers](repro/)
- [Pipeline summary](pipeline-summary.md) and [severity report](bug-severity.md)
- [Source history audit](audit/history.md)
- [Run identity](run.json), [record manifest](.record/manifest.json), and
  [file hashes](.record/files.tsv)

This is a curated evidence subset. Build products, source worktrees, process and
resume state, and TLC state databases remain outside the published record.
Selected `.specula-output` artifacts are stored at the run root with their
internal directory structure preserved. Original reports and scripts retain
historical machine paths and may refer to excluded runtime files. The original
run configuration is summarized in `run.json`, with its source hash retained.
