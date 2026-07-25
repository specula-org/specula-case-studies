# Modeling Brief: MongoDB Distributed Transactions (2PC Coordinator)

## 1. System Overview

- **System**: MongoDB distributed transactions — cross-shard 2PC coordination
- **Language**: C++ (~280K LOC across coordinator, router, and storage layers)
- **Protocol**: Two-Phase Commit with single-shard and read-only optimizations
- **TLA+ baseline**: `vldb25-dist-txns/MultiShardTxn.tla` (594 LOC, 22 vars, 15 actions, snapshot isolation checks)
- **Key architectural choices**:
  - **Router-coordinator separation**: mongos router classifies transactions (single-shard / read-only / single-write-shard / full 2PC) before delegating to a coordinator shard
  - **Coordinator is a participant**: The first shard contacted becomes the coordinator — it may also hold prepared data
  - **Recovery via persistent coordinator docs**: Participant list and decision are majority-written to `config.transaction_coordinators`; step-up recovers from these documents
  - **Process crash as protocol action**: Coordinator uses `fassert`/`LOGV2_FATAL` to force failover on unrecoverable errors (e.g., ShardNotFound during commit delivery)
  - **Coordinator doc deletion uses `w:1`**: Final cleanup is best-effort — recovery may re-drive already-completed decisions
- **Concurrency model**: Async future chains for 2PC steps; concurrent session reapers on timers; WiredTiger write ticket pool shared between coordinator and participant operations

## 2. Bug Families

### Family 1: 2PC Coordinator Recovery on Failover (HIGH)

**Mechanism**: When the coordinator primary fails over during 2PC, the new primary's recovery logic is incomplete or misclassifies errors, leaving transactions in inconsistent cross-shard states.

**Evidence**:
- SERVER-106075: After failover, new primary returns `APIMismatchError` on commit/abort (apiVersion not persisted in oplog). Coordinator misclassifies error as acknowledgment → torn commit across shards. Fixed 7.0.26/8.0.16.
- SERVER-61483: Resharding coordinator fails to read abort decision on step-up, proceeds to commit → data loss. Fixed 5.0.5.
- SERVER-48307: Single-write-shard retry incorrectly returns "definitive abort" after failover on read-only participant → duplicate execution. Fixed 4.2.8.
- SERVER-38918 (OPEN TODO): ShardNotFound during commit/abort delivery → `fassert(51068)` crash. No safe alternative exists (C++ line: `transaction_coordinator_util.cpp:951`).
- SERVER-38307 (OPEN TODO): Corrupt coordinator doc during step-up recovery crashes entire recovery, blocking ALL 2PC transactions.
- TLA+ spec gap: `Restart(s)` is dead code (not in Next). If enabled, it clears `shardPreparedTxns` but preserves `txnSnapshots` — prepared transactions become unreachable (orphaned).

**Affected code paths**:
- `TransactionCoordinator::_done()` — fatal assertion on unexpected errors
- `TransactionCoordinatorService::_scheduleRecoveryTask()` — step-up recovery chain
- `sendDecisionToShard()` — ShardNotFound handling (fassert)
- `readAllCoordinatorDocs()` — missing try/catch during recovery parsing

**Suggested modeling approach**:
- Variables: `coordDocState [Shard -> [TxId -> {"none", "participants_written", "decision_written", "deleted"}]]`, `primaryShard [Shard -> Server]`
- Actions: Split `ShardTxnCoordinatorDecideCommit` into `WriteDecision` (persist) and `SendDecision` (broadcast). Add `CoordinatorFailover(s)` that: (a) loses in-memory state, (b) reads coordinator docs, (c) resumes from persisted state. Add `ShardNotFoundDuringCommit` modeling shard removal.
- Granularity: Decision persistence must be a separate step from decision delivery to expose the crash window.

**Priority**: High
**Rationale**: 5 historical bugs, 2 open TODOs, confirmed production data loss (SERVER-106075 affected all versions since 5.0.0). The existing TLA+ spec completely skips coordinator recovery — Restart is dead code.

---

### Family 2: Session Reaper vs. Active 2PC Races (HIGH)

**Mechanism**: Timer-based session cleanup (reaper) destroys sessions that hold prepared transactions or yielded transaction routers, causing torn commits or crashes.

**Evidence**:
- SERVER-105751 (CRITICAL): Router-mode session reaper destroys `TransactionParticipant` with prepared transaction. Destructor aborts the prepared write; coordinator treats `NoSuchTransaction` as success → torn cross-shard commit. Fixed 8.0.13.
- SERVER-61816: Reaper kills local transaction before coordinator sends abort. Subsequent no-op write hangs forever. Fixed 5.0.6.
- SERVER-92607: Eager reaping destroys yielded `TransactionRouter`. Resumed operation finds default-constructed router → invariant crash. Fixed 8.1.0-rc0.
- SERVER-50365: Transaction reaper deadlocks with WiredTiger cache pressure.

**Affected code paths**:
- Session catalog reaping callback
- `TransactionParticipant` destructor (implicit abort on destroy)
- Coordinator error classification for `NoSuchTransaction` response

**Suggested modeling approach**:
- Variables: `sessionState [Session -> {"active", "prepared", "yielded", "reaped"}]`, `reaperTimer`
- Actions: `ReapSession(s)` that destroys a session (transitions to "reaped"). `ResumeYieldedSession(s)` that checks if session is still valid. Guard: `ReapSession` must not destroy sessions in "prepared" or "yielded" states.
- Key invariant: A prepared transaction is never reaped before the coordinator decision is persisted and delivered.

**Priority**: High
**Rationale**: 4 bugs including critical data loss (SERVER-105751). The reaper is a concurrent actor not modeled in any existing TLA+ spec. Very small state space — classic model-checking target.

---

### Family 3: Resource Contention Deadlocks During Prepared State (MEDIUM)

**Mechanism**: Prepared transactions hold resources (locks, storage tickets, oplog slots) that create circular dependencies with other operations trying to make progress.

**Evidence**:
- SERVER-60682: Coordinator blocks on WiredTiger write ticket to persist commit decision, but tickets are exhausted by operations blocked on prepared transactions → cascading deadlock. Fixed 5.0.6.
- SERVER-65821: `setFCV` holds global S lock, waits for prepared txns. Coordinator needs IX lock on `config.transaction_coordinators` → deadlock. Fixed 5.0.10.
- SERVER-41980: Prepared txns release ticket but hold global IX lock. Non-txn ops get tickets but block on collection locks. `commitTransaction` can't get ticket → deadlock. Fixed 4.2.0-rc5.
- SERVER-57476: Oplog slot held during prepare conflict retry blocks replication, blocking prepared txn commit → circular deadlock. Fixed 5.0.0-rc2.
- SERVER-82883: Coordinator recovery on step-up acquires tickets unnecessarily → blocks behind ticket exhaustion. Fixed 7.0.5.
- C++ fix: `ScopedAdmissionPriority::kExempt` for coordinator operations (in `transaction_coordinator_util.cpp`).

**Suggested modeling approach**:
- Variables: `tickets [Pool -> Nat]`, `locks [Resource -> {"free", "S", "IX"}]`, `holdsTicket [Thread -> BOOLEAN]`
- Actions: `AcquireTicket`, `ReleaseTicket`, `AcquireLock`, `ReleaseLock` with proper ordering constraints
- Key invariant: No circular wait (deadlock freedom)

**Priority**: Medium
**Rationale**: 5 bugs, all fixed with ticket exemptions. Abstract resource modeling is feasible in TLA+ but adds state space without targeting protocol-level bugs. The C++ fixes (ScopedAdmissionPriority) are implementation-specific.

---

### Family 4: Chunk Migration / Resharding During Transactions (HIGH)

**Mechanism**: Chunk migration and prepared transaction handling have incomplete coordination — callbacks lost on failover, namespace filters drop retryability state, snapshot pinning misses concurrent writes.

**Evidence**:
- SERVER-71219: Migration's `LogTransactionOperationsForShardingHandler` callback registered only during prepare. Failover loses callback → committed writes invisible to migration → data loss. Fixed 6.0.5.
- SERVER-68361: `getPreImageDocumentKey` returns empty → migration misses documents with changed shard keys. Fixed 6.0.4.
- SERVER-78050: Chunk migration pins stale snapshot during deferred modification processing → misses concurrent writes → data loss. Fixed 7.0.0-rc4.
- SERVER-89529: Resharding creates noop oplog entries with empty namespace. Migration session cloner filters by namespace → loses retryability state → duplicate writes. Fixed 8.0.5.
- SERVER-99969: Cross-shard retryable txn in prepared state on recipient blocks migration session cloner → migration failure. Fixed 8.2.0-rc0.
- TLA+ spec gap: `MoveKey` is dead code (not in Next). If enabled, `rCatalog` is never refreshed — router routes to stale shard forever. No shard version check exists.

**Affected code paths**:
- `LogTransactionOperationsForShardingHandler::commit` — callback registration lifecycle
- `SessionCatalogMigrationSource` — namespace filtering
- Migration chunk cloner — snapshot management during deferred mods
- `MoveKey` in base.tla — dead code, no shard version validation

**Suggested modeling approach**:
- Variables: `catalog [Key -> Shard]` (ground truth), `rCatalog [Router -> [Key -> Shard]]` (cached), `migrationState [Key -> {"idle", "cloning", "catchup", "committed"}]`
- Actions: Enable `MoveKey` with counter-bounded fault injection. Add `RefreshCatalog(r)` action. Add `ShardVersionCheck(s, k)` guard to shard operations. Add `MigrationCatchup(k)` that reads committed writes.
- Key invariant: All committed writes within a migrated chunk's key range are visible in the destination shard after migration completes.

**Priority**: High
**Rationale**: 5 historical data-loss bugs. Migration-transaction interaction is the single most dangerous area in the MongoDB codebase. The TLA+ spec has `MoveKey` and `rCatalog` already defined but disabled — enabling them is low-effort, high-value.

---

### Family 5: Stale Router Cache / Cross-Shard Snapshot Inconsistency (MEDIUM)

**Mechanism**: Routers with stale routing information or per-shard independent snapshots cause transactions to operate on wrong shards or observe inconsistent catalog states.

**Evidence**:
- SERVER-42856: Stale mongos captures snapshot time from old routing version. After refresh, write path uses outdated timestamp → routes to wrong shard. Fixed 4.2.1.
- SERVER-84760: Transaction observes inconsistent state: data from one snapshot + catalog from another. Won't Fix for <7.0. Fixed via PM-2218 (point-in-time catalog).
- SERVER-88746: Write path skips catalog consistency check that read path performs → writes to dropped collection. Fixed 7.0.10.
- SERVER-107699: Sub-router uses stale `TransactionRouter::atClusterTime` from previous transaction → queries target wrong shards. Fixed 8.2.0-rc0.
- SERVER-84723: Per-shard independent snapshots + concurrent DDL → different shards see different metadata → inconsistent reads. Fixed 7.0.6.
- TLA+ spec gap: `rCatalog` is never refreshed. No shard version checks. No DDL actions.

**Suggested modeling approach**:
- Variables: Reuse `rCatalog` from Family 4. Add `catalogVersion [Key -> Nat]` and `rCatalogVersion [Router -> Nat]`.
- Actions: Add `ShardVersionCheck(s, k, version)` as a guard on shard operations. Add `DDLOperation(k)` (drop/rename) as a concurrent action.
- Key invariant: All shards in a transaction observe consistent catalog state at the transaction's read timestamp.

**Priority**: Medium
**Rationale**: 5 bugs, mostly fixed in 7.0+ with point-in-time catalog. The stale cache issue is partially modeled (rCatalog exists but MoveKey is disabled). DDL modeling would significantly expand spec scope.

---

### Family 6: Abort/Commit Decision Propagation Gaps (MEDIUM)

**Mechanism**: The coordinator's decision (commit or abort) fails to reliably reach all participants due to missing abort paths, sender destruction, or layer mismatches.

**Evidence**:
- SERVER-66067: Transaction API's best-effort abort interferes with coordinator's 2PC commit → one participant aborts while another commits. Fixed.
- SERVER-116284: `MultiStatementTransactionRequestsSender` destructed before commit reaches all shards → dangling prepared transactions. Fixed 8.2.7.
- SERVER-116340 (OPEN): `abortTransaction` on different connection finds stale txn number → `NoSuchTransaction` → transaction leaks for 60s.
- TLA+ spec gap: No `ShardTxnCoordinatorDecideAbort` action exists. `RouterTxnAbort` is commented out. `msgsAbort` is a completely dead variable. If any participant votes abort during 2PC, the coordinator hangs forever.

**Affected code paths**:
- `ShardTxnCoordinatorDecideCommit` in base.tla — no abort branch
- `AsyncRequestsSender` lifecycle during commit broadcast
- Transaction API abort layer vs. `TransactionRouter` coordination

**Suggested modeling approach**:
- Actions: Add `ShardTxnCoordinatorDecideAbort(s, tid)` that fires when a participant aborts or fails to prepare. Uncomment `RouterTxnAbort`. Add `msgsAbort` message production and consumption.
- Key invariant: 2PC Agreement — if any participant committed, all participants must eventually commit (and vice versa for abort).

**Priority**: Medium
**Rationale**: 3 bugs including 1 open. The missing abort path is the most glaring gap in the TLA+ spec — it's structurally incomplete for modeling failure scenarios.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Coordinator failover + recovery | Family 1: 5+ production bugs, existing Restart is broken dead code | Fix Restart to preserve prepared txns; add coordinator doc persistence; add step-up recovery action |
| Coordinator abort decision | Family 6: no abort path exists in spec, coordinator hangs on participant failure | Add `ShardTxnCoordinatorDecideAbort`; uncomment `RouterTxnAbort`; use `msgsAbort` |
| MoveKey with stale router cache | Family 4: 5 data-loss bugs in migration-transaction interaction | Enable MoveKey in Next with counter bounds; keep rCatalog stale; add shard version check |
| Session reaper vs. prepared txn | Family 2: critical data-loss bug (SERVER-105751), small state space | Add `ReapSession` action; guard against reaping prepared/yielded sessions |
| Coordinator doc persistence steps | Family 1: crash between write-decision and send-decision is the core 2PC window | Split `ShardTxnCoordinatorDecideCommit` into `WriteDecision` + `SendDecision` |
| Single-write-shard optimization | Family 1 (SERVER-48307): retry logic bug in this optimization | Model the `RouterTxnCommitSingleWriteShard` path (currently commented out) |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| WiredTiger write tickets / lock ordering | Family 3: resource contention bugs, all fixed with `ScopedAdmissionPriority::kExempt`. Implementation-specific, not protocol logic. |
| DDL operations (drop/rename) | Family 5: fixed in 7.0+ with point-in-time catalog. Would significantly expand spec scope for diminishing returns. |
| Session reaper timer semantics | Family 2: the timer mechanism is implementation-specific. Model reaper as a nondeterministic action instead. |
| Oplog replication / majority commit | Orthogonal to 2PC protocol. Model persistence as atomic majority-write actions. |
| Error code classification | SERVER-106075 root cause is error category mismatch — better verified by code review/type system, not TLA+. |
| Sub-router / getMores | SERVER-107699 is a state management bug in sub-routing. Requires modeling the mongos request pipeline, too implementation-specific. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Coordinator doc lifecycle | `coordDocState [Shard -> [TxId -> DocState]]` | Model persist-before-send protocol; expose crash windows | Family 1 |
| Coordinator failover | `primary [Shard -> Server]`, split `Restart` into `StepDown`+`StepUp` | Model recovery from coordinator docs | Family 1 |
| Abort decision path | (reuse `msgsAbort`, add abort vote type) | Complete 2PC protocol; model participant failure → abort | Family 6 |
| MoveKey + shard version | `shardVersion [Key -> Nat]`, `rShardVersion [Router -> [Key -> Nat]]` | Detect stale routing; model migration-transaction races | Family 4 |
| Session reaper | `sessionState [Session -> State]`, `reaperEnabled` | Model concurrent session cleanup | Family 2 |
| Single-write-shard commit | (split existing commit path) | Model the two-step optimization and retry fallback | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| SnapshotIsolation | Safety | All committed transactions satisfy snapshot isolation (existing) | Standard |
| TwoPCAtomicity | Safety | If any participant committed tid, all participants must eventually commit tid (no torn commits) | Family 1, 2, 6 |
| NoOrphanedPrepared | Safety | `\A s, t : txnSnapshots[s][t].prepared => t \in shardPreparedTxns[s]` — no prepared txn unreachable from shard tracking | Family 1 |
| CoordinatorDocConsistency | Safety | Coordinator doc decision matches actual decision delivered to participants | Family 1 |
| ReaperSafety | Safety | Reaper never destroys a session with a prepared transaction | Family 2 |
| MigrationCompleteness | Safety | All committed writes in a migrated key range are visible post-migration | Family 4 |
| CatalogRoutingConsistency | Safety | Transaction operations only execute on the shard owning the key at commit time | Family 4, 5 |
| AbortCompleteness | Liveness | If any participant aborts, coordinator eventually decides abort | Family 6 |
| CommitTermination | Liveness | Every started 2PC eventually reaches a commit or abort decision | Family 1, 6 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Coordinator crash after prepare but before decision write → prepared txns orphaned | NoOrphanedPrepared, CommitTermination | 1 |
| MC-2 | MoveKey during active transaction + stale rCatalog → writes to wrong shard | CatalogRoutingConsistency, SnapshotIsolation | 4 |
| MC-3 | Participant abort during 2PC → coordinator hangs (no abort decision path) | CommitTermination, AbortCompleteness | 6 |
| MC-4 | Session reaper fires while transaction is prepared → torn commit | TwoPCAtomicity, ReaperSafety | 2 |
| MC-5 | Coordinator decides commit, sender destroyed before all participants receive → partial commit | TwoPCAtomicity | 6 |
| MC-6 | Single-write-shard optimization: read-only shard failover on retry → duplicate execution | SnapshotIsolation | 1 |
| MC-7 | MoveKey + Restart combination: key migrated, coordinator on old shard fails → orphaned prepared | NoOrphanedPrepared, MigrationCompleteness | 1, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `WriteReadConflictExists` in Storage.tla has tautological comparison (`tOther.ts = tOther.ts`) | Fix the operator and check if enabling it changes model checking results |
| TV-2 | `TxnCanStart` in Storage.tla missing node parameter `[n]` on snapshot access | Fix and verify compilation |
| TV-3 | Spurious `k \in Keys` quantification in 6 Next disjuncts (performance bug) | Remove unused quantifier, benchmark TLC speedup |
| TV-4 | `stableTs`, `oldestTs` initialized to 0 and never modified — timestamp guards trivially true | Determine if these should be actively managed |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `msgsAbort` variable: completely dead (never written to or read from) | Remove from spec or uncomment `RouterTxnAbort` |
| CR-2 | `commitIndex` variable: never modified in base.tla or Storage.tla | Remove or connect to majority-commit modeling |
| CR-3 | `Fairness` defined but never used in `Spec` | Either apply fairness or remove definition |
| CR-4 | `RouterTxnCommitSingleWriteShard` in Fairness but not in Next | Inconsistency — either add to Next or remove from Fairness |
| CR-5 | SERVER-38918 (OPEN TODO in C++): ShardNotFound during commit → `fassert` crash with no safe alternative | Discuss with maintainers |
| CR-6 | SERVER-120584 (OPEN TODO): Coordinator doc deletion with `w:1` — safe but potentially wasteful recovery cycles | Low priority |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb/analysis-report.md`
- **TLA+ spec (modified)**: `case-studies/mongodb/spec/base.tla` (33K), `spec/MC.tla` (1.7K)
- **TLA+ spec (upstream)**: `artifact/vldb25-dist-txns/MultiShardTxn.tla` (594 LOC), `Storage.tla` (446 LOC)
- **C++ coordinator**: `src/mongo/db/s/transaction_coordinator.cpp` (34K), `transaction_coordinator_util.cpp` (49K)
- **C++ router**: `src/mongo/s/transaction_router.cpp` (121K)
- **C++ design doc**: `src/mongo/db/s/README_sessions_and_transactions.md` (49K)
- **Key JIRA tickets**: SERVER-106075, SERVER-105751, SERVER-71219, SERVER-48307, SERVER-61483, SERVER-65821, SERVER-66067, SERVER-116284
- **Jepsen analysis**: [MongoDB 4.2.6](https://jepsen.io/analyses/mongodb-4.2.6)
- **MongoDB VLDB 2025 paper**: [vldb25-dist-txns](https://github.com/mongodb-labs/vldb25-dist-txns)
