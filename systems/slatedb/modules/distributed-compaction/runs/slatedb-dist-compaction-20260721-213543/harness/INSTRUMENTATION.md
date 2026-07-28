# SlateDB Distributed Compaction Harness

## Key Instrumentation Points

- `slatedb/src/lib.rs:168-171`
  Adds `tla_trace` and `tla_trace_scenarios` under `#[cfg(test)]`.
- `slatedb/src/compactor_state_protocols.rs:332-345`
  `CompactorStateWriter::trace_durable_view()` snapshots the current fenced manifest and `.compactions` state for trace emission.
- `slatedb/src/compactor.rs:554-567`
  Emits `CoordinatorRefreshCompactions` for `CommitCompacted`'s initial durable refresh.
- `slatedb/src/compactor.rs:616-629`
  Emits `StartCoordinator` after fenced bootstrap completes.
- `slatedb/src/compactor.rs:745-771`
  Emits `CoordinatorRefreshCompactions` and `CoordinatorRefreshManifest` during the normal poll ticker.
- `slatedb/src/compactor.rs:836-849`
  Emits `ReclaimStaleWorkers` after stale-running reclamation persists.
- `slatedb/src/compactor.rs:984-1015`
  Emits the manifest-first split for `CommitCompactedEntriesWriteManifest`, `CommitCompactedEntriesWriteCompactions`, and `CommitCompactedEntriesFail`.
- `slatedb/src/compactor.rs:1271-1288`
  Emits `MaybeScheduleCompactions` once local scheduler inserts persist.
- `slatedb/src/compactor.rs:1357-1380`
  Emits `MaybeValidateSubmittedFail` and `MaybeValidateSubmittedSchedule` after submitted validation persists.
- `slatedb/src/compaction_worker.rs:351-364`
  Emits `PollAndClaimStopDuplicate`.
- `slatedb/src/compaction_worker.rs:406-418`
  Emits `PollAndClaim`.
- `slatedb/src/compaction_worker.rs:432-444`
  Emits `DispatchClaimedJob`.
- `slatedb/src/compaction_worker.rs:454-466`
  Emits `ReleaseClaimPostClaimInvalid`.
- `slatedb/src/compaction_worker.rs:594-631`
  Emits `HeartbeatLoseOwnership`.
- `slatedb/src/compaction_worker.rs:661-676`
  Emits `HeartbeatOwnedJobs`.
- `slatedb/src/compaction_worker.rs:703-739`
  Emits `HandleFinishedLostOwnership`.
- `slatedb/src/compaction_worker.rs:750-764`
  Emits `HandleFinishedSuccess`.
- `slatedb/src/compaction_worker.rs:838-850`
  Emits `HandleFinishedExecError`.
- `slatedb/src/tla_trace.rs:257-273`
  Scenario setup. `SPECULA_TRACE_DIR` controls output; fallback is `./traces`.
- `slatedb/src/tla_trace.rs:948-1027`
  Builds and writes the NDJSON envelope. Add/remove state fields here after updating the runtime caches.
- `slatedb/src/tla_trace_scenarios.rs:320-574`
  Harness scenarios. The current set covers five passing traces.

## Adjusting Fields

- To add a new state field, update the corresponding cache in `slatedb/src/tla_trace.rs`:
  `JobRecord`, `CheckpointBinding`, `TraceRuntime`, `build_durable_cache`, `build_coord_cache`, and `build_trace_line`.
- If the field is event-derived rather than read from durable state, update `apply_symbolic_transition`, `apply_coord_event_updates`, or `apply_worker_event_updates`.

## Adding or Moving Events

- For coordinator events, copy an existing `crate::tla_trace::emit_coord_event(...)` call in `slatedb/src/compactor.rs`.
- For worker events, copy an existing `crate::tla_trace::emit_worker_event(...)` call in `slatedb/src/compaction_worker.rs`.
- If an event needs harness-only modeling, add a helper in `slatedb/src/tla_trace.rs` and drive it from `slatedb/src/tla_trace_scenarios.rs`.
- If a capture point needs to move from pre- to post-persist (or vice versa), move only the emit call; keep the surrounding protocol code unchanged.

## Rebuild and Re-run

- From `.specula-output/`, run `bash harness/run.sh`.
- The harness forces `cargo test ... --test-threads=1` because `tla_trace.rs` uses a single global writer; parallel Rust test execution causes empty or interleaved scenario files.
- TLC validation must run from `spec/` because `Trace.tla` resolves `../traces/trace.ndjson` relative to the process working directory.

## Current Coverage Notes

- Passing scenarios cover:
  `StartCoordinator`, `CrashCoordinator`, `CoordinatorRefreshCompactions`, `CoordinatorRefreshManifest`, `MaybeScheduleCompactions`, `ExternalSubmit`, `MaybeValidateSubmittedFail`, `MaybeValidateSubmittedSchedule`, `PollAndClaimStopDuplicate`, `PollAndClaim`, `DispatchClaimedJob`, `WriteOutputSst`, `HeartbeatLoseOwnership`, `HeartbeatOwnedJobs`, `HandleFinishedSuccess`, `HandleFinishedLostOwnership`, `HandleFinishedExecError`, `ReclaimStaleWorkers`, `CommitCompactedEntriesWriteManifest`, `CommitCompactedEntriesWriteCompactions`, `RefreshCheckpoint`, and `GcSweep`.
- `MaybeValidateSubmittedDrain` is not currently emitted by the source tree. The spec keeps the action reserved, but the harness does not yet drive a drain scenario.
- `ReleaseClaimPostClaimInvalid` is instrumented but not covered by the current small model. Reaching it requires a modeled manifest/source mismatch between the worker's claim CAS and its post-claim manifest read.
- `CommitCompactedEntriesFail` is instrumented but not covered by the current passing scenarios. Reaching it needs a recovery-style state where the manifest publish is durable while `.compactions` still carries `Compacted`.
