# Analysis Report: MongoDB TxnsCollectionIncarnation — DDL + Transaction placementConflictTime

## Coverage Statistics

### Git History Mining
- **Searches performed**: 26 keyword searches across sharding DDL files and full repo
- **Total commits identified**: 80+ unique commits
- **Critical bug-fix commits deeply analyzed**: 25+ (full diff review)
- **Key tickets traced**: SERVER-82353, SERVER-87660, SERVER-97587, SERVER-102821, SERVER-117340, SERVER-84723, SERVER-77506, SERVER-85383, SERVER-84761, SERVER-102063, SERVER-103170, SERVER-86920, SERVER-107685, SERVER-107237, SERVER-76985, SERVER-74192, SERVER-85913, SERVER-91247, SERVER-77748, SERVER-88147, SERVER-48531, SERVER-49508, SERVER-76546, SERVER-95544, SERVER-119435
- **Note**: MongoDB uses Jira (SERVER-* tickets), not GitHub Issues. All gh issue/PR queries return empty (issues disabled on mongodb/mongo).

### GitHub/JIRA Issues
- **Total SERVER tickets collected**: 100+ unique (from git log mining)
- **Deeply read (commit diffs + root cause analysis)**: 25+
- **Confirmed relevant to DDL+txn placement model**: 15
- **Excluded as irrelevant or different abstraction level**: 85+
- **Categories**: placementConflictTime propagation (7), DDL coordinator correctness (6), DDL failover/recovery (5), deadlocks DDL+txn+stepdown (7), chunk migration+txn (6), stale metadata/race conditions (8), critical section (6), movePrimary (8), StaleDbVersion (8), rename (5), drop (4), create (5), TLA+ spec evolution (3), miscellaneous (22)

### Deep Code Analysis
- **Files fully read**: 12 core source files
- **Files partially analyzed**: 15+ additional (headers, IDL, coordinators, tests)
- **Findings generated**: 49 (16 shard-side, 16 transaction router, 17 DDL coordinators, some overlapping)
- **Findings after verification**: 44 (5 excluded as intentional design or protected by compensating mechanisms)

---

## Phase 1: Reconnaissance Summary

### Architecture

MongoDB's sharded transaction system has three layers:

1. **Router layer** (`transaction_router.cpp`): Manages transaction state, sets `placementConflictTime` at first statement, routes statements to shards, handles stale errors with first-statement-only retry, sends commit.

2. **Shard layer** (`collection_sharding_runtime.cpp`, `database_sharding_runtime.cpp`): Validates placement version on each statement. Three-level check:
   - Level 1: Database version equality + placementConflictTime vs dbVersion timestamp (with `createdDatabases` bypass)
   - Level 2: Collection shard version compatibility + placementConflictTime vs chunk migration time + placementConflictTime vs collection generation timestamp
   - Level 3: UUID comparison at storage layer (implicit in snapshot)

3. **DDL coordinator layer** (per-operation coordinator files): Multi-phase state machines persisted to config server. Each DDL operation:
   - Acquires DDL lock (MODE_X per namespace)
   - Acquires critical section (blocks reads/writes)
   - Commits metadata to config server (bumps version)
   - Releases critical section and DDL lock

### Existing TLA+ Spec Coverage

The existing `TxnsCollectionIncarnation.tla` (582 lines) models:
- Single database ("db"), multiple namespaces, multiple shards, multiple transactions
- Router: statement routing with cached metadata, placementConflictTime set at first statement, stale error handling (abort only, no retry)
- Shard: snapshot establishment, 3-level metadata check (database → shard → local UUID)
- DDL: Create/Drop (tracked and untracked), Rename, MovePrimary — all **atomic** (single-step)
- 7 invariants + 2 temporal properties + 5 bait properties

**What it does NOT model** (gaps for our spec):
1. DDL as multi-phase (no failover between phases)
2. Critical sections / DDL locks
3. Stale error retry with placementConflictTime reset
4. Separate commit step
5. Multiple databases (only "db")
6. Concurrent routers or sub-routers
7. Network partitions or message loss

---

## Phase 2: Bug Archaeology — Detailed Findings

### Critical Bug-Fix Commits (Chronological)

#### 1. SERVER-82353 (Jan 2024) — Foundational placementConflictTime

**Commit**: `b347171d4e`
**Root cause**: Before this fix, movePrimary during a multi-document transaction caused the transaction to read from the wrong shard. The router picked `atClusterTime` before movePrimary completed; it routed to the new primary with an old snapshot timestamp, operating on intermediate cloned state.
**Fix**: Introduced `placementConflictTime` on `DatabaseVersion`. The shard checks `placementConflictTime >= installedDatabaseVersion.getTimestamp()` and throws `MigrationConflict` if violated. Added `createdDatabases` tracking and `annotateCreatedDatabase()`.
**Modeled in existing spec**: YES — this is exactly what the spec was designed to verify.

#### 2. SERVER-85383 (Feb 2024) — Aggregation pipeline gap

**Commit**: `0f1450f373`
**Root cause**: Aggregation sub-requests (e.g., `$merge`, `$out`) did not carry `placementConflictTime` from the TransactionRouter.
**Fix**: Propagated placementConflictTime through `AggregateCommandRequest`.
**Modeled in existing spec**: Not directly (spec doesn't model aggregation), but the principle is covered (all statements carry placementConflictTime).

#### 3. SERVER-84761 (Apr 2024) — Stale placement in MigrationSourceManager

**Commit**: `a798ce213d`
**Root cause**: MigrationSourceManager used potentially stale routing info when checking if recipient already owned chunks.
**Fix**: Added `getCollectionRoutingInfoWithPlacementRefresh` after starting clone.
**Modeled in existing spec**: No (migration source details not modeled).

#### 4. SERVER-87660 (Jul 2024) — Mutable placementConflictTime

**Commit**: `4a141a4ec7`
**Root cause**: The `AtClusterTime` class allowed changing the timestamp within the same statement (via `canChange(stmtId)`). This could bypass conflict detection if placement changed between the two selection points.
**Fix**: Removed `AtClusterTime` class. Made placementConflictTime a bare `LogicalTime`, immutable once set. Only reset to uninitialized on full first-statement retry.
**Modeled in existing spec**: The spec already has correct (immutable) behavior. The bug was in the implementation deviating from the intended protocol.

#### 5. SERVER-97886 (Jan 2025) — TLA+ spec creation

**Commit**: `bc3f885ca4`
**This is the existing TLA+ spec we are analyzing and extending.**

#### 6. SERVER-102821 (Apr 2025) — BulkWrite missing placementConflictTime

**Commit**: `30e34cf436` (2nd attempt, after revert of 1st attempt `2224cd6a45`)
**Root cause**: BulkWrite embeds shard/database versions per-`nsInfo` entry (not top-level). The functions `appendFieldsForStartTransaction`/`appendFieldsForContinueTransaction` only updated top-level fields.
**Fix**: Special-case detection and update of BulkWrite `nsInfo` array entries.
**Modeled in existing spec**: No (command serialization not modeled). Not worth modeling — serialization bug, not protocol.

#### 7. SERVER-97587 (Dec 2025) — Architectural refactor

**Commit**: `e3568763be`
**Root cause**: N/A (not a bug fix). Major architectural change moving placementConflictTime into `TransactionRuntimeContext` on `TransactionParticipant`, with invariant-level assertions that it never changes during a transaction.
**Impact on modeling**: Introduces the dual-transport path (legacy on ShardVersion/DatabaseVersion + new on TransactionRuntimeContext).

#### 8. SERVER-117340 (Recent) — Premature DDL lock release after failover

**Commit**: `99f2b24fab`
**Root cause**: During `unshardCollection` (implemented via resharding), after the coordinator persists commit decision but before telling participants, primary stepdown + step-up triggers coordinator rebuild. The `ReshardCollectionCoordinator` had an early-return path for "already unsharded" collections, which was erroneously triggered on recovery, releasing DDL locks during the critical commit phase.
**Fix**: Moved "already unsharded" check from `_runImpl` to `_isReshardingOpRedundant` (evaluated at correct point in lifecycle).
**Modeled in existing spec**: NO. The spec models DDL as atomic.
**Should be modeled**: YES — primary motivation for Family 1.

#### 9. SERVER-107685 (Jul 2025) — View aggregation missing placementConflictTime

**Commit**: `5ecd646da7`
**Root cause**: When `aggregate` targets a view resolving to an unsharded collection, `ResolvedViewAggExState::setShardRole()` correctly constructed a `ShardVersion sv` with placementConflictTime but then passed a **fresh `ShardVersion::UNSHARDED()` literal** instead of `sv` to `ScopedSetShardRole`. The decorated version was silently discarded. Classic shadowed-variable bug.
**Fix**: Changed argument from `ShardVersion::UNSHARDED()` to `sv`.
**Modeled in existing spec**: No (view resolution not modeled). Not worth modeling — code-level bug.

#### 10. SERVER-85913 (Jan 2024) — DDL locks + transactions (reverted, re-applied)

**Commits**: `a752a3d1f4` (first), `bc5b98c070` (revert), `9340b95d51` (re-apply same day)
**Root cause**: Adapting DDL locks to work with transactions introduced a correctness issue that required revert and re-landing. The revert-redo pattern on the same day suggests a regression was caught in CI.
**Impact on modeling**: Confirms DDL lock + transaction interaction is error-prone.

#### 11. SERVER-91247 — DDLCoordinator creation doesn't survive stepDown-stepUp

**Commit**: `49b06b69f3`
**Root cause**: DDLCoordinator creation did not survive node stepDown-stepUp. On recovery, the coordinator state was lost, potentially leaving orphaned critical sections or metadata.
**Impact on modeling**: Directly supports Family 1 (multi-phase DDL non-atomicity under failover).

#### 12. DDL+Transaction Deadlock Family (7 confirmed bugs)

| Ticket | Summary |
|--------|---------|
| SERVER-48531 | 3-way deadlock: chunk splitter + prepared txns + stepdown |
| SERVER-49508 | Step-up deadlock: migration recovery + prepared transaction |
| SERVER-76546 | _migrateClone deadlock with prepared txns on secondaries |
| SERVER-78021 | Session checkout vs _chunkOpLock ordering deadlock |
| SERVER-84468 | runTransactionOnShardingCatalog deadlock |
| SERVER-95544 | setFCV + createCollection + moveCollection 3-way deadlock |
| SERVER-119435 | Range deletion task registration deadlock |

These are less amenable to TLA+ modeling (requires lock ordering semantics) but confirm that DDL+transaction+failover interactions are a persistent source of production bugs.

### JIRA Issue Triage (Top 25 Deep-Read)

| Ticket | Root Cause | Fixed? | Cross-Shard? | Failover? | Concurrent DDL? | Model-Checkable? |
|--------|-----------|--------|--------------|-----------|-----------------|-----------------|
| SERVER-84723 | Stashed catalog reused between statements without revalidation | Yes | Single-shard | No | Yes | Yes |
| SERVER-77506 | No placementConflictTime for non-snapshot txns | Yes | Cross-shard | No | Yes (migration) | Yes (already modeled) |
| SERVER-67538 | Index catalog min-visible-snapshot not bumped | Yes | Single-shard | No | Yes (index build) | No (sub-collection) |
| SERVER-62457 | Lock-free read ABA on drop+recreate | Yes | Single-shard | No | Yes | Partial (ABA covered by UUID) |
| SERVER-43848 | Stale _shardVersions used for snapshot routing | Yes | Cross-shard | No | Yes (migration) | Yes |
| SERVER-40352 | Untimestamped reads skip min-visible-snapshot | Yes | Single-shard | No | Yes | Partial (local mechanism) |
| SERVER-64730 | Non-monotonous metadata from concurrent refresh | Yes | Single-shard | No | Yes (resharding) | No (impl detail) |
| SERVER-78414 | Migration _transferMods early termination | Yes | Cross-shard | No | No | No |
| SERVER-71219 | Migration misses prepared txn writes | Yes | Cross-shard | Yes (term change) | No | Partial |
| SERVER-87660 | Mutable placementConflictTime | Yes | Cross-shard | No | Yes | Yes (already modeled correctly) |
| SERVER-102821 | BulkWrite serialization missing placementConflictTime | Yes | Cross-shard | No | Yes | No (serialization) |
| SERVER-117340 | Premature DDL lock release after failover | Yes | Cross-shard | Yes | Yes | Yes |

---

## Phase 3: Deep Analysis — All Findings

### Shard-Side Version Checking (16 findings)

| ID | Finding | File:Line | Classification | Severity |
|----|---------|-----------|----------------|----------|
| CSR-1 | Inconsistent error codes (SnapshotUnavailable vs MigrationConflict) for placementConflictTime failures | collection_sharding_runtime.cpp:113,126 vs 678 | Code-review-only | Low |
| CSR-2 | Redundant but complementary placementConflictTime checks (chunk migration vs collection DDL) | collection_sharding_runtime.cpp:676-686 vs 688-689 | Code-review-only (correct) | Info |
| CSR-3 | No createdDatabases bypass in collection-level checks (intentional: only for untracked via DB path) | collection_sharding_runtime.cpp:659-667 | Model-checkable (confirm correct) | Info |
| CSR-4 | Double fetch of db version (TOCTOU if locking changes) | database_sharding_runtime.cpp:235,237 | Code-review-only | Low |
| CSR-5 | Critical section + version check non-atomicity (protected by DSS MODE_IS lock) | database_sharding_runtime.cpp:231-241 | Model-checkable | Low |
| CSR-6 | createdDatabases bypass skips BOTH atClusterTime and placementConflictTime (intentional for snapshot txns creating DB) | database_sharding_runtime.cpp:126-128 | Model-checkable (confirm correct) | Info |
| CSR-7 | TLA+ LocalMetadataCheck (UUID) handled at storage layer, not in these files | TxnsCollectionIncarnation.tla:273-283 | Model-checkable | Info |
| CSR-8 | Silent placementConflictTime skip when TransactionParticipant is null | collection_sharding_runtime.cpp:665-666 | Test-verifiable | Medium |
| CSR-9 | DDL between version check and data access (protected by snapshot isolation) | Both files | Model-checkable (confirm correct) | Low |
| CSR-10 | createdDatabases unconditionally overwritten on continue statement (can shrink set) | transaction_participant.cpp:1072-1074 | Test-verifiable | Medium |
| CSR-11 | **Legacy bypass is overbroad: ALL databases bypassed when ANY was created** | database_sharding_runtime.cpp:112-121 | Model-checkable | Medium |
| CSR-12 | **annotateCreatedDatabase called BEFORE create succeeds** | cluster_ddl.cpp:129-131 | Model-checkable | Medium |
| CSR-13 | Missing TransactionRuntimeContext during mixed-version upgrade → check silently skipped | database_sharding_runtime.cpp:103-115 | Test-verifiable | Medium |
| CSR-14 | Collection path has no isUpgradingOrDowngrading guard (safe: both encodings set during upgrade) | collection_sharding_runtime.cpp:660 | Code-review-only | Low |
| CSR-15 | Asymmetric access type management between DB and collection critical sections | database_sharding_runtime.cpp:324-341 vs collection_sharding_runtime.cpp:343-348 | Code-review-only | Info |
| CSR-16 | Catch-up phase cancels refresh but doesn't change access type (consistent) | Both files | Code-review-only | Info |

### Transaction Router (16 findings)

| ID | Finding | File:Line | Classification | Severity |
|----|---------|-----------|----------------|----------|
| TR-1 | 2nd+ statement stale errors force abort (no in-place retry) | transaction_router.cpp:1181-1205,2280-2300 | Model-checkable | Info (by design) |
| TR-2 | **Retry on first statement can target completely different shard set** | transaction_router.cpp:1220-1234 | Model-checkable | Medium |
| TR-3 | **New placementConflictTime after reset depends on vector clock gossip timing** | transaction_router.cpp:1228-1234,1331-1356 | Model-checkable | Medium |
| TR-4 | Sub-router inherits placementConflictTime from opCtx readConcern | transaction_router.cpp:2050-2064,1300-1329 | Code-review-only | Info |
| TR-5 | **Sub-router time can diverge if parent retries but sub-router has participants** | transaction_router.cpp:1373-1395 | Model-checkable | Medium |
| TR-6 | Sub-routers cannot retry stale errors (design constraint) | transaction_router.cpp:934-936,2295-2298 | Code-review-only | Info |
| TR-7 | Participant registration sequential, network dispatch parallel | multi_statement_transaction_requests_sender.cpp:62-90 | Model-checkable | Info |
| TR-8 | **DDL can complete between parallel shard dispatches** | No explicit protection | Model-checkable | Medium |
| TR-9 | **Shard1 success + shard2 stale: abort skipped on retryable stale → dangling txn** | transaction_router.cpp:1122-1124 | Model-checkable | Medium |
| TR-10 | **Commit does NOT carry placementConflictTime or re-check routing** | transaction_router.cpp:1598-1630,136-198 | Model-checkable | High |
| TR-11 | Single-write-shard optimization: sequential read-only → write commit with DDL window | transaction_router.cpp:1734-1745 | Test-verifiable | Medium |
| TR-12 | Session yield releases router locks; DDL metadata changes may proceed during yield | transaction_router.cpp:1515-1555,1980-1982 | Model-checkable | Low |
| TR-13 | Multiple concurrent yields via int counter (by design) | transaction_router.h:897 | Code-review-only | Info |
| TR-14 | Recovery path trusts recovery token completely — no cross-validation | transaction_router.cpp:1458-1473,2066-2095 | Test-verifiable | Medium |
| TR-15 | Recovery may misidentify state after recovery shard primary failover | transaction_router.cpp:2083-2094 | Test-verifiable | Medium |
| TR-16 | `kCommit` action for new txn number: no readConcern, no placement info set | transaction_router.cpp:1458-1473 | Code-review-only | Low |

### Additional Shard-Side Findings (from expanded analysis)

| ID | Finding | File:Line | Classification | Severity |
|----|---------|-----------|----------------|----------|
| CSR-17 | **Production-only warning for missing placementConflictTime**: `assertPlacementConflictTimePresentWhenRequired` uses tassert in test mode but only logs a warning in production (`collection_sharding_runtime.cpp:137-175`, `database_sharding_runtime.cpp:64-93`). Operations from older routers silently bypass placement conflict checking. | Both sharding runtime files | Test-verifiable | High |
| CSR-18 | **Feature flag transition dual-path**: placementConflictTime sent both via `TransactionRuntimeContext` (new, gated by `gAddTransactionRuntimeContextAsAGenericArgument`) and as `_DEPRECATED` fields on `ShardVersion`/`DatabaseVersion` (old). Both paths must stay in sync until SERVER-115178 resolves. | collection_sharding_runtime.cpp:659-667 | Code-review-only | Medium |
| CSR-19 | **Timestamp(0,0) sentinel for legacy bypass**: The deprecated channel uses `Timestamp(0,0)` to signal "skip all checks" for created databases (`transaction_router.cpp:344`). While clusterTime starts at 1, this is a fragile convention. | transaction_router.cpp:331-349 | Code-review-only | Low |
| CSR-20 | **Participant invariant on placementConflictTime**: `getParticipant` (transaction_router.cpp:1012-1015) asserts participant's stored PCT matches transaction-wide value. Complementary to shard-side tassert 9758703. | transaction_router.cpp:1009-1016 | Code-review-only (correct) | Info |

### DDL Coordinators (17 findings)

| ID | Finding | File:Line | Classification | Severity |
|----|---------|-----------|----------------|----------|
| CC-1 | Transient UUID not persisted in coordinator document (re-read from catalog on recovery) | create_collection_coordinator.cpp:1290-1376 | Code-review-only | Low |
| CC-2 | **Gap between local collection creation and catalog commit** — critical section on coordinator only, not all shards | create_collection_coordinator.cpp:1735-2384 | Model-checkable | Medium |
| CC-3 | Concurrent creates serialized via DDL lock + PrimaryOnlyService conflict detection | create_collection_coordinator.cpp:1442-1455 | Model-checkable (confirm correct) | Low |
| DC-1 | **Non-atomic metadata removal and local data drop** (metadata removed from config first) | drop_collection_coordinator.cpp:295-429 | Model-checkable | Medium |
| DC-2 | Metadata removed before data dropped on shards | drop_collection_coordinator.cpp:359,389-400 | Model-checkable | Low |
| RC-1 | **Local rename on ALL shards before metadata commit** | rename_collection_coordinator.cpp:900-1031 | Model-checkable | Medium |
| RC-2 | Version bump atomic within metadata transaction (safe) | rename_collection_coordinator.cpp:392-465 | Code-review-only | Low |
| RC-3 | Old chunks cleaned after critical section release (safe: old UUID) | rename_collection_coordinator.cpp:1078-1089 | Code-review-only | Low |
| MP-1 | **Data cloned before read-blocking critical section; version bumped later** | move_primary_coordinator.cpp:278-348 | Model-checkable | High |
| MP-2 | Clone is non-idempotent; failure during clone forces abort | move_primary_coordinator.cpp:239-251 | Model-checkable | Medium |
| MP-3 | **Gap between config server commit and shard metadata propagation** | move_primary_coordinator.cpp:318-325 | Model-checkable | High |
| MP-4 | dbVersion timestamp set during commit, inside critical section (correct) | sharding_catalog_manager_database_operations.cpp:241-242 | Code-review-only | Info |
| MP-5 | Stale data on donor persists until kClean phase (after commit) | move_primary_coordinator.cpp:339 | Model-checkable | Medium |
| XC-1 | **All DDL operations are multi-phase and non-atomic by design** | All coordinator files | Model-checkable | High |
| XC-2 | Recovery re-execution relies on session idempotency for remote commands | sharding_coordinator.cpp:477-503 | Test-verifiable | Medium |
| XC-3 | Critical section / version bump ordering is correct | All coordinator files | Model-checkable (confirm) | Low |
| XC-4 | DDL lock prevents concurrent DDL on same namespace (confirmed) | sharding_coordinator.cpp:254-315 | Model-checkable (confirm) | Info |

---

### Additional DDL Coordinator Findings (from expanded analysis)

| ID | Finding | File:Line | Classification | Severity |
|----|---------|-----------|----------------|----------|
| CC-4 | **CreateCollection 10-phase state machine**: Between `kCreateCollectionOnParticipants` and `kCommitOnShardingCatalog`, collection exists on shards but not committed to config server. Cleanup (`_cleanupOnAbort`, line 2416-2488) can itself fail partway. | create_collection_coordinator.cpp:1503-1591 | Model-checkable | High |
| CC-5 | **TODO SERVER-87265**: Multiple causality barrier calls marked "Remove this call if possible", suggesting uncertainty about their necessity for recovery correctness. | create_collection_coordinator.cpp:1850,1908 | Code-review-only | Medium |
| DC-3 | **Non-atomic drop 6-step sequence**: remove query analyzer metadata → remove collection+chunks from config → remove zone tags → checkpoint configTime → drop on non-notifier shards → drop on notifier shard. Crash between steps leaves inconsistent state. | drop_collection_coordinator.cpp:295-428 | Model-checkable | Medium |
| RC-4 | **Rename target TOCTOU window**: At `kCheckPreconditions`, critical section acquired on target namespace then immediately released if target exists (line 676-683). Between release and `kBlockCrudAndRename`, target could be dropped and recreated with different UUID. | rename_collection_coordinator.cpp:662-685 | Model-checkable | Medium |
| RC-5 | **Cross-DB rename generates new UUID** (line 651). Spec's `RenameCommon` preserves UUIDs. Implementation deviation for cross-DB case. | rename_collection_coordinator.cpp:648-654 | Model-checkable | Medium |
| RC-6 | **Metadata transaction with 7 statements** — idempotent via statement IDs but sequential numbering means not safe to replay with different parameters. | rename_collection_coordinator.cpp:392-486 | Code-review-only | Low |
| MP-6 | **MovePrimary clone phase explicitly non-idempotent** (line 239-251) — aborts on recovery. The TLA+ spec models MovePrimary as atomic. | move_primary_coordinator.cpp:239-251 | Model-checkable | High |
| MP-7 | **Cleanup-on-abort catches ShardNotFound** and continues (line 410-414, 425-429). If recipient shard is removed during cleanup, orphaned data remains. | move_primary_coordinator.cpp:390-442 | Test-verifiable | Medium |
| XC-5 | **DDL lock in-memory only**: Not persisted across failover. Recovery gating via `waitForRecovery` has 5-minute timeout. Window between step-up and full DDL service recovery allows early lock acquisition (SERVER-88147). | ddl_lock_manager.h:73,100-125 | Model-checkable | High |
| XC-6 | **SERVER-107237 pattern**: renameCollection writes unstable epoch if commit is retried. Non-idempotent metadata writes under retry are a systematic risk across all coordinators. | rename_collection_coordinator.cpp | Model-checkable | High |

---

## Bug Family Formation

### Family 1: Multi-Phase DDL Non-Atomicity Under Failover

**Historical evidence**: SERVER-117340, SERVER-91247, SERVER-77748, SERVER-88147, SERVER-107237, SERVER-76985, SERVER-74192, SERVER-85913, SERVER-83320, SERVER-98161, SERVER-87805
**Code analysis findings**: MP-1, MP-2, MP-3, MP-5, MP-6, MP-7, CC-2, CC-4, CC-5, DC-1, DC-3, RC-1, RC-4, RC-5, RC-6, XC-1, XC-2, XC-5, XC-6
**Total bugs in family**: 11 confirmed + 19 potential findings
**Model-checkable**: Yes (all major findings)

### Family 2: Transaction Statement Interleaving with DDL

**Historical evidence**: SERVER-84723, SERVER-77506, SERVER-43848
**Code analysis findings**: TR-8, TR-10, TR-11
**Total bugs in family**: 3 confirmed + 3 potential
**Model-checkable**: Yes

### Family 3: createdDatabases Bypass Scope and Correctness

**Historical evidence**: None (spec analysis finding)
**Code analysis findings**: CSR-11, CSR-12, CSR-10, spec line 207
**Total bugs in family**: 0 confirmed + 3 potential
**Model-checkable**: Yes

### Family 4: Stale Error Retry and placementConflictTime Reset

**Historical evidence**: SERVER-87660
**Code analysis findings**: TR-2, TR-3, TR-5, TR-9
**Total bugs in family**: 1 confirmed + 4 potential
**Model-checkable**: Yes

### Family 5: Commit Protocol Without Placement Validation

**Historical evidence**: None
**Code analysis findings**: TR-10 (primary), TR-11
**Total bugs in family**: 0 confirmed + 2 potential
**Model-checkable**: Yes

---

## Existing Spec Analysis: createdDatabases Issue

The existing spec's `createdDatabases` behavior deserves special attention.

**Spec line 207**: `rCreatedDatabases' = [rCreatedDatabases EXCEPT ![t] = @ \union {"db"}]`

This unconditionally adds `"db"` to `createdDatabases` for every transaction on every statement. Since `DatabaseNames == {"db"}` (the only database), every transaction always has `createdDatabases == {"db"}`.

**Consequence in spec line 258**: `"db" \notin createdDatabases` is ALWAYS FALSE, making the `SNAPSHOT_INCOMPATIBLE` branch in `DatabaseMetadataCheck` dead code.

**Implementation comparison** (`cluster_ddl.cpp:125-142`): In the real code, `annotateCreatedDatabase(dbName)` is called ONLY when `catalogCache->getDatabase` returns `NamespaceNotFound` — i.e., only when the database doesn't exist and must be created. Most transactions do NOT create databases, so `createdDatabases` is usually empty.

**Impact**: The spec cannot find any bug related to:
1. movePrimary bumping dbVersion → placementConflictTime < new dbVersion → SNAPSHOT_INCOMPATIBLE
2. The bypass being incorrectly applied to non-created databases (legacy path)
3. The bypass persisting after a failed database creation

**Fix**: Model with 2 databases, conditional creation, and the bypass applied correctly.

---

## Excluded Findings (False Positives / Intentional Design)

| Finding | Reason for Exclusion |
|---------|---------------------|
| CSR-2 (redundant checks) | Two checks are complementary: one for chunk migrations, one for collection DDL |
| CSR-5 (critical section + version check atomicity) | Protected by DSS MODE_IS lock held by caller |
| CSR-9 (DDL between check and access) | Protected by storage engine snapshot isolation |
| CSR-14 (no upgrade guard in collection path) | Both legacy and new encodings are always set during FCV upgrade |
| TR-12 (yield enables DDL metadata) | Shard-side locks held during yield; only router-side session released |
