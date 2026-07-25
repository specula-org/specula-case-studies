# Modeling Brief: MongoDB Range Deletion on Secondaries

## 1. System Overview

**System**: MongoDB range deletion service managing cleanup of orphaned documents during shard migrations
**Language**: C++, ~3000 LOC of core logic
**Category**: **Category A (Distributed / Message-Passing)** — The system coordinates range deletion across primary and secondary replicas through persistent document state (`config.rangeDeletions`) and in-memory replica-set-aware service state. Primary-only deletion operations are triggered by OpObserver hooks reacting to state changes in durable storage, with secondary-specific coordination for query preservation.
**Reference Algorithm**: MongoDB sharding protocol (range deletion phase of chunk migration)
**Key Architectural Choices**:
- Primary-only deletion execution (secondaries read-only track)
- Three-layer state model: persistent (config.rangeDeletions), in-memory tracked (RangeDeletionTaskTracker), and transient (ReadyRangeDeletionsProcessor queue)
- OpObserver hooks for persistent-to-in-memory synchronization
- Separate recovery phase on primary step-up
- Term-aware recovery tracking (RangeDeletionRecoveryTracker) to detect incomplete recovery on early termination

## 2. Bug Families

### Family 1: Persistent State Synchronization Windows

**Mechanism**: The system maintains consistency between persistent `config.rangeDeletions` documents and in-memory task tracking through OpObserver hooks registered on transaction commit. Multiple crash windows exist: (a) between task document insert and in-memory registration, (b) between in-memory task completion and document deletion, (c) during recovery when persistent state is reloaded but in-memory state is cleared.

**Evidence**:
- Historical: Multiple comments in code about race conditions between persistent and in-memory state (range_deletion_util.cpp:243-271 `ensureRangeDeletionTaskStillExists`)
- Code analysis: 
  - range_deleter_service.cpp:213-254 recovery loads from persistent storage into empty in-memory state
  - range_deleter_service_op_observer.cpp:68-102 onCommit hooks register tasks asynchronously
  - Recovery observes "processing" flag that may not exist in original document (line 222)

**Affected code paths**:
- `RangeDeleterService::onStepUpComplete()` → `_launchRangeDeletionRecoveryTask()`
- `RangeDeleterService::registerTask()` with pending/non-pending variants
- `RangeDeleterServiceOpObserver::onUpdate()` handling "pending" flag transitions
- `RangeDeleterService::completeTask()` and document deletion path

**Suggested modeling approach**:
- Variables: persistent task state (pending/ready/processing/deleted), in-memory task state, last recovered term
- Actions: separate crash recovery, task document state transitions (insert, update pending→ready, update processing, delete), in-memory registration, task completion
- Granularity: model the "pending" flag lifecycle separately from document existence to expose timing races

**Priority**: High
**Rationale**: This is the foundational synchronization mechanism. Both secondaries (must see deletions) and primaries (must execute them) depend on correct state flow. The code explicitly checks for task document existence during deletion (line 263-265 `RangeDeletionAbandonedBecauseTaskDocumentDoesNotExist`), indicating this has been a real issue.

---

### Family 2: Recovery Completeness vs. Term Boundaries

**Mechanism**: On step-up, recovery is spawned asynchronously on the executor (not blocking). A `RangeDeletionRecoveryTracker` tracks how many recovery jobs are still in flight. But if the node steps down before recovery completes, the state is inconsistent: some tasks re-registered, others not. The `Outcome` enum (kComplete/kIncomplete/kUnknown) tries to track this, but the use of this outcome signal is incomplete.

**Evidence**:
- Code analysis:
  - range_deleter_service.cpp:127-180 onStepUpBegin/onStepUpComplete don't block on recovery completion
  - range_deleter_service.cpp:156-175 recovery runs asynchronously via executor, may outlive the term
  - range_deletion_recovery_tracker.h:43-48 Outcome enum but unclear how result flows to protocol decisions
  - ready_range_deletions_processor.cpp:78-86 processor thread starts independently of recovery completion

**Affected code paths**:
- `RangeDeleterService::onStepUpBegin()` → `registerRecoveryJob()`
- `RangeDeleterService::onStepUpComplete()` → `_launchRangeDeletionRecoveryTask()` (executor spawn)
- `RangeDeleterService::onStepDown()` → `_stopService()` (may interrupt in-flight recovery)
- `RangeDeletionRecoveryTracker::getRecoveryFuture()` outcome handling

**Suggested modeling approach**:
- Variables: term counter, recovery_in_flight flag, completion_outcome, set of tasks registered in current term
- Actions: step-up (spawn recovery without waiting), step-down (interrupt recovery), recovery complete, task re-registration, service transition to kUp state (only after recovery completes)
- Granularity: separate step-up-begin from step-up-complete; model recovery as an asynchronous process that can fail to complete

**Priority**: High
**Rationale**: Secondary nodes must coordinate with primary on deletion status. If recovery is incomplete, secondaries may hold stale information about which ranges have orphans, breaking read-safety guarantees. The incomplete recovery outcome is tracked but no code path explicitly handles it.

---

### Family 3: Overlapping Range Task Ordering and De-duplication

**Mechanism**: When multiple tasks overlap, the system tries to serialize them by registration order (time + task ID). But the de-duplication logic has a TOCTOU (time-of-check-time-of-use) window: a task is registered first (line 377), then checked for overlaps (line 392). Between those, another task with an earlier registration time could be inserted, creating a race where both tasks run concurrently instead of the intended serialization.

**Evidence**:
- Code analysis:
  - range_deleter_service.cpp:377-426 registration followed by overlap check with wait
  - Registration is into _rangeDeletionTasks map (line 377)
  - Overlap check happens in async chain (line 392), after registration but potentially after task enqueue
  - Comment on line 418-422 acknowledges "assuming no overlapping tasks" in processor

**Affected code paths**:
- `RangeDeleterService::registerTask()` line 377 registration
- Async chain line 385-426 overlap detection and waiter setup
- `ReadyRangeDeletionsProcessor::_runRangeDeletions()` assumes no overlapping tasks are queued simultaneously

**Suggested modeling approach**:
- Variables: map of active tasks by collection/range, registration queue, pending overlaps
- Actions: register task (atomic add to map), query overlapping tasks, wait for overlaps, enqueue for deletion
- Granularity: split task registration into two phases: map insertion (atomic) and overlap detection (queued)

**Priority**: Medium
**Rationale**: The code assumes no overlapping deletions but the synchronization doesn't fully guarantee it. However, the async chain structure may provide enough ordering guarantees in practice that this is defensive rather than critical.

---

### Family 4: Secondary-Specific Coordination Gaps

**Mechanism**: The README states this is a "primary only service" but the OpObserver is registered unconditionally in `onStartup()`, on all replica nodes. Secondaries run the service initialization but should not delete documents. However, the OpObserver still triggers on secondaries (oplog replay), attempting to register tasks that will never execute, wasting memory and coordination overhead. More critically: the code that invalidates range preservers (range_deleter_service_op_observer.cpp:105-113) runs on secondaries during oplog application, potentially creating divergence between primary and secondary views of which ranges have been invalidated.

**Evidence**:
- Code analysis:
  - range_deleter_service.h:71 "primary only service"
  - range_deleter_service.cpp:121-125 OpObserver registered unconditionally in onStartup
  - range_deleter_service_op_observer.cpp:139-175 onUpdate handler invalidates range preservers without checking primary role (line 168)
  - range_deleter_service_op_observer.cpp:89-90 task registration catches NotYetInitialized without checking replica role

**Affected code paths**:
- `RangeDeleterService::onStartup()` → OpObserver registration
- `RangeDeleterServiceOpObserver::onUpdate()` → `invalidateRangePreservers()` 
- Replica role checks missing in observer methods

**Suggested modeling approach**:
- Variables: replica role (primary/secondary), range preserver invalidation state, task registration state
- Actions: mark observer as primary-only at registration time; separate invalidation logic (should run on all) from task registration (primary only)
- Granularity: two separate observer concerns (invalidation vs. task tracking); model replica role transitions

**Priority**: Medium
**Rationale**: This creates divergence between primary and secondary views, breaking linearizability of read safety. Secondaries may see different invalidated ranges than primary, allowing some secondaries to serve stale data. The code path exists and runs, but the impact depends on whether range preservers are actually used for correctness on secondaries.

---

### Family 5: Ready Deletions Queue and Shutdown Race

**Mechanism**: `ReadyRangeDeletionsProcessor` maintains a queue of tasks to be deleted. The thread that drains this queue (`_runRangeDeletions`) can be interrupted mid-task when the processor shuts down. The shutdown sequence (processor.shutdown() → opCtx.markKilled()) will interrupt the thread, but there's no synchronization on which task is currently being deleted. A task that started deletion might be abandoned partway through if the service shuts down (step-down). On the next step-up, recovery will reload the persisted task document, but it won't have the "processing" flag if deletion completed before step-down, leading to orphans remaining.

**Evidence**:
- Code analysis:
  - range_deleter_service.cpp:306-309 processor shutdown without joining
  - ready_range_deletions_processor.cpp:104-119 shutdown marks state kStopped and kills opCtx
  - ready_range_deletions_processor.cpp:210-228 main loop can be interrupted at any point
  - The "processing" flag is only set in markRangeDeletionTaskAsProcessing (range_deletion_util.cpp:273-294), which happens during deletion but not persisted if deletion completes

**Affected code paths**:
- `RangeDeleterService::_stopService()` 
- `ReadyRangeDeletionsProcessor::shutdown()`
- `ReadyRangeDeletionsProcessor::_runRangeDeletions()` processing loop

**Suggested modeling approach**:
- Variables: processor state (initializing/running/stopped), current_task_in_flight, deletion_progress_per_task
- Actions: task dequeue, begin deletion (mark processing), deletion completion, processor shutdown, task requeue on interrupt
- Granularity: model deletion as multi-step (mark processing, delete batches, mark complete, remove document); track which step can be interrupted

**Priority**: Medium
**Rationale**: This is an edge case (failure during deletion) but has real impact: orphans remain if deletions are partially completed. However, the idempotency of deletion (same query run twice) limits the severity.

---

### Family 6: Missing Operation Context Cleanup in Async Recovery Chain

**Mechanism**: In `_launchRangeDeletionRecoveryTask`, an operation context is created and stored in `_initOpCtxHolder`. The recovery task uses this context in an async chain on the executor. If the executor is destroyed before the async chain completes (e.g., rapid step-down after step-up), the opCtx may be destroyed while still in use by the async lambda, leading to use-after-free.

**Evidence**:
- Code analysis:
  - range_deleter_service.cpp:198 `_initOpCtxHolder = tc->makeOperationContext()`
  - range_deleter_service.cpp:201-204 ON_BLOCK_EXIT resets _initOpCtxHolder
  - range_deleter_service.cpp:268-271 executor join/reset in _joinAndResetState
  - The async chain (188-261) captures serviceContext and this, but opCtx is passed by reference in subsequent lambdas
  - If executor->shutdown() is called during the chain, the opCtx may outlive its cleanup

**Affected code paths**:
- `RangeDeleterService::_launchRangeDeletionRecoveryTask()` 
- `RangeDeleterService::_joinAndResetState()`
- `RangeDeleterService::onStepDown()` → `_stopService()`

**Suggested modeling approach**:
- Variables: executor lifecycle, opctx lifecycle, async chain lifetime
- Actions: create opctx, launch async chain, executor shutdown (interrupt), executor join, cleanup opctx
- Granularity: model executor lifecycle separately from service lifecycle; ensure opctx cleanup happens after all async work completes

**Priority**: Low
**Rationale**: This requires a specific timing (rapid step-down during recovery initialization). The ON_BLOCK_EXIT guard should catch most cases, but the async chain structure could leak the context if executor shutdown is not properly ordered.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| Item | Why | How |
|------|-----|-----|
| Persistent task state transitions (pending→ready, ready→processing, processing→deleted) | Family 1: synchronization windows expose races between persistent and in-memory state; multiple code paths check for task document existence | Model as explicit BSON document state in abstract storage; separate crash recovery phase |
| Recovery completeness on term boundaries | Family 2: async recovery can be interrupted by step-down; incomplete recovery breaks secondary coordination | Add term counter and recovery_outcome variable; model recovery as asynchronous action; enforce service cannot reach kUp until recovery completes |
| Task registration and overlap detection ordering | Family 3: TOCTOU window between map insertion and overlap detection | Model as two-phase: register (atomic), then query overlaps (may race); verify no concurrent overlapping deletes execute |
| Replica role effect on OpObserver behavior | Family 4: secondaries run same logic as primary, creating state divergence | Add replica role variable to model; separate invalidation (all) from task registration (primary only) |
| Deletion execution under shutdown | Family 5: deletions can be interrupted with partial completion | Model deletion as multi-step (mark processing, batch delete, mark complete); interrupt can occur at any step; recovery path must handle partial completion |

### 3.2 Do Not Model (with rationale)

| Item | Why |
|------|-----|
| Batch sizing and deletion query optimization (useBatchedDeletes flag) | Implementation detail; does not affect protocol correctness |
| Metrics and logging statements | Observability only; does not affect correctness |
| Thread pool task executor details (network interface, thread pools) | MongoDB infrastructure; model only the task ordering semantics |
| Copy-paste drift in shard key pattern handling | One-off code quality issue, not a protocol pattern |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| PersistentTaskState | pending: bool, processing: bool, deleted: bool | Model the lifecycle of a range deletion task in config.rangeDeletions | Family 1 |
| TermAwareRecovery | current_term, recovery_outcome, tasks_recovered, recovery_in_flight | Track whether recovery completes before term ends; detect incomplete recovery | Family 2 |
| OverlapOrdering | registration_order: (time, task_id), waiting_tasks: set | Ensure overlapping tasks are serialized in registration order | Family 3 |
| ReplicaRoleAwareness | is_primary: bool | Control which actions (deletion execution vs. state tracking) execute based on role | Family 4 |
| DeletionStepwise | deletion_step: (not_started, processing, batch_deleting, mark_complete, removed_doc) | Model intermediate states during deletion; allow interrupts at each step | Family 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| TaskDocumentExistenceConsistency | Safety | If in-memory task tracker has a task, the corresponding document exists in config.rangeDeletions (or deletion has completed) | Family 1 |
| RecoveryCompletenessOnRoleChange | Safety | On transition to primary, recovery must complete before service reaches kUp state | Family 2 |
| OverlapSerializationOrder | Safety | If two tasks overlap and registered in order T1 < T2, then T1 completes before T2 starts | Family 3 |
| SecondaryInvalidationConsistency | Safety | Secondary invalidates the same ranges as primary for the same task documents | Family 4 |
| OrphansDeletion | Safety | Once a task completes (document deleted), no orphans remain for that range | Family 5 |
| NoTaskQueueDeadlock | Liveness | If a task is queued in ReadyRangeDeletionsProcessor and processor is running, task will eventually complete or be interrupted | Family 5 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable Findings

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | Can a range deletion task document be deleted from config.rangeDeletions while the in-memory task tracker still has a reference to it? (causing use-after-free in task completion) | TaskDocumentExistenceConsistency violation; subsequent registrations of overlapping tasks fail | Family 1 |
| MC2 | If the node steps down during recovery, can the next step-up transition service to kUp without all recovered tasks being registered? | RecoveryCompletenessOnRoleChange violation; some tasks never run, orphans remain | Family 2 |
| MC3 | Can two overlapping tasks both be enqueued for deletion if the second task is registered while the first is in the async overlap-checking chain? | OverlapSerializationOrder violation; both tasks run concurrently, processor assumptions violated | Family 3 |
| MC4 | On a secondary, if the oplog application causes invalidateRangePreservers() to run before a primary has yet invalidated that range, can a primary-secondary divergence occur? | SecondaryInvalidationConsistency violation; reads on secondaries serve stale data | Family 4 |
| MC5 | If deletion is interrupted (marked as processing but not completed) and the node steps down, will recovery correctly re-enqueue the task with its progress preserved? | OrphansDeletion violation on next term; orphans remain from partial deletion | Family 5 |

### 6.2 Test-Verifiable Findings

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | Verify range deletion task documents are not prematurely cleaned up | Unit test: manually delete task doc during async registration phase, check for crash or data corruption |
| TV2 | Verify recovery outcome (complete vs. incomplete) is correctly reported | Integration test: step-up, interrupt recovery after N seconds, check outcome enum value matches actual state |
| TV3 | Verify overlapping tasks are serialized | Integration test: register two overlapping tasks, force slow completion of first, verify second waits |

### 6.3 Code-Review-Only Findings

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | OpObserver registered unconditionally in onStartup; should be conditional on or wrapped with replica role check | Refactor RangeDeleterServiceOpObserver to check replica role in onInserts/onUpdate before registering tasks (keep invalidation unconditional) |
| CR2 | Missing explicit synchronization between _initOpCtxHolder and executor lifecycle | Add explicit join guarantee: executor must be joined before _initOpCtxHolder is reset; add assertion in _joinAndResetState |

---

## 7. Reference Pointers

**Skill guide**: `/home/ubuntu/Specula/.claude/skills/code_analysis/guide.md`

**Core source files**:
- `range_deleter_service.h` (134 lines): service interface, state machine
- `range_deleter_service.cpp` (530 lines): initialization, recovery, task registration
- `range_deletion_util.h/cpp` (220+1100 lines): deletion execution, persistence utilities
- `range_deletion_recovery_tracker.h/cpp`: term-aware recovery tracking
- `range_deletion_task_tracker.h/cpp`: in-memory task map
- `ready_range_deletions_processor.h/cpp` (122+300 lines): task queue processing
- `range_deleter_service_op_observer.h/cpp` (80+178 lines): oplog/state synchronization

**Key architectural documentation**:
- `README_range_deleter.md`: service initialization, steady state, shutdown phases

**MongoDB source directory**:
- `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-rangedeletions-secondary/artifact/mongo-src/src/mongo/db/s/`

