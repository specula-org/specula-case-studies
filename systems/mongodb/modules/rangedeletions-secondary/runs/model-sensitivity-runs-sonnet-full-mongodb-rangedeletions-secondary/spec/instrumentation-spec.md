# Instrumentation Spec: mongodb-rangedeletions-secondary

Maps each TLA+ base spec action to the source code location and fields to capture
for trace-based validation.

---

## Section 1: Trace Event Schema

### Event Envelope

Every event is a JSON object emitted as one NDJSON line:

```json
{
  "event": "<event-name>",
  "node": "<replica-set-member-id>",
  "task": "<collectionUUID:rangeMin:rangeMax>",     // optional; only for task-scoped events
  "primary": "<node-id>",                           // only for ReplicateDiskState
  "secondary": "<node-id>",                         // only for ReplicateDiskState
  "state": { <state-snapshot-fields> }
}
```

`node` is the replica set member ID (e.g., `rs0:27017`). `task` is a stable string
key derived from `(collectionUUID, range.getMin(), range.getMax())`.

### State Snapshot Fields (captured at every event)

| Field | Implementation source | TLA+ variable |
|---|---|---|
| `state.role` | `repl::ReplicationCoordinator::getMemberState()` | `nodeRole[n]` |
| `state.termInitReady` | `_termInitializationPromise.has_value() && _termInitializationPromise->getFuture().isReady()` | `termInitReady[n]` |
| `state.recoveryPhase` | see per-action notes | `recoveryPhase[n]` |
| `state.diskTaskState` | DB read of `config.rangeDeletions` for task | `diskTaskState[n][t]` |
| `state.deletionStep` | local variable / control-flow position in `_runRangeDeletions` | `deletionStep[n][t]` |
| `state.completionFulfilled` | `task->getCompletionFuture().isReady()` | `completionFulfilled[n][t]` |

### recoveryPhase encoding

| Implementation state | `recoveryPhase` string |
|---|---|
| Before `_launchRangeDeletionRecoveryTask` | `"idle"` |
| Inside phase 1 loop (`processing=true` scan) | `"phase1"` |
| Inside phase 2 loop (`pending!=true, processing!=true` scan) | `"phase2"` |
| After `notifyRecoveryJobComplete(term)` | `"done"` |

### deletionStep encoding

| Control-flow position | `deletionStep` string |
|---|---|
| Not actively deleting | `"idle"` |
| `deleteRangeInBatches` running | `"deleting"` |
| `waitUntilMajorityForWrite` running | `"waiting"` |
| After `completeTask`, before `removePersistentTask` | `"completing"` |

### diskTaskState encoding

Derived from a live DB read of `config.rangeDeletions` for the specific task:

| Document state | `diskTaskState` string |
|---|---|
| `pending: true` present | `"pending"` |
| `pending` absent, `processing` absent | `"ready"` |
| `processing: true` | `"processing"` |
| Document not found | `"deleted"` |

---

## Section 2: Action-to-Code Mapping

---

### 1. `OpObserverClearPending`

| Field | Value |
|---|---|
| **Spec action** | `OpObserverClearPending(n, t)` |
| **Code location** | `range_deleter_service_op_observer.cpp:116-177` — `onInserts` / `onUpdate` |
| **Trigger point** | After the document write commits (op_observer fires post-commit) |
| **Trace event name** | `"OpObserverClearPending"` |
| **Fields** | `node`, `task`, `state.role`, `state.diskTaskState`, `state.termInitReady`, `state.recoveryPhase` |
| **Notes** | Only emit when `kPendingFieldName` is being cleared (`$unset pending` or initial insert without `pending: true`). On secondary, `registerTask` call will throw `NotYetInitialized` which is swallowed (op_observer_cpp:92-101) — still emit the event because the disk state changes. |

---

### 2. `StepUp`

| Field | Value |
|---|---|
| **Spec action** | `StepUp(n)` |
| **Code location** | `range_deleter_service.cpp:135` — entry of `onStepUpComplete` |
| **Trigger point** | After `_joinAndResetState()` returns, before `_state = kReadyForInitialization` |
| **Trace event name** | `"StepUp"` |
| **Fields** | `node`, `state.role`, `state.termInitReady`, `state.recoveryPhase` |
| **Notes** | Emit AFTER the state transitions to `kReadyForInitialization` and `_termInitializationPromise` is fulfilled (`range_deleter_service.cpp:177`). The trace event captures the post-step-up state. Capture `term` as an additional field for correlation. |

---

### 3. `RecoveryPhase1Scan`

| Field | Value |
|---|---|
| **Spec action** | `RecoveryPhase1Scan(n)` |
| **Code location** | `range_deleter_service.cpp:231` — after phase-1 cursor is exhausted |
| **Trigger point** | After the while loop at line 225 exits (all `processing=true` tasks registered) |
| **Trace event name** | `"RecoveryPhase1Scan"` |
| **Fields** | `node`, `state.role`, `state.recoveryPhase` |
| **Notes** | recoveryPhase string should be `"phase2"` in the post-state (transitioning from phase1 to phase2). |

---

### 4. `RecoveryPhase2Scan`

| Field | Value |
|---|---|
| **Spec action** | `RecoveryPhase2Scan(n)` |
| **Code location** | `range_deleter_service.cpp:253` — after phase-2 cursor is exhausted |
| **Trigger point** | After the inner while loop at line 248 exits (all non-pending tasks registered) |
| **Trace event name** | `"RecoveryPhase2Scan"` |
| **Fields** | `node`, `state.role`, `state.recoveryPhase` |
| **Notes** | recoveryPhase string should be `"done"` in the post-state. Followed by `notifyRecoveryJobComplete(term)` at line 259 which triggers the `kUp` transition. |

---

### 5. `OpObserverRegisterTask`

| Field | Value |
|---|---|
| **Spec action** | `OpObserverRegisterTask(n, t)` |
| **Code location** | `range_deleter_service.cpp:366-368` — `registerTask` guard check passes |
| **Trigger point** | Immediately after `_getTermInitializationFuture(lock).isReady()` check passes during op_observer path |
| **Trace event name** | `"OpObserverRegisterTask"` |
| **Fields** | `node`, `task`, `state.role`, `state.termInitReady`, `state.recoveryPhase` |
| **Notes** | Distinct from `OpObserverClearPending` — this fires when the op_observer successfully registers the task in memory (vs just committing the disk write). Only emit when `registrationResult == kRegisteredNewTask` or `kJoinedExistingTask` (both succeed). |

---

### 6. `DeleteOrphans`

| Field | Value |
|---|---|
| **Spec action** | `DeleteOrphans(n, t)` |
| **Code location** | `ready_range_deletions_processor.cpp:258` — LOGV2_INFO 6872501 ("Beginning deletion") |
| **Trigger point** | Before `deleteRangeInBatches` call (line 278) |
| **Trace event name** | `"DeleteOrphans"` |
| **Fields** | `node`, `task`, `state.diskTaskState`, `state.deletionStep` |
| **Notes** | Emit at the start of the orphan deletion batch. `diskTaskState` should be `"processing"` in post-state because `DeleteOrphans` sets it. If `processing` flag is set to disk before this emit point, capture the updated value. |

---

### 7. `MajorityWaitSuccess`

| Field | Value |
|---|---|
| **Spec action** | `MajorityWaitSuccess(n, t)` |
| **Code location** | `ready_range_deletions_processor.cpp:340` — after `.get(opCtx)` on the majority future returns without throwing |
| **Trigger point** | After the `waitUntilMajorityForWrite(...).get(opCtx)` call at line 338-339 succeeds |
| **Trace event name** | `"MajorityWaitSuccess"` |
| **Fields** | `node`, `task`, `state.deletionStep` |
| **Notes** | `deletionStep` should be `"waiting"` in post-state (transitions from `"deleting"` to `"waiting"`). The majority-committed state is the critical safety point for F1. |

---

### 8. `MajorityWaitInterrupted`

| Field | Value |
|---|---|
| **Spec action** | `MajorityWaitInterrupted(n, t)` |
| **Code location** | `ready_range_deletions_processor.cpp:388-397` — outer catch block, `_stopRequested()` check |
| **Trigger point** | After catching `DBException` and determining `_stopRequested() == true` (line 392) |
| **Trace event name** | `"MajorityWaitInterrupted"` |
| **Fields** | `node`, `task`, `state.deletionStep`, `state.diskTaskState` |
| **Notes** | `deletionStep` should be `"idle"` in post-state (task abandoned). `diskTaskState` must still be `"processing"` (disk document survives). This is the critical F1 path. |

---

### 9. `CompleteInMemory`

| Field | Value |
|---|---|
| **Spec action** | `CompleteInMemory(n, t)` |
| **Code location** | `ready_range_deletions_processor.cpp:345` — call to `self->completeTask(collectionUuid, range)` |
| **Trigger point** | After `completeTask` returns (which calls `task->markComplete()` at range_deleter_service.cpp:496) |
| **Trace event name** | `"CompleteInMemory"` |
| **Fields** | `node`, `task`, `state.deletionStep`, `state.completionFulfilled` |
| **Notes** | Emit after `markComplete()` fires at `range_deletion.cpp:75-76`. `completionFulfilled` should be `true` in post-state. `deletionStep` should be `"completing"`. This is the F3 crash window entry. |

---

### 10. `RemovePersistentTask`

| Field | Value |
|---|---|
| **Spec action** | `RemovePersistentTask(n, t)` |
| **Code location** | `ready_range_deletions_processor.cpp:347` — call to `rangedeletionutil::removePersistentTask(opCtx, task->getTaskId())` |
| **Trigger point** | After `removePersistentTask` returns (disk document deleted) |
| **Trace event name** | `"RemovePersistentTask"` |
| **Fields** | `node`, `task`, `state.diskTaskState`, `state.deletionStep` |
| **Notes** | `diskTaskState` should be `"deleted"` in post-state. `deletionStep` should be `"idle"`. This closes the F3 crash window. Emit only when the `if (task)` check at line 346 passes. |

---

### 11. `StepDown`

| Field | Value |
|---|---|
| **Spec action** | `StepDown(n)` |
| **Code location** | `range_deleter_service.cpp:316` — entry of `onStepDown` |
| **Trigger point** | After `_stopService()` completes (line 316) |
| **Trace event name** | `"StepDown"` |
| **Fields** | `node`, `state.role`, `state.termInitReady`, `state.recoveryPhase` |
| **Notes** | Emit after `_stopService` finishes. `role` should be `"Secondary"`, `termInitReady` should be `false`, `recoveryPhase` should be `"idle"`. |

---

### 12. `ReplicateDiskState`

| Field | Value |
|---|---|
| **Spec action** | `ReplicateDiskState(primary, secondary, t)` |
| **Code location** | Replication applier on secondary — when oplog entry for `config.rangeDeletions` is applied |
| **Trigger point** | After the secondary applies the oplog write (OpObserver on secondary fires) |
| **Trace event name** | `"ReplicateDiskState"` |
| **Fields** | `primary` (source node), `secondary` (applying node), `task`, `state.diskTaskState` |
| **Notes** | This event is emitted on the **secondary** node. The `primary` field identifies the originating node. Capture `diskTaskState` on the secondary after applying. Required for validating the F1 ordering invariant at the secondary. |

---

## Section 3: Special Considerations

### 3.1 Task ID stability

The `task` field must be a stable string key across the lifetime of a task:
```
task = collectionUUID.toString() + ":" + range.getMin().toString() + ":" + range.getMax().toString()
```
Use BSON to string conversion for the range bounds to ensure reproducible keys.

### 3.2 Recovery-phase tracking requires shadow state

The base spec's `recoveryPhase` variable is internal to `_launchRangeDeletionRecoveryTask`. The harness must track phase transitions locally (e.g., with a thread-local or `static` variable in the recovery task lambda) to emit the correct `recoveryPhase` string at each event.

### 3.3 termInitReady from multiple code paths

`termInitReady` transitions to `true` at `range_deleter_service.cpp:177` (`ensureSet(lock, *_termInitializationPromise)`) and back to `false` in `_stopService` (promise reset at line 287). Both transitions must be captured correctly in the state snapshot at every event.

### 3.4 F3 window is a single-threaded window

Between `CompleteInMemory` and `RemovePersistentTask` events, no other thread can observe the task in-memory (it has been removed from `_rangeDeletionTasks`). The harness does not need special locking for this window — the two events always appear consecutively in the trace for a single task, unless a step-down occurs between them (in which case `StepDown` appears instead of `RemovePersistentTask`).

### 3.5 Op-observer on secondary silently swallowed

`range_deleter_service_op_observer.cpp:92-101` catches `NotYetInitialized` and `NotPrimaryError`. On secondary nodes, `OpObserverClearPending` events are still emitted (the disk state changes), but `OpObserverRegisterTask` is never emitted (registration fails silently). The Trace spec handles this correctly because `OpObserverRegisterTask` only appears in traces for primary nodes.

### 3.6 Majority-wait interruption vs normal step-down path

`MajorityWaitInterrupted` is emitted when `_stopRequested()` returns true after catching the majority-wait exception (`ready_range_deletions_processor.cpp:392`). A normal non-interrupt exception causes the loop to continue (`continue` at line 397) — do NOT emit `MajorityWaitInterrupted` in that case.

### 3.7 Trace file format

Trace files are stored in `../traces/` relative to the spec directory. Set `IOEnv.JSON` to override the default path `../traces/trace.ndjson`. Run one trace file per test scenario (step-down-mid-majority, recovery-during-phase-transition, etc.) for efficient trace validation.
