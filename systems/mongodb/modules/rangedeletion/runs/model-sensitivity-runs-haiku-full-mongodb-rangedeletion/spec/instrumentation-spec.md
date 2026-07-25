# Instrumentation Spec: MongoDB Range Deletion Service

Maps TLA+ spec actions to source code locations and trace event fields.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<string: event name>",
  "node": "<string: replica set member ID>",
  "term": "<int: replica set term>",
  "task": "<string: task UUID>",
  "timestamp": "<int64: nanosecond timestamp>",
  "<other fields>": "..."
}
```

### State Snapshot Fields (Captured at Every Event)

| Field | Implementation Source | TLA+ Variable | Type | Notes |
|-------|----------------------|---------------|------|-------|
| `node` | `repl::getMyHostName()` | Node | string | Current node identifier |
| `term` | `_opCtx->getTerm()` / `replication::ReplicationCoordinator::getTerm()` | current_term | int | Current replica set term |
| `service_state` | `_state` (range_deleter_service.h) | service_state | enum | DOWN / READY_FOR_INIT / INITIALIZING / UP |
| `in_memory_tasks` | `_rangeDeletionTasks.keys()` | in_memory_tasks | set | Task IDs currently in memory |
| `recovery_outcome` | `_recoveryTracker->getOutcome()` | recovery_outcome | enum | UNKNOWN / COMPLETE / INCOMPLETE |
| `recovery_scan_state` | Implicit in control flow | recovery_scan_state | string | initial / scanned_processing / scanned_all |

### Message Fields (Event-Specific)

N/A for this system (distributed via persistent collection, not RPC messages)

## Section 2: Action-to-Code Mapping

### OnStepUpComplete
- **Spec action**: `OnStepUpComplete(node)`
- **Code location**: `range_deleter_service.cpp:156-173`
- **Trigger point**: After state transition `DOWN` → `READY_FOR_INIT`
- **Event name**: `"OnStepUpComplete"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: new term after increment
  - `service_state`: "READY_FOR_INIT"
  - `recovery_started`: boolean (true)
  - (state snapshot)

**Notes**: Event occurs immediately after `onStepUpComplete()` callback, before recovery task is launched.

---

### OnStepDown
- **Spec action**: `OnStepDown(node)`
- **Code location**: `range_deleter_service.cpp:315-316`
- **Trigger point**: During `notifyEndOfTerm()` callback, state transition → `DOWN`
- **Event name**: `"OnStepDown"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term at step-down
  - `service_state`: "DOWN"
  - (state snapshot)

**Notes**: Event signals service is stepping down. Recovery outcome (if initializing) should be marked "INCOMPLETE".

---

### LaunchRangeDeletionRecoveryTask
- **Spec action**: `LaunchRangeDeletionRecoveryTask(node)`
- **Code location**: `range_deleter_service.cpp:195-210`
- **Trigger point**: Before async recovery task is spawned on executor
- **Event name**: `"LaunchRangeDeletionRecoveryTask"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term
  - `service_state`: "INITIALIZING" (after transition)
  - (state snapshot)

**Notes**: Recovery task launches asynchronously; this event marks the launch, not completion.

---

### RecoveryCompletesFirstScan
- **Spec action**: `RecoveryCompletesFirstScan(node)`
- **Code location**: `range_deleter_service.cpp:220-231`
- **Trigger point**: After completing query for "processing=true" tasks
- **Event name**: `"RecoveryCompletesFirstScan"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term
  - `recovery_scan_state`: "scanned_processing"
  - (state snapshot)

**Notes**: First scan queries `config.rangeDeletions` with filter `{processing: true}`. Event fires after cursor closed.

---

### RecoveryCompletesSecondScan
- **Spec action**: `RecoveryCompletesSecondScan(node)`
- **Code location**: `range_deleter_service.cpp:241-254`
- **Trigger point**: After completing query for non-pending tasks and registering them
- **Event name**: `"RecoveryCompletesSecondScan"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term
  - `in_memory_tasks`: set of recovered task IDs
  - `recovery_scan_state`: "scanned_all"
  - (state snapshot)

**Notes**: Second scan queries with filter `{pending: {$ne: true}}`. Recovery re-registers all matched tasks in memory. This is the last step of recovery scanning (before completion signal).

---

### RecoveryCompletes
- **Spec action**: `RecoveryCompletes(node)`
- **Code location**: `range_deleter_service.cpp:156-173 (promise fulfillment)`
- **Trigger point**: When recovery promise is resolved and state transitions to "UP"
- **Event name**: `"RecoveryCompletes"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term
  - `service_state`: "UP" or "DOWN" (depending on whether step-down occurred)
  - `recovery_outcome`: "COMPLETE" or "INCOMPLETE"
  - (state snapshot)

**Notes**: Event fires when recovery completes (successfully or unsuccessfully). Conditional transition: if service stepped down during recovery, outcome is "INCOMPLETE" and state remains "DOWN".

---

### RegisterTask
- **Spec action**: `RegisterTask(node, task)`
- **Code location**: `range_deleter_service.cpp:361-416`
- **Trigger point**: After task is registered in `_rangeDeletionTasks` and overlaps computed (line 393)
- **Event name**: `"RegisterTask"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term
  - `task`: task UUID
  - `registration_time`: term (used for ordering overlapping tasks)
  - `overlapping_with`: set of task IDs that overlap
  - `in_memory_tasks`: updated set (includes new task)
  - (state snapshot)

**Notes**:
- Task registered unconditionally (line 377-378), then overlaps queried (line 391-393).
- Event fires after overlap detection completes but before scheduling chain starts.
- Overlapping tasks determined by range intersection; record full overlap set.

---

### ClearPendingFlag
- **Spec action**: `ClearPendingFlag(node, task)`
- **Code location**: `range_deleter_service_op_observer.cpp:149-173`
- **Trigger point**: When observer detects pending field removal in `config.rangeDeletions` document
- **Event name**: `"ClearPendingFlag"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term
  - `task`: task UUID
  - `persistent_pending_flag[task]`: false (after update)
  - `pending_promise_state[task]`: "RESOLVED"
  - (state snapshot)

**Notes**:
- Observer fires when migration commits and marks pending flag as false in collection (via oplog callback).
- Event marks the point where in-memory pending promise is resolved.
- Timing: can occur in any term, races with step-down and task execution.

---

### ExecuteTask
- **Spec action**: `ExecuteTask(node, task)`
- **Code location**: `ready_range_deletions_processor.cpp:78-95`
- **Trigger point**: Task begins execution in deletion processor thread (after all conditions met)
- **Event name**: `"ExecuteTask"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term (must be stable during execution)
  - `task`: task UUID
  - `task_executing[task]`: true
  - `service_state`: "UP" (must be UP to execute)
  - (state snapshot)

**Notes**:
- Task can only execute if service is UP, pending promise is resolved, and all overlapping tasks completed.
- Event fires at the start of actual deletion work in the processor thread.
- Processor thread is separate from main executor thread.

---

### CompleteTask
- **Spec action**: `CompleteTask(node, task)`
- **Code location**: `range_deleter_service.cpp:491-498`
- **Trigger point**: After `completeTask()` call returns (successfully or fails)
- **Event name**: `"CompleteTask"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term
  - `task`: task UUID
  - `task_executing[task]`: false (after action)
  - `task_completed[task]`: true (if successful) or false (if service stepped down)
  - `service_state`: state at completion time
  - (state snapshot)

**Notes**:
- `completeTask()` verifies service is UP before marking complete (line 102-106).
- If service stepped down, exception is raised; future is NOT marked complete.
- Event should capture both the task state and service state to show the race condition.

---

### MigrationInsertTask
- **Spec action**: `MigrationInsertTask(node, task)`
- **Code location**: Migration code (not in range deletion service, but affects recovery)
- **Trigger point**: When migration inserts task document into `config.rangeDeletions`
- **Event name**: `"MigrationInsertTask"`
- **Fields to capture**:
  - `node`: node identifier (shard that receives chunk)
  - `term`: current term
  - `task`: task UUID
  - `persistent_tasks`: updated set
  - `persistent_pending_flag[task]`: true (newly inserted tasks are pending)
  - (state snapshot)

**Notes**:
- Migration inserts are modeled to occur between recovery scans to test Family 5 bug.
- In real system, inserts happen via oplog/replication; for testing, can be triggered by test harness.
- Event helps verify recovery doesn't miss concurrently inserted tasks.

---

### Crash
- **Spec action**: `Crash(node)`
- **Code location**: Induced by test harness (not intrinsic to code)
- **Trigger point**: Simulated crash event
- **Event name**: `"Crash"`
- **Fields to capture**:
  - `node`: node identifier
  - `term`: current term before crash
  - `service_state`: "DOWN" (after crash)
  - `in_memory_tasks`: empty (in-memory state lost)
  - (state snapshot)

**Notes**:
- Crash is not instrumented from real code, but triggered by test harness to simulate failure.
- Used to verify recovery correctly reloads persisted tasks on step-up after crash.

---

## Section 3: Special Considerations

### Timing and Atomicity

**Non-atomic persist**: Tasks are persisted as documents in `config.rangeDeletions`. The persistent state and in-memory state can diverge if service crashes or steps down during recovery. Trace should capture post-crash state to validate recovery logic.

### Bootstrap State

**Initial state**: On first step-up, service starts with:
- `service_state`: "DOWN"
- `current_term`: 0
- `persistent_tasks`: loaded from `config.rangeDeletions` at startup
- `in_memory_tasks`: empty

Adjust `TraceInit` to match the actual snapshot of `config.rangeDeletions` at test start.

### Concurrent Threads

**Main executor thread** (recovery, task registration, state transitions):
- Range deletion service main logic runs here.
- Operations are serialized via `_mutex` lock.

**Deletion processor thread** (task execution):
- `ReadyRangeDeletionsProcessor` runs on a separate executor.
- Executes tasks concurrently with recovery and registration on main thread.
- Instrumentation must capture events from both threads with consistent term/node info.

### Pending Flag and Promise Semantics

**Pending flag**:
- Persistent field in `config.rangeDeletions` document.
- In-memory future (`SharedPromise`) is created at task registration.
- Observer fires when persistent field is removed (oplog callback).
- If service steps down before observer fires, the future remains unresolved forever.

**ClearPendingFlag event**:
- Occurs when observer fires, not when persistent field is actually removed.
- May occur in a later term if recovery runs in a new term.

### Recovery Scan Timing

**First scan** (`{processing: true}`):
- Recovers tasks marked as "being processed" from a prior term.

**Second scan** (`{pending: {$ne: true}}`):
- Recovers tasks that are not pending (migration committed).
- Can miss tasks inserted concurrently between first and second scan.

Instrumentation should emit **separate events** for first and second scan completions to test Family 5.

### Task Completion Race

**CompleteTask failure scenario**:
- Task finishes deletion work (in deletion processor thread).
- Calls `completeTask()` on main executor (via callback).
- Service steps down between task finish and call.
- Exception raised; future not marked complete.

Trace should capture this timing by emitting `CompleteTask` event **after** the call returns (success or exception), showing both `service_state` and `task_completed` values.

### No Special Serialization

The instrumentation should emit events in the order they are observed, without additional serialization. The trace validation spec (`Trace.tla`) will explore all valid orderings via TLC's interleaving semantics.

---

## JSON Trace Example

```json
{"event":"OnStepUpComplete","node":"n1","term":1,"service_state":"READY_FOR_INIT","recovery_started":true,"timestamp":1000}
{"event":"LaunchRangeDeletionRecoveryTask","node":"n1","term":1,"service_state":"INITIALIZING","timestamp":1001}
{"event":"RecoveryCompletesFirstScan","node":"n1","term":1,"recovery_scan_state":"scanned_processing","timestamp":1050}
{"event":"MigrationInsertTask","node":"n1","term":1,"task":"t1","persistent_pending_flag":true,"timestamp":1051}
{"event":"RecoveryCompletesSecondScan","node":"n1","term":1,"in_memory_tasks":["t1"],"recovery_scan_state":"scanned_all","timestamp":1100}
{"event":"RecoveryCompletes","node":"n1","term":1,"service_state":"UP","recovery_outcome":"COMPLETE","timestamp":1101}
{"event":"RegisterTask","node":"n1","term":1,"task":"t2","registration_time":1,"overlapping_with":[],"timestamp":1102}
{"event":"ClearPendingFlag","node":"n1","term":1,"task":"t2","persistent_pending_flag":false,"pending_promise_state":"RESOLVED","timestamp":1110}
{"event":"ExecuteTask","node":"n1","term":1,"task":"t2","service_state":"UP","timestamp":1150}
{"event":"CompleteTask","node":"n1","term":1,"task":"t2","task_completed":true,"service_state":"UP","timestamp":1200}
```

---

## Harness Generation Notes

Use this spec to generate code patches that:
1. Identify instrumentation points in source code (file:line above).
2. Capture state snapshots at each action (all enum values, collections, timestamps).
3. Emit NDJSON events with all required fields.
4. Handle concurrent threads correctly (each event includes node/term for context).
5. Match field names exactly (trace validation will fail on mismatches).

See `harness-generation` skill for implementation details.
