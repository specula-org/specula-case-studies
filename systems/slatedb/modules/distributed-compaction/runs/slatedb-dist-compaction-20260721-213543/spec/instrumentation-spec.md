# Instrumentation Spec: SlateDB Distributed Compaction

## Section 1: Trace Envelope

The repository already contains a trace adapter in `slatedb/src/tla_trace.rs` plus scenario helpers in `slatedb/src/tla_trace_scenarios.rs`.

Each event should be emitted as:

```json
{
  "tag": "trace",
  "event": {
    "name": "<spec action>",
    "job": "<optional modeled job id>",
    "worker": "<optional modeled worker id>",
    "sst": "<optional modeled sst id>",
    "state": {
      "coord_up": true,
      "coord_time": 0,
      "worker_time": [{"worker": "w1", "time": 0}, {"worker": "w2", "time": 0}],
      "manifest_refs": ["s0", "s2"],
      "checkpoints": [{"job": "j1", "active": false, "refs": [], "expire": 0}],
      "manifest_version": 1,
      "manifest_epoch": 1,
      "compactions_exists": true,
      "dur_jobs": [],
      "compactions_version": 1,
      "compactions_epoch": 1,
      "coord_manifest_refs": ["s0", "s2"],
      "coord_checkpoints": [{"job": "j1", "active": false, "refs": [], "expire": 0}],
      "coord_jobs": [],
      "coord_seen_manifest_version": 1,
      "coord_seen_compactions_version": 1,
      "local_executing": [{"worker": "w1", "jobs": []}, {"worker": "w2", "jobs": []}],
      "buffered_ctx": [{"worker": "w1", "jobs": []}, {"worker": "w2", "jobs": []}],
      "present_ssts": ["s0", "s2"],
      "deleted_ssts": [],
      "output_ts": [{"sst": "o0", "ts": 0}],
      "publish_count": [{"job": "j1", "count": 0}],
      "retry_count": [{"job": "j1", "count": 0}]
    }
  }
}
```

`Trace.tla` validates the post-state snapshot after every visible event. Silent steps are reserved for:

- coordinator clock advancement
- worker clock advancement
- checkpoint expiry

## Section 2: State-Field Mapping

| Trace field | TLA+ variable |
|---|---|
| `coord_up` | `coordUp` |
| `coord_time` | `coordTime` |
| `worker_time[*].time` | `workerTime` |
| `manifest_refs` | `manifestRefs` |
| `checkpoints[*]` | `checkpointActive`, `checkpointRefs`, `checkpointExpire` |
| `manifest_version` | `manifestVersion` |
| `manifest_epoch` | `manifestEpoch` |
| `compactions_exists` | `compactionsExists` |
| `dur_jobs[*]` | `durJob` |
| `compactions_version` | `compactionsVersion` |
| `compactions_epoch` | `compactionsEpoch` |
| `coord_manifest_refs` | `coordManifestRefs` |
| `coord_checkpoints[*]` | `coordCheckpointActive`, `coordCheckpointRefs`, `coordCheckpointExpire` |
| `coord_jobs[*]` | `coordJob` |
| `coord_seen_manifest_version` | `coordSeenManifestVersion` |
| `coord_seen_compactions_version` | `coordSeenCompactionsVersion` |
| `local_executing[*].jobs` | `localExecuting` |
| `buffered_ctx[*].jobs` | `bufferedCtx` |
| `present_ssts` | `presentSsts` |
| `deleted_ssts` | `deletedSsts` |
| `output_ts[*].ts` | `outputTs` |
| `publish_count[*].count` | `publishCount` |
| `retry_count[*].count` | `retryCount` |

Encoding rules:

- Jobs, workers, and SSTs should be emitted as stable modeled aliases such as `j1`, `w1`, `o0`.
- Empty durable/local worker ownership should be emitted as the literal `"Nil"`.
- `dur_jobs` and `coord_jobs` must include the full record fields used by `Trace.tla`: `status`, `worker`, `last_hb`, `origin`, `retry`, `ctx`, `output`, `submitted_ts`.

## Section 3: Action-to-Code Mapping

| Spec action | Event name | Code location / trigger |
|---|---|---|
| `StartCoordinator` | `StartCoordinator` | Emitted from `slatedb/src/compactor.rs` after `CompactorEventHandler::new` completes the fenced `CompactorStateWriter::new` bootstrap. |
| `CrashCoordinator` | `CrashCoordinator` | Harness-only event emitted via `tla_trace::emit_crash_coordinator` in `slatedb/src/tla_trace_scenarios.rs`. |
| `CoordinatorRefreshCompactions` | `CoordinatorRefreshCompactions` | Emitted in `CompactorEventHandler::handle_ticker` immediately after `load_compactions()`. |
| `CoordinatorRefreshManifest` | `CoordinatorRefreshManifest` | Emitted in `CompactorEventHandler::handle_ticker` immediately after `load_manifest()`. |
| `MaybeScheduleCompactions` | `MaybeScheduleCompactions` | Emitted after the scheduler inserts and persists a new local `Submitted` compaction. |
| `ExternalSubmit` | `ExternalSubmit` | Harness-side wrapper around `Compactor::submit` in `slatedb/src/tla_trace_scenarios.rs`. |
| `MaybeValidateSubmittedFail` | `MaybeValidateSubmittedFail` | Emitted from `maybe_validate_submitted_compactions()` after durable `Submitted -> Failed`. |
| `MaybeValidateSubmittedSchedule` | `MaybeValidateSubmittedSchedule` | Emitted from `maybe_validate_submitted_compactions()` after durable `Submitted -> Scheduled`. |
| `MaybeValidateSubmittedDrain` | `MaybeValidateSubmittedDrain` | Reserved by `tla_trace.rs`; emit after drain `write_state_safely()` if drain scenarios are added. |
| `PollAndClaimStopDuplicate` | `PollAndClaimStopDuplicate` | Emitted from `CompactionWorkerHandler::poll_and_claim()` when a worker stops a duplicate local execution instead of re-claiming it. |
| `PollAndClaim` | `PollAndClaim` | Emitted after the worker CAS writes `Scheduled -> Running`. |
| `DispatchClaimedJob` | `DispatchClaimedJob` | Emitted after post-claim manifest validation succeeds and the executor is dispatched. |
| `ReleaseClaimPostClaimInvalid` | `ReleaseClaimPostClaimInvalid` | Emitted after post-claim manifest validation fails and the worker releases the claim. |
| `WriteOutputSst` | `WriteOutputSst` | Harness-side output-object event emitted before `write_compacted`; used to model the object-store-before-manifest window. |
| `HeartbeatLoseOwnership` | `HeartbeatLoseOwnership` | Emitted when a heartbeat observes missing or moved ownership and stops local execution. |
| `HeartbeatOwnedJobs` | `HeartbeatOwnedJobs` | Emitted after the heartbeat CAS succeeds and buffered context is published. |
| `HandleFinishedSuccess` | `HandleFinishedSuccess` | Emitted after `write_compacted()` succeeds. |
| `HandleFinishedLostOwnership` | `HandleFinishedLostOwnership` | Emitted when `write_compacted()` discovers the worker no longer owns the job. |
| `HandleFinishedExecError` | `HandleFinishedExecError` | Emitted after execution failure releases the claim back to `Scheduled`. |
| `ReclaimStaleWorkers` | `ReclaimStaleWorkers` | Emitted after the coordinator persists stale `Running -> Scheduled` reclamation. |
| `CommitCompactedEntriesFail` | `CommitCompactedEntriesFail` | Emitted when recovery/commit marks a durable `Compacted` entry `Failed`. |
| `CommitCompactedEntriesWriteManifest` | `CommitCompactedEntriesWriteManifest` | Emitted after checkpoint + manifest durability succeeds and before `.compactions` terminalization. |
| `CommitCompactedEntriesWriteCompactions` | `CommitCompactedEntriesWriteCompactions` | Emitted after the second half of the manifest-first write makes `.compactions` catch up. |
| `RefreshCheckpoint` | `RefreshCheckpoint` | Harness-side event emitted after `StoredManifest::refresh_checkpoint`. |
| `GcSweep` | `GcSweep` | Harness-side event emitted after deleting a modeled compacted SST. |

## Section 4: Coverage Notes

- The current source tree already emits every worker/coordinator event used by `Trace.tla` except `MaybeValidateSubmittedDrain`; that action remains modeled so drain instrumentation can be added without changing the trace validator.
- Family 2 depends on the split between `CommitCompactedEntriesWriteManifest` and `CommitCompactedEntriesWriteCompactions`; both events are mandatory.
- Family 4 depends on version and epoch snapshots being included in every event. Omitting `manifest_version`, `compactions_version`, `manifest_epoch`, or `compactions_epoch` would remove the fencing check from trace validation.
