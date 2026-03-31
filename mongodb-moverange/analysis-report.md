# Analysis Report: MongoDB MoveRange — Chunk Migration Commit Protocol

## Coverage Statistics

- **Git commits analyzed**: 150+ unique bug-fix commits across 7 core files
- **SERVER tickets referenced in code**: 7 (SERVER-92531, SERVER-71444, SERVER-51397, SERVER-62368, SERVER-103046, SERVER-103838)
- **Bug-fix commits by keyword**: fix(49), race(22), deadlock(6), hang(73), orphan(28), stepdown(17), recover(36), critical section(31), stale(12), crash(1)
- **Files deep-analyzed**: 6 (migration_coordinator.cpp, migration_source_manager.cpp, migration_destination_manager.cpp, migration_util.cpp, range_deletion_util.cpp, range_deleter_service.cpp)
- **Primary bug tracker**: MongoDB Jira (SERVER-* tickets). GitHub Issues disabled on mongodb/mongo.

## Phase 1: Reconnaissance

### Codebase Structure

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| Coordinator | migration_coordinator.cpp | 427 | Commit/abort decision, range deletion orchestration |
| Source Manager | migration_source_manager.cpp | 1034 | Donor-side state machine, critical section, config commit |
| Destination Manager | migration_destination_manager.cpp | 2291 | Recipient-side data ingest, critical section, recovery |
| Chunk Cloner Source | migration_chunk_cloner_source.cpp | 1655 | Op observer, transfer mods queue, clone data |
| Range Deletion Util | range_deletion_util.cpp | 850 | Batch deletion, task persistence, orphan tracking |
| Range Deleter Service | range_deleter_service.cpp | 530 | Primary-only service lifecycle, task registration |
| Migration Util | migration_util.cpp | 900+ | Recovery, retry, persistence helpers |

### Migration Protocol Flow (Implementation)

```
1. Donor: Create coordinator doc + pending range deletion task (majority WC)
2. Recipient: Create pending range deletion task (majority WC)
3. Recipient: Clone data from donor in batches
4. Recipient: Catch up on writes via transferMods
5. Donor: Enter critical section Phase 1 (block writes)
6. Recipient: Final transferMods + enter critical section (block writes)
7. Donor: Upgrade critical section Phase 2 (block reads+writes)
8. Donor: Send _configsvrCommitChunkMigration to config server
9. Config server: Update chunk ownership metadata (atomic)
10. Donor: Persist commit decision to coordinator doc (majority WC)
11. Donor: Advance txn on recipient, delete recipient's range deletion task
12. Donor: Mark own range deletion task as ready (majority WC)
13. Donor: Delete coordinator doc (w:1 !)
14. Donor: Release critical section
15. Range deleter: Asynchronously delete orphaned documents on donor
```

### Existing TLA+ Spec Coverage

The existing `MoveRange.tla` (487 lines) models:
- 7 migration states: Unset -> Cloning -> RecipientPrepared -> AllPrepared -> ConfigShardCommitted -> RecipientCommitted -> Unset
- Read routing with cached routing tables and version-based staleness
- Timestamp-aware ownership filtering for point-in-time and untimestamped reads
- Range deletion (simplified: atomic, single-step)
- 6 safety invariants + 1 liveness property

**Does NOT model**: Failover/stepdown, recovery, writes, replication, two-phase critical section, range deletion lifecycle, concurrent migrations on different ranges, network failures

### Concurrency Model

- **Single migration per shard**: `ActiveMigrationsRegistry` enforces exclusive access
- **Migration thread**: Dedicated thread on recipient (`_migrateThread`)
- **Range deleter**: Separate single-threaded executor (`ReadyRangeDeletionsProcessor`)
- **Stepdown**: Can interrupt any operation via `OperationContext::markKilled()`
- **Recovery**: Runs on fixed executor pool after step-up
- **Critical locking resources**: RSTL, collection locks, `_mutex` per manager, `ScopedRangeDeleterLock`

## Phase 2: Bug Archaeology

### Hotspot Analysis

| File | Bug-fix Commits | Top Bug Types |
|------|----------------|---------------|
| migration_destination_manager.cpp | 61 | Race conditions, stepdown handling, recovery |
| migration_source_manager.cpp | 58 | Stepdown, critical section, config commit |
| migration_util.cpp | 37 | Recovery, retry logic, range deletion |
| range_deletion_util.cpp | 23 | Orphan handling, task lifecycle, batch deletion |
| range_deleter_service.cpp | 11 | Race conditions, deadlocks, step-up/step-down |
| migration_coordinator.cpp | 11 | Recovery, commit/abort paths, write concern |
| migration_chunk_cloner_source.cpp | 7 | Op observer races, assertion violations |

### Bug Categories (from 150+ commits)

| Category | Count | Key SERVER Tickets |
|----------|-------|--------------------|
| Race conditions | 22 | SERVER-84625, SERVER-83161, SERVER-71544, SERVER-115921, SERVER-115750 |
| Stepdown/deadlock | 23 | SERVER-119435, SERVER-70888, SERVER-66825, SERVER-55573, SERVER-49508 |
| Recovery bugs | 18 | SERVER-62245, SERVER-62282, SERVER-62296, SERVER-65947, SERVER-62857 |
| Orphan/range deletion | 15 | SERVER-60518, SERVER-46395, SERVER-63243, SERVER-81241, SERVER-68042 |
| Crash/fassert | 6 | SERVER-32593, SERVER-45752, SERVER-26145, SERVER-73264 |
| Stale metadata | 4 | SERVER-84761, SERVER-44975, SERVER-36132 |
| Critical section | 7 | SERVER-60413, SERVER-48679, SERVER-89163 |
| Retry resilience | 10 | SERVER-50890, SERVER-45520, SERVER-46383, SERVER-45246, SERVER-45339 |

### Key Historical Bugs (Detailed)

#### SERVER-32593: Stepdown after failed config commit crashes source shard
- **Root cause**: `migration_source_manager.cpp` asserted primary status after config commit failed, but node had stepped down
- **Fix**: Check primary status before asserting (commit `153610cb74`)
- **Impact**: Process crash on stepdown during migration

#### SERVER-46395: Range deletion task persistence race
- **Root cause**: Range deletion task document could be deleted while deletion was in progress during rapid stepdown/stepup
- **Fix**: Verify task document exists during each deletion batch (commit `90eefa051e`, +136 lines)
- **Impact**: Data corruption — overlapping migrations accepted

#### SERVER-60518: Best-effort range deleter leaves orphans
- **Root cause**: Range deleter checked metadata (best-effort), metadata cleared by concurrent rename, deletion skipped
- **Fix**: Remove best-effort path, always complete deletion (commit `3ed974c923`, +99/-93 lines)
- **Impact**: Permanent orphaned documents

#### SERVER-49508: Step-up deadlock between migration recovery and prepared transactions
- **Root cause**: Migration recovery acquires MODE_X collection lock, prepared transaction holds MODE_IX, circular dependency
- **Fix**: Move recovery to avoid holding both locks simultaneously (commit `c857e1dcb2`)
- **Impact**: Server deadlock on step-up

#### SERVER-62245: Recovery assumes only one migration needs recovery
- **Root cause**: `_recoverMigrationCoordinations` had single-migration assumption
- **Fix**: Support multiple concurrent recoveries (commit `8e6ab9a259`)
- **Impact**: Lost migration recovery — orphaned range deletion tasks

#### SERVER-89163: Missing majority WC before recipient critical section
- **Root cause**: Recipient entered critical section without waiting for majority replication of state
- **Fix**: One-line addition of `waitForMajority()` (commit `9774047167`)
- **Impact**: Data loss on failover — committed state lost

#### SERVER-119435: Deadlock with range deletion task registration (Feb 2026)
- **Root cause**: Lock ordering inconsistency between task registration and service shutdown
- **Fix**: Restructured lock acquisition order (commit `9343c350ae`, +63/-28 lines)
- **Impact**: Server deadlock during range deletion registration

#### SERVER-65947: Recipient recovery fails when critical section release fails
- **Root cause**: Error during critical section release left recipient in unrecoverable state
- **Fix**: Major rewrite of recipient error handling (+356/-153 lines, commit `5bd946b1fc`)
- **Impact**: Recipient stuck with critical section held after failed migration

#### SERVER-62282: Migration recovery should retry until success
- **Root cause**: Recovery gave up after first failure, leaving migration state inconsistent
- **Fix**: Wrap recovery in `retryIdempotentWorkAsPrimaryUntilSuccessOrStepdown` (commit `e7cf352780`)
- **Impact**: Unfinished migrations with lingering coordinator documents

#### SERVER-50890: Coordinator doc insert fails during retry
- **Root cause**: Coordinator document upsert could fail on retry, leaving migration in indeterminate state
- **Fix**: Major rewrite of failover management in coordinator (commit `40aa110c65`)
- **Impact**: Hung migration that cannot be recovered

### Developer Signals (TODO/FIXME in Code)

| Ticket | File | Occurrences | Risk |
|--------|------|-------------|------|
| SERVER-71444 | migration_source_manager.cpp | 5 | `UninterruptibleLockGuard` usage can stall stepdown indefinitely |
| SERVER-92531 | migration_source_manager.cpp | 1 | Early-stage abort cleanup infrastructure incomplete |
| SERVER-103046 | range_deletion_util.cpp | 1 | Legacy field cleanup (9.0 LTS migration) |
| SERVER-103838 | migration_util.cpp | 2 | FCV-gated field serialization cleanup |

## Phase 3: Deep Analysis Findings

### Finding DA-1: Non-idempotent `$inc` for orphan count in recovery path (MEDIUM-HIGH)

**File**: `range_deletion_util.cpp:535-557`, called from `migration_coordinator.cpp:269-270`

The commit path calls `persistUpdatedNumOrphans()` which uses `$inc` to update the orphan count. This is **not idempotent**. If the node crashes after this `$inc` but before `forgetMigration`, recovery re-executes the entire commit path, including a second `$inc`, double-counting orphans.

Combined with `forgetMigration` using `w:1` (migration_coordinator.cpp:400), a stepdown after `forgetMigration` is locally acked but before majority replication also triggers re-execution.

**Impact**: Permanently inflated orphan counts, affecting balancer decisions.
**Classification**: Model-checkable — model the `$inc` as a non-idempotent side-effect and check orphan count accuracy after recovery.

### Finding DA-2: Commit path missing `ShardNotFound` catch for `advanceTransactionOnRecipient` (MEDIUM)

**File**: `migration_coordinator.cpp:252-255` vs `migration_coordinator.cpp:361-365`

In `_commitMigrationOnDonorAndRecipient`, `advanceTransactionOnRecipient` is called without a try-catch for `ShardNotFound`. The abort path wraps the same call in a try-catch. If the recipient shard is removed after the commit decision is persisted, the commit path throws, and recovery retries indefinitely in `retryIdempotentWorkAsPrimaryUntilSuccessOrStepdown` (no upper bound on retries, no backoff for this path).

**Impact**: Migration recovery loops forever if recipient shard is removed post-commit.
**Classification**: Model-checkable — inject shard removal after commit decision.

### Finding DA-3: `persistCommitDecision` swallows `NoMatchingDocument` and continues (MEDIUM)

**File**: `migration_util.cpp:288-295`

If the coordinator document was already deleted (e.g., by concurrent cleanup or operator intervention), `persistCommitDecision` logs an error but continues. The commit side-effects (delete recipient task, mark donor ready) proceed without a durable decision. If the node crashes after `deleteRangeDeletionTaskOnRecipient` but before completing, recovery finds no coordinator document and cannot re-derive the decision.

**Impact**: Lost range deletion cleanup — orphaned state on recipient.
**Classification**: Model-checkable — model concurrent coordinator doc deletion.

### Finding DA-4: Post-commit refresh failure skips async recovery scheduling (MEDIUM)

**File**: `migration_source_manager.cpp:706-744`

When `commitChunkMetadataOnConfig` succeeds but the subsequent metadata refresh fails (line 714), the code calls `_cleanup(false)` at line 743 without scheduling `asyncRecoverMigrationUntilSuccessOrStepDown`. The coordinator document persists but no proactive mechanism completes the migration. Recovery depends on the next migration starting (`drainMigrationsPendingRecovery`) or a failover.

In contrast, the config commit failure path at line 694-697 explicitly dismisses the guard and calls async recovery.

**Impact**: Orphan documents on donor persist indefinitely if no further migrations or failovers occur.
**Classification**: Model-checkable — inject refresh failure after successful commit, check liveness.

### Finding DA-5: `abort()` race with post-commit refresh kills cleanup without recovery (MEDIUM)

**File**: `migration_source_manager.cpp:863-869` vs `706-744`

`abort()` calls `_opCtx->markKilled()` from another thread. If this happens after config commit succeeds (line 679) but before the metadata refresh (line 714), `forceCollectionPlacementRefresh` throws. The catch at line 723 calls `_cleanup(false)` — same path as DA-4, without async recovery.

**Impact**: Same as DA-4 — orphan documents persist.
**Classification**: Model-checkable — inject abort concurrent with post-commit cleanup.

### Finding DA-6: Recipient recovery livelock on critical section acquisition failure (LOW-MEDIUM)

**File**: `migration_destination_manager.cpp:1904-1938`

During recovery (`skipToCritSecTaken=true`), if `acquireRecoverableCriticalSectionBlockWrites` fails, the exception propagates to `_migrateThread` (line 1316), which sets `recovering=true` and loops. The recovery document is NOT deleted in this path. On the next iteration, the recovery doc still exists (line 1286), so the thread retries indefinitely.

**Impact**: Recipient migration thread livelocks if critical section acquisition fails repeatedly.
**Classification**: Test-verifiable — mock critical section failure, verify recovery behavior.

### Finding DA-7: Abort path — `deleteRangeDeletionTaskLocally` failure prevents recipient cleanup (LOW-MEDIUM)

**File**: `migration_coordinator.cpp:347-350`

In `_abortMigrationOnDonorAndRecipient`, `deleteRangeDeletionTaskLocally` is NOT wrapped in a try-catch. If it throws, `markAsReadyRangeDeletionTaskOnRecipient` (line 382) never executes. The recipient's pending range deletion task is never marked ready.

In contrast, the commit path's `markAsReadyRangeDeletionTaskLocally` (range_deletion_util.cpp:729-734) catches `NoMatchingDocument` for idempotent recovery.

**Impact**: Orphaned data lingers on recipient after failed abort.
**Classification**: Model-checkable — inject failure during abort, check orphan cleanup liveness.

### Finding DA-8: Recovery invariant crashes on multiple coordinator docs per namespace (LOW)

**File**: `shard_filtering_metadata_refresh.cpp:516`

```cpp
invariant(++migrationRecoveryCount == 1);
```

Two coordinator documents for the same namespace (possible via DA-3 scenarios or manual intervention) crash the server. Combined with the `NoMatchingDocument` swallowing in DA-3, edge cases exist where stale coordinator documents could accumulate.

**Classification**: Code-review-only.

### Finding DA-9: `markRangeDeletionTaskAsProcessing` uses local write concern (LOW)

**File**: `range_deletion_util.cpp:290`

The `processing` flag uses `writeConcernLocalHavingUpstreamWaiter` (not majority). If the node steps down immediately after, the flag is lost. On recovery, the task is treated as regular non-pending rather than processing, affecting recovery ordering (processing tasks are prioritized).

**Classification**: Code-review-only — affects ordering, not correctness.

### Finding DA-10: Steady-state abort check gated on zero-size transfer mods (LOW)

**File**: `migration_destination_manager.cpp:1741-1807`

The steady-state loop checks for `kAbort` only when `mods["size"].number()` is 0 (line 1777-1780). Under continuous write load, the abort check is skipped via `continue` at line 1777, delaying abort indefinitely.

**Classification**: Test-verifiable — abort migration under heavy write load, measure delay.

## Spec vs. Implementation Gap Analysis

### Gaps Ranked by Model-Checking Value

| Priority | Gap | Historical Evidence | MC Value | Complexity |
|----------|-----|---------------------|----------|------------|
| P0 | Failover/stepdown during migration | 23 deadlock + 18 recovery bugs | HIGH | MEDIUM |
| P1 | Range deletion lifecycle + interactions | 15 orphan bugs | HIGH | MEDIUM |
| P1 | Two-phase critical section | Read consistency window | HIGH | LOW |
| P1 | Network failures during config commit | Dedicated failpoint exists | HIGH | MEDIUM |
| P2 | Concurrent writes during migration | 22 race conditions | MEDIUM | MEDIUM |
| P2 | State granularity mismatch | Interleaving correctness | MEDIUM | LOW-MEDIUM |
| P3 | Prepared transactions blocking | Explicit data loss scenario in code | LOW | MEDIUM |
| P3 | Session migration | Session correctness | LOW | HIGH |

### Detailed Gap: Failover/Stepdown (P0)

**Implementation mechanisms not in spec**:
- `MigrationCoordinatorDocument` in `config.migrationCoordinators` (write-ahead log)
- `MigrationRecipientRecoveryDocument` in `config.migrationRecipients`
- `RangeDeletionTask` documents in `config.rangeDeletions` with pending/ready lifecycle
- Recovery on step-up: `resumeMigrationCoordinationsOnStepUp` + `resumeMigrationRecipientsOnStepUp`
- `RangeDeletionRecoveryTracker` counting down from 2 before enabling range deleter

**Key crash windows**:
1. After config commit, before `persistCommitDecision` — decision lost, must re-derive from config server
2. After `persistCommitDecision`, before `deleteRangeDeletionTaskOnRecipient` — recipient task orphaned
3. After `markAsReadyRangeDeletionTaskLocally`, before `forgetMigration` — re-execution idempotent
4. After `forgetMigration` (w:1), before majority replication — re-execution idempotent
5. Recipient: after recovery doc persisted, before critical section acquired — recovery re-acquires
6. Recipient: after critical section acquired, before release signal received — stalls until donor releases

### Detailed Gap: Two-Phase Critical Section (P1)

**Phase 1 (write-block)**: `migration_source_manager.cpp:566` — `CollectionCriticalSection` blocks writes. Reads still succeed on donor with stale ownership.

**Phase 2 (read+write block)**: `migration_source_manager.cpp:659` — `_critSec->enterCommitPhase()` upgrades to block reads. No reads or writes during config server commit.

**Gap in spec**: Spec models critical section as single binary state. Reads during Phase 1 may return data that is about to be migrated, which the recipient may also serve — potential duplicate.

### Detailed Gap: Range Deletion Lifecycle (P1)

**Implementation lifecycle**:
```
Create(pending=true) -> MarkReady(unset pending) -> RegisterWithService -> StartProcessing -> DeleteBatches -> WaitMajority -> CompleteTask -> RemovePersistentDoc
```

**Existing spec**: `DeleteRange` is a single atomic step with simple guards (no migration, not owned, not filtered).

**Missing interactions**:
- Conflicting deletion blocks new migration start (`migration_source_manager.cpp:346-369`)
- Single-threaded executor assumption for safety (`range_deletion_util.cpp:253-254`)
- Recovery ordering: range deleter waits for migration coordinator recovery before processing
- `ensureRangeDeletionTaskStillExists` TOCTOU with concurrent migrations

## Bug Family Summary

| Family | Bugs (Historical) | New Findings | Priority | TLA+ Value |
|--------|-------------------|--------------|----------|------------|
| 1: Recovery under stepdown | 41 (deadlock/stepdown + recovery) | DA-2, DA-3, DA-4, DA-5, DA-8 | HIGH | HIGH |
| 2: Range deletion safety | 15 (orphan/deletion) | DA-1, DA-7 | HIGH | HIGH |
| 3: Lock ordering deadlocks | 6 (deadlock) | - | MEDIUM | LOW |
| 4: Metadata consistency | 4 (stale metadata) | - | MEDIUM | MEDIUM |
| 5: Write safety during migration | 22 (race conditions) | DA-10 | LOW (no new safety bugs) | MEDIUM |
