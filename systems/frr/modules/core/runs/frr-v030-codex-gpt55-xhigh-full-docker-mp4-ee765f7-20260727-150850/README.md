# FRRouting Zebra route-realization run

## Reviewed result

The independent second review records:

- **1 new bug, Critical (MC-2):** a late asynchronous FPM route notification can be matched to a newer selected route and falsely acknowledge that route as installed.
- **1 known-fixed bug, Critical (MC-3):** a BGP-to-Zebra send failure can leave `suppress-fib-pending` without outstanding work; upstream later added selected-route replay after reconnect.
- **1 masked candidate not recorded (MC-1):** the stale-result path is real, but the archived run did not establish a durable wrong-route consequence.

Read [independent-review.md](review/independent-review.md) for the source evidence, archived reproductions, and final disposition.

## Important correction

The archived pipeline's [confirmed-bugs.md](confirmed-bugs.md) and [bug-severity.md](bug-severity.md) are preserved as original run evidence, but the independent review supersedes their novelty summary. The pipeline reported two reproduced bugs and classified both as new. The second review keeps MC-2 as new, reclassifies MC-3 as known-fixed by upstream Issue #22362 and PR #22411, and does not record masked MC-1 as a bug.

## Provenance

- Source archive: `frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850.tar.gz`
- Archive SHA-256: `940be04e491c10a1ef6accdca37bf9dd8c7a7bff3c0eac461e57d56b673eeb0f`
- Archive size: 792,382,563 bytes
- Archive inventory: 54,598 entries
- Archived run ID: `frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850`
- Run created: `2026-07-27T07:09:58+00:00`
- Agent: `codex`, requested model `gpt-5.5` from `run.json`
- Target source: [`FRRouting/frr@ee765f7fa0d6533ec2479da3e442d17d4b93d474`](https://github.com/FRRouting/frr/tree/ee765f7fa0d6533ec2479da3e442d17d4b93d474)

## Included evidence

This record retains 72 byte-exact archive files: top-level run metadata and reports; the core TLA+ models, hunt configurations, review reports, and three primary counterexample JSON files; all three confirmation records; three reproduction wrappers; the archived MC-1 and MC-2 minimal tests and configurations; final XML/JSON test results; and a compact instrumentation harness.

The archive does not contain the generated MC-3 topotest source or its FRR configuration as standalone members. Its wrapper and final JUnit XML are retained, and no reconstructed file is presented as byte-exact evidence.

The raw archive is not committed because it exceeds GitHub's 100 MiB per-file limit. Full source/build/persist trees, TLC state directories, logs, prompts, agent traces, and session metadata are excluded. The archive hash and [.record metadata](.record/manifest.json) preserve the source reference and curation boundary.
