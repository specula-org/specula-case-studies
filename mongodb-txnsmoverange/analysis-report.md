# Analysis Report: MongoDB TxnsMoveRange — Transactions During Range Migration

## 1. Reconnaissance Summary

### System Overview
- **Repository**: mongodb/mongo (C++, ~30K LOC in sharding/transaction subsystem)
- **Protocol**: Multi-statement transactions with placement conflict detection during chunk range migration
- **Existing TLA+ spec**: `TxnsMoveRange.tla` (327 lines) — models placementConflictTime mechanism for 2 shards, 2 namespaces, 2 transactions, 2 migrations
- **Key architectural choices**:
  - 6-step migration protocol with two-phase critical section (write-block, then read+write-block)
  - Config server as authoritative metadata store (separate network hop for commit)
  - Persistent migration coordinator documents for failover recovery
  - Dual placement conflict paths: `atClusterTime` (snapshot readConcern) vs `placementConflictTime` (non-snapshot)
  - Sub-router mechanism for additional participant discovery

### Core Files Analyzed

| File | Lines | Purpose |
|------|-------|---------|
| `migration_source_manager.cpp` | 1,034 | Donor-side migration state machine (6 steps) |
| `migration_destination_manager.cpp` | 2,291 | Recipient-side migration state machine |
| `migration_coordinator.cpp` | ~430 | 2PC commit/abort + failover recovery |
| `transaction_router.cpp` | 2,651 | Router-side transaction management, placementConflictTime |
| `transaction_participant.cpp` | ~3,700 | Shard-side transaction state, runtime context |
| `collection_sharding_runtime.cpp` | ~700 | Placement conflict enforcement layer |
| `database_sharding_runtime.cpp` | ~150 | Database-level conflict checking |
| `migration_chunk_cloner_source_op_observer.cpp` | 372 | Write-time conflict detection (snapshot txns) |

### Concurrency Model
- **Mongos (router)**: Session checkout serializes per-session operations. `TransactionRouter` uses Client lock for `ObservableState` (participants, timestamps), no lock for `PrivateState` (protected by session checkout).
- **Mongod (shard)**: CSR (CollectionShardingRuntime) lock protects migration registration. Critical section blocks operations at namespace level. Transaction participant state protected by Client lock.
- **Config server**: Atomic metadata updates via internal transactions. `validAfter` timestamp set at commit time.
- **Cross-component**: Migration protocol coordinates donor, recipient, and config server via RPCs. Critical sections on donor and recipient overlap during commit.

### Atomicity Boundaries
- **MoveRange in spec**: Single atomic action
- **MoveRange in reality**: 6 steps with failure windows between each:
  1. Register + snapshot metadata
  2. Validate shard key and range
  3. Start clone (extended async phase)
  4. Await catch-up
  5. Enter critical section + commit clone on recipient
  6. Commit on config server + cleanup

---

## 2. Bug Archaeology

### 2.1 Coverage Statistics

| Source | Total Found | Deeply Analyzed | Confirmed Bugs | False Positives |
|--------|------------|-----------------|----------------|-----------------|
| Git commits (all keywords) | 94 | 25 | 20 | 2 |
| GitHub/Jira issues | 51 | 30 | 25 | 3 |
| Code analysis (new findings) | 12 | 12 | 8 | 4 (by-design) |

### 2.2 Bug-Fix Commits (Most Relevant)

#### Critical: Data Loss / Correctness

| Commit | Ticket | Summary | Root Cause |
|--------|--------|---------|------------|
| `2f708612dc` | SERVER-71219 | Migration misses writes from prepared txns | Non-primary prepare path lacked op observer hook |
| `98b60eb0d7` | SERVER-55111 | Nested shard key delete in txn bypasses MigrationConflict | Shard key extraction failed for dot-notation paths |
| `ae61a4d91c` | SERVER-62580 | Recipient exits CS before commit confirmed | `launchReleaseRecipientCriticalSection` called before status check |
| `4a141a4ec7` | SERVER-87660 | placementConflictTime could change mid-transaction | `AtClusterTime::canChange(stmtId)` allowed mutation |
| `30e34cf436` | SERVER-102821 | BulkWrite missing placementConflictTime in txn | Per-namespace nsInfo array not processed by router |
| `0f1450f373` | SERVER-85383 | Aggregation pipeline not propagating placementConflictTime | Pipeline helper didn't attach timestamp to shard version |

#### Critical: Deadlocks

| Commit | Ticket | Summary | Root Cause |
|--------|--------|---------|------------|
| `c857e1dcb2` | SERVER-49508 | Step-up deadlock: migration recovery vs prepared txn | MODE_X + CSR lock ordering inversion |
| `e90dcb18de` | SERVER-76546 | _migrateClone deadlock with prepared txns on secondary | Clone read blocks on prepared txn lock; secondary can't resolve |
| `1e23a0f765` | SERVER-48531 | 3-way deadlock: chunk splitter + prepared txn + stepdown | Lock hierarchy violation across 3 actors |
| `5489c851ef` | SERVER-78021 | Session checkout vs _chunkOpLock ordering | Lock ordering inversion |

#### High: Races and Recovery

| Commit | Ticket | Summary | Root Cause |
|--------|--------|---------|------------|
| `30dd148d45` | SERVER-84625 | Data races on MigrationSourceManager | Missing mutex for concurrent status reporting |
| `cd96f9b455` | SERVER-42751 | Missing CSR lock in txn commit observer | TOCTOU: MSM destroyed between check and use |
| `ee8a38cc92` | SERVER-71544 | Race on _sessionCatalogSource | Concurrent access without synchronization |
| `cbf8cba3e3` | SERVER-113740 | Prepared txns from precise checkpoint + migration | Recovery path lacks operation statements |
| `e86c6a7bfb` | SERVER-99969 | Cross-shard retryable txn causes migration failure | PreparedTransactionInProgress unhandled |
| `5bd946b1fc` | SERVER-65947 | Recipient must recover on CS release error | Missing recovery path |

### 2.3 Key GitHub Issues / Jira Tickets

| Ticket | Title | Status | Relevance |
|--------|-------|--------|-----------|
| SERVER-87660 | Don't allow changing placementConflictTime | Fixed | Core correctness bug in timestamp management |
| SERVER-102821 | BulkWrite fails to attach placementConflictTime | Fixed (2 attempts) | First fix reverted (SERVER-103535) due to unsafe rebuild |
| SERVER-71219 | Migration can miss writes from prepared txns | Fixed | Data loss during failover + migration |
| SERVER-113740 | Support prepared txns with chunk migrations | Fixed (3 attempts) | First landing reverted, second reverted, third succeeded |
| SERVER-49508 | Step-up deadlock: migration recovery + prepared txn | Fixed | Deadlock on primary election |
| SERVER-62580 | Premature recipient CS release on commit failure | Fixed | Protocol ordering violation |
| SERVER-100839 | Dangling txns cause placement conflict test timeout | Fixed | Resource leak from unterminated sessions |
| SERVER-39704 | TODO: retry within txn on stale version | Open (TODO) | Router retry logic acknowledged as incomplete |
| SERVER-115178 | Remove deprecated placementConflictTime paths | Open (TODO, 8 occurrences) | Dual propagation paths add complexity |

---

## 3. Deep Analysis Findings

### 3.1 Existing Spec Gaps (vs Real Implementation)

| # | Gap | Evidence | Risk |
|---|-----|----------|------|
| G1 | Two-phase critical section not modeled | Spec uses boolean lock; real has write-block then read+write-block | HIGH: reads during phase 1 can observe pre-migration data |
| G2 | Data cloning phase not modeled | Spec's MoveRange is atomic; real has extended cloning window | MEDIUM: snapshot established during cloning |
| G3 | Migration failure/rollback not modeled | Spec has no abort/recovery transitions | HIGH: recovery bugs (SERVER-62580, SERVER-65947) |
| G4 | Config server commit as separate network hop | Spec's MoveRange atomically updates metadata | HIGH: "committed but unknown" state |
| G5 | createdDatabases exemption dead code | Spec carries field but RespondStatus ignores it | MEDIUM: bypass could mask conflicts |
| G6 | Router retry with fresh placementConflictTime not modeled | Spec aborts on staleRouter, no retry | HIGH: retry resets timestamp (SERVER-87660 class) |
| G7 | Non-atomic cache refresh | Spec's refresh is omniscient and instantaneous | LOW: refresh can race with concurrent migration |
| G8 | Failover completely absent | No stepdown, no recovery coordinator | HIGH: richest bug family (6+ historical bugs) |
| G9 | Sub-router / additional participants not modeled | Entire mechanism absent | MEDIUM: newer feature with known fragility |

### 3.1b Additional Findings from Deep Bug Analysis

**SERVER-81508 (Double Execution) — Detailed Root Cause:**
When a shard encounters `ShardCannotRefreshDueToLocksHeld` (error code 343), this error occurs during post-write sharding validation, NOT before the write. The write was already executed on the shard but reported as an error. The router treated it as an ordinary retryable error and re-sent the entire batch, causing double execution of non-idempotent writes. Fix: record error in results (not throw), track per-write retry. `write_ops_exec.cpp:510-530` now handles this error the same way as `StaleConfig`.

**SERVER-57051 (Swallowed Stale Error) — Detailed Root Cause:**
Two sub-bugs: (1) The `StaleDbVersion` and `StaleShardVersionError` handlers had no transaction check — unconditionally retried. (2) The `ShardCannotRefreshDueToLocksHeld` handler used `inMultiDocumentTransaction()` instead of `isContinuingMultiDocumentTransaction()`. The first statement CAN safely retry; continuing statements CANNOT. Fix: all three handlers now check `!opCtx->isContinuingMultiDocumentTransaction()`.

**SERVER-93435 (Error Conversion) — Detailed Root Cause:**
`plan_executor.cpp:129-143` — When executing `updateMany`, if `numDocsModified > 0` and `StaleConfig` thrown, it was converted to `QueryPlanKilled` (non-retryable). For standalone updates, this is correct (partial update can't be retried). For transactions, this is WRONG because transactions have atomicity — abort rolls back all writes. Fix: added `!getOpCtx()->inMultiDocumentTransaction()` guard.

**SERVER-99969 (Cross-Shard Retryable Transaction) — Detailed Root Cause:**
`session_catalog_migration_destination.cpp:379-557` — Session catalog migration code predated internal transactions. When chunk migration clones session state, `beginOrContinue` can throw `PreparedTransactionInProgress` or `RetryableTransactionInProgress`. Old code only caught `TransactionTooOld` and `IncompleteTransactionHistory`. Fix: new utility `session_catalog_migration_util::runWithSessionCheckedOutIfStatementNotExecuted` handles all 5 outcomes, with `while(!beganOrContinuedTxn)` retry loop.

**Multi-Shard Commit Protocol Analysis:**
`transaction_router.cpp:1632-1772` has 5 commit protocols: kNoShards, kSingleShard, kReadOnly, kSingleWriteShard, kTwoPhaseCommit. The kSingleWriteShard path (lines 1734-1745) commits read-only shards first, then the write shard. This creates an atomicity window: if a migration commits between these two phases, the read-only commit to the old shard succeeds but the write commit to the other shard may fail if routing changed. The existing spec has no commit protocol concept.

**Active Migration Registry:**
`active_migrations_registry.h:73-77` — One migration per shard (global, not per-namespace). But this is per-shard, not per-cluster. Shard A donating ns1 to shard B while shard C donates ns2 to shard D is allowed. Shard B cannot simultaneously be a donor (for ns2) and recipient (for ns1) due to registry constraints. This affects multi-collection transactions spanning shards with concurrent migrations.

### 3.2 New Potential Findings

**Finding NF-1: Donor CS release before commit decision persistence (Protocol Ordering)**

In the successful commit path, the donor releases its critical section at `migration_source_manager.cpp:926` (`_critSec.reset()`), which happens in `_cleanup()`. The commit decision is persisted later at `migration_coordinator.cpp:240` (`persistCommitDecision`). If the donor steps down between CS release and decision persistence, the new primary's recovery must infer the decision from config server metadata. During this window, the donor accepts new operations (CS released) but the decision isn't durable.

This is intentional design (the config server is authoritative), but the window creates a state not captured by the existing spec where the donor has "moved on" from the migration but the coordinator document still lacks a decision.

**Finding NF-2: Asymmetric conflict checking (Donor vs Recipient)**

For non-snapshot transactions:
- **Recipient**: `placementConflictTime < getShardMaxValidAfter()` check in `collection_sharding_runtime.cpp:676-677`
- **Donor**: No per-chunk placementConflictTime check. Relies on critical section blocking + StaleConfig on placement version mismatch.

This asymmetry means: after migration commits and the donor refreshes its metadata (bumping the major placement version), a transaction that was already established on the donor with a stale placement version will get `StaleConfig`, not `MigrationConflict`. The router handles these differently — `StaleConfig` can trigger retry, `MigrationConflict` is immediately retryable. If the router retries on `StaleConfig` with a new timestamp and targets the recipient, the `placementConflictTime` check on the recipient should catch it. But the two-hop retry (StaleConfig → refresh → re-target → MigrationConflict) is not modeled.

**Finding NF-3: Sub-router cannot retry stale errors**

`transaction_router.cpp:934-935`: `isSafeToRetryStaleErrors()` returns false for sub-routers. If a sub-router contacts a newly-added participant and gets a StaleConfig error (because a migration happened), it propagates the error upward. The main router must handle the retry. But the main router's retry logic (`_errorAllowsRetryOnStaleShardOrDb`) only allows retry for the first statement with at most one participant. If the sub-router has already added additional participants, the main router cannot retry and the transaction fails.

**Finding NF-4: Equal-timestamp edge case**

The placement conflict comparison is strict less-than: `placementConflictTime < timeOfLastIncomingChunkMigration`. The config server sets `validAfter = VectorClock::get(opCtx)->getTime().clusterTime()` at migration commit. The router sets `placementConflictTime` from its own cluster time. If both happen at the exact same logical time (possible with causal consistency), the transaction is allowed to proceed. This is intentionally conservative (no false positives), but it means a transaction that starts "simultaneously" with a migration commit may observe pre-migration data on the donor and post-migration data on the recipient.

**Finding NF-5: createdDatabases exemption masks concurrent migration conflicts**

`database_sharding_runtime.cpp:112-114`: When a database name appears in `createdDatabases`, the entire placement conflict check is skipped. `transaction_router.cpp:337-344`: For created databases, `placementConflictTime` is set to `Timestamp(0,0)` on the database version. If a concurrent `movePrimary` changes the database's primary shard between the database creation and a subsequent statement in the same transaction, the exemption would prevent the `MigrationConflict` error from firing.

**Finding NF-6: Metadata refresh timing on recipient after CS release**

`migration_destination_manager.cpp:2126-2149`: The recipient refreshes metadata before releasing CS, but if the refresh fails, it clears metadata non-authoritatively (line 2148) and releases CS anyway (line 2155). Operations arriving immediately after CS release may see no metadata and trigger a lazy refresh, creating a brief window of `StaleConfig` errors.

---

## 4. Bug Family Grouping

### Family 1: Non-Atomic Migration Protocol (Critical Section Windows)

**Mechanism**: The 6-step migration protocol has multiple failure windows where intermediate states can interact with concurrent transactions.

**Evidence**:
- Historical: SERVER-62580 (premature CS release), SERVER-45752 (fassert during CS commit), SERVER-65947 (CS release error recovery)
- Spec gaps: G1 (two-phase CS), G2 (cloning phase), G3 (failure/rollback), G4 (config commit network hop)
- New findings: NF-1 (CS release before decision persistence), NF-6 (metadata refresh failure)

**Affected code paths**: `migration_source_manager.cpp` (all 6 steps), `migration_coordinator.cpp` (completeMigration, recovery), `migration_destination_manager.cpp` (CS acquisition/release)

**Assessment**: 3+ historical bugs sharing this mechanism. The spec's atomic MoveRange cannot exercise any of these windows. Splitting MoveRange into phases is the highest-value extension.

**Priority**: HIGH

### Family 2: placementConflictTime Propagation and Consistency

**Mechanism**: The timestamp must be set once, propagated consistently to all participants, and not changed during the transaction's lifetime. Multiple propagation paths (readConcern, shardVersion, databaseVersion, transactionRuntimeContext) increase complexity.

**Evidence**:
- Historical: SERVER-87660 (timestamp mutation), SERVER-102821 (BulkWrite missing), SERVER-85383 (aggregation pipeline), SERVER-107685 (view aggregation)
- Spec gaps: G5 (createdDatabases exemption dead), G6 (retry with fresh timestamp not modeled)
- New findings: NF-4 (equal-timestamp edge), NF-5 (createdDatabases exemption masks conflicts)

**Affected code paths**: `transaction_router.cpp` (setDefaultAtClusterTime, appendFieldsForStartTransaction, onStaleShardOrDbError), `collection_sharding_runtime.cpp` (getPlacementConflictTime), `database_sharding_runtime.cpp` (checkPlacementConflictTimestamp)

**Assessment**: 4+ historical bugs. The router retry logic resets the timestamp, creating a new timing window. The createdDatabases exemption is a concrete correctness gap in the spec.

**Priority**: HIGH

### Family 3: Prepared Transaction + Migration Interaction

**Mechanism**: Prepared transactions hold locks and resources that interact with migration state machines, creating deadlocks and data loss when failover occurs.

**Evidence**:
- Historical: SERVER-71219 (missed writes), SERVER-49508 (step-up deadlock), SERVER-76546 (secondary deadlock), SERVER-48531 (3-way deadlock), SERVER-42751 (CSR lock TOCTOU), SERVER-113740 (checkpoint recovery), SERVER-66340 (FCV lock generalization)
- Spec gap: G8 (failover absent)

**Affected code paths**: `migration_source_manager.cpp` (startClone, ReclaimedPreparedTxnTracker wait), `migration_chunk_cloner_source_op_observer.cpp` (onTransactionPrepareNonPrimaryForChunkMigration), `migration_coordinator.cpp` (recovery)

**Assessment**: 7+ historical bugs — the richest family. Most bugs require modeling failover (stepdown + step-up) alongside migration and prepared transactions. TLA+ is excellent for exploring these interleavings.

**Priority**: HIGH (for the subset modelable without full lock-hierarchy modeling)

### Family 4: Stale Routing / Router Retry During Transactions

**Mechanism**: The router's cached routing table can become stale during a transaction, and the retry logic for handling stale errors is incomplete and explicitly acknowledged as such (TODO SERVER-39704).

**Evidence**:
- Historical: SERVER-46679 (stale shard version in txn), SERVER-55111 (nested shard key bypass)
- Spec gap: G6 (retry not modeled), G7 (non-atomic refresh)
- Code analysis: TODO SERVER-39704 ("Remove this fail point once the router can safely retry"), TODO SERVER-37207 ("Change batch writes to retry only failed writes")
- New finding: NF-2 (asymmetric conflict checking donor vs recipient), NF-3 (sub-router cannot retry)

**Affected code paths**: `transaction_router.cpp` (_errorAllowsRetryOnStaleShardOrDb, onStaleShardOrDbError, canContinueOnStaleShardOrDbError)

**Assessment**: The retry logic is explicitly incomplete. The spec doesn't model it at all. Adding retry to the spec would exercise the timestamp-reset + re-targeting path.

**Priority**: MEDIUM (correctness is handled by abort-and-retry at transaction level; the gap is about unnecessary aborts, not safety violations)

### Family 5: Stale Routing Error Propagation in Transactions

**Mechanism**: Incorrect error classification, suppression, or conversion at the shard causes the router to make wrong retry/abort decisions.

**Evidence**:
- Historical: SERVER-57051 (shard swallows stale error in continuing transaction), SERVER-81508 (double execution), SERVER-93435 (error code conversion)
- Code analysis: TODO SERVER-39704 (retry safety acknowledged as incomplete)
- New findings: NF-2 (asymmetric conflict checking donor vs recipient), NF-3 (sub-router cannot retry)

**Affected code paths**: `service_entry_point_common.cpp`, `write_ops_exec.cpp`, `transaction_router.cpp` (error handlers)

**Assessment**: 3 confirmed bugs with production impact. Error pipeline has many classification points that interact. TLA+ can verify end-to-end invariants.

**Priority**: MEDIUM-HIGH

### Family 6: Multi-Shard Commit Protocol Atomicity

**Mechanism**: The 5 commit protocols have different atomicity guarantees. kSingleWriteShard creates an interleaving window between read-only and write commits.

**Evidence**:
- Code analysis: `transaction_router.cpp:1704-1746` (kSingleWriteShard two-step commit)
- Historical: SERVER-99969 (cross-shard retryable txn + migration failure)
- Historical: SERVER-90230 (dangling transactions block migration)
- Code analysis: `document_shard_key_update_util.cpp:339` (WouldChangeOwningShard forces 2PC)

**Affected code paths**: `transaction_router.cpp` (_commitTransaction), `session_catalog_migration_destination.cpp`

**Assessment**: The kSingleWriteShard optimization is a real gap. The existing spec has no commit protocol concept.

**Priority**: MEDIUM

### Family 7: Sub-Router / Additional Participants

**Mechanism**: Shards acting as sub-routers can add new participants to a transaction, creating a distributed participant discovery problem.

**Evidence**:
- Code analysis: Sub-router derives placementConflictTime independently from incoming readConcern (`transaction_router.cpp:1300-1328`)
- Code analysis: Sub-router cannot retry (NF-3), shard enforces immutability via tassert (`transaction_participant.cpp:1056-1070`)
- Historical: SERVER-92331, SERVER-94664 (test fragilities)
- Spec gap: G9 (not modeled)

**Affected code paths**: `transaction_router.cpp` (processParticipantResponse, processAdditionalParticipants)

**Assessment**: Newer feature, lower historical bug count. Shard-side tassert provides runtime guard.

**Priority**: LOW-MEDIUM

---

## 5. Reference Pointers

### Key Source Files
- `src/mongo/db/s/migration_source_manager.cpp` (donor state machine)
- `src/mongo/db/s/migration_destination_manager.cpp` (recipient state machine)
- `src/mongo/db/s/migration_coordinator.cpp` (commit/abort protocol)
- `src/mongo/s/transaction_router.cpp` (router-side txn management)
- `src/mongo/db/transaction/transaction_participant.cpp` (shard-side txn state)
- `src/mongo/db/shard_role/shard_catalog/collection_sharding_runtime.cpp` (placement conflict enforcement)
- `src/mongo/db/shard_role/shard_catalog/database_sharding_runtime.cpp` (database conflict enforcement)
- `src/mongo/tla_plus/Sharding/TxnsMoveRange/TxnsMoveRange.tla` (existing spec)

### Relevant Jira Tickets
- SERVER-87660, SERVER-102821, SERVER-85383 (Family 2: timestamp propagation)
- SERVER-71219, SERVER-49508, SERVER-76546, SERVER-113740 (Family 3: prepared txns)
- SERVER-62580, SERVER-45752, SERVER-65947 (Family 1: critical section)
- SERVER-39704 (open TODO: router retry safety)

### Documentation
- `src/mongo/db/s/README_migrations.md` (migration protocol)
- `src/mongo/db/s/README_sessions_and_transactions.md` (session/txn management)
- `src/mongo/db/global_catalog/ddl/README_transactions_and_ddl.md` (placement conflict design)
