# Modeling Brief: MongoDB TxnsCollectionIncarnation — DDL + Transaction placementConflictTime

## 1. System Overview

- **System**: MongoDB sharded cluster — transaction routing with concurrent DDL operations
- **Language**: C++, ~5000 LOC core logic (transaction_router.cpp 2651 + collection_sharding_runtime.cpp 729 + database_sharding_runtime.cpp 278 + DDL coordinators ~1500)
- **Protocol**: placementConflictTime-based detection of DDL/transaction conflicts in multi-document transactions across shards
- **Key architectural choices**:
  - DDL operations are **multi-phase coordinator state machines** (create/drop/rename/movePrimary each have 6-10 phases), persisted to config server, recoverable after failover
  - **placementConflictTime** set once at first transaction statement (immutable after SERVER-87660 fix); sent to shards on every statement
  - **createdDatabases** bypass: transactions that create a database skip the placement conflict check for that database (shard-side, `database_sharding_runtime.cpp:113-114`)
  - **Dual transport**: placementConflictTime carried both in ShardVersion/DatabaseVersion (legacy) and TransactionRuntimeContext (new), feature-flag gated
  - **Critical sections** (DDL locks) block reads/writes during version bump, but are acquired/released in separate phases from the metadata commit
- **Concurrency model**: Router is single-threaded per transaction; shard-side checks under DSS lock (MODE_IS); DDL coordinators serialized via DDL lock (MODE_X per namespace)
- **Existing TLA+ spec**: `TxnsCollectionIncarnation.tla` (582 lines) — models placementConflictTime for Create/Drop/Rename/MovePrimary with 7 invariants. Does NOT model failover, multi-phase DDL, stale error retry, sub-routers, or concurrent routers.

## 2. Bug Families

### Family 1: Multi-Phase DDL Non-Atomicity Under Failover (HIGH)

**Mechanism**: DDL operations span 6-10 phases with separate metadata commit and critical section release. Failover between phases can leave DDL locks released while the operation is incomplete, allowing concurrent DDL or stale transactions.

**Evidence**:
- Historical: SERVER-117340 — unshardCollection after failover releases DDL locks prematurely; coordinator rebuild triggers early-return path, allowing concurrent DDL during commit phase
- Historical: SERVER-91247 — DDLCoordinator creation doesn't survive stepDown-stepUp
- Historical: SERVER-77748 — movePrimary doesn't clear database metadata on stepdown
- Historical: SERVER-88147 — DDL lock acquired when state not PrimaryAndRecovered (window between step-up and DDL service recovery)
- Historical: SERVER-107237 — renameCollection writes unstable collection epoch if commit is retried (non-idempotent metadata write)
- Historical: SERVER-76985 / SERVER-74192 — renameCollection commit phase non-idempotent (2 separate fixes needed)
- Historical: SERVER-85913 — DDL locks + transactions adaptation reverted then re-applied same day (correctness issue in first landing)
- Code analysis: `move_primary_coordinator.cpp` — clone phase explicitly non-idempotent (line 239-251: aborts on recovery); data cloned before read-blocking CS
- Code analysis: `create_collection_coordinator.cpp` — 10-phase pipeline; between kCreateCollectionOnParticipants and kCommitOnShardingCatalog, collection exists on shards but not in config. Cleanup on abort can itself fail partway (line 2416-2488)
- Code analysis: `rename_collection_coordinator.cpp` — target CS acquired then immediately released if target exists (TOCTOU window, line 662-685); cross-DB rename generates new UUID (line 651) but spec preserves UUIDs
- Code analysis: `drop_collection_coordinator.cpp` — 6-step non-atomic commit: metadata removed from config before data dropped on shards (line 295-428)
- Code analysis: DDL locks are in-memory only (`ddl_lock_manager.h:73`) — lost on failover, 5-minute recovery timeout

**Affected code paths**:
- `sharding_coordinator.cpp:477-503` (recovery loop)
- `move_primary_coordinator.cpp:278-348` (kClone → kExitCriticalSection)
- `create_collection_coordinator.cpp:1735-2384` (kEnterWriteCSOnCoordinator → kExitCriticalSection)
- `rename_collection_coordinator.cpp:900-1089` (kBlockCrudAndRename → kUnblockCRUD)
- `drop_collection_coordinator.cpp:274-429` (kEnterCriticalSection → kReleaseCriticalSection)

**Suggested modeling approach**:
- Variables: `ddlPhase[DDLOp -> Phase]`, `ddlLockHeld[DDLOp -> BOOLEAN]`, `criticalSectionActive[Namespace -> {none, write, readwrite}]`
- Actions: Split each DDL into 3-4 key phases (acquire-lock, do-work, commit-metadata, release-lock). Add `DDLFailover` action that resets coordinator to last persisted phase, potentially releasing locks.
- Key invariant: DDL lock must be held whenever metadata is being committed or critical section is active

**Priority**: High
**Rationale**: 11 confirmed historical bugs (SERVER-117340, -91247, -77748, -88147, -107237, -76985, -74192, -85913, -83320, -98161, -87805) sharing multi-phase DDL non-atomicity as root cause. The existing spec models DDL as atomic — this is the largest gap. Multi-phase DDL + failover is the most fertile ground for finding new bugs via model checking.

---

### Family 2: Transaction Statement Interleaving with DDL (HIGH)

**Mechanism**: Between transaction statements (or between parallel shard dispatches within a single statement), DDL operations can complete, changing collection identity (UUID) or placement. The protection depends on placementConflictTime checks catching the change, but there are gaps.

**Evidence**:
- Historical: SERVER-84723 — multi-doc txn sees partial DDL effects between statements; stashed catalog from statement 1 reused for statement 2 without revalidation
- Historical: SERVER-77506 — second statement operates on stale snapshot after chunk migration (the foundational bug that motivated placementConflictTime)
- Historical: SERVER-43848 — stale routing table used for shard targeting in snapshot transactions
- Historical: SERVER-102821 — BulkWrite command failed to attach placementConflictTime to per-namespace versions in nsInfo array (4 commits + 1 revert; structural assumption violation: TransactionRouter assumed versions are top-level fields)
- Historical: SERVER-107685 — view aggregation path dropped decorated ShardVersion due to shadowed variable
- Historical: SERVER-85383 — aggregation pipeline sub-requests didn't propagate placementConflictTime
- Code analysis: `transaction_router.cpp:136-198` — commit command does NOT carry placementConflictTime or re-check routing staleness; commit is "blind" to DDL changes between last statement and commit
- Code analysis: `transaction_router.cpp:954-1001` — participant registration is sequential but dispatch is parallel; DDL can complete between shard1 receiving request and shard2 receiving request
- Code analysis: `collection_sharding_runtime.cpp:137-175` — **production only logs warning** (not error) when placementConflictTime is missing from a transaction operation; older routers silently bypass checking
- Supporting: 7 confirmed deadlock bugs (SERVER-48531, -49508, -76546, -78021, -84468, -95544, -119435) where DDL critical sections + transaction locks + stepdown create multi-way deadlocks

**Affected code paths**:
- `transaction_router.cpp:1598-1630` (commitTransaction — no staleness re-check)
- `transaction_router.cpp:954-1001` (attachTxnFieldsIfNeeded — sequential participant registration)
- `collection_sharding_runtime.cpp:640-729` (_getMetadataWithVersionCheckAt — shard-side check)
- `database_sharding_runtime.cpp:229-246` (checkDbVersionOrThrow — shard-side check)

**Suggested modeling approach**:
- Variables: `txnStatements[Txn -> Seq(Statement)]`, `commitSent[Txn -> BOOLEAN]`
- Actions: Model `RouterSendCommit` as a separate action (distinct from `RouterSendTxnStmt`) that does NOT check placement. Allow DDL to interleave between `RouterSendTxnStmt` (last statement) and `RouterSendCommit`.
- Granularity: Split multi-shard statement dispatch into per-shard sub-actions to model DDL interleaving between dispatches

**Priority**: High
**Rationale**: 6+ confirmed bugs (SERVER-84723, -77506, -102821, -107685, -85383, -43848) plus 7 deadlock bugs sharing the DDL+txn interleaving mechanism. The commit-time gap is an unexplored area �� the existing spec models `RouterHandleOK` as atomically completing the transaction, not modeling a separate commit step. The production warning-only enforcement (not error) for missing placementConflictTime confirms the protocol's attack surface is broader than modeled.

---

### Family 3: createdDatabases Bypass Scope and Correctness (MEDIUM)

**Mechanism**: The `createdDatabases` set controls which databases skip the placementConflictTime check. The existing spec unconditionally adds "db" (spec line 207), making the bypass always active — a dead code path in the spec. The implementation has additional edge cases around bypass granularity and premature annotation.

**Evidence**:
- Spec analysis: `TxnsCollectionIncarnation.tla:207` — `rCreatedDatabases' = [rCreatedDatabases EXCEPT ![t] = @ \union {"db"}]` unconditionally adds the sole database on every statement, making `DatabaseMetadataCheck`'s SNAPSHOT_INCOMPATIBLE path dead code
- Code analysis: `cluster_ddl.cpp:129-131` — `annotateCreatedDatabase` called BEFORE `_configsvrCreateDatabase` succeeds; if create fails, bypass persists for a database not actually created by this transaction
- Code analysis: `database_sharding_runtime.cpp:112-121` ��� Legacy path (`!createdDatabases.empty()`) bypasses check for ALL databases when ANY database was created; new path checks per-database (`std::ranges::find(createdDatabases, dbName)`)
- Code analysis: `database_sharding_runtime.cpp:113-114` — bypass skips BOTH `atClusterTime` AND `placementConflictTime` checks (via `skipAtClusterTimeAndPlacementConflictTimeChecks`); broader than just placementConflictTime
- Code analysis: `transaction_participant.cpp:1072-1074` — `transactionRuntimeContext.createdDatabases` unconditionally overwritten on continue statement (could shrink set if router sends smaller set)
- Code analysis: `transaction_router.cpp:331-349` — Deprecated channel uses `Timestamp(0,0)` as "skip all checks" sentinel for created databases; fragile convention
- Code analysis: `createdDatabases` not persisted on shard — if shard fails over mid-transaction, re-sent by router on next statement, but there's a window where a statement arrives without it

**Affected code paths**:
- `cluster_ddl.cpp:125-142` (annotateCreatedDatabase in createDatabase)
- `database_sharding_runtime.cpp:95-150` (checkPlacementConflictTimestamp)
- `transaction_router.cpp:651,979,1000` (propagation to shards)

**Suggested modeling approach**:
- Variables: `createdDatabases[Txn -> SUBSET DatabaseNames]` (already exists); add `DatabaseNames == {"db1", "db2"}` (multiple databases)
- Actions: Make `createDatabase` a conditional action (not unconditional like spec line 207). Add `CreateDatabaseFails` action that annotates but doesn't actually create.
- Key: Model with 2 databases to exercise the bypass granularity (legacy all-or-nothing vs new per-database)

**Priority**: Medium
**Rationale**: The bypass makes the existing spec's database version check dead code. Fixing this in the model (2 databases + conditional creation) could find bugs where the legacy bypass incorrectly protects an unrelated database, or where premature annotation masks a real conflict.

---

### Family 4: Stale Error Retry and placementConflictTime Reset (MEDIUM)

**Mechanism**: When a stale version error occurs on the first statement, the router resets placementConflictTime to uninitialized and retries with a fresh timestamp. This reset depends on vector clock gossip timing, can target different shards, and interacts with sub-routers.

**Evidence**:
- Historical: SERVER-87660 — placementConflictTime was mutable within a statement (fixed: now immutable after first set)
- Code analysis: `transaction_router.cpp:1220-1234` — on first-statement stale error, all participants cleared and placementConflictTime reset
- Code analysis: `transaction_router.cpp:1331-1356` — new time from `VectorClock::get(opCtx)->getTime()`; depends on gossip from stale error response having updated the clock
- Code analysis: `transaction_router.cpp:1373-1395` — sub-router reuse after parent retry: if sub-router has non-empty participants, it falls through to `kContinue` and does NOT reset its placementConflictTime
- Code analysis: `transaction_router.cpp:1122-1124` — when retryable stale error, abort NOT sent to pending participants (dangling transaction on shard until timeout)

**Affected code paths**:
- `transaction_router.cpp:1181-1235` (canContinueOnStaleShardOrDbError + onStaleShardOrDbError)
- `transaction_router.cpp:2280-2300` (_errorAllowsRetryOnStaleShardOrDb)
- `transaction_router.cpp:1331-1356` (setDefaultAtClusterTime)
- `transaction_router.cpp:2050-2064` (_resetRouterStateForStartOrContinueTransaction — sub-router)

**Suggested modeling approach**:
- Variables: `retryCount[Txn -> Nat]`, `staleErrorOnStmt[Txn -> {none, first, later}]`
- Actions: Add `RouterReceiveStaleError` that resets placementConflictTime for first-statement errors only. Add `RouterRetry` that re-sends with fresh time. Model the DDL interleaving during the retry window.
- Key constraint: On 2nd+ statement stale error, transaction MUST abort (no in-place retry)

**Priority**: Medium
**Rationale**: SERVER-87660 was a real bug (now fixed). The retry mechanism introduces a window where the new placementConflictTime could miss a DDL that committed just before the old time was captured. Worth verifying that the reset-and-retry protocol is safe.

---

### Family 5: Commit Protocol Without Placement Validation (MEDIUM)

**Mechanism**: The commit path (single-shard commit, single-write-shard optimization, 2PC) does not re-check placement or routing staleness. A DDL completing between the last statement and commit is not detected.

**Evidence**:
- Code analysis: `transaction_router.cpp:1598-1630` — `commitTransaction` does not check placement conflict or routing staleness
- Code analysis: `transaction_router.cpp:136-198` — `sendCommitDirectlyToShards` sends via `MultiStatementTransactionRequestsSender` but with `isTransactionCommand=true`, so no readConcern or placement info attached
- Code analysis: `transaction_router.cpp:1734-1745` — single-write-shard optimization commits read-only shards FIRST (sequentially), then write shard; DDL can occur between

**Affected code paths**:
- `transaction_router.cpp:1632-1772` (_commitTransaction — all commit paths)
- `transaction_router.cpp:136-198` (sendCommitDirectlyToShards)

**Suggested modeling approach**:
- Variables: (reuse existing) — add `commitPhase[Txn -> {notStarted, committingReadOnly, committingWrite, done}]`
- Actions: Add `RouterSendCommit` as a distinct action from `RouterSendTxnStmt`. Allow DDL to interleave between last `ShardResponse(OK)` and `RouterSendCommit`.
- Key invariant: If all statements succeeded with consistent placement, does commit preserve consistency even if DDL occurs between last statement and commit?

**Priority**: Medium
**Rationale**: The commit path is unprotected by design (relying on shard-side snapshot isolation for read-only data and locks for write data). TLA+ model checking can verify whether this design assumption holds under all DDL interleavings.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Multi-phase DDL with failover | Family 1: SERVER-117340 (confirmed bug from DDL failover); all DDL coordinators are multi-phase | Split DDL into phases (acquire-lock → do-work → commit-metadata → release-lock); add `DDLFailover` action between phases |
| DDL interleaving between transaction statements | Family 2: SERVER-84723, SERVER-77506 (confirmed production bugs) | Allow DDL actions between `RouterSendTxnStmt` and `ShardResponse` |
| Separate commit step | Family 5: commit has no placement validation | Add `RouterSendCommit` action distinct from last statement |
| Multiple databases | Family 3: createdDatabases bypass dead code with single DB | Use `DatabaseNames == {"db1", "db2"}` to exercise bypass granularity |
| Conditional createDatabase | Family 3: spec always bypasses | Only add to `createdDatabases` when database is actually being created (not unconditionally) |
| First-statement retry with reset | Family 4: SERVER-87660 pattern | Model stale error → reset placementConflictTime → retry; verify new time catches the DDL |
| Critical section (DDL lock) | Family 1, 2: prevents reads/writes during DDL commit | Model as blocking guard on shard-side operations; verify it's held during metadata commit |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Sub-router behavior | Complex implementation detail; sub-routers inherit parent's placementConflictTime via readConcern; no independent bugs identified beyond Family 4 retry edge case |
| Feature flag / mixed-version transitions | FCV is cluster-wide; the transition window is narrow; not a protocol-level concern |
| BulkWrite serialization format | SERVER-102821 is a serialization bug, not protocol logic |
| Index-level catalog changes | SERVER-67538 is sub-collection granularity; orthogonal to placement model |
| Metadata refresh thread concurrency | SERVER-64730 is implementation detail of shard refresh mechanism |
| Migration data transfer protocol | SERVER-78414, SERVER-71219 are migration protocol details unrelated to DDL+txn placement |
| Lock-free read path | SERVER-62457's ABA is already covered by UUID check; lock-free is optimization |
| Session yield/unyield | Router-side yield releases session, not shard locks; DDL blocked by shard-side txn |
| 2PC commit protocol details | Out of scope; existing spec already abstracts commit as atomic |
| Concurrent routers | Would massively expand state space; single router sufficient for placement check verification |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Multi-phase DDL | `ddlPhase`, `ddlLockHeld`, `criticalSection` | Model DDL as non-atomic; enable failover between phases | Family 1 |
| DDL Failover | `configPrimary`, `persistedPhase` | Crash/recover DDL coordinator at any phase | Family 1 |
| Separate commit action | `commitSent` | Model commit as distinct step without placement check | Family 2, 5 |
| Multiple databases | expand `DatabaseNames` to `{"db1","db2"}` | Exercise createdDatabases bypass granularity | Family 3 |
| Conditional createDatabase | modify `rCreatedDatabases` update | Only bypass when DB actually created | Family 3 |
| Stale error + retry | `retryCount`, `staleErrorOnStmt` | Model first-statement retry with placementConflictTime reset | Family 4 |
| Critical section guard | `criticalSection[ns -> Phase]` | Block shard operations during DDL commit | Family 1, 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| CommittedTxnConsistentKeySet | Safety | (existing) Committed txn responses have consistent UUID and data partition | Family 2 |
| CommittedTxnImpliesAllStmtsSuccessful | Safety | (existing) All statements of a committed txn returned OK | Family 2, 4 |
| DDLLockHeldDuringCommit | Safety | DDL lock must be held whenever metadata is being committed to config server | Family 1 |
| NoDanglingCriticalSection | Safety | Critical section is eventually released (no leak after failover) | Family 1 |
| PlacementConflictTimeMonotonicity | Safety | After retry, new placementConflictTime >= DDL commit time that caused the stale error | Family 4 |
| CommitSafeAfterStatements | Safety | If all statements passed placement checks, commit cannot violate consistency even without re-check | Family 5 |
| CreatedDatabasesBypassCorrectness | Safety | createdDatabases bypass only skips check for databases actually created by this txn | Family 3 |
| NoCrossDatabaseBypassLeak | Safety | Creating db1 does not bypass placement check for db2 | Family 3 |
| DDLPhaseRecoveryConsistency | Safety | After DDL failover recovery, all invariants of the persisted phase hold | Family 1 |
| AllTxnsEventuallyDone | Liveness | (existing) All transactions eventually complete | Family 4 |
| NoOrphanedCriticalSection | Safety | After DDL failover recovery, no critical section is held without a corresponding DDL lock | Family 1 |
| RenameTargetUUIDConsistency | Safety | After rename, target namespace UUID matches source UUID (same-DB) or is fresh (cross-DB) | Family 1 |
| PlacementCheckNotBypassed | Safety | Every transaction statement that reaches a shard has placementConflictTime validated (fault injection) | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1-1 | DDL failover between commit-metadata and release-lock leaves locks released but operation incomplete | DDLLockHeldDuringCommit | Family 1 |
| F1-2 | MovePrimary: data cloned to recipient before read-blocking critical section on donor | CommittedTxnConsistentKeySet (txn reads from donor with stale data) | Family 1 |
| F2-1 | DDL between last statement and commit — commit proceeds without placement re-check | CommitSafeAfterStatements | Family 5 |
| F2-2 | DDL completes between parallel dispatches to shard1 and shard2 in same statement | CommittedTxnConsistentKeySet | Family 2 |
| F3-1 | Legacy createdDatabases bypass (all-or-nothing) allows stale read on unrelated database | NoCrossDatabaseBypassLeak | Family 3 |
| F3-2 | annotateCreatedDatabase before create succeeds → bypass persists for non-created database | CreatedDatabasesBypassCorrectness | Family 3 |
| F4-1 | Reset placementConflictTime on retry captures time before DDL gossip arrives | PlacementConflictTimeMonotonicity | Family 4 |
| F2-3 | Missing placementConflictTime (production: warning only, not rejected) allows operation to bypass all placement checks | CommittedTxnConsistentKeySet | Family 2 |
| F1-3 | Rename target TOCTOU: CS released after check, target dropped+recreated before kBlockCrudAndRename | CommittedTxnConsistentKeySet | Family 1 |
| F1-4 | Cross-DB rename generates new UUID but spec preserves UUIDs — incarnation mismatch possible | CommittedTxnConsistentKeySet | Family 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | TransactionParticipant null → placementConflictTime silently skipped (`collection_sharding_runtime.cpp:665-666`) | Construct multi-doc txn where TransactionParticipant is not initialized |
| T2 | createdDatabases shrinks on continue statement (`transaction_participant.cpp:1072-1074`) | Send continue with smaller createdDatabases set than start |
| T3 | Mixed-version: old router + new shard → TransactionRuntimeContext absent, check skipped (`database_sharding_runtime.cpp:103-115`) | Mixed-version cluster test during FCV upgrade |
| T4 | Single-write-shard commit: DDL between read-only commit and write commit (`transaction_router.cpp:1734-1745`) | Trigger DDL during sequential commit window |
| T5 | Recovery token sent to wrong shard (`transaction_router.cpp:2066-2095`) | Failover recovery shard during commit recovery |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | Inconsistent error codes: SnapshotUnavailable vs MigrationConflict for similar placementConflictTime failures | Review whether different error codes cause different router retry behavior |
| C2 | Double fetch of db version in checkDbVersionOrThrow (TOCTOU if locking changes) | Safe under current locking; document the dependency |
| C3 | Asymmetric critical section access type management between DB and collection sharding runtimes | Architectural difference, not a bug |

## 7. Reference Pointers

- **Existing TLA+ spec**: `artifact/mongo-src/src/mongo/tla_plus/Sharding/TxnsCollectionIncarnation/TxnsCollectionIncarnation.tla`
- **Full analysis report**: `case-studies/mongodb-txnscollincarnation/analysis-report.md`
- **Key source files**:
  - `src/mongo/s/transaction_router.cpp` (2651 lines — router-side txn coordination)
  - `src/mongo/db/shard_role/shard_catalog/collection_sharding_runtime.cpp` (729 lines — shard-side collection version check)
  - `src/mongo/db/shard_role/shard_catalog/database_sharding_runtime.cpp` (278 lines — shard-side database version check)
  - `src/mongo/db/global_catalog/ddl/move_primary_coordinator.cpp` (movePrimary DDL coordinator)
  - `src/mongo/db/global_catalog/ddl/create_collection_coordinator.cpp` (createCollection DDL coordinator)
  - `src/mongo/db/global_catalog/ddl/drop_collection_coordinator.cpp` (dropCollection DDL coordinator)
  - `src/mongo/db/global_catalog/ddl/rename_collection_coordinator.cpp` (renameCollection DDL coordinator)
  - `src/mongo/db/global_catalog/ddl/sharding_coordinator.cpp` (base DDL coordinator infrastructure)
  - `src/mongo/db/global_catalog/ddl/cluster_ddl.cpp` (annotateCreatedDatabase)
  - `src/mongo/db/transaction/transaction_participant.cpp` (shard-side txn context storage)
- **JIRA issues**:
  - Family 1: SERVER-117340, -91247, -77748, -88147, -107237, -76985, -74192, -85913, -83320, -98161, -87805
  - Family 2: SERVER-84723, -77506, -102821, -107685, -85383, -43848 + deadlocks: SERVER-48531, -49508, -76546, -78021, -84468, -95544, -119435
  - Family 3: (spec analysis — no historical bugs, unexplored territory)
  - Family 4: SERVER-87660
  - Foundational: SERVER-82353, -97587
  - TLA+ evolution: SERVER-97886, -99358, -114642
- **Shared harness**: `case-studies/mongodb-shared-harness.md` (Docker compose, log parsing)
- **Protocol documentation**: `src/mongo/db/global_catalog/ddl/README_transactions_and_ddl.md` (194 lines — definitive protocol description)
