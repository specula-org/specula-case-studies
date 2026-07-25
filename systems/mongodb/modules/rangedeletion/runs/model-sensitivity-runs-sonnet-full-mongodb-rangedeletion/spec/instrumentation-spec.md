# Instrumentation Spec: MongoDB Range Deletion Protocol

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object on a single line (NDJSON format):

```json
{
  "event":              "<event name>",
  "migrationId":        "<string: migration UUID>",
  "coordDocState":      "<absent|present|committed|aborted>",
  "donorTaskState":     "<absent|pending|ready|processing>",
  "recipientTaskState": "<absent|pending|ready|processing>",
  "recipientAlive":     <true|false>
}
```

### State Field Mapping

| Trace Field | Implementation Source | TLA+ Variable | Notes |
|---|---|---|---|
| `migrationId` | `_migrationInfo.getId().toString()` | `MigrationId` (key) | Migration UUID as string |
| `coordDocState` | Read from `config.migrationCoordinators` after the operation | `coordDoc[m]` | "absent" if doc not found |
| `donorTaskState` | Read `pending` and `processing` fields from `config.rangeDeletions` | `donorTask[m]` | See state derivation rules below |
| `recipientTaskState` | Same fields, queried on recipient shard | `recipientTask[m]` | May require remote read |
| `recipientAlive` | Whether `markAsReadyRangeDeletionTaskOnRecipient` can reach shard | `recipientShardAlive` | Capture as `true` on success path |

#### State Derivation for `donorTaskState` / `recipientTaskState`

Read the `pending` and `processing` fields from `RangeDeletionTask` document:
- Document absent → `"absent"`
- `pending == true` → `"pending"`
- `processing == true` → `"processing"`
- Otherwise (pending absent/false, processing absent/false) → `"ready"`

---

## Section 2: Action-to-Code Mapping

### 1. WriteCoordDoc

| Field | Value |
|---|---|
| **Spec action** | `WriteCoordDoc(m)` |
| **Code location** | `migration_coordinator.cpp:150` — `migrationutil::insertMigrationCoordinatorDoc(opCtx, _migrationInfo)` |
| **Trigger point** | After `insertMigrationCoordinatorDoc` returns successfully |
| **Trace event name** | `"WriteCoordDoc"` |
| **Fields to capture** | `migrationId`, `coordDocState` (must be `"present"`), `donorTaskState` (must be `"absent"`), `recipientTaskState`, `recipientAlive` |
| **Notes** | This is step 1 of the non-atomic two-write init (Family 1). Must emit before step 2 to capture the crash window. |

---

### 2. WriteRangeDeletionTask

| Field | Value |
|---|---|
| **Spec action** | `WriteRangeDeletionTask(m)` |
| **Code location** | `migration_coordinator.cpp:158-169` — `rangedeletionutil::createAndPersistRangeDeletionTask(...)` |
| **Trigger point** | After `createAndPersistRangeDeletionTask` returns; after `_donorRangeDeletionTask.emplace(...)` |
| **Trace event name** | `"WriteRangeDeletionTask"` |
| **Fields to capture** | `migrationId`, `donorTaskState` (must be `"pending"`), `recipientTaskState` (must be `"pending"`), `coordDocState`, `recipientAlive` |
| **Notes** | Step 2 of non-atomic init (Family 1). Both donor task and recipient task become `pending` at this point. The `pending:true` flag is set explicitly — last arg `true` at `migration_coordinator.cpp:166`. |

---

### 3. PersistCommitDecision

| Field | Value |
|---|---|
| **Spec action** | `PersistCommitDecision(m)` |
| **Code location** | `migration_coordinator.cpp:240` — `migrationutil::persistCommitDecision(opCtx, _migrationInfo)` |
| **Trigger point** | After `persistCommitDecision` returns |
| **Trace event name** | `"PersistCommitDecision"` |
| **Fields to capture** | `migrationId`, `coordDocState` (must be `"committed"`), `donorTaskState`, `recipientTaskState`, `recipientAlive` |

---

### 4. DeleteRecipientTaskOnCommit

| Field | Value |
|---|---|
| **Spec action** | `DeleteRecipientTaskOnCommit(m)` |
| **Code location** | `migration_coordinator.cpp:278-282` — `rangedeletionutil::deleteRangeDeletionTaskOnRecipient(...)` |
| **Trigger point** | After `deleteRangeDeletionTaskOnRecipient` returns |
| **Trace event name** | `"DeleteRecipientTaskOnCommit"` |
| **Fields to capture** | `migrationId`, `recipientTaskState` (must be `"absent"`), `coordDocState`, `donorTaskState`, `recipientAlive` |
| **Notes** | This is the commit path for the recipient. The recipient task is deleted (not activated) on commit because the committed migration means the range now belongs to the recipient — no deletion needed there. |

---

### 5. ActivateDonorTaskOnCommit

| Field | Value |
|---|---|
| **Spec action** | `ActivateDonorTaskOnCommit(m)` |
| **Code location** | `migration_coordinator.cpp:320-321` — `rangedeletionutil::markAsReadyRangeDeletionTaskLocally(opCtx, ...)` |
| **Trigger point** | After `markAsReadyRangeDeletionTaskLocally` returns (the `$unset` of `pending` field) |
| **Trace event name** | `"ActivateDonorTaskOnCommit"` |
| **Fields to capture** | `migrationId`, `donorTaskState` (must be `"ready"`), `coordDocState`, `recipientTaskState`, `recipientAlive` |
| **Notes** | Family 1 success path. The op-observer fires when `pending` is unset, which triggers `registerTask` in RangeDeleterService. Capture state AFTER the `$unset`. The `registerTask` call at line 309 also fires, but the observable state change is the `$unset` at line 320. |

---

### 6. PersistAbortDecision

| Field | Value |
|---|---|
| **Spec action** | `PersistAbortDecision(m)` |
| **Code location** | `migration_coordinator.cpp:334` — `migrationutil::persistAbortDecision(opCtx, _migrationInfo)` |
| **Trigger point** | After `persistAbortDecision` returns |
| **Trace event name** | `"PersistAbortDecision"` |
| **Fields to capture** | `migrationId`, `coordDocState` (must be `"aborted"`), `donorTaskState`, `recipientTaskState`, `recipientAlive` |

---

### 7. DeleteDonorTaskOnAbort

| Field | Value |
|---|---|
| **Spec action** | `DeleteDonorTaskOnAbort(m)` |
| **Code location** | `migration_coordinator.cpp:347-350` — `rangedeletionutil::deleteRangeDeletionTaskLocally(opCtx, ...)` |
| **Trigger point** | After `deleteRangeDeletionTaskLocally` returns |
| **Trace event name** | `"DeleteDonorTaskOnAbort"` |
| **Fields to capture** | `migrationId`, `donorTaskState` (must be `"absent"`), `coordDocState`, `recipientTaskState`, `recipientAlive` |
| **Notes** | Abort path: donor's pending task is deleted since the range now stays on the donor (migration aborted). |

---

### 8. MarkRecipientTaskReady

| Field | Value |
|---|---|
| **Spec action** | `MarkRecipientTaskReady(m)` |
| **Code location** | `migration_coordinator.cpp:382-386` — `rangedeletionutil::markAsReadyRangeDeletionTaskOnRecipient(opCtx, ...)` |
| **Trigger point** | After `markAsReadyRangeDeletionTaskOnRecipient` returns successfully |
| **Trace event name** | `"MarkRecipientTaskReady"` |
| **Fields to capture** | `migrationId`, `recipientTaskState` (must be `"ready"`), `coordDocState`, `donorTaskState`, `recipientAlive` (must be `true`) |
| **Notes** | **Family 2 critical instrumentation point.** This call is OUTSIDE the try/catch block at lines 352–375. If `ShardNotFound` is thrown here, no event is emitted (the exception propagates). The silent action `TraceSilentMarkRecipientTaskReadyFails` in Trace.tla handles this case. |

---

### 9. ForgetMigration

| Field | Value |
|---|---|
| **Spec action** | `ForgetMigration(m)` |
| **Code location** | `migration_coordinator.cpp:396-401` — `store.remove(opCtx, ...)` with `WriteConcernOptions{1,...}` |
| **Trigger point** | After `store.remove` returns (w:1 acknowledged by primary only) |
| **Trace event name** | `"ForgetMigration"` |
| **Fields to capture** | `migrationId`, `coordDocState` (must be `"absent"` from primary's view), `donorTaskState`, `recipientTaskState`, `recipientAlive` |
| **Notes** | **Family 2 w:1 note**: The write concern is `{1, ...}` (line 400), not majority. The coordinator doc is deleted on the primary but may not replicate before stepdown. After `store.remove`, `coordDocDurable` is set to `FALSE` in the spec. The `RollbackForgetMigration` spec action (no trace event) models the rollback on stepdown. |

---

### 10. ExecuteRangeDeletion

| Field | Value |
|---|---|
| **Spec action** | `ExecuteRangeDeletion(m)` |
| **Code location** | `ready_range_deletions_processor.cpp` — when `_completeTask` begins processing a task (or when `deleteRangeInBatches` is entered) |
| **Trigger point** | Before `deleteRangeInBatches` is called; after `markRangeDeletionTaskAsProcessing` sets `processing:true` |
| **Trace event name** | `"ExecuteRangeDeletion"` |
| **Fields to capture** | `migrationId`, `donorTaskState` (must be `"processing"`), `coordDocState`, `recipientTaskState`, `recipientAlive` |
| **Notes** | The `markRangeDeletionTaskAsProcessing` call in `range_deletion_util.cpp:274-296` sets `processing:true` on disk. Instrument AFTER this call. |

---

### 11. CompleteRangeDeletion

| Field | Value |
|---|---|
| **Spec action** | `CompleteRangeDeletion(m)` |
| **Code location** | `ready_range_deletions_processor.cpp` — after `removePersistentTask` removes the on-disk document |
| **Trigger point** | After the task document is deleted from `config.rangeDeletions` |
| **Trace event name** | `"CompleteRangeDeletion"` |
| **Fields to capture** | `migrationId`, `donorTaskState` (must be `"absent"`), `coordDocState`, `recipientTaskState`, `recipientAlive` |
| **Notes** | **CR3 note**: In the current code, `_completeTask` fulfills the in-memory completion future BEFORE `removePersistentTask`. Instrument AFTER the persistent removal to match the spec's state. |

---

### 12. Recovery

| Field | Value |
|---|---|
| **Spec action** | `Recovery` |
| **Code location** | `range_deleter_service.cpp:256-259` — after `notifyRecoveryJobComplete(term)` |
| **Trigger point** | After the recovery scan's two passes complete and all tasks are re-registered |
| **Trace event name** | `"Recovery"` |
| **Fields to capture** | `migrationId` (use a representative migration ID, or `"*"` for all), `donorTaskState`, `recipientTaskState`, `coordDocState`, `recipientAlive` |
| **Notes** | Emit one `Recovery` event per step-up. The spec's `Recovery` action re-registers all `ready`/`processing` tasks atomically. Only tasks with `pending != true` and `processing != true` or `processing == true` are re-registered (matching the two-pass filter). |

---

## Section 3: Special Considerations

### 3.1 Crash Window (Family 1)

The crash between `WriteCoordDoc` and `WriteRangeDeletionTask` is triggered by injecting a process crash after the `WriteCoordDoc` event. To exercise this:
1. Set a failpoint after `insertMigrationCoordinatorDoc` (line 150) to simulate crash.
2. Restart the process. Recovery will run `resumeMigrationCoordinationsOnStepUp`.
3. Observe: if `donorTask` is absent on recovery, `CommitSilentSkip` fires in the spec.

No extra trace event is needed for the crash itself — the recovery `Recovery` event captures the post-crash persistent state.

### 3.2 ShardNotFound at Line 382 (Family 2)

`markAsReadyRangeDeletionTaskOnRecipient` at `migration_coordinator.cpp:382` is OUTSIDE the try/catch block (lines 352–375). If it throws `ShardNotFound`:
- No `MarkRecipientTaskReady` event is emitted.
- The trace spec's silent action `TraceSilentMarkRecipientTaskReadyFails` handles this.
- To trigger in tests: remove the recipient shard from config before the abort path reaches line 382.

### 3.3 Remote Recipient Task State

`recipientTaskState` requires querying the recipient shard's `config.rangeDeletions`. For local-only instrumentation, this field can be omitted and the Trace spec's `ValidateRecipientTask` check removed for affected events. Document clearly if weakening validation this way.

### 3.4 coordDocDurable Tracking

The spec's `coordDocDurable` field is not directly observable via a document read — it reflects the replication state of `forgetMigration`'s w:1 write. For trace validation purposes, `coordDocDurable` is not captured in trace events. The `ValidateFullState` helper omits it.

### 3.5 Term Tracking

The spec's `term` variable increments on `Crash`. Trace events do not need to capture `term` directly — the `Recovery` event implicitly signals a new term.

### 3.6 overlapSnapshot (Family 3)

`getOverlappingRangeDeletionsFuture` (range_deleter_service.h:153) returns a snapshot without a trace-visible side effect. The snapshot content is an internal in-memory state. To trace Family 3 scenarios:
- Emit a `GetOverlapSnapshot` event (not in the standard set) immediately after the snapshot is taken.
- The `inMemoryTasks` set at that moment is captured as `overlapSnapshot`.
- A subsequent `RegisterTaskPostSnapshot` event confirms a new task was added after the snapshot.

These Family 3 events are optional extensions — the core protocol events above are sufficient for validating Families 1, 2, and 4.
