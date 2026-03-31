# Instrumentation Spec: MongoDB Range Deletion

## 1. Trace Event Schema

### Common Envelope

```json
{
    "tag": "range_deletion",
    "action": "<action_name>",
    "ts": "<ISO 8601 timestamp>",
    "serviceState": "<kDown|kReadyForInit|kInitializing|kUp>",
    "processorState": "<kInit|kRunning|kStopped>",
    ...action-specific fields...
}
```

### State Fields (captured at every event)

| Implementation field | TLA+ variable | Access pattern |
|---------------------|---------------|----------------|
| `RangeDeleterService::_state` | `serviceState` | `_acquireMutexUnconditionally()` then read `_state` |
| `ReadyRangeDeletionsProcessor::_state` | `processorState` | Protected by `_mutex` |

### Per-Task Fields (when task is involved)

| Implementation field | TLA+ variable | Access pattern |
|---------------------|---------------|----------------|
| `RangeDeletionTask::_id` (migration UUID) | `task` (ID) | `task.getId()` — maps to Task integer in spec |
| `RangeDeletion::_range` | `taskRange` | `task.getRange()` |
| `RangeDeletionTask::_pending` | `taskDocPending` | From persistent doc |
| `RangeDeletionTask::_processing` | `taskDocProcessing` | From persistent doc |
| In-memory state (tracker presence + chain stage) | `taskState` | Inferred from instrumentation point |

---

## 2. Action-to-Code Mapping

### Service Lifecycle

#### StepUp
- **Code location**: `range_deleter_service.cpp:135-154` (`onStepUpComplete`)
- **Trigger**: After line 154 (processor created, before recovery launch)
- **Event name**: `"StepUp"`
- **Fields**: `serviceState`, `processorState`
- **Notes**: Combines `onStepUpBegin` (line 127) and `onStepUpComplete` (line 135). Instrument after processor creation.

#### RecoveryBegin
- **Code location**: `range_deleter_service.cpp:197` (inside `_launchRangeDeletionRecoveryTask`)
- **Trigger**: After `_state = kInitializing` (line 197), before task re-registration loop
- **Event name**: `"RecoveryBegin"`
- **Fields**: `serviceState`
- **Notes**: Runs on executor thread. Capture after state transition.

#### RecoveryComplete
- **Code location**: `range_deleter_service.cpp:167-170` (recovery future completion callback)
- **Trigger**: After `_state = kUp` (line 167) and `beginProcessing()` (line 169)
- **Event name**: `"RecoveryComplete"`
- **Fields**: `serviceState`, `processorState`
- **Notes**: Inside `_acquireMutexUnconditionally()` section. Only fires if `_state != kDown`.

#### StepDown
- **Code location**: `range_deleter_service.cpp:315-322` (`onStepDown` / `onShutdown`)
- **Trigger**: After `_stopService()` completes
- **Event name**: `"StepDown"`
- **Fields**: `serviceState`, `processorState`
- **Notes**: `_stopService` clears in-memory task tracker and stops processor.

### Migration Lifecycle

#### StartMigration
- **Code location**: `migration_source_manager.cpp:337-369` (drain check + migration setup)
- **Additional**: Range deletion task persistence point (where task doc with `pending:true` is created)
- **Trigger**: After task doc is persisted and migration transitions to cloning
- **Event name**: `"StartMigration"`
- **Fields**: `migration` (migration ID), `range`, `task` (task ID from `RangeDeletionTask::_id`)
- **Notes**: The task doc is created during migration setup, not during commit. Map migration ID to spec Migration constant.

#### CommitMigration
- **Code location**: `migration_coordinator.cpp:297-321` (`_commitMigrationOnDonorAndRecipient`)
- **Trigger**: After `registerTask()` call (line 308-311), before `markAsReadyRangeDeletionTaskLocally` (line 320)
- **Event name**: `"CommitMigration"`
- **Fields**: `migration`, `task`, `migrationState` ("committed"), `taskState` ("pending")
- **Notes**: This is the point where ongoing queries future is captured (line 297-302). The task is registered as pending. The pending flag is removed in ClearPending (next event).

#### AbortMigration
- **Code location**: `migration_coordinator.cpp:347-350` (`_abortMigrationOnDonorAndRecipient`)
- **Trigger**: After `deleteRangeDeletionTaskLocally()` completes (line 347-350)
- **Event name**: `"AbortMigration"`
- **Fields**: `migration`, `migrationState` ("aborted")
- **Notes**: The local delete uses range-only filter (no migrationId). This is the Family 4 asymmetry.

### Task Registration Chain

#### ClearPending
- **Code location 1**: `range_deleter_service.cpp:476-478` (in `registerTask`, `clearPending()`)
- **Code location 2**: `range_deleter_service_op_observer.cpp:149-172` (onUpdate, pending removed)
- **Trigger**: After `task->clearPending()` is called (either from registerTask or OpObserver path)
- **Event name**: `"ClearPending"`
- **Fields**: `task`, `taskState` ("registered"), `taskDocPending` (false)
- **Notes**: Two code paths lead here. The OpObserver path (line 170-171) fires when the persistent doc update commits. The direct path fires in `registerTask` when `pending == kNotPending`.

#### CheckOverlap
- **Code location**: `range_deleter_service.cpp:390-426` (overlap check in async chain)
- **Trigger**: After overlap computation completes (line 393), before waiting on futures
- **Event name**: `"CheckOverlap"`
- **Fields**: `task`, `taskState` ("waitOverlap" or "waitQueries")
- **Notes**: Log whether blocking tasks were found. If no blocking tasks, taskState will be "waitQueries" (skips overlap wait).

#### OverlapResolved
- **Code location**: `range_deleter_service.cpp:428` (after `whenAll` completes)
- **Trigger**: When all overlapping task futures resolve
- **Event name**: `"OverlapResolved"`
- **Fields**: `task`, `taskState` ("waitQueries")
- **Notes**: This is implicit — the async chain continues after all overlap futures complete. May need to instrument the `.then()` callback at line 428.

#### QueriesDrained
- **Code location**: `range_deleter_service.cpp:432` (after `waitForOngoingQueries` resolves)
- **Trigger**: When the ongoing queries future completes
- **Event name**: `"QueriesDrained"`
- **Fields**: `task`, `taskState` ("ready")
- **Notes**: At this point the task is about to be enqueued to the processor. The delay step (lines 434-451) is not modeled.

### Deletion Execution

#### ProcessorPickTask
- **Code location**: `ready_range_deletions_processor.cpp:242-244` (dequeue from queue)
- **Additional**: `range_deletion_util.cpp:273-294` (markRangeDeletionTaskAsProcessing)
- **Trigger**: After task is dequeued and processing flag is set
- **Event name**: `"ProcessorPickTask"`
- **Fields**: `task`, `taskState` ("executing"), `taskDocProcessing` (true)
- **Notes**: Instrument after `markRangeDeletionTaskAsProcessing()` succeeds (line ~355 in processor).

#### CompleteTask
- **Code location**: `ready_range_deletions_processor.cpp:344-365` (completion sequence)
- **Additional**: `range_deleter_service.cpp:491-499` (`completeTask`)
- **Trigger**: After `completeTask()` and `removePersistentTask()` both complete
- **Event name**: `"CompleteTask"`
- **Fields**: `task`, `taskState` ("completed"), `taskDocExists` (false)
- **Notes**: Two-step: in-memory removal (line 344) then persistent removal (line 348). Crash between them leaves stale doc (Family 5, not modeled).

### Query Lifecycle

#### StartQuery
- **Code location**: Query execution entry point (e.g., `find` command handler or `AutoGetCollectionForReadCommand`)
- **Trigger**: After query begins reading from a sharded range
- **Event name**: `"StartQuery"`
- **Fields**: `query` (query ID), `range` (chunk range being read)
- **Notes**: Query IDs need to be assigned at instrumentation time. Map to spec Query constants.

#### EndQuery
- **Code location**: Query cursor cleanup (`PlanExecutor::dispose()` or cursor destruction)
- **Trigger**: After query releases its range preserver
- **Event name**: `"EndQuery"`
- **Fields**: `query`
- **Notes**: May not need explicit instrumentation — can be inferred from absence. See SilentEndQuery in Trace.tla.

### Metadata Lifecycle

#### ClearMetadata
- **Code location**: `collection_sharding_runtime.cpp` — `clearFilteringMetadata()`
- **Trigger**: After metadata is cleared
- **Event name**: `"ClearMetadata"`
- **Fields**: (none beyond envelope)
- **Notes**: SERVER-67385 was caused by this destroying MetadataManager and losing query tracking.

#### RefreshMetadata
- **Code location**: `collection_sharding_runtime.cpp` — `setFilteringMetadata()`
- **Trigger**: After new metadata is set
- **Event name**: `"RefreshMetadata"`
- **Fields**: (none beyond envelope)
- **Notes**: New MetadataManager has no knowledge of prior queries.

### Clock

#### TickClock
- **Not instrumented directly**. The clock is an abstraction of the system clock used for task registration timestamps. In traces, timestamp ordering is implicit from event ordering. Silent TickClock in Trace.tla handles this.

---

## 3. Special Considerations

### Task ID Mapping

Task IDs in the implementation are UUIDs (`RangeDeletionTask::_id`, which is the migration UUID). For trace validation, map these to spec Task integers (1, 2, 3, ...) in order of first encounter. The preprocessor should maintain a mapping table.

### Migration ID Mapping

Migration IDs are also UUIDs. Map to spec Migration constants ("M1", "M2", ...) in order of first encounter.

### Range Mapping

Chunk ranges are `{min, max}` BSON pairs. Map to spec Range constants ("R1", "R2", ...). The Overlap relation must be computed from the actual ranges and provided in the Trace.cfg.

### Registration Timestamp

The spec's `clock` and `taskRegTime` model the `Timestamp` field used for overlap ordering. In traces, the actual `registrationTime` from `RangeDeletion` objects can be captured and compared. For trace validation, the clock value is implicit — SilentTickClock ensures alignment.

### OpObserver Timing

The OpObserver fires registration callbacks inside `RecoveryUnit::onCommit()` (line 71 in `range_deleter_service_op_observer.cpp`). The ongoing queries future is captured INSIDE this callback (line 74-77), which is AFTER oplog commit. In contrast, the migration coordinator captures queries BEFORE oplog commit (line 297-302 in `migration_coordinator.cpp`). This timing difference is the Family 3 mechanism.

### Concurrent Threads

The range deletion system uses multiple threads:
1. **Main thread**: handles step-up/step-down, migration coordinator
2. **Executor thread**: runs async future chains (registration, overlap wait, query drain)
3. **Processor thread**: `ReadyRangeDeletionsProcessor::_runRangeDeletions()`
4. **Recovery thread**: `_launchRangeDeletionRecoveryTask`

Events from different threads may interleave. The instrumentation must use thread-safe logging (MongoDB's structured logging is already thread-safe). Event ordering in the trace file represents the actual happens-before relation.

### Bootstrap State

`TraceInit` uses the base spec's `Init` (all services down, no tasks, no migrations). If tracing starts after system initialization, the trace preprocessor must reconstruct the initial state from MongoDB's current state and adjust `TraceInit` accordingly.

### MongoDB Structured Logging

MongoDB already has structured logging with log IDs. Many range deletion events already have log entries (e.g., log ID 6834800, 11943500). The instrumentation can augment existing log entries with additional fields rather than adding entirely new log points. Set `MONGO_LOG_DEFAULT_COMPONENT=mongo::logv2::LogComponent::kSharding` for component filtering.
