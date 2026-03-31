# Modeling Brief: MongoDB TxnsMoveRange — Transactions During Range Migration

## 1. System Overview

- **System**: MongoDB sharded cluster — multi-statement transactions interacting with chunk range migration
- **Language**: C++, ~12K LOC core logic (migration managers + transaction router + coordinator)
- **Protocol**: placementConflictTime-based conflict detection for transactions during chunk migration, with 6-step migration protocol, two-phase critical section, and persistent recovery coordination
- **Existing TLA+ spec**: `TxnsMoveRange.tla` (327 lines) — models single-atomic MoveRange with placementConflictTime checking. Already model-checked by MongoDB's team.
- **Key architectural choices**:
  - Migration is a 6-step protocol with two-phase critical section (write-block, then read+write-block) — not atomic
  - Config server commit is a separate network hop that can fail or return unknown status
  - Persistent `MigrationCoordinatorDocument` enables recovery after donor/recipient failover
  - Dual conflict paths: `atClusterTime` (snapshot readConcern) vs `placementConflictTime` (non-snapshot)
  - Router retry on stale errors resets `placementConflictTime` and re-targets with fresh timestamp
  - Sub-router mechanism allows shards to add new transaction participants dynamically

## 2. Bug Families

### Family 1: Non-Atomic Migration Protocol (Critical Section Windows) — HIGH

**Mechanism**: The 6-step migration protocol has multiple failure windows. The spec models MoveRange as atomic, missing all intermediate states where transactions can interact with partially-committed migrations.

**Evidence**:
- Historical: SERVER-62580 (commit `ae61a4d91c`) — Donor told recipient to exit critical section *before* confirming config server commit succeeded. Fix: moved `launchReleaseRecipientCriticalSection` after status check. If commit fails, recipient had already released CS, allowing writes to migrating range during recovery.
- Historical: SERVER-45752 — opCtx interruption during CS commit triggers fassert
- Historical: SERVER-65947 — recipient must recover if error during CS release
- Code analysis: Two-phase CS (`sharding_migration_critical_section.h:45-53`): catch-up phase (`readsShouldWaitOnCritSec=false`, line 113) blocks writes only; commit phase blocks reads+writes. Spec uses binary lock.
- Code analysis: Donor CS release (`migration_source_manager.cpp:926`) happens before commit decision persistence (`migration_coordinator.cpp:240`). Window where donor accepts operations but decision not durable.
- Code analysis: Recipient metadata refresh failure (`migration_destination_manager.cpp:2148`) clears metadata non-authoritatively and releases CS anyway, creating brief StaleConfig window.
- Code analysis: Config server sets `validAfter` from `VectorClock::get(opCtx)->getTime().clusterTime()` — separate network hop from CS entry.

**Affected code paths**: `migration_source_manager.cpp` (6 steps), `migration_coordinator.cpp:183-401` (completeMigration), `migration_destination_manager.cpp:1828-1960` (CS acquisition/release)

**Suggested modeling approach**:
- Variables: `migrationPhase[ns] ∈ {Idle, Cloning, CritSec_WriteBlock, CritSec_CommitBlock, ConfigCommitted, Done}`, `configDecision[ns] ∈ {None, Committed, Aborted}`
- Actions: Split `MoveRange` into: `StartMigration` (enter cloning), `EnterCriticalSection` (block writes), `EnterCommitPhase` (block reads+writes), `ConfigCommit` (separate step, can fail), `ReleaseCriticalSection`, `MigrationFail` (at any step)
- Granularity: The critical section phases are essential; cloning internals can be abstracted. The config commit MUST be a separate action from CS entry.

**Priority**: HIGH
**Rationale**: 3 historical bugs, all in the gap between spec's atomic MoveRange and reality. This is the #1 extension for finding new bugs.

---

### Family 2: placementConflictTime Propagation and Consistency — HIGH

**Mechanism**: The timestamp must be immutable per-transaction and consistently propagated to all participants. Multiple bugs arose from mutation during retries and missing propagation paths.

**Evidence**:
- Historical: SERVER-87660 — placementConflictTime could change mid-transaction (AtClusterTime::canChange allowed mutation)
- Historical: SERVER-102821 — BulkWrite missing placementConflictTime (nsInfo array not processed); first fix reverted (SERVER-103535)
- Historical: SERVER-85383 — aggregation pipeline not propagating timestamp to shard versions
- Code analysis: Spec's `createdDatabases` exemption is dead code — field propagated but never checked in RespondStatus
- Code analysis: `database_sharding_runtime.cpp:112-114` skips placement conflict check for created databases, could mask concurrent movePrimary conflicts
- Code analysis: Router retry resets timestamp (`transaction_router.cpp:1233`) — not modeled in spec

**Affected code paths**: `transaction_router.cpp:1207-1235` (onStaleShardOrDbError), `transaction_router.cpp:2035-2039` (timestamp selection), `collection_sharding_runtime.cpp:672-686` (enforcement), `database_sharding_runtime.cpp:95-150` (database check)

**Suggested modeling approach**:
- Variables: `rPlacementConflictTime[t]` (already exists), add `rRetryCount[t]` and `rCreatedDatabases[t]`
- Actions: Add `RouterRetryOnStale(t)` that clears participants, resets placementConflictTime, re-sends with new timestamp. Add `CreateDatabase(t, db)` that populates createdDatabases and enables the exemption. Implement the exemption check in ShardRespond.
- Granularity: Router retry is one action (reset + resend); the exemption is a predicate in the response status check

**Priority**: HIGH
**Rationale**: 4+ historical bugs with this mechanism, including a fix that was reverted. The router retry + fresh timestamp path is completely untested by the existing spec.

---

### Family 3: Failover During Migration With Active Transactions — HIGH

**Mechanism**: Donor or recipient stepdown during migration leaves the protocol in an intermediate state. Recovery requires re-acquiring critical sections, inferring commit decisions from config server metadata, and coordinating with the surviving nodes.

**Evidence**:
- Historical: SERVER-71219 — migration misses writes from prepared txns after step-up (op observer hook missing on non-primary prepare)
- Historical: SERVER-49508 — step-up deadlock between migration recovery and prepared transaction
- Historical: SERVER-76546 — _migrateClone deadlock with prepared txns on secondaries
- Historical: SERVER-113740 — precise checkpoint recovery lacks operation statements for migration hook (took 3 attempts to land)
- Historical: SERVER-48531 — 3-way deadlock: chunk splitter + prepared txns + stepdown
- Code analysis: `migration_coordinator.cpp:531-617` infers decision from config server metadata on recovery
- Code analysis: `migration_destination_manager.cpp:600-654` recovers recipient state from persisted recovery document

**Affected code paths**: `migration_source_manager.cpp:425-461` (wait for reclaimed prepared txns), `migration_coordinator.cpp:183-401` (completeMigration with recovery), `migration_destination_manager.cpp:1273-1327` (migrate thread retry loop), `shard_filtering_metadata_refresh.cpp:495-634` (_recoverMigrationCoordinations)

**Suggested modeling approach**:
- Variables: `primary[shard] \in Server`, `coordinatorDoc[ns] \in {None, Persisted(decision)}`, `recipientRecoveryDoc[ns] \in BOOLEAN`
- Actions: `DonorStepDown(shard)` (kills opCtx, triggers cleanup), `DonorStepUp(shard)` (drains pending migrations, reads coordinator doc, infers decision from config), `RecipientStepDown(shard)`, `RecipientStepUp(shard)` (re-acquires CS from recovery doc)
- Simplification: Model only donor stepdown (richest bug family). Skip lock-hierarchy modeling (deadlocks require different analysis tools). Focus on the recovery protocol's correctness: does the new primary correctly infer and complete the migration?

**Priority**: HIGH
**Rationale**: 7+ historical bugs (richest family). Recovery protocol has been a persistent source of bugs. Modeling donor stepdown during each migration phase would explore state space the existing spec completely ignores.

---

### Family 4: Stale Routing Error Propagation in Transactions — MEDIUM-HIGH

**Mechanism**: When a shard detects stale routing during a multi-statement transaction, incorrect error classification, suppression, or conversion causes the router to make wrong retry/abort decisions, leading to double execution, silent data loss, or transaction failure.

**Evidence**:
- Historical: SERVER-57051 (commit `4493d9309d`) — Shard silently retries after StaleConfig in a *continuing* transaction instead of propagating error to router. Used `inMultiDocumentTransaction()` instead of `isContinuingMultiDocumentTransaction()`. Router never learned routing was stale.
- Historical: SERVER-81508 (commit `bec596c52e`) — `ShardCannotRefreshDueToLocksHeld` thrown *after* write was already executed. Router retries entire batch, causing **double execution** of non-idempotent writes. Fix: record error in results instead of throwing.
- Historical: SERVER-93435 (commit `bbc6257af6`) — `StaleConfig` converted to `QueryPlanKilled` for `updateMany` in transaction (partial update detected). Loses `TransientTransactionError` label, prevents router retry. Fix: check `inMultiDocumentTransaction()` (txns rollback on abort, making retry safe).
- Code analysis: TODO SERVER-39704 ("Remove this fail point once the router can safely retry") — retry acknowledged as unsafe for production
- Code analysis: Asymmetric conflict checking — donor returns StaleConfig, recipient returns MigrationConflict; router handles differently
- Code analysis: `_clearPendingParticipants()` (line 1124) skips abort on retryable stale error to avoid race, leaving lingering sessions
- Code analysis: Sub-router `isSafeToRetryStaleErrors()` returns false (`transaction_router.cpp:934`)

**Affected code paths**: `service_entry_point_common.cpp` (shard-side error handlers), `write_ops_exec.cpp` (write execution error recording), `transaction_router.cpp:1113-1235` (_clearPendingParticipants, onStaleShardOrDbError), `transaction_router.cpp:2280-2300` (_errorAllowsRetryOnStaleShardOrDb)

**Suggested modeling approach**:
- Variables: `errorType ∈ {staleConfig, migrationConflict, shardCannotRefresh, none}`, `writeExecuted[shard][stmt] ∈ BOOLEAN`, `errorReported[shard][stmt] ∈ BOOLEAN`
- Actions: Model shard-side error classification (throw vs record-in-results), error propagation to router, router retry vs abort decision. Model "error after execution" vs "error before execution" as distinct states.
- Key invariant: `AtMostOnceExecution` — no write is executed more than once; `StaleErrorReachesRouter` — continuing transaction stale errors reach router

**Priority**: MEDIUM-HIGH
**Rationale**: 3 confirmed production bugs with concrete impact (double execution, hung transactions). The error pipeline has many classification decisions that are individually correct but interact poorly. TLA+ can verify the end-to-end invariants across all error paths.

---

### Family 5: Multi-Shard Commit Protocol Atomicity — MEDIUM

**Mechanism**: The commit protocol is chosen dynamically (5 variants) based on per-shard read/write classification at commit time. The `kSingleWriteShard` optimization commits read-only shards first, then the write shard, creating an atomicity window not present in the existing spec.

**Evidence**:
- Code analysis: `transaction_router.cpp:1704-1746` — `kSingleWriteShard` commits read-only shards (line 1734) before write shard (line 1745). Migration between these creates inconsistency.
- Code analysis: `transaction_router.cpp:1665-1682` — Commit type determined at commit time from participant state, not known at transaction start.
- Code analysis: `document_shard_key_update_util.cpp:339` — `WouldChangeOwningShard` forces `disallowSingleWriteShardCommit` to trigger 2PC.
- Historical: SERVER-99969 (commit `e86c6a7bfb`) — Cross-shard retryable transaction during chunk migration fails because session catalog migration didn't handle `PreparedTransactionInProgress`/`RetryableTransactionInProgress` exceptions.
- Historical: SERVER-90230 (commit `835f050e50`) — Dangling transactions (interrupted during internal commit) block migration indefinitely.

**Affected code paths**: `transaction_router.cpp:1632-1772` (_commitTransaction, 5 protocols), `transaction_router.cpp:1557-1596` (_handOffCommitToCoordinator), `session_catalog_migration_destination.cpp` (session state cloning during migration)

**Suggested modeling approach**:
- Variables: `commitType ∈ {noShards, singleShard, readOnly, singleWriteShard, twoPhaseCommit}`, `participantReadOnly[shard] ∈ BOOLEAN`, `commitPhase ∈ {notStarted, readOnlyCommitted, writeCommitted, done}`
- Actions: Model commit protocol selection; model `kSingleWriteShard` as two sequential commit actions with interleaving; model `WouldChangeOwningShard` forcing 2PC
- Key invariant: `CommitAtomicity` — if any participant commits, all eventually commit

**Priority**: MEDIUM
**Rationale**: The kSingleWriteShard optimization is a real atomicity gap. SERVER-99969 confirms the migration-transaction-session interaction is fragile. The existing spec has no commit protocol concept.

---

### Family 6: Sub-Router / Additional Participants — LOW-MEDIUM

**Mechanism**: Shards acting as sub-routers add new participants during transaction execution, creating distributed participant discovery where placementConflictTime must be transitively propagated.

**Evidence**:
- Code analysis: Sub-router derives placementConflictTime independently from incoming readConcern's `afterClusterTime` (`transaction_router.cpp:1300-1328`)
- Code analysis: Sub-router cannot retry stale errors (`transaction_router.cpp:934` — `isSafeToRetryStaleErrors()` returns false)
- Code analysis: Shard enforces immutability of placementConflictTime via `tassert` (`transaction_participant.cpp:1056-1070`)
- Historical: SERVER-92331, SERVER-94664 — test fragilities with additional participants

**Affected code paths**: `transaction_router.cpp:834-869` (processAdditionalParticipants), `transaction_router.cpp:2050-2064` (sub-router state reset)

**Suggested modeling approach**: Phase 2 extension — add after initial model passes. Model sub-router as a second router that forwards placementConflictTime from incoming request.

**Priority**: LOW-MEDIUM
**Rationale**: Newer feature, lower historical bug count. The shard-side `tassert` provides a runtime guard. Can be added as extension after initial model checking.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Multi-phase migration | Family 1: root cause of 3+ bugs; spec's atomic MoveRange misses all intermediate states | Split MoveRange into 4-5 actions (start, CS-write-block, CS-commit-block, config-commit, release) |
| Config server commit as separate action | Family 1: SERVER-62580 class — premature release before commit confirmation | Separate `ConfigCommit` action that can fail; migration must not release CS until commit confirmed |
| Router retry with timestamp reset | Family 2: SERVER-87660 class — timestamp mutation during retry | Add `RouterRetryOnStale` action that clears participants, resets placementConflictTime, re-sends |
| createdDatabases exemption | Family 2: spec carries field but never checks it | Implement exemption check in ShardRespond; add CreateDatabase action |
| Donor stepdown during migration | Family 3: 7+ historical bugs, richest family | Add `DonorStepDown` + `DonorRecovery` actions; recovery infers decision from config server |
| Recipient critical section recovery | Family 3: SERVER-65947 — CS release error | Add `RecipientStepDown` + `RecipientStepUp` with recovery document |
| Error propagation paths | Family 4: 3 production bugs (double execution, swallowed errors) | Model shard-side error classification + router retry/abort decision |
| Multi-shard commit protocol | Family 5: kSingleWriteShard creates atomicity gap | Model commit type selection; model kSingleWriteShard as two-step commit |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Data cloning internals (batch fetching, session migration) | Too low-level. Model cloning as a phase, not as data movement. |
| Lock hierarchy / ordering | Family 3 deadlocks (SERVER-49508, SERVER-76546, SERVER-48531) are lock-ordering bugs. TLA+ models interleavings, not lock contention. Better found by lockdep-style tools. |
| BulkWrite serialization | SERVER-102821 is a serialization-layer bug (nsInfo array not processed). Code-level oversight, not protocol logic. |
| Op observer registration | SERVER-71219 is a missing hook in a specific code path. Model the abstract effect (migration sees/misses writes), not C++ observer patterns. |
| Full prepared transaction 2PC | Model prepared transactions as "blocking" operations that prevent migration CS acquisition, not full 2PC. |
| Snapshot readConcern | The existing spec handles non-snapshot. Snapshot uses `atClusterTime` with different mechanics (MVCC guarantees). Focus on non-snapshot (placementConflictTime). |
| Sub-router mechanism | Family 6: newer feature, lower priority. Add as Phase 2 extension after initial model checking passes. |
| Specific error code conversion | Family 4, SERVER-93435: StaleConfig→QueryPlanKilled is a code-level classification error. Model the abstract error propagation, not specific error codes. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Multi-phase migration | `migrationPhase`, `configDecision` | Capture intermediate states between CS phases | Family 1 |
| Config commit failure | `configCommitResult ∈ {Success, Fail, Unknown}` | Model "committed but unknown" state | Family 1 |
| Router retry | `rRetryCount`, timestamp reset logic | Exercise timestamp-reset path during stale error retry | Family 2 |
| createdDatabases exemption | Enable existing `rCreatedDatabases` + add check | Exercise the bypass logic for created databases | Family 2 |
| Donor stepdown | `donorAlive`, `coordinatorDoc` | Model failover during each migration phase | Family 3 |
| Recipient recovery | `recipientRecoveryDoc` | Model CS recovery after recipient stepdown | Family 3 |
| Error propagation | `errorType`, `writeExecuted`, `errorReported` | Track shard-side error classification + router decision | Family 4 |
| Commit protocol | `commitType`, `participantReadOnly`, `commitPhase` | Model kSingleWriteShard atomicity gap | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| CommittedTxnImpliesAllStmtsSuccessful | Safety | If txn committed, all statements got ok (existing) | Standard |
| CommittedTxnImpliesKeysAreVisible | Safety | If txn committed, all keys found (existing) | Standard |
| NoPrematureCSRelease | Safety | Recipient CS not released until config commit confirmed | Family 1, SERVER-62580 |
| CriticalSectionCoversCommit | Safety | Config commit only happens while donor is in commit-phase CS | Family 1 |
| PlacementConflictTimeImmutable | Safety | placementConflictTime does not change after first participant receives it (except full retry) | Family 2, SERVER-87660 |
| AllParticipantsSameTimestamp | Safety | All participants in a committed txn used the same placementConflictTime | Family 2 |
| CreatedDbExemptionSafe | Safety | If createdDatabases exemption skips a check, no concurrent movePrimary affected that database | Family 2 |
| RecoveryPreservesDecision | Safety | After donor stepdown + recovery, the migration outcome (commit/abort) matches config server state | Family 3 |
| NoOrphanedCriticalSection | Liveness | If a migration is abandoned (donor stepped down), the recipient CS is eventually released | Family 3 |
| MigrationEventuallyCompletes | Liveness | Every started migration eventually reaches Done or Aborted (with fairness) | Family 1, 3 |
| AtMostOnceExecution | Safety | No write statement is executed more than once across retries | Family 4, SERVER-81508 |
| StaleErrorReachesRouter | Safety | If shard detects stale routing in continuing transaction, router eventually learns | Family 4, SERVER-57051 |
| CommitAtomicity | Safety | If any participant commits, all participants eventually commit (or all abort) | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC-1 | Transaction reads during write-block CS phase (before commit-block) observe pre-migration data, then migration commits | CommittedTxnImpliesKeysAreVisible | 1 |
| MC-2 | Config commit succeeds but response lost; donor recovery infers wrong decision | RecoveryPreservesDecision | 1, 3 |
| MC-3 | Router retry after StaleConfig resets timestamp; new timestamp is after a concurrent migration commit on recipient | AllParticipantsSameTimestamp | 2 |
| MC-4 | createdDatabases exemption skips check; concurrent movePrimary moves database | CreatedDbExemptionSafe | 2 |
| MC-5 | Donor steps down during config commit; new primary infers "committed" but recipient hasn't refreshed metadata | NoPrematureCSRelease | 3 |
| MC-6 | Two concurrent migrations to different namespaces; transaction spans both; first migration commits, second aborts | CommittedTxnImpliesAllStmtsSuccessful | 1 |
| MC-7 | Shard silently retries after StaleConfig in continuing transaction; router sends next statement to wrong shard | StaleErrorReachesRouter | 4 |
| MC-8 | Write executed on shard, then error thrown (ShardCannotRefreshDueToLocksHeld); router retries, write executes again | AtMostOnceExecution | 4 |
| MC-9 | kSingleWriteShard: read-only shard commits, migration moves data, write shard commit sees stale routing | CommitAtomicity | 5 |
| MC-10 | WouldChangeOwningShard forces 2PC; concurrent migration on destination shard's chunk | CommitAtomicity | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested Test Approach |
|----|-------------|----------------------|
| TV-1 | BulkWrite with multiple namespaces in transaction during migration | Integration test: BulkWrite targeting 2 namespaces, moveChunk on one |
| TV-2 | Sub-router encounters StaleConfig for additional participant | Integration test: shard-to-shard routing with moveChunk |
| TV-3 | Metadata refresh failure on recipient after CS release | Failpoint test: `hangBeforePostMigrationCommitRefresh` + kill refresh |
| TV-4 | Dangling transactions from interrupted internal commit block migration | Integration test: kill primary mid-internal-transaction, verify migration completes |

### 6.3 Code-Review-Only

| ID | Description | Suggested Action |
|----|-------------|-----------------|
| CR-1 | 8 occurrences of TODO SERVER-115178 (deprecated placementConflictTime paths) | Track removal timeline; dual paths add complexity |
| CR-2 | TODO SERVER-39704 (router retry safety) | Discuss with maintainers; retry logic explicitly acknowledged as unsafe |
| CR-3 | Equal-timestamp edge case in placement conflict check (`<` not `<=`) | Verify causal consistency guarantees prevent simultaneous timestamps |
| CR-4 | `migration_destination_manager.cpp:395-406` — `_sessionMigration->forceFail()` called outside `_mutex` | Verify thread safety |
| CR-5 | `migration_destination_manager.cpp:1741-1801` — Multiple `getState()` calls without single lock hold | Verify no harmful state transitions between calls |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-txnsmoverange/analysis-report.md`
- **Existing TLA+ spec**: `artifact/mongo-src/src/mongo/tla_plus/Sharding/TxnsMoveRange/TxnsMoveRange.tla`
- **Key source files**:
  - `src/mongo/db/s/migration_source_manager.cpp` (donor, 1034 lines)
  - `src/mongo/db/s/migration_destination_manager.cpp` (recipient, 2291 lines)
  - `src/mongo/db/s/migration_coordinator.cpp` (commit protocol, ~430 lines)
  - `src/mongo/s/transaction_router.cpp` (router txn management, 2651 lines)
  - `src/mongo/db/shard_role/shard_catalog/collection_sharding_runtime.cpp` (enforcement, ~700 lines)
- **GitHub/Jira tickets**:
  - Family 1: SERVER-62580, SERVER-45752, SERVER-65947 (critical section ordering)
  - Family 2: SERVER-87660, SERVER-102821, SERVER-85383, SERVER-107685 (timestamp propagation)
  - Family 3: SERVER-71219, SERVER-49508, SERVER-76546, SERVER-48531, SERVER-113740 (failover)
  - Family 4: SERVER-57051, SERVER-81508, SERVER-93435 (error propagation)
  - Family 5: SERVER-99969, SERVER-90230 (commit protocol / session interaction)
  - Open TODOs: SERVER-39704 (router retry safety), SERVER-115178 (deprecated PCT paths)
- **Shared harness doc**: `case-studies/mongodb-shared-harness.md` (Docker + log parsing approach)
- **Protocol documentation**: `src/mongo/db/s/README_migrations.md`, `src/mongo/db/s/README_sessions_and_transactions.md`
