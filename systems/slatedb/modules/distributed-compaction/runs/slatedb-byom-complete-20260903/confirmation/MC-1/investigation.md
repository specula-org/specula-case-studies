# MC-1 Investigation

## Finding

External compaction submissions can bypass the cross-compaction conflict checks that the local scheduler path applies before admitting work. A duplicate externally submitted tiered compaction can be promoted to `Scheduled` alongside an already equivalent active job.

## Code Path

- Public entry point: `slatedb/src/admin.rs:192` exposes `Admin::submit_compaction`, and `slatedb-cli/src/main.rs:208`-`227` exposes the same path through `submit-compaction`.
- External persistence path: `slatedb/src/compactor.rs:478` creates a new `Compaction` and inserts it directly into `.compactions` at `slatedb/src/compactor.rs:493`-`495`.
- Remote merge path: `slatedb/src/compactor_state.rs:882` accepts newly observed remote entries. `Submitted` entries that are absent from local state are inserted at `slatedb/src/compactor_state.rs:903`-`910`.
- Local scheduler path: `slatedb/src/compactor_state.rs:988` applies cross-job checks before inserting. It rejects destination collisions across active compactions at `slatedb/src/compactor_state.rs:1005`-`1013`.
- Submitted validation path: `slatedb/src/compactor.rs:910` says the validator is the canonical manifest-validity gate, but also says cross-compaction conflicts are enforced upstream in `CompactorState::add_compaction` and are not rechecked there (`slatedb/src/compactor.rs:914`-`916`).
- Promotion path: `slatedb/src/compactor.rs:1178` gathers all `Submitted` entries and validates each independently. A valid tiered spec is changed to `Scheduled` at `slatedb/src/compactor.rs:1211`-`1214`.
- Worker consumer: `slatedb/src/compaction_worker.rs:327`-`353` claims claimable `Scheduled` entries up to capacity without destination/source deduplication. It dispatches each claimed job at `slatedb/src/compaction_worker.rs:393`-`403`.
- Executor failure: `slatedb/src/compactor_executor.rs:893` asserts that no existing task has the same destination sorted run. When a worker dispatches both duplicate scheduled jobs, this assertion panics.
- Public error surface: `slatedb/src/error.rs:617`-`619` maps `BackgroundTaskPanic` to `ErrorKind::Closed(CloseReason::Panic)`.

## Developer Intent

- RFC-0002 states that compaction execution should ensure there is no other ongoing compaction that includes the SSTs or SRs referenced by the compaction (`rfcs/0002-compaction.md:314`-`316`).
- RFC-0013 describes local scheduling as calling `CompactorState::add_compaction` and says this enforces destination conflict/overwrite rules (`rfcs/0013-compaction-state-persistence.md:283`-`287`).
- RFC-0013 also describes external requests as using `Admin::submit_compaction` and notes that no scheduler validation happens at submit time (`rfcs/0013-compaction-state-persistence.md:291`-`297`).
- RFC-0025 frames distributed compaction throughput as scaling over independent, non-conflicting work (`rfcs/0025-distributed-compaction.md:67`-`70`).

## Prior Report Search

Checked upstream issue/PR search and local git history for this mechanism before marking novelty.

- GitHub issue #1838, "Compaction worker can panic when concurrent jobs share the same destination sorted run", is an open upstream report for the same destination-conflict path: https://github.com/slatedb/slatedb/issues/1838
- GitHub PR #2018, "fix: reject conflicting compaction jobs without panicking workers", is open and unmerged, and its body describes external CLI submissions bypassing `CompactorState::add_compaction`: https://github.com/slatedb/slatedb/pull/2018
- Local git history searches for compaction conflict, destination, duplicate, submit, and scheduled paths did not show a merged fix in the checked out revision (`cc69461d902560bb5f4407a506f32cd154ede79d`).

Novelty result: KNOWN, fix-status unfixed.

## Reproduction Plan

Use only public APIs:

1. Build a small database and create a committed sorted run.
2. Use the public size-tiered scheduler to generate a manual `Full` compaction spec for that sorted run.
3. Submit the same spec twice through `Admin::submit_compaction`.
4. Run the public compactor loop until both submitted entries are promoted to `Scheduled`.
5. Run the public compaction worker with capacity 2.

Expected observable failure: the worker claims both duplicate scheduled jobs, dispatches both to the executor, and receives `ErrorKind::Closed(CloseReason::Panic)` after the destination uniqueness assertion trips.

## Result

Reproduced with `<run-output>/repro/test_bugMC-1_external_compaction_conflict.sh`.

The successful run used public APIs only. No source patch, mock peer, or direct state injection was used.
