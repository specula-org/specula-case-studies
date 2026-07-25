# Modeling Brief: MongoDB Range Deletion Service

## 1. System Overview

- **System**: MongoDB Range Deletion Service — shard-local service managing cleanup of orphaned documents after chunk migrations
- **Language**: C++, ~2000 LOC core logic (range_deleter_service.cpp 531, range_deleter_service_op_observer.cpp 178, range_deletion_recovery_tracker.cpp 163, ready_range_deletions_processor.cpp ~300, range_deletion.h ~75)
- **Category**: **Category A (Distributed / Message-Passing)** — persistent state in `config.rangeDeletions` collection, asynchronous recovery on step-up, multi-document state transitions (pending → ready → deleted), inter-shard coordination during migrations
- **Protocol**: Task-based range deletion state machine with async recovery and observer-pattern notification
- **Key architectural choices**:
  - **Observer pattern for persistent state**: Changes to `config.rangeDeletions` trigger immediate in-memory task registration via `RangeDeleterServiceOpObserver`
  - **Asynchronous recovery**: On step-up, recovery spawns on a separate executor thread and completes independently, delaying service transition to UP state
  - **State machine**: Service has explicit states (kDown, kReadyForInitialization, kInitializing, kUp) with separate transitions for recovery completion and actual service readiness
  - **Two-phase task lifecycle**: Tasks created as "pending" (waiting for migration outcome), then cleared to "ready" when migration commits, triggering actual deletion
  - **Overlapping task serialization**: Tasks with overlapping ranges block each other based on registration time + task ID ordering
  - **Dual executor threads**: One for recovery/scheduling (main executor), one for actual deletion (dedicated range deletion processor thread)
  - **Per-term tracking**: Recovery completion is tracked per replica set term to handle step-down during async recovery
- **Concurrency model**: Multiple threads (main executor thread, range deletion processor thread, user operation threads) contend on shared `_rangeDeletionTasks` map via mutex

---

## 2. Bug Families

### Family 1: Service State and Recovery Completion Ordering (HIGH)

**Mechanism**: The service transitions to UP state only after recovery completes AND _state != kDown. But recovery completion happens asynchronously, and task execution is blocked until state reaches UP. If step-down occurs during recovery, recovery will not transition to UP, leaving pending tasks in limbo. These tasks will not execute on next step-up if marked as "processing" (not reinserted) or if their pending flag is never cleared.

**Evidence**:
- Code analysis: range_deleter_service.cpp:156-173 — recovery future transitions state to UP only if `_state != kDown` when promise is set
- Code analysis: range_deleter_service.cpp:381-384 — task scheduling chain explicitly waits for `getServiceUpFuture()` before proceeding
- Code analysis: range_deleter_service.cpp:194-196 — if `_state != kReadyForInitialization` when recovery task runs, it returns early without resubmitting tasks
- Code analysis: range_deletion_recovery_tracker.cpp:141-151 — cleanup of old terms marks recovery as kIncomplete, but service state may remain kDown
- Code analysis: range_deleter_service.cpp:137 — `_joinAndResetState()` is called unconditionally on step-up, clearing in-memory tasks from previous term

**Affected code paths**:
- `onStepUpComplete` — sets up recovery future chain
- `_launchRangeDeletionRecoveryTask` — conditionally resubmits based on state
- `scheduleRangeDeletionChain` — waits for service UP before executing
- `notifyEndOfTerm` — marks recovery incomplete for stepped-down terms
- `_joinAndResetState` — clears previous term's in-memory tasks

**Suggested modeling approach**:
- Variables: `service_state[Node -> {DOWN, READY_FOR_INIT, INITIALIZING, UP}]`, `recovery_outcome[Node, Term -> {UNKNOWN, COMPLETE, INCOMPLETE}]`, `persistent_tasks[Node -> SUBSET {TaskId}]` (tasks in config.rangeDeletions), `in_memory_tasks[Node -> SUBSET {TaskId}]` (tasks in service)
- Actions: `StepUp` (sets state to READY_FOR_INIT, launches async recovery), `StepDown` (transitions to DOWN, may interrupt recovery), `RecoveryCompletes` (conditionally transitions to UP based on current state), `ResubmitTasks` (only proceeds if state matches expectations)
- Model crash recovery explicitly: node can fail at any point, recovering persisted tasks on next step-up
- Track whether recovery is marked kIncomplete (service will not transition to UP) and model waiting tasks stranding

**Priority**: High
**Rationale**: Complex state machine with async recovery that can complete after step-down. Tasks can be left dangling if recovery marks incomplete but service was already INITIALIZING. Production impact: orphaned documents not deleted if recovery races with step-down. TLA+ is ideal for verifying all step-down/up interleavings.

---

### Family 2: Pending Task Unblocking and Persistent State Inconsistency (HIGH)

**Mechanism**: Tasks are created with `pending=true` flag (persisted to config.rangeDeletions). The in-memory task's `_pendingPromise` is resolved when the persistent "pending" field is removed. But the chain of futures (`scheduleRangeDeletionChain`) is started immediately, chained to `task->getPendingFuture()`. If the service steps down before the promise is resolved and the future chain executes, the unresolved future will never be fulfilled on next step-up, because the future was created in the previous term and won't be part of the newly recovered tasks. The old future object will hang forever.

**Evidence**:
- Code analysis: range_deleter_service.cpp:361-489 (registerTask) — future chain is scheduled immediately (line 472), regardless of pending status
- Code analysis: range_deleter_service.cpp:476-478 — clearPending() is called after scheduling (in user-facing call), not as part of recovery
- Code analysis: range_deletion.cpp:55-57 — `getPendingFuture()` returns a shared promise that is cleared via `clearPending()`
- Code analysis: range_deleter_service_op_observer.cpp:149-173 — pending field is updated asynchronously via oplog commit callback
- Code analysis: range_deleter_service.cpp:137, 279-280 — on step-up, `_joinAndResetState()` is called, clearing all in-memory tasks and their associated promises

**Affected code paths**:
- `registerTask` — immediate scheduling of future chain
- `RangeDeletion::clearPending` — manually called by observer on oplog entry commit
- `onStepUpComplete` → `_joinAndResetState` — clears all tasks and their futures
- `RangeDeleterServiceOpObserver::onInserts` / `onUpdate` — observer callbacks that should trigger clearPending

**Suggested modeling approach**:
- Variables: `pending_promise_state[TaskId -> {UNRESOLVED, RESOLVED}]`, `persistent_pending_flag[TaskId -> BOOL]`, `task_futures_executing[Node, TaskId -> SUBSET {CHAIN_STEP}]` (which steps of the chain have started)
- Actions: `ClearPendingFlag` (observer calls clearPending on matching task), `StepDown` (abandons unresolved futures), `Recover` (creates new futures for recovered tasks)
- Model explicit scenarios: (a) task persisted as pending → persisted flag removed → future resolved → service steps down; (b) task created → future scheduled but not yet started → service steps down before observer clears pending flag
- Track whether a future that was created in term T can be resolved in term T+1

**Priority**: High
**Rationale**: Dangling futures that will never resolve are a correctness issue. Observer pattern introduces async clearPending that races with service state transitions. TLA+ can verify that all pending tasks eventually progress to non-pending or are recovered.

---

### Family 3: Overlapping Task Detection and Registration Order Races (MEDIUM)

**Mechanism**: When a new task is registered, it queries for overlapping tasks and decides whether to wait. The overlap detection happens at line 392-393 under lock, AFTER the task is already registered at line 377. But a second task registering concurrently could see the first task in the overlap query. The ordering logic (lines 404-406) compares registration times and task IDs. If two tasks are registered with identical registration times (possible due to clock granularity), the tie-breaker is task ID comparison. But task IDs are UUIDs generated at migration start time, and two concurrent migrations could have UUIDs with non-deterministic order in the task map iteration at line 396.

**Evidence**:
- Code analysis: range_deleter_service.cpp:377-378 — task registered unconditionally under lock
- Code analysis: range_deleter_service.cpp:391-393 — overlapping tasks queried after registration, but before scheduling chain
- Code analysis: range_deleter_service.cpp:396-416 — iteration over overlappingTasks map (unordered) may see tasks in non-deterministic order
- Code analysis: range_deleter_service.cpp:404-406 — ordering decision based on (registration_time, task_id) pair
- Code analysis: range_deletion_task_tracker.cpp:58-59 — tasks stored in stdx::unordered_map with ChunkRangeHasher, not ordered

**Affected code paths**:
- `registerTask` — registration and overlap detection
- `RangeDeletionTaskTracker::registerTask` / `getOverlappingTasks` — tracker operations
- Main deletion loop waiting for overlapping tasks to complete

**Suggested modeling approach**:
- Variables: `tasks_registered[Node -> SUBSET {TaskId}]`, `registration_time[TaskId -> Nat]`, `overlapping_with[TaskId -> SUBSET {TaskId}]` (computed at registration time)
- Actions: `RegisterTask` — atomically register and compute overlaps
- Model the unordered iteration: capture which overlapping tasks are visible at registration time
- Key invariant: if task A waits for task B, then B must have an earlier registration time (or tie-break on ID)

**Priority**: Medium
**Rationale**: Could cause tasks to deadlock if A waits for B and B waits for A (circular wait). Also could cause tasks to proceed out-of-order despite intent to serialize overlaps. TLA+ can verify the serialization invariant holds across all possible interleavings.

---

### Family 4: Task Completion and Service State Check Race (MEDIUM)

**Mechanism**: `completeTask()` acquires the "fail-if-not-up" lock, which raises `NotYetInitialized` if service is not in UP state. But between the time a task finishes executing and calls completeTask, the service could step down, causing completeTask to raise. The exception propagates, and the task future is never marked complete, leaving callers waiting forever.

**Evidence**:
- Code analysis: range_deleter_service.cpp:491-498 (completeTask) — requires service to be UP (via `_acquireMutexFailIfServiceNotUp`)
- Code analysis: range_deleter_service.cpp:102-106 — `_acquireMutexFailIfServiceNotUp` raises NotYetInitialized if state != kUp
- Code analysis: ready_range_deletions_processor.cpp:78-95 — processor is destroyed during shutdown, could interrupt task mid-execution
- Code analysis: range_deleter_service.cpp:315-316 — onStepDown calls `_stopService`, which stops the executor

**Affected code paths**:
- `completeTask` — task completion confirmation
- `ready_range_deletions_processor::_runRangeDeletions` — main deletion loop that would call completeTask
- `onStepDown` / `_stopService` — service shutdown

**Suggested modeling approach**:
- Variables: `task_executing[Node, TaskId -> BOOL]`, `task_completed[Node, TaskId -> BOOL]`, `service_state[Node -> {UP, NOT_UP}]`
- Actions: `ExecuteTask` (task is running), `CompleteTask` (atomically verify service UP and mark complete), `StepDown` (service transitions from UP to NOT_UP)
- Verify: if task_executing is true and StepDown occurs, CompleteTask will fail
- Model: what happens if execution finishes but completeTask fails due to state change

**Priority**: Medium
**Rationale**: Task futures not completed could cause indefinite hangs. However, this is mitigated if errors are propagated to waiters. TLA+ can verify that all tasks either complete or fail their futures.

---

### Family 5: Recovery Task Scan and Concurrent Writes (MEDIUM)

**Mechanism**: Recovery scans config.rangeDeletions in two passes: first for "processing" tasks, then for "not-pending" tasks. But concurrent migrations could insert new tasks between the first and second scan, or update tasks' status between reading and registering. The scan uses direct client queries which are point-in-time snapshots, but task state in the collection could change after the cursor is closed.

**Evidence**:
- Code analysis: range_deleter_service.cpp:220-231 — first scan for processing=true
- Code analysis: range_deleter_service.cpp:241-254 — second scan for non-pending tasks
- Code analysis: range_deleter_service.cpp:211-215 — scopes holds MODE_S lock on range deletions collection, but this is before scanning
- Code analysis: range_deleter_service.cpp:217 — DBDirectClient used for find, which doesn't hold locks during cursor iteration

**Affected code paths**:
- `_launchRangeDeletionRecoveryTask` — recovery scanning
- Migration code that inserts/updates config.rangeDeletions (not in scope of brief but relevant)

**Suggested modeling approach**:
- Variables: `persistent_tasks[Node -> SUBSET {(task, pending_flag, processing_flag)}]`
- Actions: `Recovery` (scans persistent state and reregisters), `MigrationInsert` (concurrent inserts into config.rangeDeletions)
- Model: recovery should be atomic with respect to concurrent writes, OR should be resilient to missed tasks (which are recovered on next step-up)
- Verify: if a task is inserted after first scan but before second scan, is it recovered?

**Priority**: Medium
**Rationale**: Could miss some tasks during recovery if inserts happen concurrently. However, missed tasks are rescheduled on next step-up. This is a liveness issue (tasks not immediately deleted) rather than safety.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| Item | Why | How |
|------|-----|-----|
| **Service state transitions** | Complex async recovery and explicit state machine (DOWN, READY_FOR_INIT, INITIALIZING, UP) drives task execution. Bugs: recovery completing after step-down, tasks waiting forever for service UP | Model 4-state enum with transitions: onStepUpComplete→READY_FOR_INIT, recovery completes conditionally→UP, onStepDown→DOWN |
| **Recovery completion outcome** | Recovery outcome (kComplete/kIncomplete) determines if service reaches UP. Bugs: recovery marked incomplete but service already transitioned | Track per-term recovery completion signal, separate from service state transition |
| **Pending task futures** | Pending future is resolved asynchronously by observer pattern. Bugs: future never resolved if step-down before observer fires, leaving task chains hanging | Model SharedPromise for each task, explicit action to resolve pending promise |
| **Task registration and overlaps** | Overlapping task serialization requires ordering. Bugs: concurrent registrations might compute inconsistent overlap sets | Model task registration as atomic: register + compute overlaps in single action |
| **Two-phase task lifecycle** | Task state (pending → ready → executing → completed) drives observer notifications. Bugs: persistent state and in-memory state diverge | Track persistent_pending_flag and in_memory_task_state separately |
| **Crash recovery** | On step-up, recover persisted tasks. Bugs: tasks left dangling if recovery fails or service steps down during recovery | Model explicit Crash action, Recovery action that re-reads persisted state |

### 3.2 Do Not Model (with rationale)

| Item | Why |
|------|-----|
| **Network partitions / message loss** | Range deletion is primarily local to a shard. Partitions between shards don't directly affect recovery; migrations themselves handle partition scenarios |
| **Actual document deletion** | The `ready_range_deletions_processor` performs the actual deletion. For this brief, we model it as a black box: task sent to processor → task completes. The deletion logic is orthogonal to the state machine coordination bugs |
| **Lock contention / performance** | No safety violations from lock contention. Performance analysis is not a goal of model checking |
| **Observer registration order** | The observer pattern is complex, but for this brief we model it as: when persistent state changes, clearPending or registerTask is called. The exact observer lifecycle is implementation detail |
| **Metrics / logging** | Diagnostic-only, no impact on safety |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| ServiceStateTransitions | `service_state: Node → {DOWN, READY_FOR_INIT, INITIALIZING, UP}` | Model explicit state machine and verify transitions never go backward or transition to UP without completing recovery | Family 1 |
| RecoveryCompletionSignal | `recovery_outcome: (Node, Term) → {UNKNOWN, COMPLETE, INCOMPLETE}` | Distinguish recovery outcome from service state; verify incomplete recovery prevents service UP | Family 1 |
| PerTaskPendingPromise | `pending_promise_state: TaskId → {UNRESOLVED, RESOLVED}` | Model persistent pending flag and in-memory promise independently; verify they stay synchronized | Family 2 |
| TaskRegistrationTime | `registration_time: TaskId → Nat` | Enforce deterministic ordering for concurrent task registrations | Family 3 |
| PersistentVsInMemoryState | `persistent_tasks: Node → SET TaskId`, `in_memory_tasks: Node → SET TaskId` | Track divergence between what's persisted and what's in memory; model recovery | Families 1, 2, 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **ServiceUPImpliesRecoveryComplete** | Safety | If `service_state = UP`, then `recovery_outcome = COMPLETE` for the current term | Family 1 |
| **PendingTasksNeverScheduleUnpending** | Safety | If a task is marked pending, its scheduling chain is deferred until pending flag is cleared; no task should execute while pending | Family 2 |
| **AllTasksEventuallyComplete** | Liveness | Every registered task eventually transitions to completed state, or service steps down (and task is recovered on next step-up) | Families 1, 4 |
| **OverlappingTasksSerialize** | Safety | If task A and B overlap, and A registered before B, then B waits for A to complete before starting | Family 3 |
| **PersistentStateRecoveredCompletely** | Safety | After recovery completes, every task in config.rangeDeletions is either recovered to in_memory_tasks (if not-pending and not-processing) or will be recovered on next step-up | Family 5 |
| **TaskCompletionDoesNotRaceWithStepDown** | Safety | If task is executing and calls completeTask, either the call succeeds (service is UP) or the error is propagated to the task future, never leaving the future unresolved | Family 4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | If recovery is marked incomplete due to step-down during async recovery, can tasks that were registered in-memory before step-down be lost on next step-up? | `in_memory_tasks` before step-down ≠ `in_memory_tasks` after recovery if recovery marked incomplete; tasks not recovered | Family 1 |
| MC2 | Can a task's pending promise remain unresolved forever if step-down occurs before observer fires clearPending? | Violation of `AllTasksEventuallyComplete` — future never resolved, future never failed | Family 2 |
| MC3 | Can two overlapping tasks deadlock: task A waits for overlapping task B, task B created after A but somehow ordered before A due to registration time collision or UUID comparison? | Circular wait: B waits for unregistered task, A waits for B | Family 3 |
| MC4 | If a task completes and calls completeTask() exactly when service steps down, can the error from NotYetInitialized leave the task future unresolved? | Task executing, completeTask raises NotYetInitialized, future never marked complete/failed | Family 4 |
| MC5 | Recovery scans config.rangeDeletions twice (processing, then others). If migration inserts a task between the two scans, is it recovered on the same step-up or deferred to next? | If deferred, verify it's recovered on next step-up; if immediate, verify recovery is atomic | Family 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | Verify recovery eventually completes (finite time bound) even under high concurrency | Unit test: spawn many migrations concurrently, measure recovery time |
| T2 | Verify all in-memory tasks before step-down are either deleted (completed) or recovered on step-up | Integration test: checkpoint in-memory tasks, step down, count recovered tasks, assert equality |
| T3 | Verify pending tasks unblock correctly when persistent pending flag is removed | Unit test: set task as pending, verify future not resolved, then remove pending flag, verify future resolves |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | Service state check in `_acquireMutexFailIfServiceNotUp` raises error instead of returning failure status, forcing all call sites to handle exception. Verify this is intentional and all paths handle it | Review call sites of `_acquireMutexFailIfServiceNotUp` and `completeTask` |
| CR2 | Recovery outcome (`RangeDeletionRecoveryTracker::Outcome`) has `kUnknown` state, but service code doesn't check for this. If recovery future returns `kUnknown`, service might silently fail to UP | Search for usage of recovery outcome, verify kUnknown is handled |

---

## 7. Reference Pointers

- **Full analysis report**: This document serves as the modeling brief; detailed code analysis follows from sections 2-3
- **Core source files** (with key line ranges):
  - `range_deleter_service.cpp` (121-531) — service lifecycle and task registration
  - `range_deleter_service_op_observer.cpp` (120-175) — observer for persistent state changes
  - `range_deletion_recovery_tracker.cpp` (60-160) — per-term recovery tracking
  - `ready_range_deletions_processor.cpp` (78-150) — task processor state machine
  - `range_deletion.h` (43-72) — in-memory task representation with futures
  - `range_deletion_task_tracker.h` (63-100) — task registration and overlap tracking
- **Relevant MongoDB internal data structures**:
  - `config.rangeDeletions` collection (persistent): documents with fields `collectionUUID`, `range`, `pending`, `processing`, etc.
  - `RangeDeletionTask` BSON struct (range_deletion_task_gen.h)
- **Related systems**:
  - Chunk migration protocol (calls into range deletion service)
  - Replication state machine (provides term, step-up/down callbacks)
  - ReadyRangeDeletionsProcessor (dedicated thread executing actual deletions)
