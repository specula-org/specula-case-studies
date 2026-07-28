# SlateDB distributed-compaction run

## Reviewed result

The independent second review records:

- **1 strong new bug, High (MC-2 / CR-5):** external submissions can overrun the coordinator-wide concurrency bound and trigger an unsigned-underflow panic.
- **1 masked/weak new bug, Minor (CR-1):** a cross-segment external submission can bypass active destination reservation, but the current commit path rejects the loser before duplicate publication.
- **1 known-fixed bug, Medium (CR-4):** stale remote `Compacted` or terminal state could be rejected during `.compactions` conflict recovery; upstream PR #1840 fixed the exact merge path.

Read [independent-review.md](review/independent-review.md) for source evidence, archived reproductions, deduplication, and the final disposition of all candidates.

## Important correction

The archived [confirmed-bugs.md](spec/confirmed-bugs.md) and [bug-severity.md](spec/bug-severity.md) are preserved as original run evidence, but the independent review controls the ledger classification. MC-2 and CR-5 are one mechanism, not two bugs. CR-1 is recorded as a real but masked admission defect with `Minor` demonstrated impact; the archive's `Critical` rating describes hypothetical corruption only if the current commit-time protection were absent. CR-4 was dropped from the archive's new-bug count because it matched an upstream fix, and is recorded here as known-fixed.

## Provenance

- Source archive: `slatedb-dist-compaction-20260721-213543.zip`
- Archive SHA-256: `ea77d713265229f7121e49cbc7510ad5705dc0ca34e934ff842983d4e8defb21`
- Archive size: 37,720,160 bytes
- Archive inventory: 625 entries, 333,552,625 expanded bytes
- Archived run ID: `slatedb-dist-compaction-20260721-213543`
- Run created: `2026-07-21T21:35:43+08:00`
- Agent: `codex`, requested model `gpt-5.4` from `run.json`
- Target source: [`slatedb/slatedb@cc69461d902560bb5f4407a506f32cd154ede79d`](https://github.com/slatedb/slatedb/tree/cc69461d902560bb5f4407a506f32cd154ede79d)

## Included evidence

This record retains 73 byte-exact archive files totaling 655,257 bytes: run metadata and reports; all seven confirmation records; six reproduction wrappers; the compact instrumentation harness; the core TLA+ models and hunt configurations; repair and validation records; four selected TLC outputs; and five validation traces.

The confirmation worktrees and generated Rust test sources are not standalone archive members. Their wrappers and complete verdict output are retained, but the wrappers reference archive-local paths and are not directly runnable from this curated record.

The raw archive is not committed. TLC state directories, generated `MC_TTrace_*` files, bulk outputs, logs, prompts, agent/session data, build products, and temporary worktrees are excluded. The archive hash and [.record metadata](.record/manifest.json) preserve the source reference and curation boundary.
