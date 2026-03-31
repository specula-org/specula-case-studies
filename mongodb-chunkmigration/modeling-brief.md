# Modeling Brief: MongoDB Chunk Migration — Full Donor-Recipient Flow

## 1. System Overview

- **System**: MongoDB chunk migration — the full donor-recipient data transfer lifecycle for moving a range of data between shards in a sharded cluster
- **Language**: C++, ~9,800 LOC core logic (migration_source_manager 1034, migration_destination_manager 2291, migration_coordinator 427, range_deletion_util 850, migration_chunk_cloner_source 1655, active_migrations_registry 404, migration_util 626)
- **Protocol**: Donor-orchestrated two-phase commit with multi-phase data transfer (clone, catch-up, steady, critical section, commit/abort), persistent coordinator documents for crash recovery, and range deletion tasks as persistent locks
- **Key architectural choices**:
  - Donor shard orchestrates the entire migration lifecycle (not config server)
  - Recipient runs a state machine: kReady, kClone, kCatchup, kSteady, kCommitStart, kEnteredCritSec, kExitCritSec, kDone/kFail/kAbort
  - Donor runs a state machine: kCreated, kCloning, kCloneCaughtUp, kCriticalSection, kCloneCompleted, kCommittingOnConfig, kDone
  - Range deletion tasks in `config.rangeDeletions` serve dual role: orphan cleanup + persistent migration lock
  - Local operations on range deletion tasks do NOT include migrationId in query filters; remote operations DO
  - `forgetMigration` uses w:1 write concern; all other coordinator ops use majority
  - Critical section has two phases: write-blocking and read+write-blocking
- **Concurrency model**: Single migration thread per shard (enforced by `ActiveMigrationsRegistry`); separate range deleter thread; step-down can interrupt any operation
- **Existing TLA+ specs**: `MoveRange.tla` (487 lines, commit protocol + read routing); mongodb-moverange and mongodb-rangedeletion modeling briefs exist but do NOT cover the full donor-recipient transfer flow

## 2. Bug Families

### Family 1: Missing migrationId in Local Range Deletion Operations (HIGH)

**Mechanism**: All operations targeting range deletion tasks on the local donor shard use only `{collectionUuid, range}` as the query filter, while operations targeting the remote recipient shard correctly include `migrationId`. During recovery after stepdown, or during back-to-back migrations on the same range, the donor's local operations can match the wrong migration's task document.

**Evidence**:
- Historical: SERVER-69586 -- Non-idempotent delete/update on recipient fixed by adding migrationId to filter. Fix only applied to recipient-side operations.
- Code analysis: `range_deletion_util.cpp:320-322` -- Comment explicitly states why migrationId is needed, but fix only in `getQueryFilterForRangeDeletionTaskOnRecipient`.
- Code analysis: `deleteRangeDeletionTaskLocally` (range_deletion_util.cpp:707) -- Uses `getQueryFilterForRangeDeletionTask` (no migrationId). Called during abort (migration_coordinator.cpp:347).
- Code analysis: `markAsReadyRangeDeletionTaskLocally` (range_deletion_util.cpp:721-725) -- Builds own filter without migrationId. Called during commit (migration_coordinator.cpp:320). NEW: can prematurely unblock a future migration's range deletion task.
- Code analysis: `persistUpdatedNumOrphans` (range_deletion_util.cpp:539) -- Uses filter without migrationId. NEW: can corrupt orphan count on wrong task.
- Code analysis: `getRangeDeletionTask` (range_deletion_util.cpp:841) -- Reads first matching task without migrationId. NEW: during recovery, can read wrong task, chaining with markAsReady bug.

**Affected code paths**:
- `deleteRangeDeletionTaskLocally()` (range_deletion_util.cpp:702-715)
- `markAsReadyRangeDeletionTaskLocally()` (range_deletion_util.cpp:717-741)
- `persistUpdatedNumOrphans()` (range_deletion_util.cpp:535-557)
- `getRangeDeletionTask()` (range_deletion_util.cpp:835-848)
- `_abortMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:326-387)
- `_commitMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:231-324)

**Suggested modeling approach**:
- Variables: `rangeDeletionTasks[Shard]` -- set of records `{migrationId, collUuid, range, pending}`. Model multiple tasks for the same range from different migrations.
- Actions: Split `DeleteRangeDeletionTaskLocally` into two variants: `DeleteByRange` (current, unsafe) and `DeleteByMigrationId` (correct). Model `MarkReadyLocally` similarly.
- Add `StartNextMigration(key)` action that creates a new task before the old one is cleaned up.
- Fault injection: `StepdownDuringAbort` and `StepdownDuringCommit` that interrupt cleanup mid-way.
- Key scenario: Migration M1 aborts, stepdown, recovery replays abort, M2 starts on same range, M1 abort cleanup hits M2's task.

**Priority**: High
**Rationale**: 4 vulnerable functions sharing the same mechanism. 1 known bug, 3 NEW findings. The asymmetry between local (no migrationId) and remote (has migrationId) is systematic and directly model-checkable. `markAsReadyRangeDeletionTaskLocally` is potentially the most severe (premature data deletion).

---

### Family 2: Coordinator Commit Path Missing Exception Handling (HIGH)

**Mechanism**: The commit path in `_commitMigrationOnDonorAndRecipient` does not handle `ShardNotFound` exceptions for multiple operations contacting the recipient shard. The abort path correctly handles this exception. If the recipient shard is removed after the commit decision is persisted, the commit path throws, `forgetMigration` is never called, and the coordinator document persists -- causing an infinite recovery loop on every primary election.

**Evidence**:
- Known: `migration_coordinator.cpp:252-255` -- `advanceTransactionOnRecipient` NOT in try-catch (abort path at line 361-375 catches ShardNotFound).
- NEW: `migration_coordinator.cpp:265-266` -- `retrieveNumOrphansFromShard` NOT in try-catch. Throws ShardNotFound if recipient removed.
- NEW: `migration_coordinator.cpp:278-282` -- `deleteRangeDeletionTaskOnRecipient` NOT in try-catch. Throws ShardNotFound via `invokeCommandOnShardWithIdempotentRetryPolicy`.
- Known: `migration_util.cpp:291-295` -- `persistCommitDecision` silently swallows `NoMatchingDocument`, proceeding with commit operations even without durable decision.

**Affected code paths**:
- `_commitMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:231-324)
- `_abortMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:326-387)

**Suggested modeling approach**:
- Actions: Model commit as sequence: PersistDecision, AdvanceTxnOnRecipient, RetrieveOrphanCount, DeleteRecipientTask, RegisterLocalTask, MarkReadyLocally, ForgetCoordinatorDoc. Each step can fail.
- Fault injection: RecipientShardRemoved flag causing all recipient-contacting steps to fail.
- Check: CommitPathCompletes liveness -- no infinite recovery loop.

**Priority**: High
**Rationale**: 2 NEW findings (retrieveNumOrphansFromShard, deleteRangeDeletionTaskOnRecipient). Direct asymmetry with abort path. Trivially model-checkable.

---

### Family 3: Abort During Config Server Commit -- Limbo State (HIGH)

**Mechanism**: When `abort()` is called while the config server commit RPC is in flight, the kill signal causes the RPC to fail. The donor enters `_cleanup(false)` which does NOT set a migration decision and does NOT call `completeMigration`. The coordinator document persists with no decision, leaving the system in limbo.

**Evidence**:
- Code analysis: `migration_source_manager.cpp:863-869` -- `abort()` calls `_opCtx->markKilled()`.
- Code analysis: `migration_source_manager.cpp:681-698` -- Error path calls `_cleanup(false)`, which at line 953-955 does NOT set kAborted (because `_state == kCommittingOnConfig`), and at line 966-971 does NOT call `completeMigration`.
- Code analysis: `migration_source_manager.cpp:695-697` -- `asyncRecoverMigrationUntilSuccessOrStepDown` only refreshes metadata; does NOT complete coordinator.
- Code analysis: `migration_source_manager.cpp:946-948` -- `cancelClone` uses killed opCtx; recipient not notified.
- Code analysis: `migration_source_manager.cpp:974-993` -- `_state` not set to `kDone` when catch block fires; destructor signals wrong error status.
- Historical: `migrationCommitNetworkError` failpoint (line 673) confirms MongoDB is aware of this edge case.

**Affected code paths**:
- `MigrationSourceManager::abort()` (migration_source_manager.cpp:863-869)
- `MigrationSourceManager::commitChunkMetadataOnConfig()` (migration_source_manager.cpp:626-830)
- `MigrationSourceManager::_cleanup()` (migration_source_manager.cpp:903-994)

**Suggested modeling approach**:
- Variables: `configServerCommitted[Key]`, `coordinatorDoc[Shard]` with decision field, `donorCleanupComplete[Key]`
- Actions: Split config commit into SendCommitToConfig, ConfigPersistsCommit (may succeed), DonorReceivesResponse (may fail). Add Abort action at any point. Add DonorCleanup with true/false parameter.
- Model StepdownRecovery that reads coordinator doc without decision, queries config server.

**Priority**: High
**Rationale**: Most complex interaction between donor state machine and coordinator recovery. The limbo state exists in current code. Recovery eventually handles it but the window can be unbounded.

---

### Family 4: Transfer Protocol / Recipient State Machine Issues (MEDIUM)

**Mechanism**: The recipient's multi-phase data transfer has race conditions at state transitions, particularly between the `startCommit` signal and critical section acquisition.

**Evidence**:
- Code analysis: `migration_destination_manager.cpp:795-811` -- NEW: `startCommit` timeout races with critical section acquisition. Session migration join or recovery doc persistence can be slow, causing timeout while critSec acquisition proceeds anyway.
- Code analysis: `migration_destination_manager.cpp:1927-1931` -- NEW: Recovery path unconditionally sets kEnteredCritSec, ignoring kAbort/kFail (normal path at 1898-1902 correctly checks).
- Code analysis: `migration_destination_manager.cpp:2000-2012` -- NEW: Orphan count decremented for delete no-ops.
- Historical: SERVER-78414 -- transferMods empty batch terminates early (data loss, fixed).
- Historical: SERVER-89163 -- Missing majority write concern before recipient critSec (fixed).
- Historical: SERVER-25344 -- Abort arrives before migration thread starts; invariant crash (fixed).

**Affected code paths**:
- `startCommit()` (migration_destination_manager.cpp:753-819)
- `_migrateDriver()` (migration_destination_manager.cpp:1350-1960)
- `abort()` (migration_destination_manager.cpp:725-744)

**Suggested modeling approach**:
- Variables: `recipientState`, `critSecHeld`, `recoveryDocPersisted`
- Actions: DonorSendStartCommit, RecipientAcquireCritSec, DonorAbort, RecipientTimeout
- Model the race between startCommit timeout and critical section acquisition

**Priority**: Medium
**Rationale**: startCommit/critSec race is a real timing issue. System eventually recovers. The recipient state machine (10 states) with abort/fail/recovery interactions is a rich modeling target.

---

### Family 5: Recovery Ordering and forgetMigration Write Concern (MEDIUM)

**Mechanism**: `forgetMigration` uses w:1 write concern. On stepdown before replication, the coordinator document reappears and recovery re-executes all commit/abort operations. Safety depends on operation idempotency, which Family 1's migrationId bugs violate.

**Evidence**:
- Code analysis: `migration_coordinator.cpp:399-400` -- `forgetMigration` uses `WriteConcernOptions{1, ...}`.
- Code analysis: `range_deletion_util.cpp:535-557` -- `persistUpdatedNumOrphans` uses non-idempotent `$inc`.
- Historical: SERVER-48883 -- Range deletion recovery invalidates migration recovery on step-up.
- Historical: SERVER-62245 -- Recovery assumed single coordinator doc; multiple docs crashed.
- Code analysis: `migration_coordinator.cpp:285-295` -- `getRangeDeletionTask` returning nothing during recovery means orphans never cleaned.

**Suggested modeling approach**:
- Variables: `forgetMigrationAcked`, `decisionMajorityAcked`
- Actions: ForgetMigration (rollback on stepdown), Stepdown, Recovery
- Model non-idempotent $inc for orphan count

**Priority**: Medium
**Rationale**: w:1 write concern is a deliberate design choice. Safety depends on idempotency violated by Family 1.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Range deletion task identity (migrationId) | Family 1: 4 vulnerable functions, 3 NEW | Model tasks with migrationId; local ops match by range vs by migrationId |
| Back-to-back migrations on same range | Family 1: trigger scenario | Allow second migration before first cleanup completes |
| Non-atomic commit with stepdown | Family 2+3: 41 historical + 5 new | Split commit into 7 sub-steps, add Stepdown between each |
| Coordinator recovery from config server | Family 3: limbo state | Model recovery querying config server for authoritative decision |
| Commit/abort path asymmetry | Family 2: systematic missing handling | Model as distinct action sequences with independent faults |
| Recipient state machine with startCommit race | Family 4: timing race | Model donor and recipient state machines with abort/timeout |
| forgetMigration w:1 rollback | Family 5: depends on idempotency | Model w:1 ops as rollback-able on stepdown |
| Range deletion task lifecycle | Family 1+5: persistent lock | Model pending/ready/processing states |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Data cloning batches / transferMods content | SERVER-78414 fixed; remaining issues are timing |
| Session migration | Separate subsystem, no chunk ownership interaction |
| Lock ordering / RSTL deadlocks | Implementation-level C++ threading |
| Op observer / document tracking | No bugs found; single-node correctness |
| Read routing / timestamp consistency | Already covered by existing MoveRange.tla |
| Orphan count accuracy | Low severity metadata drift |
| Clone convergence loop | Performance/liveness only |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Range deletion task identity | `rangeDeletionTasks[Shard]` with migrationId | Model wrong-task matching | Family 1 |
| Back-to-back migration | `migrationCounter`, `activeMigration[Key]` | Enable 2nd migration before 1st cleanup | Family 1 |
| Non-atomic commit | `commitSubStep` per migration | Model crash windows | Family 2, 3 |
| Coordinator document | `coordinatorDoc[Shard]` with decision | Model persistence and recovery | Family 3, 5 |
| Config server authority | `configServerOwner[Key]` | Authoritative chunk ownership | Family 3 |
| Recipient state machine | `recipientState`, `critSecHeld` | Model startCommit/abort races | Family 4 |
| Write concern | `majorityAcked[Op]` | Model w:1 rollback | Family 5 |
| Recipient shard removal | `shardExists[Shard]` | Model ShardNotFound | Family 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| TaskIdentityCorrect | Safety | Local range deletion ops only affect correct migration's task | Family 1 |
| NoOrphanAfterCommit | Safety | After commit, donor's orphans eventually cleaned | Family 1, 5 |
| NoPrematureRangeDeletion | Safety | Range deletion never starts while owning migration active | Family 1 |
| CommitPathCompletes | Liveness | If config committed, donor completes all side-effects | Family 2, 3 |
| AbortPathCompletes | Liveness | If aborted, both sides clean up | Family 2 |
| NoLimboCoordinatorDoc | Safety | No coordinator doc persists indefinitely without decision | Family 3 |
| CritSecBounded | Liveness | Recipient critSec held for bounded duration | Family 4 |
| RecoveryConsistency | Safety | After recovery, ownership matches config server | Family 3, 5 |
| NoOverlappingMigrations | Safety | No two migrations on same range simultaneously | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | M1 aborts, M2 starts same range, M1 abort cleanup deletes M2's task | TaskIdentityCorrect | 1 |
| MC-2 | Recovery reads M2's task instead of M1's, marks it ready | NoPrematureRangeDeletion | 1 |
| MC-3 | retrieveNumOrphansFromShard throws ShardNotFound on commit path | CommitPathCompletes | 2 |
| MC-4 | deleteRangeDeletionTaskOnRecipient throws ShardNotFound on commit | CommitPathCompletes | 2 |
| MC-5 | Abort during config commit: config committed but donor in limbo | NoLimboCoordinatorDoc | 3 |
| MC-6 | forgetMigration w:1 rolled back + non-idempotent $inc doubles orphan count | RecoveryConsistency | 5 |
| MC-7 | startCommit timeout vs critSec acquisition race | CritSecBounded | 4 |
| MC-8 | markAsReadyRangeDeletionTaskLocally hits wrong task | NoPrematureRangeDeletion | 1 |
| MC-9 | Abort: deleteRangeDeletionTaskLocally failure prevents markAsReadyOnRecipient | AbortPathCompletes | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test |
|----|-------------|----------------|
| TV-1 | deleteRangeDeletionTaskLocally deletes wrong task | Two tasks same range, different migrationId |
| TV-2 | markAsReadyRangeDeletionTaskLocally unblocks wrong task | Pending task for M2 during M1 commit recovery |
| TV-3 | persistUpdatedNumOrphans updates wrong orphan count | Two tasks same range, verify count |
| TV-4 | Recipient orphan count drift from delete no-ops | Send deletes for non-existent docs |
| TV-5 | startCommit timeout during critSec acquisition | Failpoint on session migration join |

### 6.3 Code-Review-Only

| ID | Description | Action |
|----|-------------|--------|
| CR-1 | SERVER-71444: 5 UninterruptibleLockGuard usages can stall stepdown | Track ticket |
| CR-2 | SERVER-92531: Constructor scope guard signals success on failure | Review emplaceValue |
| CR-3 | ScopedRegisterer destructor uses killed opCtx (source_manager:1028) | Review interruption |
| CR-4 | Recovery path ignores kAbort for kEnteredCritSec (dest_manager:1927) | Compare with line 1898 |
| CR-5 | Dead counters _numCatchup/_numSteady (dest_manager:573) | Remove dead code |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-chunkmigration/analysis-report.md`
- **Related briefs**: `case-studies/mongodb-moverange/modeling-brief.md`, `case-studies/mongodb-rangedeletion/modeling-brief.md`
- **Existing TLA+ spec**: `artifact/mongo-src/src/mongo/tla_plus/Sharding/MoveRange/MoveRange.tla`
- **Key source files**:
  - `src/mongo/db/s/migration_source_manager.cpp` (1034 lines)
  - `src/mongo/db/s/migration_destination_manager.cpp` (2291 lines)
  - `src/mongo/db/s/migration_coordinator.cpp` (427 lines)
  - `src/mongo/db/s/range_deletion_util.cpp` (850 lines)
  - `src/mongo/db/s/migration_chunk_cloner_source.cpp` (1655 lines)
  - `src/mongo/db/s/migration_util.cpp` (626 lines)
- **Key JIRA tickets**: SERVER-78414, SERVER-71219, SERVER-69586, SERVER-49508, SERVER-48883, SERVER-62245, SERVER-62580, SERVER-89163, SERVER-60518, SERVER-46395, SERVER-91970, SERVER-84625, SERVER-71544, SERVER-65969
- **Shared harness**: `case-studies/mongodb-shared-harness.md`
