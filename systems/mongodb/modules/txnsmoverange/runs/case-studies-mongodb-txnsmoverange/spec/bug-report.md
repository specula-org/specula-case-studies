# MongoDB TxnsMoveRange Bug Report

Bugs found via TLA+ model checking of MongoDB's multi-statement transaction
interaction with chunk range migration protocol.

Spec: `case-studies/mongodb-txnsmoverange/spec/base.tla`
Artifact: `case-studies/mongodb-txnsmoverange/artifact/mongo/`

---

## Summary

| ID | Description | Severity | Family | Status |
|----|-------------|----------|--------|--------|
| TMR-1 | Double write execution via ShardRespondAfterExec + retry | HIGH | 4 | Known-fixed (SERVER-81508) |

No **new** bugs found. 1 known-fixed bug confirmed by model checking.

---

## Bug TMR-1: Double Write Execution via Write-Then-Error (Known-Fixed)

**Severity**: HIGH — At-most-once execution violation
**Family**: 4 (Stale-routing error propagation)
**Found by**: MC_hunt_family4.cfg, BFS, <1s, 6-state counterexample
**Status**: Known-fixed in MongoDB (SERVER-81508, commit `bec596c52e`)

### Summary

When a shard executes a write but then throws `ShardCannotRefreshDueToLocksHeld`
(error after execution), the router retries the entire statement. Since the write
was already persisted, the retry causes **double execution** of a non-idempotent
write.

### Counterexample (6 states)

```
1. Init:  ranges = {k1→s2, k2→s2}
2. RouterSendTxnStmt(t1, ns1, k1):  router sends stmt 1 to s2
3. ShardRespondAfterExec(t1, s2):   shard EXECUTES write, returns staleRouter
                                     execCount[t1][1] = 1
4. RouterRetryOnStale(t1):          router clears state, refreshes cache
                                     execCount NOT cleared (stays 1)
5. RouterSendTxnStmt(t1, ns1, k1):  router resends stmt 1 to s2
6. ShardRespond(t1, s2):            shard processes request again
                                     execCount[t1][1] = 2  →  VIOLATION
```

**Invariant violated**: `AtMostOnceExecution == \A t, stm : execCount[t][stm] <= 1`

### Root Cause

In `write_ops_exec.cpp`, the write was executed before the shard discovered it
needed to refresh placement metadata. The `ShardCannotRefreshDueToLocksHeld`
error was thrown *after* the write completed. The router, seeing a retryable
stale error on the first statement, retried the entire transaction, causing the
write to execute a second time.

### Fix (Applied in MongoDB)

The fix (SERVER-81508, commit `bec596c52e`) has 3 layers:

1. **Error timing**: `ShardCannotRefreshDueToLocksHeld` is now thrown BEFORE the
   write executes (during collection acquisition in `catalog_cache.cpp`)
2. **Statement tracking**: On retry, `checkStatementExecutedAndFetchOplogEntry()`
   returns cached result if statement was already executed
3. **Retry eligibility**: `_errorAllowsRetryOnStaleShardOrDb()` only allows retry
   on first statement with ≤1 participant (`latestStmtId == firstStmtId`)

### Confirmation

The `ShardRespondAfterExec` action in the spec models the pre-fix behavior. With
the fix applied, this code path can no longer produce write-then-error in the
current MongoDB codebase. All three protection layers are verified in
`transaction_router.cpp:2297-2299` and `write_ops_exec.cpp:1926-1945`.

---

## State Space Coverage

| Config | Mode | States | Distinct | Depth | Invariants | Result |
|--------|------|--------|----------|-------|------------|--------|
| MC.cfg (convergence) | BFS | 239K | 80K | 21 | 5 | PASS |
| MC_hunt_family1.cfg | BFS | 18K | 7K | 16 | 5 | PASS |
| MC_hunt_family2.cfg | BFS | 38K | 15K | 23 | 4 | PASS |
| MC_hunt_family3.cfg | BFS | 164K | 55K | 19 | 4 | PASS |
| MC_hunt_family4.cfg | BFS | 2K | 1K | 10 | 3 | **AtMostOnceExecution VIOLATED** |
| MC_hunt_deep.cfg | BFS | 13M | 3.9M | 31 | 8 | PASS |
| MC_hunt_2txn.cfg | BFS | 305M | 85.5M | 30 | 8 | PASS |
| MC_hunt_2txn.cfg | Sim | 2.1B | 34M traces | 60 | 8 | PASS |

Total states explored: **2.4B+** across all configurations.

---

## Invariants Checked

| Invariant | Description | Status |
|-----------|-------------|--------|
| TypeOK | Structural type safety | PASS |
| CommittedTxnImpliesAllStmtsSuccessful | Committed txn → all stmts ok | PASS |
| CommittedTxnImpliesKeysAreVisible | Committed txn → all keys found | PASS |
| MigrationPhaseConsistency | Phase + coordinator doc consistency | PASS |
| CriticalSectionCoversCommit | Config commit only under active CS | PASS |
| NoPrematureCSRelease | Committed doc → ranges updated | PASS |
| AllParticipantsSameTimestamp | All participants same PCT | PASS |
| RecoveryPreservesDecision | Post-recovery version consistency | PASS |
| AtMostOnceExecution | No double write execution | **VIOLATED** (known fix) |

---

## Spec Corrections During Validation

1. **Chunk ownership check added** (RespondStatus): The spec's `RespondStatus`
   only checked versions and critical sections. Added `ranges[ns][k] # self`
   check to faithfully model that shards verify chunk ownership, matching
   `collection_sharding_runtime.cpp:649-671`.

2. **createdDatabases exemption scoping**: The spec incorrectly applied the
   database-level `createdDatabases` exemption (`database_sharding_runtime.cpp:112-114`)
   to collection-level chunk migration checks. In MongoDB, this exemption only
   applies to `movePrimary` checks, not `moveChunk` placement conflict checks.
   Removed from collection-level `RespondStatus`. This was caught during 2-txn
   hunting (19-state counterexample for `CommittedTxnImpliesKeysAreVisible`).

3. **Tautological invariants fixed**: `NoPrematureCSRelease` and
   `RecoveryPreservesDecision` were placeholder invariants (`=> TRUE`).
   Replaced with meaningful property checks.

---

## Modeling Scope

### Covered (5 bug families)
- **Family 1**: Non-atomic migration (6-step protocol with CS phases)
- **Family 2**: placementConflictTime propagation (router retry, timestamp reset)
- **Family 3**: Donor failover during migration (step-down/step-up, recovery)
- **Family 4**: Error propagation (write-then-error, double execution)
- **Family 5**: Partial (kSingleWriteShard not explicitly modeled; covered by
  multi-shard transaction interactions)

### Not Covered
- movePrimary (database-level migration)
- Sub-router / additional participants (Family 6)
- Lock hierarchy deadlocks (requires lock-ordering analysis, not TLA+)
- Full 2PC commit protocol (simplified to single-statement commit)
- Snapshot readConcern / atClusterTime path

---

## Trace Validation

| Trace | Events | States | Result |
|-------|--------|--------|--------|
| basic_txn.ndjson | 6 | 51 | PASS |
| migration_lifecycle.ndjson | 3 | 40 | PASS |
| txn_during_migration.ndjson | 6 | 47 | PASS |
