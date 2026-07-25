# Modeling Brief: MongoDB Range Deletion + Orphan Management

## 1. System Overview

- **System**: MongoDB range deletion — the subsystem that deletes orphaned documents after chunk migrations in a sharded cluster
- **Language**: C++, ~3500 LOC core logic (range_deleter_service, range_deletion_util, ready_range_deletions_processor, migration_coordinator interaction)
- **Protocol**: Range deletion task lifecycle: pending → ready → executing → completed, coordinated between donor and recipient shards with active query barriers
- **Key architectural choices**:
  - **Two-phase registration**: Tasks registered as "pending" in-memory, then made "ready" via persistent update + OpObserver callback (range_deleter_service.cpp:309-321)
  - **Future chain scheduling**: Registration builds a 5-step async chain (pending gate → service-up gate → overlap wait → query drain → enqueue), all on a single-threaded executor
  - **Separate locks for service vs processor**: `RangeDeleterService._mutex` protects task tracker + state; `ReadyRangeDeletionsProcessor._mutex` protects the execution queue — two independent critical sections
  - **Overlap serialization by timestamp**: Overlapping range deletions are serialized by registration timestamp with task-ID tiebreaker (range_deleter_service.cpp:392-426)
- **Concurrency model**: RangeDeleterService lifecycle tied to replica set step-up/step-down; single-threaded executor for future chains; dedicated background thread for batch deletion in ReadyRangeDeletionsProcessor

## 2. Bug Families

### Family 1: Service Lifecycle / Step-Up/Step-Down Races (HIGH)

**Mechanism**: The RangeDeleterService state machine (kDown → kReadyForInitialization → kInitializing → kUp → kDown) interacts with asynchronous recovery tasks and concurrent step-down events, creating interleavings where promises are completed twice, state transitions race, or deadlocks form between lifecycle operations.

**Evidence**:
- Historical: SERVER-119435 — Deadlock: equal default timestamps create circular wait in overlap ordering (range_deleter_service.cpp, Feb 2026)
- Historical: SERVER-115921 — SharedPromise completed twice: stepdown clears promise before recovery callback fires (range_deleter_service.cpp, Dec 2025)
- Historical: SERVER-115750 — TOCTOU: overlap check done without lock before task registration; `_rangeDeletionTasks.clear()` without mutex (range_deleter_service.cpp, Dec 2025)
- Historical: SERVER-70888 — Deadlock: stepdown can't kill blocked recovery thread holding ScopedRangeDeleterLock (range_deleter_service.cpp)
- Historical: SERVER-69552 — StepDown fires without prior StepUp (SECONDARY→ROLLBACK); recovery overwrites stepdown state (range_deleter_service.cpp)
- Historical: SERVER-81241 — Task enqueued after processor stopped crashes with invariant violation (range_deleter_service.cpp)
- Historical: SERVER-89790 — Coverity: thread-shared `_state` field read without lock during initialization check (range_deleter_service.cpp)
- Historical: SERVER-70034 — Deadlock: majority write concern in task removal blocks forever during stepdown (range_deletion_util.cpp)

**Affected code paths**:
- `RangeDeleterService::onStepUpComplete()`, `_stopService()`, `_launchRangeDeletionRecoveryTask()`
- `RangeDeleterService::registerTask()` async future chain (5 steps)
- `ReadyRangeDeletionsProcessor::emplaceRangeDeletion()`, `shutdown()`

**Suggested modeling approach**:
- Variables: `serviceState ∈ {kDown, kReadyForInit, kInitializing, kUp}`, `recoveryRunning ∈ BOOLEAN`, `processorState ∈ {kInit, kRunning, kStopped}`
- Actions: `StepUp` (two phases: begin + complete), `StepDown`, `RecoveryComplete`, `RegisterTask`, `EnqueueToProcessor`, `ProcessorShutdown`
- Model nondeterministic interleaving of stepdown with recovery completion, and stepdown with in-flight future chain steps
- Timestamp equality: model clock that can return same value for consecutive reads

**Priority**: High
**Rationale**: 8 historical bugs in 2 years, all sharing the same lifecycle state machine. 3 deadlocks, 3 races, 1 crash. The state machine has only 4 states but the async recovery + concurrent stepdown creates a rich interleaving space ideal for TLA+ exploration.

---

### Family 2: Migration-Deletion Ordering / Overlap Races (HIGH)

**Mechanism**: Range deletion tasks from successive migrations on the same range can overlap in time. The ordering of drain-before-migrate, complete-before-start-next, and resume-in-progress-first-after-failover invariants have been repeatedly violated.

**Evidence**:
- Historical: SERVER-91970 — Donor side missing drain: new migration donates data while old range deletion is still running (migration_source_manager.cpp, 2024)
- Historical: SERVER-60142 — Check-then-wait not retry-safe: recipient proceeds after `waitForClean` returns prematurely when metadata is cleared (migration_destination_manager.cpp)
- Historical: SERVER-64979 — After failover, partially-completed task not resumed first; new task processed before old one finishes (range_deletion_util.cpp)
- Historical: SERVER-63243 — Round-robin interleaving: async yield between batches lets different ranges interleave on single-threaded executor (range_deletion_util.cpp)
- Code analysis: range_deleter_service.cpp:392-426 — overlap serialization relies on timestamp ordering with task-ID tiebreaker; SERVER-119435 showed equal timestamps break this

**Affected code paths**:
- `MigrationSourceManager` constructor drain loop (migration_source_manager.cpp:337-369)
- `MigrationDestinationManager` drain loop
- `RangeDeleterService::registerTask()` overlap wait (range_deleter_service.cpp:385-426)
- `ReadyRangeDeletionsProcessor::_runRangeDeletions()` batch loop

**Suggested modeling approach**:
- Variables: `rangeDeletionTasks ∈ [TaskId → {range, status, migrationId, registrationTime}]`, `activeMigrations ∈ [Range → MigrationState]`
- Actions: `StartMigration(range)`, `CommitMigration(range)`, `AbortMigration(range)`, `RegisterDeletionTask`, `WaitForOverlap`, `ExecuteDeletion`, `CompleteDeletion`
- Model two successive migrations on the same range with nondeterministic failover between them
- Granularity: split deletion into register → drain-overlaps → execute → complete

**Priority**: High
**Rationale**: 5 historical bugs, including a 2024 fix (SERVER-91970) showing the donor side was missing a fundamental safety check. The overlap ordering is the core protocol-level concern, directly expressible in TLA+.

---

### Family 3: Metadata Lifecycle / Query Safety (HIGH)

**Mechanism**: The MetadataManager tracks which queries are reading which ranges. When metadata is cleared or refreshed, the ongoing-queries tracking can be destroyed, causing range deletion to proceed while queries are still active. The timing of when the ongoing-queries future is captured relative to oplog commit is critical.

**Evidence**:
- Historical: SERVER-67385 (P2) — `clearFilteringMetadata()` destroyed MetadataManager, losing ongoing query tracking; new MetadataManager had no knowledge of prior queries (collection_sharding_runtime)
- Historical: SERVER-68660 — OpObserver registered range deletion task before oplog commit; ongoing-queries future not yet valid (range_deleter_service_op_observer.cpp)
- Historical: SERVER-59832 — Writes to orphan documents: scatter-gather writes modify orphans on donor during deletion window (write_stage_common)
- Historical: SERVER-38050 — TOCTOU: range deleter validates collection metadata once, then collection is dropped and recreated; deleter operates on wrong collection (collection_range_deleter.cpp)

**Affected code paths**:
- `CollectionShardingRuntime::clearFilteringMetadata()`, `setFilteringMetadata()`
- `MetadataManager::getOngoingQueriesCompletionFuture()`
- `RangeDeleterServiceOpObserver::registerTaskWithOngoingQueriesOnOpLogEntryCommit()`
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient()` lines 297-311

**Suggested modeling approach**:
- Variables: `activeQueries ∈ [QueryId → {range, metadataVersion}]`, `metadataState ∈ {known, unknown, refreshing}`, `ongoingQueriesFuture ∈ [Range → {resolved, pending}]`
- Actions: `StartQuery(range)`, `EndQuery(range)`, `ClearMetadata`, `RefreshMetadata`, `CaptureOngoingQueriesFuture`, `RangeDeletionProceeds`
- Key: model the window between capturing the future and the actual deletion; new queries starting after capture but before deletion

**Priority**: High
**Rationale**: SERVER-67385 was P2 (critical). The interaction between metadata lifecycle, query tracking, and range deletion scheduling is the most safety-critical aspect. A query reading partially-deleted data is a correctness violation visible to users.

---

### Family 4: Cross-Shard Task Identity / Idempotency (MEDIUM)

**Mechanism**: Range deletion task documents are managed across shards (donor and recipient). Operations to create, delete, or update these documents must be idempotent under network retries and must correctly identify which migration's task they target. Asymmetries in query filters between local and remote paths cause incorrect task identification.

**Evidence**:
- Historical: SERVER-69586 — Non-idempotent delete/update on recipient: retry of old command modifies new migration's task (migration_coordinator.cpp, migration_util.cpp)
- Historical: SERVER-60518 — TOCTOU: metadata check outside lock, then metadata cleared, causing task document to be abandoned with orphans persisting (migration_util.cpp)
- Code analysis: `deleteRangeDeletionTaskLocally` (range_deletion_util.cpp:702-708) does NOT include `migrationId` in query filter, while `deleteRangeDeletionTaskOnRecipient` (range_deletion_util.cpp:677-693) deliberately does — asymmetric safety
- Code analysis: `persistRangeDeletionTaskLocally` (range_deletion_util.cpp:607-620) has check-then-insert TOCTOU — `count()` then `add()` not atomic

**Affected code paths**:
- `rangedeletionutil::deleteRangeDeletionTaskLocally()` vs `deleteRangeDeletionTaskOnRecipient()`
- `rangedeletionutil::persistRangeDeletionTaskLocally()`
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient()`, `_abortMigrationOnDonorAndRecipient()`

**Suggested modeling approach**:
- Variables: `taskDocs ∈ [DocId → {collUUID, range, migrationId, pending}]`, `networkRetries ∈ Nat`
- Actions: `CreateTask`, `DeleteTaskLocally`, `DeleteTaskOnRecipient`, `MarkReadyLocally`, `MarkReadyOnRecipient`, `NetworkRetry`
- Model: two successive migrations for the same range; the first migration's abort/commit retry hitting the second migration's task document

**Priority**: Medium
**Rationale**: SERVER-69586 was a confirmed bug with a clear fix. The asymmetric `migrationId` filtering in local vs remote paths (Finding #2 from deep analysis) is a potential latent issue. Well-suited for TLA+ since it's about protocol-level identity and idempotency.

---

### Family 5: Non-Atomic Persistence / Orphan Count Drift (LOW)

**Mechanism**: Multi-step persistence operations (delete documents then update orphan count; delete task document then complete in-memory) have crash windows where partial completion leaves inconsistent state.

**Evidence**:
- Code analysis: range_deletion_util.cpp:382-398 — document deletion and orphan count decrement are separate operations; crash between them permanently overstates orphan count
- Code analysis: ready_range_deletions_processor.cpp:344-348 — `completeTask()` removes in-memory task before `removePersistentTask()` deletes disk document; crash between leaves stale persistent task
- Code analysis: range_deletion_util.cpp:358-360 — `ensureRangeDeletionTaskStillExists` + `markRangeDeletionTaskAsProcessing` are separate operations with a window between them

**Affected code paths**:
- `deleteRangeInBatches()` batch loop
- `ReadyRangeDeletionsProcessor::_runRangeDeletions()` completion sequence

**Suggested modeling approach**:
- Variables: `orphanCount ∈ Nat`, `persistedTask ∈ BOOLEAN`, `inMemoryTask ∈ BOOLEAN`
- Actions: `DeleteBatch`, `UpdateOrphanCount`, `Crash`, `Recover`
- Model crash between multi-step operations and verify recovery correctness

**Priority**: Low
**Rationale**: The orphan count drift is a metadata inconsistency (not data loss). The stale persistent task is recovered idempotently on step-up. These are real but low-severity compared to Families 1-3. TLA+ crash modeling is well-suited but lower priority.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Service lifecycle state machine | Family 1: root cause of 8 bugs | State variable with nondeterministic StepUp/StepDown/RecoveryComplete interleaving |
| Overlap serialization with timestamps | Family 1+2: SERVER-119435 deadlock from equal timestamps | Registration timestamp variable; model clock returning duplicate values |
| Migration → deletion ordering | Family 2: 5 bugs from missing/incorrect ordering | Two concurrent migrations on same range; task states track per-migration identity |
| Ongoing-queries barrier | Family 3: SERVER-67385 P2 critical | Active query set + metadata state; capture future timing relative to metadata refresh |
| Cross-shard task identity | Family 4: asymmetric migrationId filtering | Task documents with migrationId; model retry of old operation hitting new task |
| Two-phase registration (pending → ready) | Families 1+3: the pending/ready split is where races concentrate | Split registerTask into pending-registration + clearPending steps |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Actual document deletion batching | Performance concern, not protocol safety. Single "delete range" action suffices. |
| Orphan count tracking | Family 5: metadata drift, not data loss. Low priority. |
| Secondary-side range deletion | Already covered by existing `RangeDeletionsSecondaryNodes.tla` (187 lines). |
| Write concern mechanics | Family 1 (SERVER-70034): internal MongoDB replication detail, not protocol logic. |
| Index validation / shard key lookup | Implementation detail: range deleter stops on missing index, not a protocol issue. |
| Balancer policy decisions | Which chunks to move is orthogonal to range deletion correctness. |
| Time-series specific behavior | SERVER-94559 is in time-series bucket code, not range deletion protocol. |
| Collection rename range deletion | Specialized rename-related task snapshotting (range_deletion_util.cpp:440-530). |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Service lifecycle | `serviceState`, `recoveryRunning`, `processorState` | Model step-up/step-down races with async recovery | Family 1 |
| Registration timestamps | `registrationTime[task]`, `clock` | Model overlap ordering and equal-timestamp deadlock | Family 1, 2 |
| Migration state | `migrationState[range] ∈ {idle, cloning, committed, aborted}` | Model migration lifecycle interacting with deletion | Family 2 |
| Task pending/ready | `taskPending[task] ∈ BOOLEAN` | Two-phase registration | Family 1, 3 |
| Active queries | `activeQueries ∈ SUBSET (Query × Range)`, `ongoingFutureCaptured[range]` | Track query barrier for deletion safety | Family 3 |
| Metadata state | `metadataKnown ∈ BOOLEAN` | Model clear/refresh lifecycle affecting query tracking | Family 3 |
| Task identity | `taskMigrationId[task]` | Distinguish tasks from different migrations on same range | Family 4 |
| Processor queue | `processorQueue ∈ Seq(Task)` | Model enqueue-after-shutdown and queue ordering | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoOrphanedRangeDeletion | Safety | Range deletion task never scheduled while migration is still cloning for the same range | Family 2 |
| NoDataLoss | Safety | Range deletion never deletes documents currently owned by this shard (not orphans) | Family 3 |
| NoTaskDeadlock | Safety | No circular dependency in overlap wait graph (no two tasks each waiting on the other) | Family 1 |
| QueryNotAffected | Safety | Active queries on a range complete before any documents in that range are deleted | Family 3 |
| DrainBeforeDonate | Safety | New migration does not begin donating while old range deletion for same range is executing | Family 2 |
| ResumeInProgressFirst | Safety | After failover, the in-progress deletion task resumes before any other task for the same collection | Family 2 |
| TaskIdentityCorrect | Safety | Cross-shard task operations (delete, markReady) only affect the correct migration's task document | Family 4 |
| ServiceStateConsistency | Safety | Service never transitions to kUp while stepdown is in progress | Family 1 |
| MigrationAbortCleansUp | Liveness | After migration abort, recipient's orphaned documents are eventually deleted | Family 2, 4 |
| OverlapSerializationTotal | Safety | At most one range deletion task executes at a time for any set of overlapping ranges | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Equal registration timestamps with overlapping ranges create circular wait in overlap ordering | NoTaskDeadlock | 1 |
| MC-2 | StepDown during recovery can leave service in kUp if recovery callback fires after stopService resets state | ServiceStateConsistency | 1 |
| MC-3 | New migration donating data while old range deletion still executing on same range | DrainBeforeDonate | 2 |
| MC-4 | After failover with two pending tasks, wrong task (unstarted) resumes before partially-completed one | ResumeInProgressFirst | 2 |
| MC-5 | Metadata clear destroys ongoing-queries tracking; range deletion proceeds while queries active | QueryNotAffected | 3 |
| MC-6 | Network retry of old migration's abort command deletes new migration's task document (local path lacks migrationId filter) | TaskIdentityCorrect | 4 |
| MC-7 | Task enqueued to processor after processor stopped but before service state updated to kDown | OverlapSerializationTotal | 1 |
| MC-8 | Check-then-wait for overlapping tasks returns prematurely when metadata cleared; migration proceeds into range with active deletion | NoOrphanedRangeDeletion | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `deleteRangeDeletionTaskLocally` missing migrationId filter — can delete wrong task | Unit test: create two tasks with same range but different migrationId, delete by range, verify wrong one removed |
| TV-2 | `persistRangeDeletionTaskLocally` TOCTOU — concurrent insert between count() and add() | Concurrency test with failpoint between count and add |
| TV-3 | Silent infinite retry in `deleteRangeInBatches` on persistent non-fatal errors | Unit test: inject persistent error not in fatal list, verify no infinite loop |
| TV-4 | Non-atomic delete + orphan count update — crash between leaves overstated count | Kill test: crash process between deleteNextBatch and persistUpdatedNumOrphans |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `deleteRangeDeletionTasksForRename` implementation doesn't match header comment (missing FROM namespace deletion from config.rangeDeletions) | Verify with maintainers whether comment is stale or implementation incomplete |
| CR-2 | `ensureRangeDeletionTaskStillExists` safety depends on single-threaded executor (documented in comment at range_deletion_util.cpp:253-254) | Architectural review: add runtime assertion if executor thread count changes |
| CR-3 | `_readyRangeDeletionsProcessorPtr` is public member on RangeDeleterService (range_deleter_service.h:195) | Review encapsulation — exposed for testing but allows external mutation |
| CR-4 | `_nRescheduledTasks` log counts only "processing" tasks, not total recovered tasks (range_deleter_service.cpp:233,258) | Minor logging fix |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-rangedeletion/analysis-report.md`
- **Key source files**:
  - `src/mongo/db/s/range_deleter_service.cpp` (~540 lines) — service lifecycle, registerTask, completeTask
  - `src/mongo/db/s/range_deleter_service.h` (~230 lines) — state machine, mutex helpers
  - `src/mongo/db/s/range_deletion_util.cpp` (~850 lines) — task persistence, batch deletion, utility functions
  - `src/mongo/db/s/ready_range_deletions_processor.cpp` (~406 lines) — background deletion thread
  - `src/mongo/db/s/migration_coordinator.cpp` (~580 lines) — commit/abort orchestration
  - `src/mongo/db/s/range_deleter_service_op_observer.cpp` (~210 lines) — OpObserver triggers
  - `src/mongo/db/s/range_deletion_task_tracker.cpp` (~124 lines) — in-memory task registry
- **GitHub/Jira issues**: SERVER-119435, SERVER-115921, SERVER-115750, SERVER-91970, SERVER-67385, SERVER-68660, SERVER-69586, SERVER-60142, SERVER-60518, SERVER-64979, SERVER-38050, SERVER-59832
- **Existing TLA+ spec**: `RangeDeletionsSecondaryNodes.tla` (187 lines, secondary only — does not cover primary-side lifecycle)
- **README**: `src/mongo/db/s/README_migrations.md` — migration lifecycle documentation
