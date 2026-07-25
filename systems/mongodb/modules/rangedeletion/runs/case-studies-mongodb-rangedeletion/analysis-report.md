# Analysis Report: MongoDB Range Deletion + Orphan Management

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Total unique bug-fix commits analyzed | 88 |
| Commits touching core range deletion files (since 2024-01-01) | 100 |
| Unique SERVER tickets found in commits | 92 |
| GitHub/Jira issues collected | 35 |
| Issues deeply read (full discussion/diff) | 19 |
| Issues confirmed as correctness bugs | 13 |
| Issues excluded as feature requests/improvements | 12 |
| Issues excluded as test-only/logging fixes | 10 |
| Core source files deeply read (full file) | 10 |
| New code analysis findings | 8 |

## Phase 1: Reconnaissance — Structural Map

### Core Modules

| Module | Files | LOC | Purpose |
|--------|-------|-----|---------|
| RangeDeleterService | range_deleter_service.h/cpp | ~770 | Service lifecycle, task registration, async scheduling |
| RangeDeletionUtil | range_deletion_util.h/cpp | ~1070 | Task persistence, batch deletion, cross-shard operations |
| ReadyRangeDeletionsProcessor | ready_range_deletions_processor.h/cpp | ~530 | Background thread for executing deletions |
| RangeDeletion | range_deletion.h/cpp | ~153 | In-memory task wrapper (promises, pending gate) |
| RangeDeletionTaskTracker | range_deletion_task_tracker.h/cpp | ~248 | In-memory registry with overlap detection |
| RangeDeletionRecoveryTracker | range_deletion_recovery_tracker.h/cpp | ~251 | Term-based recovery job tracking |
| MigrationCoordinator | migration_coordinator.h/cpp | ~780 | Commit/abort orchestration |
| OpObserver | range_deleter_service_op_observer.h/cpp | ~290 | Triggers task registration on config.rangeDeletions changes |
| CleanupOrphaned | cleanup_orphaned_cmd.cpp | ~231 | User-facing cleanupOrphaned command |

**Total core LOC**: ~4,323

### Concurrency Model

**Mutexes**:
1. `RangeDeleterService::_mutex_DO_NOT_USE_DIRECTLY` (stdx::mutex) — protects service state, task tracker, promises
2. `ReadyRangeDeletionsProcessor::_mutex` (stdx::mutex) — protects execution queue and processor state
3. `ScopedRangeDeleterLock` (ResourceMutex) — serializes range deletion execution with external operations

**Lock ordering** (verified): service-mutex → processor-mutex → Client lock. No reverse ordering found in current code.

**Threads**:
- Single-threaded executor (TaskExecutor) for future chain scheduling
- Dedicated background thread in ReadyRangeDeletionsProcessor
- Separate client threads created per batch deletion operation

**Futures/Promises** (heavily used):
- `RangeDeletion::_completionPromise` — task completion
- `RangeDeletion::_pendingPromise` — pending→ready gate
- `RangeDeleterService::_termInitializationPromise` — step-up initialization gate
- `RangeDeleterService::_serviceUpPromise` — recovery completion gate
- `ReadyRangeDeletionsProcessor::_beginProcessingSignal` — thread start gate
- `getOngoingQueriesCompletionFuture()` — active query drain barrier

### State Machines

**RangeDeleterService**: kDown → kReadyForInitialization → kInitializing → kUp → kDown
- kDown → kReadyForInit: `onStepUpComplete()` creates executor/processor
- kReadyForInit → kInitializing: `_launchRangeDeletionRecoveryTask()` starts DB scan
- kInitializing → kUp: recovery future callback completes
- {any} → kDown: `_stopService()` on step-down/shutdown

**ReadyRangeDeletionsProcessor**: kInitializing → kRunning → kStopped
- kInitializing → kRunning: `beginProcessing()` called after service reaches kUp
- kRunning → kStopped: `shutdown()` called from `_stopService()`

**Migration (MigrationSourceManager)**: kCreated → kCloning → kCloneCaughtUp → kCriticalSection → kCloneCompleted → kCommittingOnConfig → kDone
- Any state → kDone via `_cleanupOnError()`

### Data Persistence

**Collections**:
- `config.rangeDeletions` — persistent range deletion tasks (UUID-indexed)
- `config.rangeDeletionsForRename` — temporary store during collection renames

**Task document fields**: `_id` (UUID = migrationId), `nss`, `collectionUuid`, `range` {min, max}, `pending` (optional boolean), `processing` (boolean), `whenToClean` (enum: kNow, kDelayed), `numOrphanDocs`, `preMigrationShardVersion`, `timestamp`

## Phase 2: Bug Archaeology

### Deadlock Bugs (3 commits)

| Commit | Ticket | Summary | Root Cause |
|--------|--------|---------|------------|
| `9343c350ae` | SERVER-119435 | Deadlock with range deletion task registration | Equal timestamps from fastClock cause circular wait in overlap ordering; fix moved registration before async chain |
| `64488b038d` | SERVER-70888 | ScopedRangeDeleterLock deadlock on stepdown | Stepdown can't kill blocked recovery thread; fix stores opCtx for external killing |
| `29fdc94ccd` | SERVER-70034 | Deadlock on step down via majority write concern | Task removal uses majority WC which blocks during stepdown; fix uses DBDirectClient |

### Race Condition Bugs (6 commits, excluding test-only)

| Commit | Ticket | Summary | Root Cause |
|--------|--------|---------|------------|
| `eed07f04fb` | SERVER-117542 | Race in `_queue.front()` | Missing mutex on queue access in processing loop |
| `fcccb877f4` | SERVER-115921 | SharedPromise completed twice | Stepdown clears promise before recovery callback fires; fix adds `has_value()` guard |
| `12d8f741fd` | SERVER-115750 | TOCTOU in overlap check + clear without mutex | Overlap check done without lock before registration; `_rangeDeletionTasks.clear()` unprotected |
| `a740f4e58b` | SERVER-89790 | Thread-shared `_state` read without lock | State field read outside mutex during initialization; Coverity-detected |
| `289aeb5651` | SERVER-69552 | StepDown without prior StepUp | `onStepDown` fires on SECONDARY→ROLLBACK; recovery overwrites stepdown state |
| `7e09aed88d` | SERVER-81241 | Task enqueued after processor stopped | `invariant(_state == kRunning)` crashes when shutdown races with enqueue; fix converts to soft check |

### Correctness / Orphan Safety Bugs (10 commits)

| Commit | Ticket | Summary | Root Cause |
|--------|--------|---------|------------|
| `92738c5fa0` | SERVER-60142 | Overlapping deletion check not retry-safe | Single check-then-wait; metadata clear causes premature return; fix adds while loop |
| `f44581d5bf` | SERVER-63243 | Round-robin interleaving of deletions | Async yield between batches lets different tasks interleave; fix uses synchronous loop |
| `cee9c4deed` | SERVER-38050 | Collection validation TOCTOU | Metadata validated once; collection dropped/recreated; deleter operates on wrong collection |
| `d5d59422cf` | SERVER-59832 | Writes to orphan documents | Scatter-gather writes modify orphans; fix adds ownership filter in write stages |
| `cb0e706157` | SERVER-64979 | Wrong task resumes after failover | No ordering guarantee on step-up recovery; fix adds `processing` flag for priority |
| `32c2f632ea` | SERVER-67385 | Deletion starts before queries finish | `clearFilteringMetadata()` destroys MetadataManager losing query tracking |
| `df3e7c75ed` | SERVER-68660 | Registration before oplog commit | OpObserver registered task before oplog entry committed; fix defers to onCommit callback |
| `efe7818d39` | SERVER-91970 | Donor missing drain before donating | New migration starts while old deletion active on same range on donor |
| `3ed974c923` | SERVER-60518 | Best-effort check abandons orphans | TOCTOU: metadata check outside lock, then cleared, causing permanent orphan persistence |
| `cae95e4429` | SERVER-69586 | Non-idempotent cross-shard operations | Retry deletes/updates new migration's task; fix adds migrationId to query filter |

### Shutdown/Stepdown Safety Bugs (6 commits)

| Commit | Ticket | Summary |
|--------|--------|---------|
| `31120c1c58` | SERVER-69886 | Major rewrite of range deleter service shutdown handling |
| `71a5942993` | SERVER-70094 | Synchronize shutdown with resuming of range deletions |
| `de6eb37f32` | SERVER-70964 | Do not wait for range deletion thread on stepdown |
| `ba892872f9` | SERVER-112357 | moveChunk with waitForDelete hangs when range deleter disabled |
| `1ab9c22972` | SERVER-70003 | Alternative client for deletion must be interruptible on stepdown |
| `df3e7c75ed` | SERVER-68660 | Register after oplog commit (also in correctness category) |

### Bug Hotspot Analysis

| File | Bug-fix commits | Categories |
|------|----------------|------------|
| range_deleter_service.cpp | 15 | deadlock(2), race(5), shutdown(4), lifecycle(4) |
| range_deletion_util.cpp | 8 | correctness(4), deadlock(1), error handling(3) |
| migration_coordinator.cpp | 3 | idempotency(1), orphan safety(2) |
| ready_range_deletions_processor.cpp | 3 | race(1), shutdown(1), correctness(1) |
| migration_destination_manager.cpp | 2 | overlap(1), orphan(1) |
| migration_source_manager.cpp | 1 | overlap drain(1) |

**`range_deleter_service.cpp` is by far the most bug-dense file**, with 15 bug-fix commits spanning deadlocks, races, and shutdown safety.

## Phase 3: Deep Analysis — New Findings

### Finding #1: Asymmetric migrationId Filtering (range_deletion_util.cpp:702 vs 677)

`deleteRangeDeletionTaskLocally()` at line 702-708 queries by `(collectionUuid, range.min, range.max)` WITHOUT `migrationId`. `deleteRangeDeletionTaskOnRecipient()` at line 677-693 deliberately includes `migrationId` with an explicit comment (line 320-322) explaining this prevents deleting tasks from future migrations.

**Risk**: If a new migration creates a task for the same range before the old local delete runs, the old delete could remove the new task, leaving orphans from the new migration unpersisted.

**Compensating mechanism**: The single-threaded executor serializes overlapping deletions, so in practice the old task completes before a new one is registered for the same range. However, step-down/step-up could break this serialization.

**Classification**: Model-checkable (MC-6)

### Finding #2: TOCTOU in persistRangeDeletionTaskLocally (range_deletion_util.cpp:607-620)

When `doNotPersistIfDocCoveringSameRangeAlreadyExists=true`, the function does `count()` then `add()` — two separate operations with no lock held. A concurrent insertion for the same range could slip between them. The DuplicateKey catch at line 621 only guards the `_id` field, not range bounds.

**Risk**: Two documents for the same range with different `_id`s could be created.

**Compensating mechanism**: The `_id` is the migrationId (UUID), so only one task per migration can exist. Two different migrations for the same range would have different `_id`s, but the overlap check in `registerTask()` prevents concurrent execution.

**Classification**: Test-verifiable (TV-2)

### Finding #3: Silent Infinite Retry in deleteRangeInBatches (range_deletion_util.cpp:420-434)

Non-fatal errors in the batch deletion loop are silently retried with no backoff, no logging, and no retry limit. Any `DBException` whose code doesn't match the explicit fatal list causes the loop to silently retry forever.

**Risk**: A persistent but non-fatal error (e.g., storage corruption) would cause an infinite retry loop with no visible signal.

**Classification**: Test-verifiable (TV-3)

### Finding #4: Single-Threaded Executor Assumption (range_deletion_util.cpp:253-254)

A code comment explicitly states that the safety of `ensureRangeDeletionTaskStillExists` relies on "the executor only having a single thread." If the executor is ever changed to multi-threaded, this safety invariant breaks silently.

**Risk**: Architectural assumption documented only in a comment. No runtime assertion.

**Classification**: Code-review-only (CR-2)

### Finding #5: Non-Atomic Delete + Orphan Count Update (range_deletion_util.cpp:382-398)

Document deletion (line 382-383) and orphan count decrement (line 398) are separate operations. Crash between them permanently overstates the orphan count.

**Risk**: Metadata inconsistency (not data loss). Orphan count used for diagnostics and balancer decisions.

**Compensating mechanism**: None visible. The count can only drift upward (over-counting), never downward.

**Classification**: Test-verifiable (TV-4)

### Finding #6: Header/Implementation Mismatch in deleteRangeDeletionTasksForRename (range_deletion_util.cpp:522-532)

The header comment says it deletes from both `config.rangeDeletions` (FROM namespace) and `config.rangeDeletionsForRename` (TO namespace). The implementation only deletes from `rangeDeletionsForRename`.

**Risk**: Either stale comment or missing deletion of FROM namespace tasks.

**Classification**: Code-review-only (CR-1)

### Finding #7: Processor Queue Not Drained on Shutdown (range_deleter_service.cpp:312)

`_stopService()` clears `_rangeDeletionTasks` (in-memory tracker) but does NOT clear the processor's `_queue`. The processor thread is killed via opCtx interrupt, but tasks in the queue are silently lost. Recovery on next step-up re-registers from persistent store.

**Risk**: None in practice (idempotent recovery), but the asymmetry between tracker and queue cleanup is a maintenance hazard.

**Classification**: Code-review-only (architectural)

### Finding #8: _joinAndResetState Called Without Lock (range_deleter_service.cpp:137)

`onStepUpComplete()` calls `_joinAndResetState()` without holding the service mutex. This function accesses `_executor`, `_readyRangeDeletionsProcessorPtr`, and `_rangeDeletionTasks`. Safety relies on serialization by the replication layer (only one step-up at a time).

**Risk**: If any future code path calls `_joinAndResetState` outside the replication layer's serialization, it would be unsafe.

**Classification**: Code-review-only (architectural)

## Phase 4: Bug Family Summary

### Family 1: Service Lifecycle / Step-Up/Step-Down Races — 8 historical bugs
SERVER-119435, SERVER-115921, SERVER-115750, SERVER-89790, SERVER-70888, SERVER-69552, SERVER-81241, SERVER-70034

### Family 2: Migration-Deletion Ordering / Overlap Races — 5 historical bugs
SERVER-91970, SERVER-60142, SERVER-64979, SERVER-63243, SERVER-119435 (overlap)

### Family 3: Metadata Lifecycle / Query Safety — 4 historical bugs
SERVER-67385, SERVER-68660, SERVER-59832, SERVER-38050

### Family 4: Cross-Shard Task Identity / Idempotency — 2 historical bugs + 1 new finding
SERVER-69586, SERVER-60518, Finding #1 (asymmetric migrationId)

### Family 5: Non-Atomic Persistence / Orphan Count Drift — 0 historical bugs, 2 new findings
Finding #5 (non-atomic delete + count), Finding #7 (processor queue not drained)

## Excluded Issues (False Positives / Out of Scope)

| Ticket | Reason for Exclusion |
|--------|---------------------|
| SERVER-94559 | Time-series bucket code, not range deletion protocol |
| SERVER-120165 | Task (re-evaluate prioritization), not a bug |
| SERVER-115667 | Test-only race condition, no production impact |
| SERVER-62368 | Batch delay not honored — performance, not correctness |
| SERVER-44092 | Orphan impact on IXSCAN — performance, not correctness |
| SERVER-23283 | Logging bug (cursor IDs) |
| SERVER-31848 | Unnecessary log verbosity |
| SERVER-30183 | waitForDelete not respected by joining moveChunk — user expectation, not data correctness |
| SERVER-29812 | Unnecessary majority write concern — performance |
| SERVER-8405 | Count including orphans — known limitation, not data loss |
