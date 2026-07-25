# MongoDB Chunk Migration: Modeling Brief

## 1. System Overview

**System**: MongoDB sharding chunk migration commit and recovery  
**Language**: C++  
**Category**: **Category A (Distributed / Message-Passing)**  
**Justification**: The system coordinates state across three independent nodes (donor shard, recipient shard, config server) via RPC/network messages. The core risks are protocol safety violations, crash windows, and message loss during the commit/abort decision propagation and recovery phases.

**Core Algorithm**: MongoDB implements a 3-phase chunk migration protocol:
1. **Clone Phase**: Recipient fetches initial chunk data from donor; donor tracks ongoing writes
2. **Critical Section Phase**: Donor enters read-only mode; recipient applies final writes
3. **Commit Phase**: Donor commits decision to config server; both shards update routing tables

**Key Architectural Choices**:
- Separate state machines on donor (MigrationSourceManager) and recipient (MigrationDestinationManager)
- Centralized commit coordination (MigrationCoordinator) that persists decision then notifies shards
- Range deletion (orphan cleanup) split into two phases: async tasks on both shards
- Async recovery of incomplete migrations on primary stepup (migration coordinator recovery service)

**Concurrency Model**:
- Donor: Single-threaded state machine (MigrationSourceManager); background cloner thread captures writes
- Recipient: Single-threaded state machine (MigrationDestinationManager); background batch inserter
- Coordinator: Async RPC calls with semaphore-based future composition for recovery

---

## 2. Bug Families

### Family 1: Non-Atomic Multi-Node Commit/Abort Decision

**Mechanism**: The migration decision (commit or abort) is persisted locally first, then propagated to remote shards asynchronously. Multiple operations between persistence and full propagation create crash windows where the decision is durable but cleanup is incomplete.

**Evidence**:
- **Historical**: SERVER-71444 (5 occurrences in migration_source_manager.cpp) - "Fix to be interruptible or document exception" in cleanup paths
- **Code analysis**:
  - Commit path (migration_coordinator.cpp:231-323): Persist decision (line 240) → wait for recipient critical section release → bump txn number → delete recipient range deletion task → retrieve donor range deletion task and register for cleanup
  - Abort path (migration_coordinator.cpp:326-387): Persist decision (line 334) → delete local range deletion task (line 347) → bump txn number on recipient (line 361) → mark recipient range deletion as ready (line 382)

**Affected code paths**:
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:231-323)
- `MigrationCoordinator::_abortMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:326-387)
- `MigrationCoordinator::completeMigration()` (migration_coordinator.cpp:183-229)

**Specific crash windows**:
1. **Commit**: Decision persisted but recipient critical section not yet released (line 240-242)
2. **Commit**: Recipient critical section released but orphan count not retrieved (line 242-265)
3. **Commit**: Orphan task marked ready locally but donor range deletion task not registered (line 320-323)
4. **Abort**: Local range deletion deleted but recipient not yet notified (line 347-361)
5. **Abort**: Recipient critical section still held while migration coordinator forgotten (line 226 after 382)

**Severity**: **Critical** - Data loss risk if crash between decision and cleanup on either shard. Recovery requires replaying incomplete cleanup, which can be delayed indefinitely if the node remains down.

**TLA+ Suitability**: **Excellent** - Core protocol safety violation. Model crash between decision persistence and state propagation.

**Priority**: **High**

---

### Family 2: Filtering Metadata Inconsistency During Commit Failure

**Mechanism**: The donor enters critical section (read-only mode) before committing the decision to the config server. If the config server commit fails, the donor clears its filtering metadata to force refresh, but the critical section may still be active on the recipient. This creates a window where donor has no metadata for the chunk but recipient still has write-only critical section active.

**Evidence**:
- **Code analysis** (migration_source_manager.cpp):
  - Line 566: Critical section entered: `_critSec.emplace(_opCtx, nss(), _critSecReason)`
  - Line 659: Critical section enters commit phase before RPC: `_critSec->enterCommitPhase()`
  - Lines 682-698: On commit failure, filtering metadata cleared before async recovery: `clearFilteringMetadata_nonAuthoritative()`
  - But critical section release on recipient is in a separate future (migration_coordinator.cpp line 205) that's only awaited in completeMigration

**Affected code paths**:
- `MigrationSourceManager::commitChunkMetadataOnConfig()` (migration_source_manager.cpp:626-714)
- `MigrationSourceManager::_cleanup()` (called at line 694)
- Error handling in lines 682-698

**Specific race windows**:
1. Donor enters critical section (line 566)
2. Donor sends commit to config server (line 665)
3. Config server commit fails (network error, timeout, etc.)
4. Donor clears filtering metadata (line 690)
5. **Race**: Recipient may still be in critical section; reads on recipient may block indefinitely waiting for metadata refresh that doesn't happen on donor

**Severity**: **High** - Reads on recipient can hang indefinitely; donor cannot serve the chunk; potential write loss if writes are attempted in the window.

**TLA+ Suitability**: **Excellent** - Model filtering metadata state on both shards plus critical section state.

**Priority**: **High**

---

### Family 3: Range Deletion Task Lifecycle Mismatch

**Mechanism**: In the abort path, the donor deletes its local range deletion task before notifying the recipient to mark its task as ready. If a crash occurs between these two operations, the donor has lost track of the range deletion but the recipient still has an active (pending) task that will never be completed.

**Evidence**:
- **Code analysis** (migration_coordinator.cpp:326-387):
  - Line 347-350: Donor deletes its range deletion task locally: `deleteRangeDeletionTaskLocally()`
  - Line 361-364: Donor attempts to notify recipient to bump txn number and mark task ready: `advanceTransactionOnRecipient()` then `markAsReadyRangeDeletionTaskOnRecipient()`
  - Lines 365-375: If ShardNotFound exception, only logs; continues to forgetMigration()

**Affected code paths**:
- `MigrationCoordinator::_abortMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:326-387)

**Specific crash windows**:
1. Crash between line 350 (local delete) and line 361 (recipient notify)
2. Crash between line 364 (recipient notify) and line 382 (mark as ready)
3. ShardNotFound at line 365 - recipient never marked as ready but donor forgot migration

**Severity**: **High** - Orphaned documents on recipient forever; overlapping migration attempts fail because range deletion is pending indefinitely.

**TLA+ Suitability**: **Excellent** - Model range deletion task state as separate persistent entities on both shards.

**Priority**: **High**

---

### Family 4: Asynchronous Recipient Critical Section Release

**Mechanism**: The recipient critical section release is launched asynchronously (as a separate future) early in `completeMigration()`. However, the code waits for this future at lines 242/338. If the future fails (network error, shard not found, exception), the error is caught and logged, but the code continues. This creates a window where the critical section is not yet released but the migration coordinator forgets the migration and doesn't retry.

**Evidence**:
- **Code analysis** (migration_coordinator.cpp):
  - Line 205: Future is launched asynchronously: `launchReleaseRecipientCriticalSection(opCtx)`
  - Lines 242/338: Future is awaited: `_waitForReleaseRecipientCriticalSectionFutureIgnoreShardNotFound(opCtx)`
  - Lines 415-424: Catches ShardNotFound exception and logs; doesn't retry
  - Line 226: `forgetMigration()` called regardless of critical section release status

**Affected code paths**:
- `MigrationCoordinator::launchReleaseRecipientCriticalSection()` (migration_coordinator.cpp:403-410)
- `MigrationCoordinator::_waitForReleaseRecipientCriticalSectionFutureIgnoreShardNotFound()` (migration_coordinator.cpp:412-424)
- `MigrationCoordinator::completeMigration()` (migration_coordinator.cpp:183-229)

**Specific race windows**:
1. Recipient is down when release future is launched → ShardNotFound exception caught
2. Recipient critical section released successfully but node steps down before completing migration
3. Network timeout during release → only ShardNotFound exceptions are ignored; other errors propagate but continue

**Severity**: **Medium** - Recipient will be blocked in critical section indefinitely; recovery would require manual intervention or a second migration to unblock.

**TLA+ Suitability**: **Good** - Model recipient critical section state and the async release future separately.

**Priority**: **Medium**

---

### Family 5: Error Handling in Abort Decision Propagation

**Mechanism**: In the abort path, if the recipient shard is unreachable when trying to notify it to bump txn number or mark the range deletion task as ready, the exceptions are caught (ShardNotFound only; others propagate). The migration coordinator still calls `forgetMigration()`, forgetting the migration doc. If the error was transient, the recipient will never learn about the abort and will eventually commit its own cleanup based on stale transaction state.

**Evidence**:
- **Code analysis** (migration_coordinator.cpp:326-387):
  - Line 352-375: Try to notify recipient; catches only ShardNotFound
  - Lines 365-375: Log and continue even if exception
  - Line 226: `forgetMigration()` called regardless
  - The recipient's critical section is released asynchronously at line 338, and if that fails, it's also logged and ignored

**Affected code paths**:
- `MigrationCoordinator::_abortMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:326-387)
- Exception handling at lines 352-375

**Specific failure modes**:
1. Network timeout during abort notification → ShardNotFound? No, times out differently → propagates differently
2. Recipient is down; ShardNotFound caught; migration forgotten; recipient still has pending range deletion and critical section
3. Partial notification: txn number bumped but range deletion task not marked ready → recipient in inconsistent state

**Severity**: **Medium-High** - Recipient left in inconsistent state; recovery is complex.

**TLA+ Suitability**: **Good** - Model exception types during RPC calls (transient vs. ShardNotFound).

**Priority**: **Medium**

---

### Family 6: Interruptibility Gaps in Critical Section Entry and Commit

**Mechanism**: The code explicitly disables interruptibility using `UninterruptibleLockGuard` in multiple places during critical migration phases. This is documented in TODO SERVER-71444 (5 occurrences). If a shutdown or step-down request arrives during these uninterruptible phases, it will be delayed, potentially causing long hangs.

**Evidence**:
- **Code analysis** (migration_source_manager.cpp):
  - Line 309-310: `UninterruptibleLockGuard noInterrupt(_opCtx)` during constructor critical section
  - Line 684: `UninterruptibleLockGuard noInterrupt(_opCtx)` during commit failure handling
  - Lines 300, 309, 683, 732, 908, 984: Five occurrences with TODO SERVER-71444 comment

**Affected code paths**:
- `MigrationSourceManager` constructor (migration_source_manager.cpp:272-385)
- `MigrationSourceManager::commitChunkMetadataOnConfig()` (migration_source_manager.cpp:626-714)

**Specific issues**:
1. Cannot interrupt during registration on CSR (line 310) → can delay shutdown for extended time
2. Cannot interrupt during filtering metadata cleanup on commit failure (line 684) → acquires exclusive lock, blocks other operations
3. No clear time bound on these uninterruptible sections

**Severity**: **Medium** - Service availability impact; not a safety violation but affects liveness.

**TLA+ Suitability**: **Poor** - Implementation detail; not relevant to protocol correctness. Skip for initial modeling.

**Priority**: **Low** (for modeling purposes)

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| Item | Why | How |
|------|-----|-----|
| Non-atomic decision persistence (Family 1) | Core safety violation - commits/aborts can be incomplete | Separate decision persistence action from cleanup actions; model crash between them |
| Filtering metadata state on both shards (Family 2) | Safety violation - metadata inconsistency between shards | Track metadata ownership state on donor and recipient independently; critical section state separate |
| Range deletion task lifecycle (Family 3) | Safety violation - orphaned tasks never cleaned up | Model range deletion tasks as persistent entities with state (pending, ready, completed) on both shards |
| Recipient critical section release (Family 4) | Safety violation - critical section can be stuck indefinitely | Model recipient critical section explicitly; model release as separate async action; allow release to fail |
| Abort error handling (Family 5) | Safety violation - inconsistent state when notifications fail | Model error cases during RPC (ShardNotFound vs. other errors) |

### 3.2 Do Not Model (with rationale)

| Item | Why |
|------|-----|
| Interruptibility (Family 6) | Implementation detail; doesn't affect protocol correctness. Liveness is the concern, not safety. |
| Txn number management | Implementation optimization detail; not essential to chunk ownership correctness |
| Batch cloning algorithm | Implementation detail; not a protocol-level concern |
| Index building during migration | Feature interaction; separate from core migration safety |
| Write concern levels | Replication detail; covered by general crash model |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| **Decision Persistence Window** | `donorDecision`, `recipientClone`, `donorRangeDeletion` | Model crash between decision persistence and cleanup actions | Family 1 |
| **Metadata State Tracking** | `donorMetadata`, `recipientMetadata`, `criticalSectionActive` | Track metadata ownership separately on each shard plus critical section state | Family 2 |
| **Range Deletion Task Lifecycle** | `donorRangeDeletionTask`, `recipientRangeDeletionTask` (states: pending, ready, completed) | Model range deletion as distributed entity | Family 3 |
| **Recipient Critical Section Release State** | `recipientCritSectionReleased`, `releaseCompleteFuture` | Track whether release has actually completed | Family 4 |
| **RPC Failure Modes** | `rpcLastCall`, `rpcFailureType` (ShardNotFound, transient, other) | Model different error scenarios during abort notification | Family 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **ChunkOwnershipConsistency** | Safety | At most one shard claims ownership of a chunk range. If migration commits, recipient must own chunk and donor must not. | Family 2, Family 1 |
| **DecisionDurabilityLeadsToCompletion** | Safety | Once a migration decision (commit/abort) is persisted, the migration must eventually complete in a manner consistent with that decision (even after crash). | Family 1, Family 3, Family 5 |
| **RangeDeletionConsistency** | Safety | A range deletion task on the donor cannot be marked completed until the recipient has also marked its task completed (or donor committed and can now delete on behalf of recipient). | Family 3 |
| **NoDoubleCommit** | Safety | A chunk migration cannot commit twice. Once committed, subsequent attempts to migrate the same chunk must fail or noop. | Family 1 |
| **MetadataReflectsDecision** | Safety | If commit decision is durable, at least one shard (donor or recipient) must have metadata reflecting the new ownership. After recovery, both must be consistent. | Family 2 |
| **CriticalSectionReleaseBeforeDone** | Liveness | Once a migration completes (commit or abort), the critical section on the recipient must be released within bounded time. | Family 4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | What states can be reached if the donor crashes immediately after persisting the commit decision but before notifying the recipient? Can the chunk be permanently stuck between the two shards (committed locally on donor, not committed on recipient)? | ChunkOwnershipConsistency, DecisionDurabilityLeadsToCompletion | Family 1 |
| MC2 | If the config server commit fails after the donor enters critical section, can filtering metadata be cleared while critical section is still active on recipient, blocking all reads on the recipient? | MetadataReflectsDecision, ChunkOwnershipConsistency | Family 2 |
| MC3 | Can a range deletion task on the recipient become permanently stuck (never marked ready) if the donor crashes between deleting its local task and marking the recipient's task as ready during abort? | RangeDeletionConsistency | Family 3 |
| MC4 | If the recipient critical section release RPC fails with ShardNotFound, and the donor forgets the migration, can the recipient remain blocked indefinitely? | CriticalSectionReleaseBeforeDone, DecisionDurabilityLeadsToCompletion | Family 4 |
| MC5 | During abort, if notifying the recipient to bump txn number fails but the migration coordinator doc is deleted, is the recipient left with orphaned range deletion tasks that will never be cleaned? | RangeDeletionConsistency, DecisionDurabilityLeadsToCompletion | Family 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | Verify that if the config server commit RPC is interrupted mid-response, the donor correctly recovers by re-sending the commit or marking the migration as failed | Chaos test: inject network failure during commitChunkMigration RPC; observe donor behavior |
| TV2 | Verify that orphaned documents are eventually deleted even if the recipient crashes during range deletion task processing | Crash test: kill recipient during range deletion; restart; verify orphaned docs are cleaned up within SLA |
| TV3 | Verify that a stalled migration (critical section stuck on recipient) is properly recovered when the donor replicas elect a new primary | Failover test: hang recipient in critical section; step down donor; verify new primary recovers migration |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | Review the cleanup logic in MigrationSourceManager::_cleanup() to ensure all state is rolled back consistently when a migration aborts. Currently multiple separate cleanup paths may leave state inconsistent. | Audit all exception paths in startClone, awaitToCatchUp, enterCriticalSection, commitChunkOnRecipient, commitChunkMetadataOnConfig for completeness |
| CR2 | Review the async recovery logic (migrationutil::asyncRecoverMigrationUntilSuccessOrStepDown) to ensure recovery is retried aggressively. Currently recovery is fire-and-forget. | Verify recovery task is retried on failure; check for potential infinite retry loops |
| CR3 | The TODO SERVER-71444 comments suggest interruptibility issues. Audit whether these uninterruptible sections are truly necessary or if they can be made interruptible with smaller critical sections. | Consider breaking UninterruptibleLockGuard sections into smaller atomic pieces |

---

## 7. Reference Pointers

**Source Files** (core migration logic):
- `/mongo/db/s/migration_source_manager.cpp` (lines 272-385: constructor; 404-529: startClone; 550-593: enterCriticalSection; 595-624: commitChunkOnRecipient; 626-714: commitChunkMetadataOnConfig)
- `/mongo/db/s/migration_destination_manager.cpp` (state machine definition; recipient-side coordination)
- `/mongo/db/s/migration_coordinator.cpp` (lines 147-170: startMigration; 172-229: completeMigration; 231-323: _commitMigrationOnDonorAndRecipient; 326-387: _abortMigrationOnDonorAndRecipient)
- `/mongo/db/s/migration_util.cpp` (recovery service and utility functions)

**Key Fail Points** (useful for testing/modeling):
- hangBeforeMakingCommitDecisionDurable (line 233, migration_coordinator.cpp)
- hangBeforeSendingCommitDecision (line 257, migration_coordinator.cpp)
- hangBeforeForgettingMigrationAfterCommitDecision (line 222, migration_coordinator.cpp)
- failMigrationCommit (line 609, migration_source_manager.cpp)
- migrationCommitNetworkError (line 673, migration_source_manager.cpp)

**Test Fixtures**:
- `jstests/sharding/migration_coordinator_*.js` - coordination failure tests
- `jstests/sharding/move_chunk_*.js` - general migration tests

**Recovery Code**:
- `migrationutil::drainMigrationsPendingRecovery()` (migration_util.cpp:357+)
- `MigrationCoordinator` recovery during primary stepup

**Related Code**:
- `RangeDeleterService` for managing orphan deletion
- `CollectionShardingRuntime` for critical section management
- `ShardingCatalogManager::commitChunkMigration()` for config server-side commit logic
