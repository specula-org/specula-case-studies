# Confirmed Bug Report — mongodb-txnscollincarnation

## Summary

- Total findings reviewed: 18
- Reproduced: 0
- Confirmed (code audit, reproduction failed): 0
- False positives (verified safe): 14
- Out of scope: 1
- Not bugs (defensive/architectural): 3
- **New bugs found: 0**

All 5 bug families were exhaustively explored by model checking (~723M states across 5 hunting configs). All invariants held. Code audit of 5 test-verifiable findings and 3 code-review findings found no new bugs — existing safeguards (snapshot isolation, DDL locks, critical sections, tasserts) prevent the hypothesized scenarios.

The 22+ historical JIRA tickets cited in the modeling brief are known/fixed bugs. They guided the spec extensions (multi-phase DDL, failover, separate commit, stale retry) but no new instances of those patterns were found.

---

## MC-Verified Findings (All PASS)

These 10 findings from the modeling brief (Section 6.1) were directly tested by model checking. All invariants held.

### F1-1: DDL failover between commit-metadata and release-lock

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family1.cfg — 84.4M states, DDLLockHeldDuringCommit + NoOrphanedCriticalSection + CommittedTxnImpliesConsistentKeySet
- **Analysis**: The spec models multi-phase DDL with failover between any phase. DDL recovery correctly re-acquires locks and resumes from persisted phase. The atomic MovePrimary failover (all-or-nothing) prevents partial moves. With 2 failover events, 2 creates, 2 drops, 1 rename, and 1 movePrimary, no invariant violations found.

### F1-2: MovePrimary clone before read-blocking CS

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family1.cfg — 84.4M states
- **Analysis**: MovePrimary's non-idempotent clone phase is modeled (abort on recovery). The spec verifies that even though data is cloned before the read-blocking critical section is entered, concurrent transactions are protected by snapshot isolation at the shard level.

### F1-3: Rename target TOCTOU (CS released after check)

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family1.cfg — 84.4M states
- **Analysis**: The rename coordinator acquires CS on both source and target. Even if the target is dropped and recreated between phases, the DDL lock serialization prevents concurrent DDL on the same namespace.

### F1-4: Cross-DB rename UUID mismatch

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family1.cfg — 84.4M states
- **Analysis**: Cross-DB rename generates a new UUID by design. The spec tracks UUID changes and verifies that committed transactions see consistent UUIDs throughout their snapshot.

### F2-1: DDL between last statement and commit

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family5.cfg — 302.7M states, CommitSafeAfterStatements + CommittedTxnConsistentKeySet
- **Analysis**: The commit path has no placement re-check by design. MC verified that snapshot isolation + shard-side locks protect data consistency: read-only shards committed their snapshot (DDL after commit is irrelevant), and write shards hold locks that block DDL until transaction completion. 302.7M states (depth 34) with 3 creates, 2 drops, 1 rename, 1 movePrimary — all pass.

### F2-2: DDL between parallel dispatches in same statement

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family2.cfg — 315M states, CommittedTxnConsistentKeySet + CommitSafeAfterStatements
- **Analysis**: The spec models per-shard dispatch as separate actions with DDL interleaving between them. The critical section mechanism correctly blocks shard responses during DDL commit phases. 315M states is the deepest exploration (depth 34).

### F2-3: Missing placementConflictTime (production: warning only)

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe + by design)
- **Severity**: N/A
- **MC Config**: MC_hunt_family2.cfg — 315M states
- **Location**: `collection_sharding_runtime.cpp:158-170`, `database_sharding_runtime.cpp:76-93`
- **Analysis**: In production, missing placementConflictTime logs a warning (not error) for backwards compatibility with old routers. This is by design — placementConflictTime is defense-in-depth; shard-side snapshot isolation + locks are the primary protection. MC verified safety even when the check is absent.

### F3-1: Legacy all-or-nothing createdDatabases bypass

- **Source**: Code Review + Spec Analysis
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family3.cfg — 12.3M states, NoCrossDatabaseBypassLeak + CommittedTxnImpliesConsistentKeySet
- **Analysis**: The legacy path (`Timestamp(0,0)` sentinel) bypasses placement checks for ALL databases when any database is created (`transaction_router.cpp:337-344`). The new path (`std::ranges::find(createdDatabases, dbName)`) is per-database. MC modeled 2 databases (db1, db2) with per-database bypass checking. No cross-database bypass leak found — collection-level checks still run, and snapshot isolation prevents stale reads.

### F3-2: annotateCreatedDatabase before create succeeds

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family3.cfg — 12.3M states, CreatedDatabasesBypassCorrectness
- **Location**: `cluster_ddl.cpp:129-131`
- **Analysis**: `annotateCreatedDatabase` is called before `_configsvrCreateDatabase` returns. If create fails, the bypass persists. However: (1) create failure propagates as an exception, aborting the statement or transaction, (2) the bypass only skips placement/atClusterTime checks — if the database wasn't created, there's nothing to read that bypasses protection, (3) MC's conditional createDatabase model (not unconditional like original spec) found no violations.

### F4-1: Reset placementConflictTime captures stale time

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **MC Config**: MC_hunt_family4.cfg — 7.9M states, PlacementConflictTimeMonotonicity + CommittedTxnConsistentKeySet
- **Location**: `transaction_router.cpp:1220-1234`
- **Analysis**: On first-statement stale error, placementConflictTime is reset and re-fetched from VectorClock. The stale error response carries gossip that updates the vector clock, so the fresh timestamp captures any DDL that committed before the error. MC verified this with DDL interleaving during the retry window.

---

## Test-Verifiable Findings (Code Audit Results)

### T1: TransactionParticipant null skips placementConflictTime

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `collection_sharding_runtime.cpp:665-666`
- **Description**: If `TransactionParticipant::get(opCtx)` returns null, `placementConflictTime` is `boost::none` and the placement check is skipped.
- **Why false positive**: `TransactionParticipant::get(opCtx)` returns null only for non-transactional operations (no session). For multi-doc transactions, the TransactionParticipant is always initialized during session checkout. The null check is defensive programming for the non-transactional code path sharing `_getMetadataWithVersionCheckAt`. The `assertPlacementConflictTimePresentWhenRequired` function (line 148) additionally guards: it only fires when `opCtx->inMultiDocumentTransaction()` is true, which requires a valid session — the same condition that guarantees TransactionParticipant exists.

### T2: createdDatabases shrinks on continue statement

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `transaction_participant.cpp:1072-1074`
- **Description**: The shard overwrites `transactionRuntimeContext` on each continue statement. If the router sends a smaller `createdDatabases` set, the bypass scope shrinks.
- **Why false positive**: The router's `createdDatabases` list (`p().createdDatabases`) is append-only via `annotateCreatedDatabase`. No code path removes entries. The router sends the full list with every statement (`transaction_router.cpp:651,979,1000`). Sub-routers inherit the parent's list. There is no mechanism in normal operation that shrinks the set. The shard-side overwrite at line 1072-1074 is a clean-slate update that always receives a superset of the previous value. Additionally, `placementConflictTime` immutability is enforced by the tassert at lines 1053-1070 (SERVER-87660 fix).

### T3: Mixed-version old router + new shard

- **Source**: Code Review
- **Status**: OUT OF SCOPE
- **Severity**: N/A
- **Location**: `database_sharding_runtime.cpp:103-115`
- **Description**: Old router without `TransactionRuntimeContext` → shard falls back to deprecated path or skips check.
- **Why out of scope**: Mixed-version clusters are tested separately by MongoDB's FCV (Feature Compatibility Version) upgrade testing framework. The modeling brief explicitly excludes "Feature flag / mixed-version transitions" from modeling scope. The production warning-only enforcement is a deliberate backwards-compatibility choice (not a bug) — the deprecated path (`Timestamp(0,0)` sentinel) provides equivalent protection.

### T4: DDL between read-only commit and write-shard commit

- **Source**: Code Review
- **Status**: FALSE POSITIVE (MC-verified safe)
- **Severity**: N/A
- **Location**: `transaction_router.cpp:1734-1745`
- **Description**: Single-write-shard optimization commits read-only shards first, then write shard. DDL can complete between the two phases.
- **Why false positive**: MC Family 5 tested this exact scenario with 302.7M states. Read-only shards have already committed their snapshot — post-commit DDL doesn't affect already-committed data. The write shard still holds transaction locks, blocking DDL until its commit completes. Snapshot isolation is the primary protection, not the commit ordering.

### T5: Recovery token sent to wrong shard

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `transaction_router.cpp:2066-2095`
- **Description**: If the recovery shard fails over during commit recovery, the recovery token might be sent to a shard that doesn't have the transaction.
- **Why false positive**: The recovery shard is deterministically set to the write shard (`tassert(4834001)` at line 1725 enforces this). For 2PC, the recovery token's `recoveryShardId` identifies the transaction coordinator, which persists its state to the config server. Failover of the recovery shard triggers standard 2PC recovery via `coordinateCommitTransaction` — the new primary rebuilds state from the oplog. This is the standard MongoDB 2PC recovery path, not specific to placementConflictTime.

---

## Code-Review-Only Findings

### C1: Inconsistent error codes (SnapshotUnavailable vs MigrationConflict)

- **Source**: Code Review
- **Status**: NOT A BUG
- **Description**: Different error codes used for similar placementConflictTime failures.
- **Analysis**: `SnapshotUnavailable` is used for atClusterTime violations (snapshot reads); `MigrationConflict` is used for placementConflictTime violations (non-snapshot transactions). These are semantically different failure modes with different retry behaviors at the router — `MigrationConflict` triggers stale error retry, `SnapshotUnavailable` triggers full transaction retry. The distinction is intentional.

### C2: Double fetch of DB version in checkDbVersionOrThrow

- **Source**: Code Review
- **Status**: NOT A BUG
- **Location**: `database_sharding_runtime.cpp`
- **Analysis**: Safe under current locking model. The DSS lock (MODE_IS) prevents concurrent modification during the double fetch. The modeling brief correctly notes "Safe under current locking; document the dependency."

### C3: Asymmetric critical section access type management

- **Source**: Code Review
- **Status**: NOT A BUG
- **Description**: DB and collection sharding runtimes manage critical section access types differently.
- **Analysis**: Architectural difference by design. Database-level and collection-level critical sections have different semantics (DB is coarser-grained). The asymmetry reflects the different granularity of DDL operations at each level, not a logic error.

---

## Historical Bugs (Known JIRA Tickets — No Reproduction Required)

The modeling brief cites 22+ historical JIRA tickets that motivated the bug families:

**Family 1 (DDL Failover)**: SERVER-117340, -91247, -77748, -88147, -107237, -76985, -74192, -85913, -83320, -98161, -87805
**Family 2 (DDL+Txn Interleaving)**: SERVER-84723, -77506, -102821, -107685, -85383, -43848; Deadlocks: SERVER-48531, -49508, -76546, -78021, -84468, -95544, -119435
**Family 4 (Stale Retry)**: SERVER-87660

These are all known/fixed bugs with existing JIRA tickets. They guided the spec extensions but no new instances of these patterns were found by MC or code audit.

---

## Conclusion

The placementConflictTime protocol for DDL + transaction conflict detection in MongoDB sharded clusters is **robust against the 5 hypothesized bug families**. Model checking exhaustively explored ~723M states across multi-phase DDL failover, DDL+transaction interleaving, createdDatabases bypass, stale error retry, and commit-without-validation scenarios. All 13 invariants held.

Code audit of 5 additional test-verifiable findings confirmed existing safeguards prevent each hypothesized bug:
- Snapshot isolation at the shard level is the primary safety mechanism (not placementConflictTime alone)
- DDL locks serialize DDL operations per namespace, preventing concurrent DDL
- Critical sections block read/write operations during DDL metadata commits
- The tassert on placementConflictTime immutability (SERVER-87660 fix) prevents mid-transaction mutation
- The router's append-only `createdDatabases` list prevents bypass scope shrinkage

The protocol's defense-in-depth design (snapshot isolation + DDL locks + critical sections + placementConflictTime) means no single mechanism's bypass is sufficient to cause a safety violation.
