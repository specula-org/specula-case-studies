# Modeling Brief: mongodb-rangedeletions-secondary

**System**: MongoDB shard-local range deletion service (`RangeDeleterService`)  
**Language**: C++  
**Core LOC**: ~2,200 across 10 source files  
**Reference algorithm**: MongoDB sharding — chunk migration cleanup (orphan document deletion)  
**GitHub**: mongodb/mongo  

---

## 1. System Overview

`RangeDeleterService` is a **primary-only** `ReplicaSetAwareServiceShardSvr` that manages deletion of "orphan" documents left behind after chunk migrations. Its lifecycle is tightly coupled to replica-set role changes:

- **Step-up** (`onStepUpComplete`): Creates executor, runs an async two-phase recovery scan of `config.rangeDeletions`, then transitions `kDown → kReadyForInitialization → kInitializing → kUp`.
- **Steady state** (`kUp`): `RangeDeleterServiceOpObserver` keeps in-memory state in sync with `config.rangeDeletions` by reacting to document inserts/updates. Op_observer fires on **both primary and secondary**; on secondary all registration attempts are silently swallowed.
- **Step-down** (`onStepDown`): Kills executor, clears all in-memory task state, sets `kDown`. All in-flight deletions are abandoned and resumed on next step-up.

**Category**: **Category A (Distributed / Message-Passing)**.  
The protocol spans multiple nodes: the primary executes orphan deletions, uses a majority write-concern wait to ensure secondaries have applied the deletions before removing the task document, and secondaries reconstruct state on each step-up via a disk scan.

**Key architectural choices**:
- Persistent authority: `config.rangeDeletions` on each shard is the durable source of truth. In-memory state is rebuilt from scratch on every step-up.
- Majority-wait ordering: orphan batch deletions must be majority committed before the task document (`config.rangeDeletions` entry) is removed. This ensures secondaries apply deletions before they see the task as complete.
- Delayed secondary cleanup: `whenToClean=kDelayed` inserts a configurable grace period (`orphanCleanupDelaySecs`) before deletion starts, to let secondary reads drain.
- No `onDelete` observer: task removal from `config.rangeDeletions` is not observed by the service; deregistration happens inline after successful deletion.

---

## 2. Bug Families

### Family 1: Orphan-Deletion-Before-Task-Removal Ordering

**Mechanism**: The protocol relies on a strict ordering guarantee: *all replicas apply orphan document deletions before any replica applies the `config.rangeDeletions` document removal*. This ordering is enforced on the primary by a majority write-concern wait between the two operations (`ready_range_deletions_processor.cpp:337-339`). If this wait is interrupted (step-down mid-deletion), the task document is NOT removed — the primary dies before reaching `completeTask`. Recovery re-executes deletion from scratch on the next step-up. The open question is whether every step-down path leaves the disk state consistent enough that recovery can reconstruct and re-enforce this ordering guarantee.

**Evidence**:
- Code: `ready_range_deletions_processor.cpp:332-339` — explicit comment: "it's important not to apply out of order the deletions of orphans and the removal of the entry persisted in `config.rangeDeletions`"
- Code: `ready_range_deletions_processor.cpp:242-401` — `taskCompleted=true` and `_completedRangeDeletion()` only called AFTER both the majority wait AND `removePersistentTask`. Step-down interrupts the majority wait (via opCtx kill), preventing premature task removal.
- Code: `range_deleter_service.cpp:297-299` — `_initOpCtxHolder->markKilled(ErrorCodes::Interrupted)` interrupts in-flight DB operations on step-down.
- Code: `range_deleter_service.cpp:388-397` — catch block re-loops only on non-shutdown errors; shutdown errors break the loop, leaving task document on disk.

**Affected code paths**:
- `ReadyRangeDeletionsProcessor::_runRangeDeletions` (ready_range_deletions_processor.cpp:225-403)
- `RangeDeleterService::_stopService` (range_deleter_service.cpp:283-313)
- `RangeDeleterService::_launchRangeDeletionRecoveryTask` (range_deleter_service.cpp:186-261)

**Suggested modeling approach**:
- Variables: `orphansDeleted[node]`, `orphansDurableOnMajority`, `taskDocumentRemoved[node]`, `nodeRole[node]`, `term`
- Actions: `DeleteOrphanBatch`, `WaitForMajority`, `RemoveTaskDocument`, `StepDown`, `StepUpAndRecover`
- Granularity: split deletion into 3 separate actions — `DeleteOrphans`, `MajorityWait` (non-deterministic success or interrupted), `RemoveTaskDoc` — to expose the crash window between each pair

**Priority**: High  
**Rationale**: This is the core safety invariant of the protocol. The majority wait is the load-bearing mechanism; checking whether it holds under all step-down timings is the primary value of TLA+ modeling for this system.

---

### Family 2: Recovery Scan Completeness — Two-Phase Scan Without Atomicity

**Mechanism**: The step-up recovery scan is two-phase and non-transactional: Phase 1 queries `config.rangeDeletions` for `processing=true` tasks; Phase 2 queries for `pending != true AND processing != true` tasks (range_deleter_service.cpp:220-253). Between phases, concurrent writes can change task state. A task transitioning from `pending=true` to `pending=false` between phases is covered by the op_observer (which fires on commit and calls `registerTask` since `_termInitializationPromise` is set at line 177 before recovery runs). The dedup mechanism (`kJoinedExistingTask`) handles races between op_observer registration and the scan. The open question is whether the dedup coverage is complete under all interleaving orders, including step-down during recovery.

**Evidence**:
- Code: `range_deleter_service.cpp:177` — `_termInitializationPromise` fulfilled before recovery task starts, allowing concurrent op_observer registrations
- Code: `range_deleter_service.cpp:366-368` — `registerTask` guard: succeeds if `_termInitializationPromise.isReady()`, even during recovery (`kInitializing`)
- Code: `range_deleter_service_op_observer.cpp:92-101` — `NotYetInitialized` and `NotPrimaryError` silently swallowed; tasks missed on secondary are only recovered via the step-up scan
- Code: `range_deleter_service.cpp:194-196` — recovery task exits early (without registering tasks) if `_state != kReadyForInitialization` at start; recovery future resolves as `kIncomplete` via `cleanUpOldTerms`
- Code: `range_deletion_recovery_tracker.cpp:141-151` — `cleanUpOldTerms` resolves all open recovery promises as `kIncomplete` on step-down

**Affected code paths**:
- `RangeDeleterService::_launchRangeDeletionRecoveryTask` (range_deleter_service.cpp:186-261)
- `RangeDeleterServiceOpObserver::onInserts` / `onUpdate` (range_deleter_service_op_observer.cpp:116-177)
- `RangeDeletionRecoveryTracker::cleanUpOldTerms` (range_deletion_recovery_tracker.cpp:141-151)

**Suggested modeling approach**:
- Variables: `taskState[task]` ∈ {pending, ready, processing, deleted}, `nodeRole`, `recoveryPhase` ∈ {idle, phase1, phase2, complete}, `inMemoryTasks`
- Actions: `RecoveryPhase1Scan`, `RecoveryPhase2Scan`, `OpObserverFire`, `StepDown`, `StepUp`
- Granularity: model recovery as two separate atomic scan steps with op_observer actions interleaved between them

**Priority**: Medium  
**Rationale**: The dedup mechanism and op_observer coverage appear to close the gap; TLA+ can confirm the invariant "every non-pending task is eventually executed" holds across all step-up/step-down interleavings. The scenario of a secondary that applied `$unset pending` just before becoming primary is the richest case.

---

### Family 3: Non-Atomic Task Completion — `completeTask` Before `removePersistentTask`

**Mechanism**: In `ReadyRangeDeletionsProcessor::_runRangeDeletions`, `completeTask` (which removes the in-memory entry and calls `markComplete()`, resolving the completion future) is called BEFORE `removePersistentTask` (which deletes the disk document). This is a non-atomic two-step operation with a crash/failure window between the steps. If the process crashes after `completeTask` but before `removePersistentTask`, the completion future was already resolved (callers received success), but the disk document survives. On the next step-up, the task is re-discovered and re-executed. If `removePersistentTask` throws a non-interrupt exception after `completeTask`, the while-loop retries, but `completeTask` returns `nullptr` (in-memory entry already gone), so `removePersistentTask` is never retried — the disk document persists until restart.

**Evidence**:
- Code: `ready_range_deletions_processor.cpp:344-347` — `completeTask` before `removePersistentTask`, guarded only by `if (task)` null check
- Code: `range_deletion.cpp:75-76` — `markComplete()` directly calls `_completionPromise.emplaceValue()` — no retry path
- Code: `ready_range_deletions_processor.cpp:357-364` — non-interrupt exception on `removePersistentTask` is logged and re-thrown, triggering outer retry loop; but second `completeTask` call returns `nullptr` and skips `removePersistentTask` (line 346: `if (task)`)
- Code: `range_deleter_service.cpp:493` — `completeTask` uses `_acquireMutexFailIfServiceNotUp()`, so it fails if service is not `kUp`. Step-down mid-retry path causes `completeTask` to throw, breaking the retry loop (line 388-397 — shutdown error breaks, non-shutdown loops back). The disk document always survives step-down.

**Affected code paths**:
- `ReadyRangeDeletionsProcessor::_runRangeDeletions` (ready_range_deletions_processor.cpp:340-401)
- `RangeDeleterService::completeTask` (range_deleter_service.cpp:491-499)
- `rangedeletionutil::removePersistentTask` (range_deletion_util.cpp)

**Suggested modeling approach**:
- Variables: `completionFutureFulfilled[task]`, `diskDocumentExists[task]`, `inMemoryEntry[task]`
- Actions: `CompleteInMemory` (removes in-memory + fulfills future), `RemoveFromDisk` (deletes document), `Crash` (process dies between the two), `StepUpRecover` (re-registers from disk)
- Invariant: "If `completionFutureFulfilled[task]` AND `diskDocumentExists[task]`, a recovery is pending; once recovery re-executes, `diskDocumentExists[task]` eventually becomes false"

**Priority**: Medium  
**Rationale**: The practical impact is that callers of `getOverlappingRangeDeletionsFuture` may believe a range is clean while a re-execution is in progress on the new primary. This is a transient inconsistency window. TLA+ can characterize exactly when callers can see an active task for a range whose prior completion future has already resolved.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Majority-wait step as a non-atomic action that can be interrupted | Family 1 — this is the load-bearing mechanism; its correctness under step-down must be verified | Split `deleteOrphans + majorityWait + removeTaskDoc` into 3 separate TLA+ actions |
| Node role (primary/secondary) and step-up/step-down transitions | Families 1, 2, 3 — all bugs are triggered by role changes | Model `nodeRole ∈ {Primary, Secondary}` with `StepUp` and `StepDown` actions |
| Persistent disk state (`config.rangeDeletions`) vs. in-memory task registry | Families 2, 3 — the protocol's correctness relies on disk being the authoritative source that recovery always faithfully reads | Two separate variables: `diskTasks` (map) and `inMemoryTasks` (map) |
| Two-phase recovery scan with interleaved op_observer registrations | Family 2 — the atomic unit of recovery is not the full scan; tasks can be registered mid-scan | Model recovery as two distinct scan steps, with op_observer events allowed between them |
| `pending` flag lifecycle (set on migration start, unset on commit) | Family 2 — recovery skips `pending=true` tasks; tasks transitioning during recovery are the gap to check | Three task states: `pending`, `ready`, `processing` |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| `orphanCleanupDelaySecs` timer-based secondary read drain | Time-based heuristic, not a protocol guarantee; not expressible as a safety invariant without real-time modeling |
| `numOrphanDocs` counter accuracy | Acknowledged as potentially off during deletion (code comment, range_deleter_service.cpp:233-237); best-effort metric, not correctness-critical |
| `remainingJobCount` int8_t overflow | Implementation artifact (only 1 recovery job ever registered per term in practice); not a protocol-level concern |
| `MONGO_MOD_NEEDS_REPLACEMENT` API surface | Refactoring flags; no protocol impact |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-atomic completion | `completionFulfilled`, `diskDocExists` | Expose crash window between `markComplete` and `removePersistentTask` | Family 3 |
| Two-phase recovery scan | `recoveryPhase ∈ {idle,phase1,phase2,done}` | Model gap between phases where op_observer and scan interact | Family 2 |
| Step-down interrupt point | `interruptedAfterOrphansDeleted` | Allow crash after orphan deletion but before majority wait completes | Family 1 |
| Majority-wait outcome | `majorityWaitOutcome ∈ {success,interrupted}` | Non-deterministic majority wait result under step-down | Family 1 |
| Task `processingState ∈ {pending,ready,processing,complete}` | `taskState[task]` | Full lifecycle including `processing` flag for recovery ordering | Families 1, 2 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `OrphanDeletionBeforeTaskDocRemoval` | Safety | For every replica, the oplog entry removing `config.rangeDeletions[task]` is never applied before the oplog entry deleting orphan documents for that task | Family 1 |
| `RecoveryCompleteness` | Liveness | After any sequence of step-up/step-down, every `ready` (non-pending) task on disk is eventually executed | Family 2 |
| `CompletionFutureImpliesMajorityOrphans` | Safety | When the completion future for task T resolves, orphan documents for T are committed on a majority of replicas | Family 1 |
| `NoLostTasks` | Liveness | A task that reaches `pending=false` state on disk is eventually either executed or its collection is dropped | Families 2, 3 |
| `NoDuplicateActiveExecution` | Safety | At any point in time, at most one primary is actively deleting orphans for a given (collectionUUID, range) | Family 1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | If step-down fires after orphan batch deletions are written but before the majority wait returns, does the next primary's re-execution guarantee that secondaries never serve a window where the task document is absent but orphan docs are still present? | `OrphanDeletionBeforeTaskDocRemoval` under concurrent step-down + secondary lag | Family 1 |
| MC2 | Can a task whose `pending=false` write commits between phase 1 and phase 2 of the recovery scan, and whose op_observer fires BEFORE `_termInitializationPromise` is set, be permanently missed across repeated step-up/step-down cycles? | `RecoveryCompleteness` under tight step-up timing | Family 2 |
| MC3 | After `completeTask` fulfills the completion future but before `removePersistentTask` removes the disk document, if step-down fires: does the new primary's re-execution preserve `CompletionFutureImpliesMajorityOrphans` for callers who already received the fulfilled future? | `CompletionFutureImpliesMajorityOrphans` under non-atomic completion | Family 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | `removePersistentTask` fails after `completeTask`: verify disk document orphan is cleaned on next step-up | Integration test: inject write failure before `removePersistentTask`, force step-down, step-up, verify document eventually absent |
| TV2 | Double `clearPending()` on same `RangeDeletion` object (op_observer + recovery scan both call `registerTask` for same task): verify idempotency | Unit test: call `registerTask` twice for same task, verify `kJoinedExistingTask`, verify single chain executed |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `dassert(_state == kDown)` at `range_deleter_service.cpp:141` uses debug-only assertion; in release builds, double step-up overwrites state without check | Promote to `invariant` or add release-mode guard |
| CR2 | `_activeTerm = _recoveryState.notifyStartOfTerm(term)` at line 138 runs without `_mutex` held while `_activeTerm.reset()` (in `_stopService`) runs under `_mutex` — asymmetric locking | Audit thread-safety assumptions; add `WithLock` annotation or document why replication coordinator guarantees single-threaded step-up |
| CR3 | `onStepUpBegin` emplaces `_termInitializationPromise` and `_serviceUpPromise` without holding any lock relative to `registerRecoveryJob(term)` at line 128 — two operations that should be atomic | Consider combining into one locked section |

---

## 7. Reference Pointers

**Key source files**:
- `src/mongo/db/s/range_deleter_service.cpp` — main service lifecycle, state machine, task registration (530 LOC)
- `src/mongo/db/s/range_deleter_service.h` — service interface, state enum, mutex access patterns (233 LOC)
- `src/mongo/db/s/ready_range_deletions_processor.cpp` — the actual deletion loop with majority wait (406 LOC)
- `src/mongo/db/s/range_deletion_recovery_tracker.cpp` — term-scoped recovery promise management (162 LOC)
- `src/mongo/db/s/range_deleter_service_op_observer.cpp` — observer driving in-memory/disk sync
- `src/mongo/db/s/range_deletion_util.cpp` — `deleteRangeInBatches`, persistence helpers (850 LOC)
- `src/mongo/db/s/range_deletion.h/.cpp` — in-memory task (`RangeDeletion`), completion/pending promises
- `src/mongo/db/s/range_deletion_task.idl` — on-disk schema for `config.rangeDeletions`
- `src/mongo/db/s/README_range_deleter.md` — authoritative description of the service lifecycle

**Critical line references**:
- Majority wait: `ready_range_deletions_processor.cpp:337-339`
- completeTask before removePersistentTask: `ready_range_deletions_processor.cpp:344-347`
- `_termInitializationPromise` set before recovery: `range_deleter_service.cpp:177` (then recovery launched at :179)
- Recovery two-phase scan: `range_deleter_service.cpp:220-253`
- Op_observer secondary error swallow: `range_deleter_service_op_observer.cpp:92-101`
- State transition guard `!= kDown`: `range_deleter_service.cpp:166`
- `_stopService` atomic teardown: `range_deleter_service.cpp:283-313`
