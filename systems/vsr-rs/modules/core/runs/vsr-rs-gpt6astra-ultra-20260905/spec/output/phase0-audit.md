# Phase 0 harness and provenance audit

**PASS: no harness or trace regeneration is required.** Audit time: 2026-09-05T14:07:40.454920+00:00.

The live source is pinned revision `3ac0104a567092139534c9022205d02281a2da41` with exactly the instrumented source status recorded by `harness/validation/provenance.json`. All **46 inherited manifest hashes** match (13 harness, 7 source, 3 replay-spec, 4 real trace, 19 validation artifacts). The four canonical/applied Rust copies match; the owned instrumentation patch equals the complete `Cargo.toml`/`lib.rs` diff and passes reverse-apply preflight. Both checker JAR hashes and all eight previously validated positive/negative trace hashes match.

A fresh, non-writing schema and L2 audit passes for **4 real traces, 478 lines, 474 transitions, 50 application calls, and 18/18 event types**. Every wrapper requires full snapshot equality and its application-observation check. Captures run from 2026-09-05 13:54:27.739786 to 13:54:28.764194 UTC; timestamps are monotone per trace. The inherited provenance was recorded at 2026-09-05T13:57:12.459629+00:00.

The controller invokes real public Replica/Client methods and captures completed handlers before persistence/publication. View storage uses actual files and `sync_all`; reconstruction uses fresh raw nonces. Feature-gated hooks retain creation-time PrepareOk prefixes and ordered real application calls/results. Replayed packets originate from actual released packets. See `harness/src/controller.rs:171,200,207,285,354` and `harness/src/tla_trace.rs:218,236,254`.

## Source line distinction

| Function | Pinned `3ac0104a` lib.rs | Instrumented working lib.rs |
|---|---:|---:|
| `commit_op` | 1362 | 1384 |
| `send_prepare_ok` | 1381 | 1415 |
| `recover` | 511 | 533 |

## Limits

- Fresh schema and snapshot-wrapper audit is read-only and does not rerun Cargo or TLC; the parent validation task independently replays all supplied traces.
- Matching hashes bind recorded evidence to current files; this is provenance and observed-schedule agreement, not exhaustive protocol correctness or general service-liveness evidence.
- All 18 event types are covered, but finer dispatch alternatives old-request, old-view, catch-up-same-view, different-view, and NewState ignore-status are not covered by supplied schedules.
- The harness implements a controlled persistence/transport/client caller. These traces do not establish the shipped examples/kvstore/main.rs persistence, identity, timer, or transport obligations.
- The three-node Register workload uses Put/Get returning the prior value and explicit deterministic schedules; there is no randomized simulator seed or simulator bug reproduction.
- Source lib.rs line references from instrumentation describe the patched working copy; pinned revision locations differ as recorded in source_line_map.
- The inherited provenance manifest binds three replay semantic files (base.tla, Trace.tla, Trace.cfg), not the model-checking wrapper/configs. This audit separately hashes all supplied spec inputs and hunting configs without attributing past validation to them.

Only this report and `phase0-audit.json` are created by this audit. Full live hashes, paths, coverage, capture references, and checks are in the JSON companion.
