# Instrumentation Specification: MongoDB Range Deletion on Secondaries

Maps TLA+ spec actions to source code locations and trace event definitions.

---

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object with the following structure:

```json
{
  "eventName": "string",
  "node": "string",
  "timestamp": "number",
  "currentTerm": "number",
  "replicaRole": "string",
  "processorState": "string",
  "persistentTaskState": "object",
  "inMemoryTaskExists": "array",
  "recoveryInFlight": "boolean",
  "recoveryOutcome": "string",
  ...action-specific fields
}
```

### State Fields (Captured at Every Event)

These fields are captured at each trace event and validated by the spec:

| TLA+ Variable | Implementation Source | Capture Point | Type |
|---|---|---|---|
| `currentTerm` | `replicaSet.getReplSetConfig().getVersion()` or `mongo::OpTime::getTerm()` | Before action | number |
| `replicaRole` | Replica set role enum (PRIMARY/SECONDARY) | Before action | string |
| `processorState` | `ReadyRangeDeletionsProcessor::_state` field | Before action | string |
| `persistentTaskState` | Config document state from `config.rangeDeletions` | Before action | object (map: taskId → state) |
| `inMemoryTaskExists` | `RangeDeletionTaskTracker::_tracker` keys | Before action | array |
| `recoveryInFlight` | `RangeDeletionRecoveryTracker::_recoveryFuture` non-empty | Before action | boolean |
| `recoveryOutcome` | `RangeDeletionRecoveryTracker::_outcome` | After recovery completes | string |
| `invalidatedRanges` | Set of ranges passed to range preserver invalidation | Before action | array |

---

## Section 2: Action-to-Code Mapping

### Family 1: Persistent State Transitions

#### Action: InsertTaskDocument

**Spec Location**: `base.tla:425-435`

**Code Locations**:
- `range_deleter_service.cpp:340-365` — Task insertion via `_tracker.add()`
- `range_deletion_util.cpp:243-271` — Document persistence logic

**Trigger Point**: After `_tracker.add()` and before returning to caller

**Trace Event Name**: `InsertTaskDocument`

**Fields to Capture**:
- `taskId` (integer) — ID of inserted task
- `persistentTaskState[taskId]` (string) — New state: `"pending"`
- `taskPendingFlag[taskId]` (boolean) — Set to `true`

**Notes**:
- Insertion is atomic in the in-memory tracker; persistence is the observable event
- If persistence fails (e.g., write concern), do not emit event

---

#### Action: MarkTaskReadyInDocument

**Spec Location**: `base.tla:439-450`

**Code Locations**:
- `range_deleter_service_op_observer.cpp:68-102` — onCommit handler
- `range_deletion_util.cpp:273-294` — `markRangeDeletionTaskAsReady()`

**Trigger Point**: After OpObserver confirms transaction commit, before registering in-memory

**Trace Event Name**: `MarkTaskReady`

**Fields to Capture**:
- `taskId` (integer) — Task ID
- `persistentTaskState[taskId]` (string) — New state: `"ready"`
- `taskPendingFlag[taskId]` (boolean) — Changed to `false`

**Notes**:
- This represents the pending flag flip in the persistent document
- OpObserver runs asynchronously after commit; timestamp the event at commit time

---

#### Action: MarkTaskProcessingInDocument

**Spec Location**: `base.tla:454-465`

**Code Locations**:
- `range_deletion_util.cpp:273-294` — `markRangeDeletionTaskAsProcessing()`
- `ready_range_deletions_processor.cpp:120-150` — Called before deletion loop

**Trigger Point**: Before entering deletion loop, after document state check

**Trace Event Name**: `MarkTaskProcessing`

**Fields to Capture**:
- `taskId` (integer) — Task ID
- `persistentTaskState[taskId]` (string) — New state: `"processing"`
- `taskProcessingFlag[taskId]` (boolean) — Set to `true`

**Notes**:
- This is the earliest point where the processing flag is written
- Critical for Family 5 (shutdown race): if processor stops here, task remains in processing state

---

#### Action: RemoveTaskDocument

**Spec Location**: `base.tla:469-479`

**Code Locations**:
- `range_deletion_util.cpp:299-330` — `removeRangeDeletionTaskDocument()`
- `ready_range_deletions_processor.cpp:155-185` — After deletion completes

**Trigger Point**: After deletion loop exits normally, before document deletion

**Trace Event Name**: `RemoveTaskDocument`

**Fields to Capture**:
- `taskId` (integer) — Task ID
- `persistentTaskState[taskId]` (string) — New state: `"deleted"`

**Notes**:
- Represents the removal from `config.rangeDeletions`
- Confirm removal before emitting event

---

### Family 3: In-Memory Task Registration & Overlap Detection

#### Action: RegisterTaskInMemory

**Spec Location**: `base.tla:510-523`

**Code Locations**:
- `range_deleter_service.cpp:377-391` — `_tracker.registerTask()`
- `range_deletion_task_tracker.h:67-92` — Map insertion

**Trigger Point**: After task added to `_rangeDeletionTasks` map, before overlap check

**Trace Event Name**: `RegisterTaskInMemory`

**Fields to Capture**:
- `taskId` (integer) — Task ID registered
- `inMemoryTaskExists` (array) — Updated set of in-memory tasks
- `taskRegistrationOrder[taskId]` (number) — Logical registration time

**Notes**:
- Registration order is determined by insertion sequence into the map
- Capture registrationClock before each registration to establish order

---

#### Action: DetectAndWaitForOverlaps

**Spec Location**: `base.tla:527-543`

**Code Locations**:
- `range_deleter_service.cpp:392-426` — Overlap detection and waiter setup
- `range_deleter_service.cpp:418-422` — Comment acknowledging no concurrent overlapping

**Trigger Point**: When task enters async overlap detection chain

**Trace Event Name**: `DetectAndWaitForOverlaps`

**Fields to Capture**:
- `taskId` (integer) — Task ID entering wait
- `pendingOverlapWaiters` (array) — Updated set of waiting tasks
- `overlappingTasks` (array) — IDs of tasks this task waits for

**Notes**:
- This captures the decision to wait (or not wait if no overlaps)
- Emit even if overlappingTasks is empty; the spec will handle the transition

---

#### Action: CompleteOverlapWait (Silent in Trace)

**Spec Location**: `base.tla:547-554`

**Code Location**: Internal event (no direct code hook)

**Trace Event Name**: `CompleteOverlapWait` (optional, silent action in trace)

**Notes**:
- No explicit hook needed; TLC will fire silent action when waiting task's prerequisite completes
- Optional: if code explicitly signals wait completion, emit event

---

### Family 2: Recovery & Term Management

#### Action: BecomePublicPrimary

**Spec Location**: `base.tla:369-383`

**Code Locations**:
- `range_deleter_service.cpp:127-154` — `onStepUpBegin()` and `onStepUpComplete()`
- `range_deleter_service.cpp:156-175` — Recovery spawned on executor

**Trigger Point**: When role transitions to primary and recovery is spawned

**Trace Event Name**: `BecomePublicPrimary`

**Fields to Capture**:
- `currentTerm` (number) — New term
- `replicaRole` (string) — Changed to `"primary"`
- `recoveryInFlight` (boolean) — Set to `true`
- `recoveryOutcome` (string) — Reset to `"unknown"`

**Notes**:
- This event marks the transition from secondary to primary with recovery spawned asynchronously
- Capture the exact moment recovery task is enqueued on executor

---

#### Action: CompleteRecoverySuccessfully

**Spec Location**: `base.tla:557-577`

**Code Locations**:
- `range_deleter_service.cpp:213-254` — Recovery task executes
- `range_deletion_recovery_tracker.cpp:102-125` — Loads and re-registers tasks

**Trigger Point**: After recovery task finishes scanning and re-registering all tasks

**Trace Event Name**: `CompleteRecoverySuccessfully`

**Fields to Capture**:
- `recoveryInFlight` (boolean) — Set to `false`
- `recoveryOutcome` (string) — Changed to `"complete"`
- `tasksRecoveredInTerm` (array) — Set of re-registered task IDs
- `inMemoryTaskExists` (array) — Updated with recovered tasks

**Notes**:
- Recovery task is asynchronous; emit event at completion, not at spawn
- Verify that `_recoveryFuture.isReady()` is true before emitting

---

#### Action: InterruptRecoveryByStepDown

**Spec Location**: `base.tla:581-592`

**Code Locations**:
- `range_deleter_service.cpp:306-309` — Processor/recovery shutdown on step-down
- `range_deleter_service.cpp:156-175` — Async recovery can be cancelled

**Trigger Point**: When role changes to secondary and recovery is cancelled

**Trace Event Name**: `InterruptRecoveryByStepDown`

**Fields to Capture**:
- `recoveryInFlight` (boolean) — Set to `false`
- `recoveryOutcome` (string) — Changed to `"incomplete"`
- `tasksRecoveredInTerm` (array) — Partially recovered tasks (snapshot of state)

**Notes**:
- Recovery may have partially executed; capture how many tasks were re-registered
- This is a fault-injection candidate: step-down during recovery

---

### Family 5: Deletion Execution & Processor Lifecycle

#### Action: StartProcessor

**Spec Location**: `base.tla:664-672`

**Code Locations**:
- `ready_range_deletions_processor.cpp:78-86` — `_thread = _ioContext.start()`
- `ready_range_deletions_processor.cpp:210-228` — Thread main loop

**Trigger Point**: After `StartProcessor` decision (only after recovery completes)

**Trace Event Name**: `StartProcessor`

**Fields to Capture**:
- `processorState` (string) — Changed to `"running"`
- `recoveryInFlight` (boolean) — Must be `false`
- `recoveryOutcome` (string) — Must be `"complete"`

**Notes**:
- Processor only starts after recovery completes; spec enforces this with precondition
- Emit event after thread is truly started and ready to dequeue

---

#### Action: DequeuTaskForDeletion

**Spec Location**: `base.tla:676-690`

**Code Locations**:
- `ready_range_deletions_processor.cpp:135-155` — Dequeue from ready queue
- `range_deleter_service.cpp:440-465` — Task selected for deletion

**Trigger Point**: When task is dequeued from ready queue, before starting deletion

**Trace Event Name**: `DequeuTaskForDeletion`

**Fields to Capture**:
- `taskId` (integer) — Task being dequeued
- `deletionProgress[taskId]` (string) — Set to `"mark_processing"`

**Notes**:
- One task at a time is in the processor; multiple tasks must be serialized

---

#### Action: BeginDeletion

**Spec Location**: `base.tla:694-703`

**Code Locations**:
- `ready_range_deletions_processor.cpp:160-180` — Main deletion loop begins
- `range_deletion_util.cpp:273-294` — Mark processing before delete

**Trigger Point**: After marking task as processing, before actual document delete

**Trace Event Name**: `BeginDeletion`

**Fields to Capture**:
- `taskId` (integer) — Task being deleted
- `deletionProgress[taskId]` (string) — Set to `"deleting"`
- `persistentTaskState[taskId]` (string) — Should still be `"processing"`

**Notes**:
- This is where the actual document deletion query runs
- Family 5 vulnerability: processor can be interrupted here

---

#### Action: CompleteDeletion

**Spec Location**: `base.tla:707-716`

**Code Locations**:
- `ready_range_deletions_processor.cpp:180-200` — After deletion returns

**Trigger Point**: After deletion query completes successfully

**Trace Event Name**: `CompleteDeletion`

**Fields to Capture**:
- `taskId` (integer) — Task deleted
- `deletionProgress[taskId]` (string) — Set to `"mark_complete"`

**Notes**:
- Documents are now deleted from the collection
- Still need to mark persistent document as removed and clean in-memory tracker

---

#### Action: RemoveTaskFromMemory

**Spec Location**: `base.tla:720-729`

**Code Locations**:
- `range_deleter_service.cpp:455-475` — Remove from in-memory tracker

**Trigger Point**: After deletion is confirmed, before releasing task resources

**Trace Event Name**: `RemoveTaskFromMemory`

**Fields to Capture**:
- `taskId` (integer) — Task ID removed
- `inMemoryTaskExists` (array) — Updated (excludes removed task)
- `inMemoryTaskState[taskId]` (string) — Changed to `"completed"`

**Notes**:
- This finalizes the task lifecycle

---

#### Action: ShutdownProcessor

**Spec Location**: `base.tla:733-741`

**Code Locations**:
- `ready_range_deletions_processor.cpp:104-119` — `shutdown()` method
- `range_deleter_service.cpp:306-309` — `_stopService()`

**Trigger Point**: When processor receives shutdown signal (step-down, service shutdown)

**Trace Event Name**: `ShutdownProcessor`

**Fields to Capture**:
- `processorState` (string) — Changed to `"stopped"`
- `serviceShuttingDown` (boolean) — Set to `true`
- `taskBeingDeleted` (integer or null) — Current task (may be mid-deletion)

**Notes**:
- Family 5: if `taskBeingDeleted` is not null, a task is abandoned mid-deletion
- This is a key fault-injection point for testing crash recovery

---

### Family 4: Secondary Coordination

#### Action: SecondaryObserveTaskInsert

**Spec Location**: `base.tla:749-762`

**Code Locations**:
- `range_deleter_service_op_observer.cpp:68-102` — onCommit on all replicas
- `range_deleter_service.cpp:121-125` — OpObserver registered unconditionally

**Trigger Point**: When secondary applies oplog entry for task document insert

**Trace Event Name**: `SecondaryObserveTaskInsert`

**Fields to Capture**:
- `taskId` (integer) — Task ID from oplog
- `replicaRole` (string) — Must be `"secondary"`
- `inMemoryTaskExists` (array) — Updated with new task
- `persistentTaskState[taskId]` (string) — State from oplog

**Notes**:
- OpObserver runs on all replicas; secondary path should NOT execute deletion
- Spec enforces primary-only deletion via preconditions on deletion actions

---

#### Action: InvalidateRangeOnSecondary

**Spec Location**: `base.tla:766-779`

**Code Locations**:
- `range_deleter_service_op_observer.cpp:139-175` — `invalidateRangePreservers()`
- Comment at line 168 says this runs without replica role check

**Trigger Point**: When oplog entry triggers range preserver invalidation on secondary

**Trace Event Name**: `InvalidateRangeOnSecondary`

**Fields to Capture**:
- `taskId` (integer) — Range/task ID being invalidated
- `invalidatedRanges` (array) — Updated set
- `replicaRole` (string) — Must be `"secondary"`

**Notes**:
- Family 4: This should match primary's invalidation set
- Currently no role check; spec allows both primary and secondary to invalidate

---

#### Action: InvalidateRangeOnPrimary

**Spec Location**: `base.tla:783-796`

**Code Locations**:
- `range_deleter_service_op_observer.cpp:139-175` — Same logic runs on primary

**Trigger Point**: When primary executes range preserver invalidation

**Trace Event Name**: `InvalidateRangeOnPrimary`

**Fields to Capture**:
- `taskId` (integer) — Range/task ID being invalidated
- `invalidatedRanges` (array) — Updated set
- `replicaRole` (string) — Must be `"primary"`

**Notes**:
- Family 4: Primary and secondary should invalidate the same ranges
- This is the source of truth for which ranges are invalidated

---

## Section 3: Special Considerations

### Timing and Ordering

**Persistent-to-In-Memory Synchronization (Family 1)**:
- Document insert happens before in-memory registration
- OpObserver fires asynchronously after transaction commit
- Race window: document exists but not yet in tracker (Family 1 mechanism)
- **Instrumentation**: Emit events in code order, not in logical order

**Recovery Lifecycle (Family 2)**:
- `BecomePublicPrimary` spawns recovery asynchronously
- Recovery task runs in parallel with other operations
- Step-down can interrupt recovery at any point
- **Instrumentation**: Track recovery progress with separate event for completion (not just start)

**Deletion Under Shutdown (Family 5)**:
- Processor shutdown can occur while deletion is in-flight
- Deletion has intermediate states (mark processing, delete, mark complete)
- **Instrumentation**: Emit events at each step, even if next is shutdown

### State Reconstruction

**Bootstrap State**:
- First trace event should include full state snapshot
- If trace starts mid-execution, TraceInit must reconstruct state from event

**Partial Events**:
- Not all events may include all fields
- Trace spec validates only fields present in event
- Missing fields are assumed unchanged from prior event

### Idempotency

**Deletion Idempotency (Family 5)**:
- Deletion queries are idempotent (deleting already-deleted documents is safe)
- Recovery must re-execute incomplete deletions
- **Instrumentation**: Do not suppress duplicate deletions; let recovery find them

**Overlap Detection (Family 3)**:
- A task can be registered multiple times without error
- Overlap check uses first registration time for ordering
- **Instrumentation**: Capture registrationOrder at first insertion

---

## Implementation Checklist

- [ ] Emit `BecomePublicPrimary` when role changes to primary AND recovery is spawned
- [ ] Emit `CompleteRecoverySuccessfully` only after recovery task finishes (not when spawned)
- [ ] Emit document state events in code order (not deferred until validation)
- [ ] Emit `MarkTaskProcessing` before deletion loop starts (earliest point)
- [ ] Emit `ShutdownProcessor` with current task state to detect mid-deletion interruption
- [ ] Capture `registrationClock` at every task registration for ordering
- [ ] Capture `invalidatedRanges` separately for primary vs. secondary to detect divergence
- [ ] For Family 5 recovery: re-scan persistent storage and compare with in-memory state
- [ ] Do NOT filter/suppress recovery events; trace validation needs complete history
