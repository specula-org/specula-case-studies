# Modeling Brief: MongoDB Chunk Migration Commit and Recovery

## 1. System Overview

- **System**: MongoDB sharding chunk migration — donor/recipient protocol for moving a range of documents between shards
- **Language**: C++, ~6,000 LOC core logic (migration_source_manager.cpp 1034, migration_destination_manager.cpp 2291, migration_coordinator.cpp 427, migration_chunk_cloner_source.cpp 1655, migration_util.cpp 626)
- **Category**: **Category A (Distributed / Message-Passing)** — three-party protocol (donor shard, recipient shard, config server) with crash-recovery, RPC message-passing, and multi-step durable writes
- **Protocol**: Custom two-phase commit for chunk ownership transfer: clone phase → critical section → config server commit → release
- **Key architectural choices**:
  - Donor persists a `MigrationCoordinatorDocument` to drive both commit and recovery; recipient persists a `MigrationRecipientRecoveryDocument`
  - The recipient's critical section release RPC is launched **asynchronously** from a background future before the donor's commit decision is persisted to disk (`coordinator.cpp:205` fires before `coordinator.cpp:240`)
  - Config server commit (`commitChunkMigration`) is called with `RetryPolicy::kIdempotent` directly from the donor's critical section; coordinator doc carries the decision for recovery
  - Range deletion tasks are written with different write concerns on donor vs. recipient (majority vs. local-then-separate-wait)
  - Recovery on primary step-up re-drives coordinator via metadata refresh, not by re-reading the persisted decision directly
- **Concurrency model**: Donor and recipient each run a migration thread (the `_migrateDriver` task on the recipient side); separate background futures manage the async critical-section release RPC; an `ActiveMigrationsRegistry` enforces one migration per shard at a time

---

## 2. Bug Families

### Family 1: Commit Decision Durability vs. Critical Section Release Ordering

**Mechanism**: The donor launches the recipient's critical section release RPC as an async background future *before* calling `persistCommitDecision`. A crash in the window between the async launch and the durable write leaves the recipient's critical section released while the donor holds no durable commit record.

**Evidence**:
- Code analysis: `migration_coordinator.cpp:205` — `launchReleaseRecipientCriticalSection` fires the async RPC; `coordinator.cpp:240` — `persistCommitDecision` writes the decision with majority WC. The RPC send precedes the durable write.
- Code analysis: `migration_coordinator.cpp:186–196` — recovery's "no decision" early-return path: if `persistCommitDecision` never completed, the new primary's recovery loop calls `completeMigration`, hits the no-decision branch, and returns without finalizing donor/recipient state. The recipient's critical section has already been released.
- Code analysis: `migration_source_manager.cpp:706–744` — if the post-commit metadata refresh fails, the cleanup path dismisses the recovery-scheduling ScopeGuard, leaving the coordinator doc with no decision for an indefinite window.
- Code analysis: `migration_coordinator.cpp:334` (abort path) — `persistAbortDecision` is called *before* `_waitForReleaseRecipientCriticalSectionFutureIgnoreShardNotFound` (line 338), so the abort path correctly persists the decision first. The asymmetry between commit and abort is confirmed.

**Affected code paths**:
- `MigrationCoordinator::completeMigration()` (`coordinator.cpp:183–229`)
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient()` (`coordinator.cpp:231–324`)
- `MigrationCoordinator::_abortMigrationOnDonorAndRecipient()` (`coordinator.cpp:326–387`) — correct ordering for reference
- `MigrationSourceManager::commitChunkMetadataOnConfig()` catch-block (`migration_source_manager.cpp:706–744`)

**Suggested modeling approach**:
- Variables: `decisionPersisted [Donor -> {none, committed, aborted}]`, `recipientCritSecReleased [BOOLEAN]`, `donorCrashed [BOOLEAN]`
- Actions: Split the commit sequence into `LaunchReleaseRecipientCritSec` (async send), `PersistCommitDecision` (durable write), `CrashDonor` (crash between these two), `RecoverDonor` (reads coordinator doc — finds no decision)
- Key invariant to check: after `RecoverDonor`, if `recipientCritSecReleased` is true but `decisionPersisted == none`, does the migration commit correctly or leave a permanent orphan window?

**Priority**: High
**Rationale**: Directly confirmed asymmetry between commit and abort paths. The crash window is concrete (async RPC dispatch precedes durable write). The recovery's no-decision early-return is documented in code. This is the primary safety frontier of the commit protocol.

---

### Family 2: Recovery Path Incompleteness and State Override Bugs

**Mechanism**: Recovery code paths fail to restore required state fields or fail to check for prior abort/fail signals before overwriting state, causing incorrect migration outcomes after failover.

**Evidence**:
- Code analysis: `migration_destination_manager.cpp:1917–1930` — the `skipToCritSecTaken` recovery branch sets `_state = kEnteredCritSec` at line 1929 without checking `_state != kFail && _state != kAbort`. The normal (non-recovery) path at line 1899 *does* have this guard. A concurrent `abort()` call that set `_state = kAbort` before the recovery thread reaches line 1929 will have its state silently overwritten, causing the coordinator to believe the recipient is ready for commit when it should be aborting.
- Code analysis: `migration_destination_manager.cpp:600–654` (`restoreRecoveredMigrationState`) — the function restores `_nss`, `_migrationId`, `_sessionId`, `_min`, `_max`, `_lsid`, `_txnNumber` but does **not** restore `_collectionUuid`, `_fromShard`, `_toShard`, `_shardKeyPattern`, or `_fromShardConnString`. These fields are used later in the recovery path.
- Code analysis: `migration_util.cpp:507` — `resumeMigrationRecipientsOnStepUp` contains an `invariant(ongoingMigrationRecipientsCount == 0)` that crashes the node if more than one recipient recovery document exists; any bug that creates a second doc causes a permanent node crash on every step-up.
- Code analysis: `migration_util.cpp:543–561` (`drainMigrationsPendingRecovery`) — no termination bound or timeout; if metadata refresh never removes the coordinator doc, the loop blocks the caller indefinitely.
- Historical (SERVER-92531 comment, `migration_source_manager.cpp:300`): early-stage migration abort bypasses standard `_cleanup()` infrastructure, leaving an ad-hoc ScopeGuard path divergent from normal cleanup.

**Affected code paths**:
- `MigrationDestinationManager::_migrateDriver` recovery branch (`destination_manager.cpp:1904–1938`)
- `MigrationDestinationManager::restoreRecoveredMigrationState` (`destination_manager.cpp:600–654`)
- `migrationutil::resumeMigrationRecipientsOnStepUp` (`migration_util.cpp:495–541`)
- `migrationutil::drainMigrationsPendingRecovery` (`migration_util.cpp:543–561`)

**Suggested modeling approach**:
- Variables: `recipientState [Recipient -> {init, cloning, critSec, done, fail, abort}]`, `recipientRecoveryDocPresent [BOOLEAN]`, `concurrentAbortSignaled [BOOLEAN]`
- Actions: `StartRecipientRecovery` (sets `skipToCritSecTaken`), `ConcurrentAbort` (sets abort flag), `RecoverySetsCritSec` (models the state overwrite)
- Invariant: if `concurrentAbortSignaled` is true before `RecoverySetsCritSec`, `recipientState` must be `abort` after recovery, never `critSec`

**Priority**: High
**Rationale**: The kFail/kAbort override in the recovery path is a confirmed asymmetry between recovery and normal code paths. Combined with Family 1, it creates a scenario where an aborted migration can be committed erroneously after recovery.

---

### Family 3: Range Deletion Task Lifecycle Inconsistency

**Mechanism**: Range deletion tasks on donor and recipient are created, deleted, and transitioned with different orderings and write concerns across the commit/abort/recovery paths, creating windows where tasks can be skipped, duplicated, or processed at wrong times.

**Evidence**:
- Code analysis: `migration_coordinator.cpp:285–294` — recovery path: if `getRangeDeletionTask` returns nothing (donor task already deleted in a prior partial recovery), the function returns early without deleting the recipient's range deletion task or marking anything ready. A mid-cleanup crash can leave the recipient's task permanently orphaned.
- Code analysis: `migration_coordinator.cpp:382–386` (abort path) — `markAsReadyRangeDeletionTaskOnRecipient` is called outside the `ShardNotFound` try/catch that wraps `advanceTransactionOnRecipient` (lines 361–364). The commit path's analogous `deleteRangeDeletionTaskOnRecipient` (lines 278–289) also has no `ShardNotFound` guard. If the recipient shard disappears post-decision, cleanup is never completed.
- Code analysis: `migration_source_manager.cpp:472–500` — `_cloneDriver` is registered on the CSR (making writes visible to OpObservers) at line 487 before `_coordinator->startMigration()` at line 500, which persists the coordinator document and donor range deletion task. A crash in this window produces buffered writes with no coordinator doc and no range deletion task.
- Code analysis: `migration_destination_manager.cpp:1537–1561` — recipient range deletion task written with `writeConcernLocalHavingUpstreamWaiter()` (local WC), then a separate majority wait via `ReplClientInfo::getLastOp()`. If the process crashes between the local write and the majority wait completing, the new primary may not have the task, and the range deleter may prematurely clean up data being cloned.
- Code analysis: `migration_destination_manager.cpp:1804–1807` — no explicit deletion of the recipient's pending range deletion task when the migration fails after `_chunkMarkedPending = true`; the coordinator is expected to clean it up later, but if the coordinator never runs on this primary, the task blocks future migrations to the same range.

**Affected code paths**:
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient` (`coordinator.cpp:259–323`)
- `MigrationCoordinator::_abortMigrationOnDonorAndRecipient` (`coordinator.cpp:326–387`)
- `MigrationSourceManager::startClone` (`migration_source_manager.cpp:466–503`)
- `MigrationDestinationManager::_migrateDriver` init (`destination_manager.cpp:1537–1582`)

**Suggested modeling approach**:
- Variables: `donorRangeDeletionTask [Donor -> {absent, pending, ready}]`, `recipientRangeDeletionTask [Recipient -> {absent, pending, ready}]`, `coordinatorDecision [Donor -> {none, committed, aborted}]`
- Actions: model each task lifecycle step as a separate action; introduce `CrashMid` action after any single step
- Invariants: `RangeDeletionConsistency` — if `coordinatorDecision == committed`, eventually `donorRangeDeletionTask == ready` and `recipientRangeDeletionTask == absent`; if `aborted`, eventually `donorRangeDeletionTask == absent` and `recipientRangeDeletionTask == ready`

**Priority**: High
**Rationale**: Multiple distinct crash windows across commit/abort/recovery paths, all with the same mechanism (task lifecycle step skipped on crash). TLA+ is well-suited to enumerate all reachable task states across decision × crash combinations.

---

### Family 4: Transfer-Mods Completeness and Silent Data Drops

**Mechanism**: The transfer-mods pipeline can miss document updates or deletes due to MVCC snapshot staleness in deferred operation processing, or due to silent discards of operations with incomplete shard key fields.

**Evidence**:
- Code analysis: `migration_chunk_cloner_source.cpp:900–927` — `nextModsBatch` calls `_processDeferredXferMods` at line 938 (which uses `findById` under the current snapshot), then abandons the snapshot at line 961. Any deferred op whose post-image was committed after the snapshot-open reads a stale version; the code at lines 912–915 interprets "not found" as "later deleted," potentially misclassifying an update as a delete.
- Code analysis: `migration_chunk_cloner_source.cpp:585–592` — `onDeleteOp` silently discards deletes whose `DocumentKey` does not carry the shard key field (logs a warning, no transfer). Affected documents may not be deleted on the recipient, leaving stale copies.
- Code analysis: `migration_destination_manager.cpp:1744–1751` — the `transferAfterCommit` flag ensures at least one full `_transferMods` round-trip after `COMMIT_START`; if this flag check is missing or the loop exits early, writes buffered on the donor between the final poll and the critical section acquisition could be missed.

**Affected code paths**:
- `MigrationChunkClonerSource::nextModsBatch` (`migration_chunk_cloner_source.cpp:930–991`)
- `MigrationChunkClonerSource::_processDeferredXferMods` (`migration_chunk_cloner_source.cpp:900–928`)
- `MigrationChunkClonerSource::onDeleteOp` (`migration_chunk_cloner_source.cpp:567–608`)
- `MigrationDestinationManager::_migrateDriver` transfer loop (`destination_manager.cpp:1741–1797`)

**Suggested modeling approach**: Not a strong TLA+ candidate. The stale-snapshot issue depends on WiredTiger MVCC semantics not easily abstracted in TLA+. The `transferAfterCommit` mechanism's correctness is better verified by testing the exact sequence of state transitions.

**Priority**: Medium (for TLA+), High (for test-level verification)

---

### Family 5: Non-Atomic Persistence and Write Concern Inconsistencies

**Mechanism**: Several lifecycle operations use weaker-than-majority write concern, and FCV-gated field serialization creates schema incompatibility during rolling upgrade/downgrade.

**Evidence**:
- Code analysis: `migration_coordinator.cpp:400` — `forgetMigration` uses `WriteConcernOptions{1, SyncMode::UNSET, Seconds(0)}` (w:1, no timeout). All other coordinator operations use majority WC. After a stepdown, the coordinator doc may reappear on the new primary and trigger redundant re-execution of all post-decision cleanup operations.
- Code analysis: `migration_util.cpp:169–184, 255` (SERVER-103838) — `serializeAndRedactCoordinatorDocument` conditionally strips `transfersFirstCollectionChunkToRecipient` below FCV 8.2. An FCV downgrade during active migration recovery leaves a coordinator doc with an unrecognized field, causing the older binary to reject it.
- Code analysis: `migration_coordinator.cpp:252–255` — `advanceTransactionOnRecipient` on the commit path has no `ShardNotFound` catch, while the same call on the abort path (lines 361–364) is wrapped. An asymmetric exception in the commit path leaves `deleteRangeDeletionTaskOnRecipient` unexecuted.

**Affected code paths**:
- `MigrationCoordinator::forgetMigration` (`coordinator.cpp:389–401`)
- `migrationutil::serializeAndRedactCoordinatorDocument` (`migration_util.cpp:169–184`)
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient` (`coordinator.cpp:252`)

**Priority**: Low (for TLA+); these are better addressed by code review and testing.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Async recipient crit-sec release before decision persist | Family 1: root cause of commit-path crash window | Split commit into `LaunchReleaseCritSec` (async fire), `PersistDecision` (durable), `CrashDonor` (crash between) |
| Commit decision persistence as distinct durable step | Family 1: whether the decision is durable determines recovery outcome | `decisionPersisted` variable; `PersistCommitDecision` and `PersistAbortDecision` actions |
| Donor crash and recovery | Family 1+3: validates recovery path correctness | `Crash` action resets volatile state; recovery re-reads coordinator doc; if no decision, call no-op |
| Range deletion task lifecycle (4 states: absent/pending/ready on donor + recipient) | Family 3: task state must be consistent with migration outcome | Two variables `donorRDTask`, `recipientRDTask`; modeled as separate actions for each transition |
| Recovery path kFail/kAbort guard asymmetry | Family 2: silent state override causes incorrect commit after abort | Introduce `abortSignaled` variable; recovery action conditionally overwrites state |
| Config server commit idempotency | Baseline: `commitChunkMigration` is idempotent; this should be a given in the spec, not an adversary | Model as single atomic action with retry; no need to split |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| MVCC snapshot staleness in xferMods (Family 4) | Requires WiredTiger storage engine semantics; not abstractable as protocol logic |
| `forgetMigration` w:1 vs majority (Family 5) | Idempotent re-execution on the re-run path is the intended design; no safety violation |
| `transferAfterCommit` flag | Implementation-level loop control; better verified by test than model checking |
| Session/txnNumber ordering | Requires modeling distributed transaction protocol internals; out of scope for chunk migration spec |
| FCV-gated schema (SERVER-103838) | Upgrade/downgrade compatibility, not protocol safety; better verified by compatibility tests |
| Data cloning batch mechanics | Performance/throughput concern; not a safety property of the commit protocol |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Async crit-sec release ordering | `critSecReleaseRPCSent`, `decisionPersisted` | Capture that RPC fires before durable write | Family 1 |
| Donor crash action | `donorCrashed`, `donorVolatileState` | Model crash between async launch and persist | Family 1 |
| Range deletion task states | `donorRDTask`, `recipientRDTask` | Track per-party task lifecycle vs. decision | Family 3 |
| Recovery kFail/kAbort guard | `recipientAbortSignaled` | Capture concurrent abort during recovery | Family 2 |
| Config server commit state | `configCommitted` | Track whether config server has recorded the migration | Family 1, baseline |
| Coordinator doc present/absent | `coordinatorDocPresent`, `coordinatorDocDecision` | Drive recovery branching correctly | Family 1, Family 3 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| CommitDecisionDurabilityBeforeRelease | Safety | If `critSecReleaseRPCSent == TRUE` and `donorCrashed == TRUE`, then `decisionPersisted != none` OR the migration must be recoverable to a consistent state | Family 1 |
| RangeDeletionConsistency | Safety | After migration outcome is final: if committed, `donorRDTask == ready ∧ recipientRDTask == absent`; if aborted, `donorRDTask == absent ∧ recipientRDTask == ready` | Family 3 |
| RecoveryHonorsAbort | Safety | If `recipientAbortSignaled == TRUE` before recovery completes, `recipientState != kEnteredCritSec` after recovery | Family 2 |
| NoOrphanAfterCommit | Safety | If `configCommitted == TRUE`, no in-range document can be deleted from the recipient by the range deleter | Family 3 |
| CoordinatorDocEventuallyGone | Liveness | After migration decision, `coordinatorDocPresent` eventually becomes FALSE | Family 1, Family 5 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC-1 | Does the no-decision early-return in `completeMigration` leave the migration in a permanently inconsistent state when the recipient's crit sec has already been released? | CommitDecisionDurabilityBeforeRelease, NoOrphanAfterCommit | Family 1 |
| MC-2 | Can a crash between `persistCommitDecision` and `deleteRangeDeletionTaskOnRecipient` (via partial `_commitMigrationOnDonorAndRecipient`) leave recipient task alive after commit, causing data loss when the range deleter fires? | RangeDeletionConsistency, NoOrphanAfterCommit | Family 3 |
| MC-3 | Can a concurrent `abort()` call set `_state = kAbort` after `skipToCritSecTaken` is set, and the recovery path then overwrite it to `kEnteredCritSec`, causing a committed-but-should-be-aborted migration? | RecoveryHonorsAbort | Family 2 |
| MC-4 | Can the early-exit at `coordinator.cpp:285–294` (missing donor range deletion task on recovery) leave the recipient's deletion task permanently alive after commit, triggering orphan data deletion? | RangeDeletionConsistency | Family 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV-1 | Deferred XferMods stale snapshot: update arrives, snapshot opens, update is committed after snapshot, `findById` returns old version | Unit test with WiredTiger snapshot pinning; verify deferred ops post-abandonment |
| TV-2 | `onDeleteOp` silent drop when shard key missing from DocumentKey | Unit test with a delete that uses a non-`_id` shard key and verify deletion appears on recipient |
| TV-3 | `resumeMigrationRecipientsOnStepUp` invariant fires when two recovery docs exist | Inject a second recipient recovery doc and verify the invariant behavior |
| TV-4 | `startCommit` timeout races with recipient entering critical section | Integration test: inject delay between `kCommitStart` transition and `acquireRecoverableCriticalSectionBlockWrites` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `forgetMigration` uses W:1 while all other coordinator ops use majority | Consider upgrading to majority or documenting the idempotency guarantee explicitly |
| CR-2 | `advanceTransactionOnRecipient` on commit path has no `ShardNotFound` guard while abort path does | Add matching `ShardNotFound` catch on commit path (lines 252–255) |
| CR-3 | `drainMigrationsPendingRecovery` has no loop termination bound | Add iteration count or timeout to prevent infinite blocking on step-up |
| CR-4 | `restoreRecoveredMigrationState` does not restore `_collectionUuid`, `_fromShard`, `_toShard` | Audit all fields used in the recovery-path branches and restore them |
| CR-5 | Change stream noop oplog entry (`notifyChangeStreamsOnChunkMigrated`) not emitted during recovery | Add emission in `_commitMigrationOnDonorAndRecipient` recovery path |

---

## 7. Reference Pointers

- **Key source files**:
  - `src/mongo/db/s/migration_coordinator.cpp` — commit/abort/recovery decision logic (427 lines)
  - `src/mongo/db/s/migration_source_manager.cpp` — donor state machine (1034 lines)
  - `src/mongo/db/s/migration_destination_manager.cpp` — recipient state machine (2291 lines)
  - `src/mongo/db/s/migration_chunk_cloner_source.cpp` — transfer-mods pipeline (1655 lines)
  - `src/mongo/db/s/migration_util.cpp` — step-up recovery orchestration (626 lines)
  - `src/mongo/db/s/README_migrations.md` — protocol diagram and synchronization overview

- **Key line ranges**:
  - Commit-path async crit-sec launch: `coordinator.cpp:204–206`
  - Commit-path decision persist: `coordinator.cpp:240`
  - Abort-path (correct ordering, for reference): `coordinator.cpp:334, 338`
  - Recovery no-decision early-return: `coordinator.cpp:186–196`
  - Recovery path kFail/kAbort override: `destination_manager.cpp:1917–1930` vs. normal path `1896–1902`
  - Range deletion task early-exit on recovery: `coordinator.cpp:285–294`
  - Donor range deletion task before coordinator doc: `migration_source_manager.cpp:472–500`

- **Known tickets referenced in source**:
  - SERVER-103838: FCV-gated coordinator document field serialization
  - SERVER-92531: Missing cleanup infrastructure for early-stage abort
  - SERVER-71444: UninterruptibleLockGuard in cleanup path

- **Protocol reference**: MongoDB documentation on moveRange command and sharding migration recovery; `README_migrations.md` in the same directory
