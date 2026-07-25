# Modeling Brief: MongoDB MoveRange — Chunk Migration Commit Protocol

## 1. System Overview

- **System**: MongoDB chunk migration (moveRange) — the protocol for moving a range of data from one shard to another in a sharded cluster
- **Language**: C++, ~5000 LOC core logic (migration_coordinator.cpp 427, migration_source_manager.cpp 1034, migration_destination_manager.cpp 2291, range_deletion_util.cpp 850)
- **Protocol**: Two-phase commit with coordinator recovery, based on a persistent coordinator document on the donor shard
- **Key architectural choices**:
  - Donor shard orchestrates the migration (not the config server)
  - Coordinator document in `config.migrationCoordinators` serves as write-ahead log for crash recovery
  - Range deletion tasks in `config.rangeDeletions` act as persistent locks preventing overlapping migrations
  - Critical section has two phases: catch-up (blocks writes only) and commit (blocks reads+writes)
  - `forgetMigration` uses w:1 write concern (all other ops use majority), relying on idempotent recovery
  - Recovery derives ambiguous decisions from config server state (not local persistence)
- **Concurrency model**: Single migration thread per shard (enforced by `ActiveMigrationsRegistry`); range deleter on a separate single-threaded executor; step-down can interrupt any operation
- **Existing TLA+ spec**: `MoveRange.tla` (487 lines) models migration states + read routing + range deletion. Does NOT model failover, writes, replication, or recovery.

## 2. Bug Families

### Family 1: Coordinator Recovery Under Stepdown (HIGH)

**Mechanism**: The migration coordinator's state machine has crash windows between non-atomic steps. When a stepdown occurs mid-commit, recovery must re-derive the migration decision from external state (config server), and the commit/abort side-effects must be idempotent. Failures in this recovery path cause hung migrations, data loss, or crashes.

**Evidence**:
- Historical: SERVER-50890 — Coordinator doc insert fails, abort path retries indefinitely (hung migration). Fixed by making persist use upsert.
- Historical: SERVER-32593 — Stepdown after failed config commit triggers fassert crash. Fixed by checking primary status before asserting.
- Historical: SERVER-46395 — Rapid stepdown/stepup creates duplicate range deletion tasks, allowing overlapping migrations that corrupt data.
- Historical: SERVER-89163 — Missing majority write concern before recipient critical section allows data loss on failover (1-line fix with major safety impact).
- Historical: SERVER-62245 — Recovery assumed only one migration needed recovery, could lose migrations.
- Historical: SERVER-62282 — Recovery gave up after first failure instead of retrying until success.
- Historical: SERVER-65947 — Recipient recovery fails when critical section release fails, major rewrite (+356/-153 lines).
- Code analysis: `migration_coordinator.cpp:252-255` — Commit path does NOT catch `ShardNotFound` for `advanceTransactionOnRecipient` (abort path does at line 365). If recipient shard is removed after commit, recovery retries forever.
- Code analysis: `migration_util.cpp:291-295` — `persistCommitDecision` silently swallows `NoMatchingDocument`, proceeding with commit side-effects even without durable decision. Crash after this = lost range deletion cleanup.
- Code analysis: `migration_source_manager.cpp:706-744` — Post-commit refresh failure calls `_cleanup(false)` without scheduling async recovery. Orphans persist until next migration or failover.
- Code analysis: `migration_coordinator.cpp:400` — `forgetMigration` uses w:1 (not majority). Stepdown before replication means recovery re-executes entire commit path.

**Affected code paths**:
- `MigrationCoordinator::completeMigration()` (migration_coordinator.cpp:183-229)
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:231-324)
- `MigrationCoordinator::_abortMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:326-387)
- Recovery: `_recoverMigrationCoordinations()` (shard_filtering_metadata_refresh.cpp:495-635)
- Recipient recovery: `restoreRecoveredMigrationState()` (migration_destination_manager.cpp:600-654)

**Suggested modeling approach**:
- Variables: `coordinatorDoc[Shard]` (with fields: exists, hasDecision, decision), `configServerCommitted[Key]`, `recipientRecoveryDoc[Shard]`
- Actions: Split `MigrateCommitOnConfigShard` into: `SendCommitToConfigServer`, `ConfigServerPersistsCommit`, `DonorReceivesCommitResponse` (may fail/lose response), `DonorPersistsDecision`, `DonorExecutesCommitSideEffects`, `DonorForgetsCoordinatorDoc`
- Add `Stepdown(shard)` action that clears in-memory state, preserves persistent state
- Add `Recovery(shard)` action that reads coordinator doc, queries config server if no decision, then re-executes commit/abort
- Model w:1 vs majority write concern: `forgetMigration` can be rolled back on stepdown

**Priority**: High
**Rationale**: 41 historical bugs (23 deadlock/stepdown + 18 recovery). 5 new code-level findings. The existing spec models commit as a single atomic step — splitting it into the real sub-steps with stepdown interleavings is the highest-value extension.

---

### Family 2: Range Deletion Safety (HIGH)

**Mechanism**: Range deletion tasks serve dual purpose: (1) track orphan cleanup work, (2) act as persistent locks preventing overlapping migrations. Bugs occur when the task lifecycle (pending -> ready -> processing -> deleted) gets out of sync with migration state, especially during stepdown/recovery.

**Evidence**:
- Historical: SERVER-60518 — TOCTOU race: range deleter validates metadata, metadata cleared by concurrent rename, deletion skips orphans permanently.
- Historical: SERVER-46395 — Range deletion task document deleted during deletion, allowing overlapping migration to corrupt data.
- Historical: SERVER-119435 (Feb 2026) — Deadlock in range deletion registration from lock ordering with service shutdown.
- Historical: SERVER-115921 (Dec 2025) — SharedPromise double-complete race between step-up and shutdown.
- Historical: SERVER-52906 — Orphaned documents on recipient block future migrations until manually cleaned.
- Historical: SERVER-63243 — Round-robin deletion ordering causes oldest orphans to persist indefinitely.
- Code analysis: `range_deletion_util.cpp:246-271` — `ensureRangeDeletionTaskStillExists` and `deleteNextBatch` at line 382 are NOT atomic. TOCTOU window if task doc deleted externally.
- Code analysis: `range_deleter_service.h:155-156` — Comment explicitly warns: "in case an overlapping range deletion task is registered AFTER invoking [getOverlappingRangeDeletionsFuture], it will not be taken into account."
- Code analysis: `range_deletion_util.cpp:535-557` — `persistUpdatedNumOrphans` uses non-idempotent `$inc`. Recovery re-execution double-counts orphans.
- Code analysis: `migration_coordinator.cpp:347-350` — Abort path: `deleteRangeDeletionTaskLocally` failure prevents `markAsReadyRangeDeletionTaskOnRecipient`, leaving orphans on recipient.

**Affected code paths**:
- `deleteRangeInBatches()` (range_deletion_util.cpp:335-437)
- `ensureRangeDeletionTaskStillExists()` (range_deletion_util.cpp:243-271)
- `RangeDeleterService::registerTask()` (range_deleter_service.cpp:361-489)
- `_commitMigrationOnDonorAndRecipient` orphan count path (migration_coordinator.cpp:265-271)
- `_abortMigrationOnDonorAndRecipient` cleanup path (migration_coordinator.cpp:326-387)

**Suggested modeling approach**:
- Variables: `rangeDeletionTasks[Shard]` (set of {range, state: pending/ready/processing}), `orphanDocuments[Shard][Key]`
- Actions: `CreatePendingRangeDeletionTask`, `MarkTaskReady`, `StartProcessingTask`, `DeleteBatch`, `RemoveTask`
- Add `MigrateBackToShard(key)` action that checks for conflicting deletions
- Key invariant: "Range deletion never deletes documents belonging to a currently-owned chunk"
- Key invariant: "No overlapping migration starts while a range deletion task exists for the same range"

**Priority**: High
**Rationale**: 15 historical bugs spanning 2020-2026 (still being fixed — SERVER-119435 was Feb 2026). Range deletion is the most error-prone subsystem. The existing spec's `DeleteRange` action is too simplified to catch these interaction bugs. Two new code-level findings (DA-1, DA-7).

---

### Family 3: Commit/Abort Path Asymmetry (MEDIUM)

**Mechanism**: The commit and abort code paths in `MigrationCoordinator` handle the same operations (advance txn, delete/mark range deletion tasks) but with different error handling. Missing catches, different ordering, and inconsistent idempotency properties create windows where partial execution leaves inconsistent state.

**Evidence**:
- Code analysis: `migration_coordinator.cpp:252-255` — Commit path: `advanceTransactionOnRecipient` NOT in try-catch. Abort path (line 361-365): same call IS in try-catch for `ShardNotFound`.
- Code analysis: `migration_coordinator.cpp:347-350` — Abort path: `deleteRangeDeletionTaskLocally` NOT in try-catch. Commit path's analogous `markAsReadyRangeDeletionTaskLocally` (line 320) catches `NoMatchingDocument`.
- Code analysis: `migration_coordinator.cpp:382` — Abort path: `markAsReadyRangeDeletionTaskOnRecipient` only executes if `advanceTransactionOnRecipient` succeeds (non-ShardNotFound error skips it).
- Historical: SERVER-45246 — Decision sent to recipient was not retryable (commit path), fixed by making it a retryable write.

**Affected code paths**:
- `_commitMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:231-324)
- `_abortMigrationOnDonorAndRecipient()` (migration_coordinator.cpp:326-387)

**Suggested modeling approach**:
- Model commit and abort as separate action sequences with distinct error handling
- Inject failures at each step independently
- Check that both paths leave the system in a consistent state regardless of which step fails

**Priority**: Medium
**Rationale**: Direct asymmetry between commit and abort paths. The commit path's missing `ShardNotFound` catch (DA-2) can cause infinite retry loops. Modeling both paths with fault injection would expose asymmetric failure modes.

---

### Family 4: Metadata Consistency During Concurrent Operations (MEDIUM)

**Mechanism**: After migration commit on the config server, there is a window where routing metadata on the donor, recipient, and routers is inconsistent. Operations during this window can observe stale state.

**Evidence**:
- Historical: SERVER-26471 — After commit, recipient becomes donor for another migration before refreshing metadata. Incremental refresh misses committed chunk.
- Historical: SERVER-84761 — Stale placement info in MigrationSourceManager affects migration decisions.
- Historical: SERVER-44975 — Donor must retry refreshing filtering metadata until success before leaving critical section.
- Code analysis: `migration_coordinator.cpp:210-211` — `waitForDurableConfigTime()` before decision execution is critical ordering requirement.
- Code analysis: `migration_source_manager.cpp:706-744` — Post-commit refresh failure leaves donor with cleared metadata; queries may fail.

**Affected code paths**:
- `commitChunkMetadataOnConfig()` (migration_source_manager.cpp:626-830)
- `_recoverMigrationCoordinations()` (shard_filtering_metadata_refresh.cpp:495-635)

**Suggested modeling approach**:
- Variables: `shardMetadata[Shard]` (owned chunks view), `configServerMetadata` (authoritative)
- Actions: `RefreshMetadata(shard)`, `ConcurrentMigration(key)` starting during post-commit cleanup
- Invariant: "After migration completes, all shards' metadata eventually reflects new ownership"

**Priority**: Medium
**Rationale**: SERVER-26471 is a textbook race that TLA+ catches. The existing spec models routing table consistency, so this is a targeted extension.

---

### Family 5: Lock Ordering Deadlocks (LOW for TLA+)

**Mechanism**: Multiple locks (RSTL, collection locks, `_mutex`, session checkout, `ScopedRangeDeleterLock`) acquired in different orders by migration, stepdown, and range deleter threads.

**Evidence**:
- Historical: SERVER-66825 — AB/BA deadlock: `exitCriticalSection` holds `_mutex` while acquiring collection lock; stepdown holds collection lock and needs `_mutex`.
- Historical: SERVER-49508 — Migration recovery vs prepared transaction: MODE_X vs MODE_IX circular dependency.
- Historical: SERVER-55573 — Stepdown blocks on session checkin hidden by `AlternativeClientRegion`.
- Historical: SERVER-70888 — `ScopedRangeDeleterLock` blocks on RSTL during stepdown.
- Historical: SERVER-119435 — Range deletion registration deadlock with service shutdown (Feb 2026).
- Code analysis: `migration_source_manager.cpp` — 5 TODO(SERVER-71444) for `UninterruptibleLockGuard` usage.

**Priority**: Low (for TLA+ modeling)
**Rationale**: 6 deadlock bugs, but all are implementation-level lock ordering issues. TLA+ can model abstract lock ordering, but the real bugs depend on C++ threading details. Better found by lock-order checking tools. Not recommended for TLA+ modeling.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Non-atomic commit protocol with stepdown | Family 1: 41 historical bugs, highest-density bug area | Split MigrateCommitOnConfigShard into 6 sub-steps, add Stepdown action between each |
| Recovery protocol | Family 1: recovery derives decision from config server, has subtle invariants | Add Recovery action that reads coordinator doc + config server state |
| Write concern (w:1 vs majority) | Family 1: forgetMigration w:1 allows rollback on stepdown, SERVER-89163 | Boolean `majorityCommitted` per operation, stepdown rolls back non-majority ops |
| Range deletion task lifecycle | Family 2: persistent lock mechanism, 15 historical + 2 new findings | Model pending/ready/processing states, conflicting deletion check |
| Two-phase critical section | Family 4: read consistency during Phase 1 -> Phase 2 transition | Split critical section into write-block and read+write-block phases |
| Commit/abort path asymmetry | Family 3: different error handling creates inconsistent failure modes | Model commit and abort as distinct action sequences with independent faults |
| Config server as authority | Family 4: recovery derives decisions from config state | Track config server metadata separately from shard metadata |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Lock ordering / RSTL semantics | Family 5: implementation-level lock hierarchy, better found by lock-order tools |
| Session checkout / AlternativeClientRegion | Family 5: C++ threading mechanism, not protocol logic |
| Prepared transactions | Interaction with migration is via lock contention, not protocol state |
| Clone convergence (catch-up loop) | Performance/liveness only, not safety. SERVER-56307 is a tuning bug. |
| Op observer / transfer mods queue | Deep analysis found no bugs. MODE_S barrier correctness is single-node. |
| Orphan count tracking (`$inc`) | Bookkeeping, not safety. DA-1 is a data quality issue, not a safety violation. |
| Session migration | Separate subsystem, no interaction with commit protocol safety. |
| Index build interaction | Implementation detail during data transfer phase. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-atomic commit | `coordinatorDoc`, `configServerDecision`, `sideEffectsExecuted` | Model crash windows between commit sub-steps | Family 1 |
| Stepdown/Recovery | `isPrimary[Shard]`, `persistedState[Shard]` | Model stepdown at any point + recovery protocol | Family 1 |
| Write concern | `majorityAcked[Operation]` | Distinguish w:1 from majority, allow rollback | Family 1 |
| Range deletion lifecycle | `rangeDeletionTasks[Shard]` with pending/ready/processing states | Model persistent lock + cleanup interaction | Family 2 |
| Two-phase critical section | `critSecPhase` (none/writeBlock/readWriteBlock) | Model read availability during Phase 1 | Family 3, 4 |
| Shard metadata refresh | `shardMetadata[Shard]`, `metadataStale[Shard]` | Model inconsistency window after commit | Family 4 |
| Recipient recovery doc | `recipientRecoveryDoc[Shard]` | Model recipient-side failover and critical section recovery | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ChunkOwnershipConsistent | Safety | At most one shard owns a chunk at any given time (outside critical section) | Standard, Family 4 |
| RangeDeletionSafety | Safety | Range deletion never deletes documents belonging to a currently-owned chunk | Family 2 |
| NoOverlappingMigrations | Safety | No two migrations operate on the same chunk range simultaneously | Family 2 |
| RecoveryConsistency | Safety | After stepdown+recovery, the migration outcome matches the config server's state | Family 1 |
| CoordinatorDecisionDurability | Safety | If commit side-effects are executed, the decision is majority-committed OR recoverable from config server | Family 1 |
| CriticalSectionBlocksReads | Safety | While critical section is in commit phase, no read returns stale data from donor | Standard, Family 4 |
| NoOrphanedCriticalSection | Safety | No shard holds a critical section indefinitely after migration completes | Family 1 |
| MigrationEventuallyCompletes | Liveness | Every started migration eventually reaches committed or aborted state | Family 1, 3 |
| RangeDeletionEventuallyCompletes | Liveness | Every ready range deletion task eventually finishes and is removed | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Stepdown between config server commit and persistCommitDecision: recovery must re-derive decision from config server | RecoveryConsistency if derivation logic has bug | Family 1 |
| MC-2 | forgetMigration w:1 rollback: stepdown after w:1 delete causes recovery to re-execute all commit side-effects | CoordinatorDecisionDurability (should hold if idempotent) | Family 1 |
| MC-3 | Commit path doesn't catch ShardNotFound for advanceTransactionOnRecipient: recipient removal causes infinite retry | MigrationEventuallyCompletes violation | Family 1, 3 |
| MC-4 | Recipient recovery stalls: donor forgets migration (coordinator doc deleted), recipient holds critical section waiting for release signal | NoOrphanedCriticalSection, MigrationEventuallyCompletes | Family 1 |
| MC-5 | Back-to-back migration: chunk migrates A->B, then B->A before range deletion on A completes | RangeDeletionSafety, NoOverlappingMigrations | Family 2 |
| MC-6 | Range deletion TOCTOU: task doc deleted externally between check and delete, new migration starts | RangeDeletionSafety | Family 2 |
| MC-7 | Duplicate range deletion tasks after rapid stepdown/stepup (SERVER-46395 pattern) | NoOverlappingMigrations | Family 2 |
| MC-8 | Post-commit refresh failure + no async recovery: orphans persist indefinitely | MigrationEventuallyCompletes, RangeDeletionEventuallyCompletes | Family 1 |
| MC-9 | Abort path: deleteRangeDeletionTaskLocally failure prevents markAsReadyOnRecipient | RangeDeletionEventuallyCompletes | Family 2, 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | persistCommitDecision swallows NoMatchingDocument (migration_util.cpp:291) | Delete coordinator doc from config.migrationCoordinators during commit, verify range deletion still happens |
| TV-2 | Recipient critical section held indefinitely when donor has forgotten migration | Stepdown donor after forgetMigration, stepdown recipient, verify recipient releases critical section on recovery |
| TV-3 | Non-idempotent $inc on orphan count (range_deletion_util.cpp:549) | Stepdown after persistUpdatedNumOrphans but before forgetMigration, check orphan count accuracy |
| TV-4 | Recipient recovery livelock on critical section acquisition failure | Mock critical section failure, verify recovery eventually gives up or succeeds |
| TV-5 | Steady-state abort delayed by continuous transferMods (destination_manager.cpp:1777) | Abort migration under heavy write load, measure abort latency |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | SERVER-71444 TODO (5 occurrences): UninterruptibleLockGuard usage can stall stepdown | Track ticket resolution; these are known issues with potential read unavailability impact |
| CR-2 | `_notePending` / `_forgetPending` are dead code (destination_manager.h:288,294) | Remove vestigial code |
| CR-3 | `restoreRecoveredMigrationState` leaves `_fromShard` etc. uninitialized | Verify no code path in recovery references these fields |
| CR-4 | `_recoverMigrationCoordinations` invariant crashes on multiple coordinator docs (shard_filtering_metadata_refresh.cpp:516) | Consider graceful handling instead of fassert |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-moverange/analysis-report.md`
- **Existing TLA+ spec**: `artifact/mongo-src/src/mongo/tla_plus/Sharding/MoveRange/MoveRange.tla` (487 lines — migration commit + read routing)
- **Key source files**:
  - `artifact/mongo-src/src/mongo/db/s/migration_coordinator.cpp` (427 lines — coordinator state machine)
  - `artifact/mongo-src/src/mongo/db/s/migration_source_manager.cpp` (1034 lines — donor orchestration)
  - `artifact/mongo-src/src/mongo/db/s/migration_destination_manager.cpp` (2291 lines — recipient state machine)
  - `artifact/mongo-src/src/mongo/db/s/range_deletion_util.cpp` (850 lines — range deletion operations)
  - `artifact/mongo-src/src/mongo/db/s/range_deleter_service.cpp` (530 lines — range deleter lifecycle)
  - `artifact/mongo-src/src/mongo/db/s/migration_util.cpp` (900+ lines — recovery, retry, persistence)
- **MongoDB JIRA tickets**: SERVER-32593, SERVER-50890, SERVER-89163, SERVER-46395, SERVER-49508, SERVER-60518, SERVER-62245, SERVER-62282, SERVER-65947, SERVER-119435, SERVER-115921, SERVER-26471
- **README docs**: `artifact/mongo-src/src/mongo/db/s/README_migrations.md`, `README_range_deleter.md`
- **Shared harness**: `case-studies/mongodb-shared-harness.md` (Docker compose, log parsing approach)
