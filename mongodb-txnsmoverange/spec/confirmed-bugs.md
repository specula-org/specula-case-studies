# Confirmed Bug Report — mongodb-txnsmoverange

## Summary

- Total findings reviewed: 22
- Reproduced: 0
- Confirmed (known-fixed, reproduction not required): 1
- False positives: 3
- Not bugs (hypotheses passed MC, test suggestions, tech debt): 18

**No new bugs found.** The one confirmed bug (TMR-1 / SERVER-81508) is a known-fixed
historical issue. All code review findings (CR-3, CR-4, CR-5) are false positives
with clear safeguards preventing the hypothesized bugs.

Model checking explored **2.4 billion+ states** across 8 configurations, covering
5 bug families (non-atomic migration, placementConflictTime propagation, donor
failover, error propagation, commit atomicity). All invariants pass except
AtMostOnceExecution, which reproduces the known-fixed SERVER-81508.

---

## Bug TMR-1: Double Write Execution via Write-Then-Error

- **Source**: MC (MC_hunt_family4.cfg, BFS, 6-state counterexample)
- **Status**: KNOWN-FIXED (SERVER-81508, commit `bec596c52e`)
- **Severity**: High
- **Location**: `write_ops_exec.cpp:1926-1945`, `transaction_router.cpp:2280-2300`
- **Description**: When a shard executes a write but then throws
  `ShardCannotRefreshDueToLocksHeld` (error after execution), the router retries
  the entire statement. Since the write was already persisted, the retry causes
  double execution of a non-idempotent write.
- **Counterexample**: Router sends stmt to shard → shard EXECUTES write but returns
  staleRouter error → router retries first statement → shard processes request
  again → `execCount[t1][1] = 2` violates AtMostOnceExecution.
- **Invariant violated**: `AtMostOnceExecution == \A t, stm : execCount[t][stm] <= 1`
- **Fix (already applied)**: Three-layer protection:
  1. Error timing: `ShardCannotRefreshDueToLocksHeld` now thrown BEFORE write
     executes (during collection acquisition)
  2. Statement tracking: On retry, `checkStatementExecutedAndFetchOplogEntry()`
     returns cached result
  3. Retry eligibility: `_errorAllowsRetryOnStaleShardOrDb()` only allows retry
     on first statement with ≤1 participant
- **Reproduction**: Not required — matches existing JIRA ticket SERVER-81508.
  The existing ticket and commit serve as confirmation.

---

## False Positive: CR-3 — Equal-Timestamp Edge Case in Placement Conflict Check

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `collection_sharding_runtime.cpp:676-677`
- **Description**: The placement conflict check uses strict less-than (`<`) rather
  than less-than-or-equal (`<=`). The concern was that if `placementConflictTime`
  equals `validAfter` (the migration timestamp), a transaction could bypass the
  check and read stale pre-migration data.
- **Why it's a false positive**:
  1. **Critical section is the primary guard.** The donor's critical section blocks
     all operations until migration is fully committed and metadata is refreshed.
     A concurrent transaction will be blocked by the CS, not the timestamp check.
  2. **VectorClock causality prevents equality in practice.** The config server's
     `commitChunkMigration` write operation advances the cluster time. By the time
     the donor's `getShardMaxValidAfter()` returns the new value, the clock has
     advanced past the migration commit time.
  3. **validAfter is strictly increasing.** `sharding_catalog_manager_chunk_operations.cpp:1672`
     explicitly rejects `newHistory.front().getValidAfter() >= validAfter`,
     ensuring consecutive migrations can never produce the same `validAfter`.
  4. **The TLA+ spec models this correctly.** `base.tla:482` uses
     `LatestMigrationTs + 1` to abstract the real implementation's guarantee that
     config server writes advance the cluster time.

---

## False Positive: CR-4 — `forceFail()` Called Outside `_mutex`

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `migration_destination_manager.cpp:395-406`
- **Description**: In `_setStateFailNoLog()`, `_sessionMigration->forceFail()` is
  called after `_mutex` is released. The concern was that another thread could
  modify the `_sessionMigration` pointer concurrently.
- **Why it's a false positive**:
  1. **Pointer stability is guaranteed.** `_sessionMigration` is only reassigned in
     `start()` and `restoreRecoveredMigrationState()`, which both join the
     migration thread via `_migrateThreadHandle->join()` before reassigning.
     Since `_setStateFail*` runs only on the migration thread, the pointer cannot
     be invalidated while `forceFail()` is executing.
  2. **`forceFail()` is internally thread-safe.** It acquires
     `SessionCatalogMigrationDestination::_mutex` (a separate mutex) before
     modifying state.
  3. **Releasing `_mutex` before `forceFail()` is intentional.** Holding both
     mutexes simultaneously would create a lock ordering risk. The
     `ScopedReceiveChunk` lifetime guarantee prevents pointer invalidation.

---

## False Positive: CR-5 — Multiple `getState()` Calls Without Single Lock Hold

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `migration_destination_manager.cpp:1741-1804`
- **Description**: The steady-state transfer loop makes 7 `getState()` calls
  (each independently acquiring `_mutex`), with state transitions possible
  between calls. The concern was a TOCTOU race.
- **Why it's a false positive**:
  1. **Terminal states (`kFail`, `kAbort`) are sinks.** Nothing transitions out of
     them, so the post-loop check at line 1804 cannot miss a failure.
  2. **The `transferAfterCommit` pattern is intentionally conservative.** Missing
     the `kCommitStart` transition on one loop iteration just adds one extra
     `_transferMods` round-trip — by design, not by accident.
  3. **The `kCommitStart` → `kEnteredCritSec` transition is same-thread.** Only
     the migration thread itself (at line 1900) transitions out of
     `kCommitStart`, so it cannot race with the loop condition on line 1741.
  4. **Short-circuit evaluation on line 1741** handles the `kSteady` case
     correctly — if the first condition is true, the second is never evaluated.

---

## Findings Not Classified as Bugs

### MC Hypotheses (MC-1 through MC-10)

These were hypothetical bugs proposed in the modeling brief that model checking
was designed to find. Model checking explored 2.4B+ states and found **none** of
them (except MC-8, which IS TMR-1). The relevant invariants all passed:

| ID | Hypothesis | Invariant Checked | MC Result |
|----|-----------|-------------------|-----------|
| MC-1 | Transaction reads during write-block CS | CommittedTxnImpliesKeysAreVisible | PASS |
| MC-2 | Config commit lost, wrong recovery inference | RecoveryPreservesDecision | PASS |
| MC-3 | Router retry resets timestamp | AllParticipantsSameTimestamp | PASS |
| MC-4 | createdDatabases exemption bypass | Not modeled (exemption correctly scoped to movePrimary only) | N/A |
| MC-5 | Donor stepdown during config commit | NoPrematureCSRelease | PASS |
| MC-6 | Two concurrent migrations + transaction | CommittedTxnImpliesAllStmtsSuccessful | PASS (305M states) |
| MC-7 | Shard silently retries in continuing txn | Known-fixed (SERVER-57051) | N/A |
| MC-8 | Write-then-error double execution | AtMostOnceExecution | VIOLATED = TMR-1 |
| MC-9 | kSingleWriteShard commit gap | Not modeled (commit protocol out of scope) | N/A |
| MC-10 | WouldChangeOwningShard + migration | Not modeled (commit protocol out of scope) | N/A |

### Test Suggestions (TV-1 through TV-4)

Integration test proposals, not bug findings:
- TV-1: BulkWrite with multiple namespaces during migration
- TV-2: Sub-router StaleConfig for additional participant
- TV-3: Metadata refresh failure on recipient after CS release
- TV-4: Dangling transactions blocking migration

### Tech Debt (CR-1, CR-2)

- CR-1: 8 occurrences of TODO SERVER-115178 (deprecated placementConflictTime paths) — cleanup tracking, not a bug
- CR-2: TODO SERVER-39704 (router retry safety acknowledged as unsafe) — known concern, not a new finding

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

## Reproduction Tests

No reproduction tests are required. The only confirmed bug (TMR-1) is a
known-fixed historical issue matching JIRA ticket SERVER-81508. Per the
bug-confirmation methodology, known/historical bugs with existing JIRA tickets
do not require reproduction — the existing ticket serves as confirmation.

All three code review findings (CR-3, CR-4, CR-5) are false positives and
do not warrant reproduction.
