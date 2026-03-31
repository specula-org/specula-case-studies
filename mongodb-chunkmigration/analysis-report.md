# Analysis Report: MongoDB Chunk Migration (Full Donor ↔ Recipient Flow)

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Core files fully read | 4 (source_manager, dest_manager, coordinator, range_deletion_util) |
| Supporting files read | 5 (migration_util, active_migrations_registry, cloner_source.h, READMEs, IDL) |
| Bug-fix commits analyzed (by keyword) | 200+ across 12 keyword searches |
| Unique JIRA tickets collected | 87 |
| Commits deeply analyzed (full diff) | 14 |
| Existing TLA+ specs reviewed | 3 (MoveRange, TxnsMoveRange, RangeDeletionsSecondaryNodes) |
| File hotspots identified | 7 files ranked by commit frequency |

## Phase 1: Reconnaissance Summary

### Core Architecture

**Donor (MigrationSourceManager)**: 7-state state machine (kCreated → kCloning → kCloneCaughtUp → kCriticalSection → kCloneCompleted → kCommittingOnConfig → kDone). Registered on CollectionShardingRuntime (CSR) via ScopedRegisterer. Coordinates with MigrationCoordinator for persistence and recovery.

**Recipient (MigrationDestinationManager)**: 10-state state machine (kReady → kClone → kCatchup → kSteady → kCommitStart → kEnteredCritSec → kExitCritSec → kDone / kFail / kAbort). Singleton per shard. Runs migration on dedicated thread (`_migrateThread`). State protected by `_mutex` with `_stateChangedCV` condition variable.

**Coordinator (MigrationCoordinator)**: Persists migration state to `config.migrationCoordinators`. Creates donor-side range deletion task at start. On commit: deletes recipient task, marks donor task ready. On abort: deletes donor task, marks recipient task ready.

**Range Deletion**: Tasks stored in `config.rangeDeletions`. RangeDeleterService manages in-memory tracking and scheduling. Overlapping tasks are serialized by registration time. Recovery on step-up re-registers all non-pending tasks.

### File Hotspot Analysis

| File | Total Commits | Bug Density |
|------|--------------|-------------|
| migration_destination_manager.cpp | 425 | Highest — deadlocks, races, recovery |
| migration_source_manager.cpp | 391 | High — critical section, stale data |
| range_deletion_util.cpp | 158 | High — ordering, filtering, orphans |
| range_deleter_service.cpp | 94 | Medium-High — races, deadlocks |
| migration_coordinator.cpp | 74 | Medium — commit protocol |
| migration_chunk_cloner_source.cpp | 70 | Low-Medium — data transfer |
| active_migrations_registry.cpp | 63 | Low — concurrency control |

### Concurrency Model

- **Donor**: Migration runs on the thread that initiated moveChunk. CSR lock (shared/exclusive) protects registration. No dedicated mutex on MigrationSourceManager (added in SERVER-84625 only for `_args` and `_cloneDriver`).
- **Recipient**: Dedicated `_migrateThread` runs clone/catchup/steady/commit. `_mutex` protects all shared state. External RPCs (`startCommit`, `abort`, `exitCriticalSection`) acquire `_mutex` and use `_stateChangedCV` to coordinate.
- **Recovery**: Async tasks on `FixedExecutor` pool. Step-up spawns `asyncRecoverMigrationUntilSuccessOrStepDown` per unfinished coordinator doc.

### What Existing MoveRange.tla Covers vs Gaps

**Covered**:
- Single-key routing model with placement versions
- 6-state migration (Unset → Cloning → RecipientPrepared → AllPrepared → ConfigShardCommitted → RecipientCommitted)
- Abort at 3 states (before ConfigShardCommitted)
- Query routing with stale version detection and retry
- Timestamp-based ownership filtering
- Async range deletion (DeleteRange action)

**NOT Covered (Our Target)**:
- Full data transfer lifecycle (batch cloning, catch-up, steady-state polling)
- Crash and recovery of donor/recipient
- Concurrent migrations for overlapping ranges
- Range deletion task lifecycle (create/delete/markReady with migrationId concerns)
- Critical section acquisition timeout vs commit protocol race
- Step-up recovery ordering
- Non-atomic commit sub-steps

## Phase 2: Bug Archaeology — Grouped by Family

### Family 1: Missing migrationId Filtering (Donor-Side)

**Root Cause**: `getQueryFilterForRangeDeletionTask` (range_deletion_util.cpp:312-318) matches only `(collectionUuid, range)`. Used by `deleteRangeDeletionTaskLocally`, `markAsReadyRangeDeletionTaskLocally`, `getRangeDeletionTask`, `persistUpdatedNumOrphans`. Recipient-side equivalents ALL include migrationId (explicitly documented at line 320-322).

**Historical Context**:
- SERVER-69555 established the policy of referring to range deletions by `(collUuid, range)` rather than migrationId — creating this asymmetry
- SERVER-64264 made migrationId non-optional in the range deleter, but local operations still don't filter by it

**Impact Scenario**: Migration M1 crashes mid-commit. M2 starts for same range. M1 recovery executes `getRangeDeletionTask(collUuid, range)` → finds M2's task → marks it ready or deletes it prematurely.

### Family 2: Non-Atomic Commit/Abort Protocol

**Historical Bugs**:
- SERVER-32593: Stepdown after failed moveChunk commit → `fassert` crash. Fix: detect stepdown, clear metadata, throw non-fatal error.
- SERVER-62580: Donor told recipient to exit critical section before confirming commit success. Fix: move release call after commit status check.
- SERVER-45752: opCtx interruption during critical section commit triggers `fassert`. Fix: graceful handling.

**Code Analysis Findings**:
- Critical section released at source_manager.cpp:926 BEFORE `completeMigration` at line 970
- `forgetMigration` uses w:1 write concern (coordinator.cpp:400), enabling re-execution on failover
- `_cleanup(false)` path (after ambiguous config commit) skips coordinator completion entirely

### Family 3: Critical Section Lifecycle

**Historical Bugs**:
- SERVER-66825: Deadlock on onStepDown — held `_mutex` while acquiring storage locks. Fix: release mutex before storage operations.
- SERVER-116089: Added lock acquisition timeouts to recipient critical section.
- SERVER-121372: Made critical section operations non-deprioritizable.

**Code Analysis Findings**:
- Recipient: If startCommit() times out (convergenceTimeout exceeded) and sets state to kFail, but migrateThread has already acquired critical section and persisted recovery document, the thread waits on `_canReleaseCriticalSectionPromise` forever. Only escape is stepdown/restart, and recovery re-acquires the critical section.
- Recovery path: Unconditionally sets kEnteredCritSec at dest_manager.cpp:1929 without checking for concurrent abort.

### Family 4: Step-Up Recovery Ordering

**Historical Bugs**:
- SERVER-49508: Lock ordering deadlock between migration recovery and prepared transaction. Fix: downgraded collection lock from MODE_X to MODE_IX.
- SERVER-48883: Range deletion recovery invalidated migration recovery metadata. Fix: bounded retry loop instead of infinite retry.
- SERVER-62857: Recipient recovery failed because previous migration still draining. Fix: added `waitForCompletionOfConflictingOps` parameter to `registerReceiveChunk`.
- SERVER-46756: Recovery tried to recover a migration that was still running. Fix: ensure migration drains before recovery starts.
- SERVER-48589: New migration started before recovery completed. Fix: `drainMigrationsPendingRecovery` barrier.
- SERVER-50174: MigrationCoordinator recovery must acquire MigrationBlockingGuard.
- SERVER-45744: Recovery must bump txnNumber to prevent stale _recvChunkStart.

### Family 5: Data Races

**Historical Bugs**:
- SERVER-84625: `_args` and `_cloneDriver` read by monitoring thread without lock. Fix: added `_mutex` to MSM.
- SERVER-83161: `_errMsg` read from MigrationDestinationManager without mutex. Fix: ScopeGuard pattern.
- SERVER-102264: Recovery document fields read without mutex. Fix: capture under lock, then persist.
- SERVER-71544: Race on `_sessionCatalogSource` in commit handler. Fix: null check.
- SERVER-25344: Race at MigrationDestinationManager abort. Fix: early state check before invariant.

### Additional Notable Bugs

**Range Deletion Service Races**:
- SERVER-119435: Deadlock in range deletion task registration (overlap detection outside mutex).
- SERVER-115750: Race in range deleter service (stale overlap list after stepdown).
- SERVER-115921: SharedPromise completed twice in range deleter.
- SERVER-117542: Race in accessing `_queue` in ReadyRangeDeletionsProcessor.

**Orphan Document Issues**:
- SERVER-52906: Orphaned documents in recipient not cleaned before index creation. Fix: reorder to drain first.
- SERVER-59832: Writes to orphan documents allowed. Fix: filtering in delete/update stages.
- SERVER-60518: Best-effort metadata check in range deleter could leave orphans. Fix: atomic check-and-act under lock.
- SERVER-91970: Donor didn't drain overlapping range deletions before starting. Fix: added drain loop to constructor.

**Recovery Correctness**:
- SERVER-89163: Recipient used user-supplied write concern for pre-critical-section replication. Fix: always use majority.
- SERVER-62855: Null dereference of `_sessionMigration` on recovery error. Fix: null check.

## Phase 3: Deep Analysis Findings

### MigrationSourceManager (Donor)

| # | Finding | Severity | Model-Checkable | Lines |
|---|---------|----------|-----------------|-------|
| S1 | `_cleanup` catch block doesn't set `_state = kDone` → promise gets misleading error | High | Yes | 975-993 |
| S2 | `_cleanup(false)` after ambiguous config commit skips coordinator completion; async recovery left to resolve | Critical | Yes | 681-698, 966-971 |
| S3 | Critical section released before migration decision is durable | High | Yes | 926 vs 970 |
| S4 | Constructor race: abort() can arrive between CSR registration and scope guard dismissal | Medium | Yes | 332, 863-869 |
| S5 | enterCriticalSection: in-memory critSec entered before persistent signal to secondaries | Medium | Yes | 566-581 |
| S6 | Non-atomic commit phase entry + config server commit | High | Yes | 659-671 |
| S7 | cancelClone uses potentially-killed opCtx | Medium | Yes | 947, 865 |
| S8 | 5x UninterruptibleLockGuard with TODO SERVER-71444 | Medium | Partially | 309,683,732,908,984 |

### MigrationDestinationManager (Recipient)

| # | Finding | Severity | Model-Checkable | Lines |
|---|---------|----------|-----------------|-------|
| D1 | Critical section held indefinitely after startCommit timeout | HIGH | Yes | 1895-1958 |
| D2 | Recovery path sets kEnteredCritSec unconditionally without checking for abort | Medium | Yes | 1927-1931 |
| D3 | Session migration thread not joined on failure path | Low-Medium | Partially | 795, 1813 |
| D4 | Critical section leak if release throws during recovery | Medium | Yes | 2108-2174 |
| D5 | Infinite retry loop in migrateThread recovery with no backoff | Medium | Yes | 1273-1327 |
| D6 | kDone overwrites error state set by concurrent abort | Low | Yes | 1960 |

### Migration Coordinator + Range Deletion

| # | Finding | Severity | Model-Checkable | Lines |
|---|---------|----------|-----------------|-------|
| C1 | Missing migrationId in local delete/markReady filters | CRITICAL | Yes | rdutil:702,717 |
| C2 | getRangeDeletionTask returns wrong task during recovery | HIGH | Yes | coord:285-288 |
| C3 | Non-atomic commit: 10 steps with crash windows | HIGH | Yes | coord:231-324 |
| C4 | Abort: permanent donor failure → recipient orphan leak (pending task never cleared) | Medium | Yes | coord:347-386 |
| C5 | forgetMigration uses w:1 → re-execution amplifies C1 | Medium | Yes | coord:398-401 |
| C6 | persistUpdatedNumOrphans silent failure on NoMatchingDocument | Low | No | rdutil:554 |

## Existing Spec Gap Analysis

The existing MoveRange.tla focuses on **routing correctness** (ensuring queries see the right data during and after migration). It models a single key and checks that routing table + ownership filters + timestamps produce correct results.

**What we should model instead** (the unexplored territory):
1. **Range deletion task lifecycle across crash/recovery** — the migrationId filtering gap (Family 1)
2. **Non-atomic commit sub-steps with interleaved crashes** — the crash windows (Family 2)
3. **Critical section timeout vs acquisition race** — the indefinite hold (Family 3)
4. **Two sequential migrations for the same range** — the concurrent migration scenario (Family 1+2)
5. **Step-down and recovery** — the recovery ordering (Family 4)

These are ALL outside the scope of the existing MoveRange.tla, which assumes atomic state transitions and no crashes.

## Cross-Pattern Analysis

The most dangerous interaction is **Family 1 + Family 2**: when a crash during the non-atomic commit sequence triggers recovery, and recovery uses the unfiltered `(collUuid, range)` query to find range deletion tasks, it can find tasks belonging to a NEWER migration for the same range. This means:

1. M1 commits, crashes after deleting recipient task but before marking donor task ready
2. Range bounces back. M2 creates a new donor task for the same range
3. M1 recovery: `getRangeDeletionTask(collUuid, range)` → finds M2's task
4. M1 recovery: registers M2's task, marks it ready → range deleter starts deleting M2's data
5. M2 is still in clone phase → data being actively transferred is deleted on the donor

This is the primary target for TLA+ model checking.
