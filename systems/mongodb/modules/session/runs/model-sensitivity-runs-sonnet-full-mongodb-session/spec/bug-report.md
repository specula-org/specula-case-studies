# MongoDB Session Lifecycle — TLA+ Model Checking Bug Report

**Target**: mongodb-session  
**Spec**: MongoDBSession.tla / MC.tla  
**Date**: 2026-06-08  
**TLC Version**: 2.20  
**Sessions modeled**: {s1, s2}, MaxTime=5  

---

## Spec Fixes Applied (Case B — Spec Modeling Issues)

These were resolved during convergence before bug hunting.

### SB-1: MCWaitersConstraint Listed as INVARIANT Instead of CONSTRAINT

**File**: `spec/MC.cfg`  
**Classification**: Case B (config bug)  
**Action taken**: Moved `MCWaitersConstraint` from `INVARIANTS` block to `CONSTRAINT` block.  
**Why**: The spec comment says "Bound the number of simultaneous waiters to prevent unbounded state space" — this is a state-space pruning constraint, not a safety property. Listed as `INVARIANT`, TLC immediately reported a violation after three `WaitForCheckout` calls (waiters = 3 > bound of 2), halting all further exploration.

---

### SB-2: MemoryReap Missing `_shouldBeReaped()` Guards

**File**: `spec/MongoDBSession.tla`, `MemoryReap` action  
**Classification**: Case B (spec over-approximates)  
**Action taken**: Added preconditions matching `_shouldBeReaped()` in `session_catalog.cpp:475`:
```tla
/\ checkoutOpCtx[s] = "none"
/\ waiters[s] = 0
/\ killsRequested[s] = 0
```
**Why**: The real `_shouldBeReaped()` returns `_markedForReap && !isCheckedOut && !_numWaitingToCheckOut && !_killed()`. Without these guards, the spec allowed `MemoryReap` to fire on checked-out sessions, violating `CheckoutImpliesInCatalog` (a false positive).  
**Implementation reference**: `session_catalog.cpp:468–476`

---

### SB-3: CheckoutForKill Allowed Double Kill-Checkout During Kill Release

**File**: `spec/MongoDBSession.tla`, `CheckoutForKill` action  
**Classification**: Case B (spec over-approximates)  
**Action taken**: Added `killReleasePhase[s] = "none"` guard to `CheckoutForKill`.  
**Why**: The `KillToken` is a C++ move-only object passed `std::move` into `checkOutSessionForKill` (`session_catalog.cpp:177`). Once consumed, it cannot be reused. Without the `killReleasePhase` guard, the spec allowed a second kill-checkout to fire during the kill-release window (after `KillReleaseClearCheckout` set `checkoutOpCtx = "none"` but before `KillReleaseDecrement`), violating `KillCheckoutRequiresToken`.

---

### SB-4: NoOrphanKillRequest Fired Prematurely (Invariant Too Strong → Fixed with State Variable)

**File**: `spec/MongoDBSession.tla`  
**Classification**: Case A (invariant too strong) — fixed by adding `killRegistrationPending` variable  
**Action taken**: Added `killRegistrationPending[s]` boolean that is:
- Set `TRUE` by `RequestKill` (kill() called, registerChange not yet attempted)
- Set `FALSE` by `RegisterKillChangeSucceed` or `RegisterKillChangeFail`

Updated `NoOrphanKillRequest` to:
```tla
NoOrphanKillRequest ==
    \A s \in Session :
        (killsRequested[s] > 0 /\ ~killRegistrationPending[s]) => killTokenRegistered[s] = TRUE
```
**Why**: Without the guard, the invariant fired immediately after `RequestKill` (before registration attempt) because `killsRequested > 0` but `killTokenRegistered = FALSE` — a normal intermediate state. The real orphan condition only occurs after `RegisterKillChangeFail` clears the pending flag without storing a token.

---

## Bug Findings

### MC-1: Refresh-Reap Protocol Race — TxnRecord Deleted for Live Session

| Field | Value |
|-------|-------|
| **Bug ID** | MC-1 |
| **Severity** | HIGH |
| **Category** | Family 1 — Refresh-Reap Protocol Race |
| **Status** | CONFIRMED (Case C: Real Bug) |
| **Invariant violated** | `TxnRecordSafeWhileLive` |
| **Hunt config** | `MC_hunt_family1.cfg` |
| **TLC output** | `spec/output/MC_hunt_family1.out` |

#### Root Cause

The refresh worker and reap worker run independently. The reap worker sets a cutoff time, identifies stale sessions by their `lastUse` in `config.system.sessions`, memory-reaps them, then disk-reaps their `config.transactions` records. Crucially, the disk reap does not re-check `config.system.sessions` after memory reap. If the refresh worker refreshes a session (re-upserts its `lastUse`) in the window between the memory reap's `findRemovedSessions()` call and the disk reap's delete, the disk reap still deletes the `config.transactions` record even though the session is now "live" again.

#### Counterexample Summary (24 states)

```
State 1:  Initial  (sessionLastRefreshed[s1]=1, currentTime=2)
State 2:  MCTickClock          → currentTime=3
State 3:  MCStartReap          → reapCutoff=3
State 4:  MCMemoryReap(s1)     → sessionInCatalog[s1]=FALSE  (1 < 3 ✓)
State 5:  MCTickClock          → currentTime=4
State 6:  MCEndReap
State 7:  MCWaitForCheckout(s2)
State 8:  MCStartRefresh       → sessionSource[s1]="runningOp" (not in catalog)
State 9:  MCRequestKill(s2)
State 10: MCRefreshSucceed(s2) → sessionLastRefreshed[s2]=4
State 11: MCRegisterKillChangeSucceed(s2)
State 12: MCRefreshSucceed(s1) → sessionLastRefreshed[s1]=4  ← KEY: refresh after memory reap
State 13: MCEndRefresh
State 14: MCCheckoutForKill(s2)
State 15: MCKillReleaseClearCheckout(s2)
State 16: MCWaitForCheckout(s2)
State 17: MCStartRefresh
State 18: MCRefreshFail(s1)
State 19: MCKillReleaseNotify(s2)
State 20: MCStartReap          → reapCutoff=4
State 21: MCWaitForCheckout(s2)
State 22: MCRefreshFail(s2)
State 23: MCDiskReapImage(s1)  → imageRecordOnDisk[s1]=FALSE
State 24: MCDiskReapTxn(s1)   → txnRecordOnDisk[s1]=FALSE  ← VIOLATION
```

**Violated invariant check at state 24**:
- `reapWorkerPhase = "running"` ✓
- `sessionLastRefreshed[s1] = 4 >= reapCutoff = 4` ✓
- `txnRecordOnDisk[s1] = FALSE` → VIOLATION

#### Affected Code Locations

- `logical_session_cache_impl.cpp:250–253` — `reapCutoff` computed once at start of `_reap`
- `logical_session_cache_impl.cpp:371` — refresh upserts `lastUse = NOW` (concurrent with reap)
- `session_catalog_mongod.cpp:186–232` — `removeExpiredTransactionSessionsNotInUseFromMemory` calls `findRemovedSessions` but session may be re-added to `config.system.sessions` before disk reap
- `session_catalog_mongod.cpp:238–340` — `removeSessionsTransactionRecordsFromDisk` does not re-verify session liveness before deleting

#### Impact

An active session's `config.transactions` record can be deleted while the session is in use, corrupting transaction state for any operation that relies on the session's transaction record.

---

### MC-2: Kill Release Ordering — notify_all Before --killsRequested

| Field | Value |
|-------|-------|
| **Bug ID** | MC-2 |
| **Severity** | NOT A REAL BUG (see analysis) |
| **Category** | Family 2a — Kill Protocol Ordering |
| **Status** | FALSE POSITIVE — Spec Over-Approximates |
| **Invariant violated** | `NoWaitersStuckAfterKillComplete` (safety) |
| **Hunt config** | `MC_hunt_family2a.cfg` |

#### Analysis

The invariant `NoWaitersStuckAfterKillComplete` fired on state 2 (`MCInit → MCWaitForCheckout(s1)`), which is a normal non-kill scenario. This is a **Case A** (invariant too strong) issue — the invariant cannot distinguish between "waiter waiting for a normal checkout" and "waiter stuck after kill complete."

More importantly, reviewing the implementation:

```cpp
// session_catalog.cpp:359–377 (_releaseSession)
stdx::unique_lock<stdx::mutex> ul(_mutex);   // mutex held throughout
...
sri->checkoutOpCtx = nullptr;                 // line 371
sri->availableCondVar.notify_all();           // line 372 — under mutex
if (killToken) {
    --sri->killsRequested;                    // line 376 — under mutex
}
```

The `notify_all()` and `--killsRequested` both execute while holding `_mutex`. Waiters sleeping on `availableCondVar` can only re-acquire the mutex AFTER `_releaseSession` fully returns. By that point, `killsRequested` has already been decremented. A waiter can never observe the intermediate state where `notify_all` fired but `killsRequested` is still > 0.

**Conclusion**: The Family 2a concern (livelock due to notify_all ordering) does **not** manifest in the current implementation because `_releaseSession` holds the mutex atomically across all three operations. The spec's three-step model is an over-approximation. The liveness property `NoLivelockAfterKill` remains the appropriate check, but it is not violated under the real mutex-protected semantics.

---

### MC-3: Orphan Kill Counter if registerChange Throws

| Field | Value |
|-------|-------|
| **Bug ID** | MC-3 |
| **Severity** | MEDIUM |
| **Category** | Family 2b — Kill Protocol Ordering |
| **Status** | CONFIRMED (Case C: Real Bug — theoretical) |
| **Invariant violated** | `NoOrphanKillRequest` |
| **Hunt config** | `MC_hunt_family2b.cfg` |
| **TLC output** | `spec/output/MC_hunt_family2b_r2.out` |

#### Root Cause

In `observeDirectWriteToConfigTransactions` (`session_catalog_mongod.cpp:683–686`):

```cpp
shard_role_details::getRecoveryUnit(opCtx)->registerChange(
    std::make_unique<KillSessionTokenOnCommit>(ti,
                                               session.kill(ErrorCodes::Interrupted)));
```

`session.kill()` is evaluated as a C++ argument before `registerChange` is called. It increments `killsRequested` synchronously. If `registerChange` then throws (e.g., allocation failure):
1. `KillSessionTokenOnCommit` is destroyed (no custom destructor)
2. `KillToken` is destroyed (no RAII to drain `killsRequested`)
3. `killsRequested` remains > 0 permanently — no token exists to drain it via `checkOutSessionForKill`

The session is permanently "killed" (no normal checkout possible) with no path to release.

#### Counterexample Summary (3 states)

```
State 1: MCInit        (killsRequested[s1]=0, killRegistrationPending[s1]=FALSE)
State 2: MCRequestKill(s1)       → killsRequested[s1]=1, killRegistrationPending[s1]=TRUE
State 3: MCRegisterKillChangeFail(s1) → killRegistrationPending[s1]=FALSE  ← VIOLATION
         (killsRequested=1, no token, not pending → orphan)
```

#### Affected Code Locations

- `session_catalog_mongod.cpp:681–686` — `session.kill()` incremented before `registerChange` guard
- `session_catalog.cpp:447–456` — `ObservableSession::kill()` increments `killsRequested` with no rollback mechanism
- `KillSessionTokenOnCommit` class (`session_catalog_mongod.cpp:645–664`) — no destructor to drain `killsRequested` on destruction

#### Impact

If `registerChange` ever throws (e.g., under memory pressure or RecoveryUnit state corruption), the session's `killsRequested` counter is permanently non-zero. The session becomes uncheckable by normal operations (they see `_killed()` = true), and `checkOutSessionForKill` can never be called (no token). The session is effectively leaked in the killed-but-undrainable state.

#### Mitigation

Move `session.kill()` before the `registerChange` call, storing the token, and drain `killsRequested` in an RAII guard if `registerChange` fails:

```cpp
auto killToken = session.kill(ErrorCodes::Interrupted);
// Guard: if registerChange throws, drain killsRequested.
auto guard = ScopeGuard([&] { /* re-checkout and release with killToken */ });
shard_role_details::getRecoveryUnit(opCtx)->registerChange(
    std::make_unique<KillSessionTokenOnCommit>(ti, std::move(killToken)));
guard.dismiss();
```

---

### MC-4: RunningOp Sessions Silently Dropped on Refresh Failure

| Field | Value |
|-------|-------|
| **Bug ID** | MC-4 |
| **Severity** | MEDIUM |
| **Category** | Family 3 — Refresh Partial-Failure |
| **Status** | CONFIRMED (Case C: Real Bug) |
| **Invariant violated** | `NoRunningOpDropped` |
| **Hunt config** | `MC_hunt_family3.cfg` |
| **TLC output** | `spec/output/MC_hunt_family3.out` |

#### Root Cause

In `logical_session_cache_impl.cpp:373–398`, when a refresh batch fails, only sessions sourced from `_activeSessions` (the "active" path) are placed back into the retry queue via the `backSwap` loop (`line 394–397`). Sessions sourced from `getActiveOpSessions()` (the "runningOp" path, `line 356`) are **not** in the backswap and are silently dropped from the batch without being queued for retry.

If a runningOp session fails to refresh:
1. Its `lastUse` is not updated in `config.system.sessions`
2. It is not placed in `failedLsids` (the retry queue)
3. On the next refresh cycle, it is not retried (not in `_activeSessions`)
4. The session's TTL continues to tick down toward expiration

#### Counterexample Summary (9 states)

```
State 1: MCInit
State 2: MCStartReap
State 3: MCMemoryReap(s1)         → sessionInCatalog[s1]=FALSE
State 4: MCRequestKill(s2)
State 5: MCDiskReapImage(s1)
State 6: MCStartRefresh           → sessionSource[s1]="runningOp"
                                    (s1 not in catalog → tagged as runningOp)
State 7: MCRegisterKillChangeSucceed(s2)
State 8: MCTickClock
State 9: MCRefreshFail(s1)        → refreshFailedWhileRunningOp[s1]=TRUE
                                    refreshRetryQueued[s1]=FALSE  ← VIOLATION
```

#### Affected Code Locations

- `logical_session_cache_impl.cpp:356–367` — `getActiveOpSessions()` path that produces runningOp sessions
- `logical_session_cache_impl.cpp:373–398` — refresh failure handling: `failedLsids` backswap only covers `activeSessions`, not `runningOpSessions`
- `logical_session_cache_impl.cpp:388–397` — the backswap loop (line 394) iterates only `activeSessions`

#### Impact

A session that is actively running an operation (`getActiveOpSessions()`) but fails to refresh is silently ignored. Over repeated refresh failures, the session's `lastUse` in `config.system.sessions` grows stale. When the TTL expires, the session is marked for reap even though an operation is actively using it. This can result in incorrect session expiry for running operations.

---

### MC-5: Non-Atomic Two-Phase Disk Reap Creates Dangling Image Records

| Field | Value |
|-------|-------|
| **Bug ID** | MC-5 |
| **Severity** | MEDIUM |
| **Category** | Family 4 — Non-Atomic Two-Phase Reap |
| **Status** | CONFIRMED (Case C: Real Bug — by design) |
| **Invariant violated** | `NoDanglingImageWithoutTxnRecord` |
| **Hunt config** | `MC_hunt_family4.cfg` |
| **TLC output** | `spec/output/MC_hunt_family4.out` |

#### Root Cause

`removeSessionsTransactionRecordsFromDisk` (`session_catalog_mongod.cpp:238–340`) performs two sequential non-transactional deletes:
1. Delete from `config.image_collection` (lines 253–270)
2. Delete from `config.transactions` (lines 272–291)

The code explicitly acknowledges this (lines 244–251):
> "We opt for this rather than performing the two sets of deletes in a single transaction simply to reduce code complexity."

Between phases 1 and 2, `imageRecordOnDisk = FALSE` but `txnRecordOnDisk = TRUE`. If a new session checkout (`RevivifySession`) occurs in this window, the session has an inconsistent disk state: the image record is gone but the transaction record still exists. This can cause incorrect behavior during session recovery (e.g., if the transaction record references an image that no longer exists).

#### Counterexample Summary (20 states)

```
State 1:  MCInit
States 2–7:  Checkout/kill/tick setup for s2
State 8:  MCTickClock (×2)
State 9:  MCStartReap
State 10: MCMemoryReap(s1)         → s1 removed from memory
States 11–13: MCRequestKill, MCEndReap, MCRegisterKillChangeSucceed on s2
State 14: MCCheckoutForKill(s2)
States 15–16: MCStartReap, MCEndReap (additional reap cycles)
State 17: MCStartRefresh
State 18: MCStartReap
State 19: MCWaitForCheckout(s2)
State 20: MCDiskReapImage(s1)      → imageRecordOnDisk[s1]=FALSE
          txnRecordOnDisk[s1]=TRUE still → VIOLATION
          (imageRecordOnDisk=FALSE but txnRecordOnDisk=TRUE)
```

**Violated invariant**: `imageRecordOnDisk[s1] = FALSE => txnRecordOnDisk[s1] = FALSE`

#### Affected Code Locations

- `session_catalog_mongod.cpp:244–291` — two-phase non-atomic disk delete
- `session_catalog_mongod.cpp:253–270` — Phase A: `config.image_collection` delete
- `session_catalog_mongod.cpp:272–291` — Phase B: `config.transactions` delete

#### Secondary Concern: NoStaleCheckoutAfterMemoryReap

The `NoStaleCheckoutAfterMemoryReap` invariant (session checked out between memory reap and disk reap finds no txn record) was not triggered in this run but is theoretically violable if `RevivifySession` fires between `DiskReapImage` and `DiskReapTxn`. The hunt config has `MaxRevivifyLimit=2` which should expose this; re-running with `-C` (continue after errors) would reveal the secondary violation.

#### Impact

In the window between the two disk deletes, any new checkout (`_getOrCreateSessionRuntimeInfo` on an absent session, i.e., RevivifySession) creates a session entry that has no image record but still has a transaction record. If the session then starts a transaction that writes to `config.image_collection`, it may assume the delete already happened (corrupt recovery behavior). The risk increases under high concurrency or slow disk I/O.

---

## Summary Table

| Bug ID | Family | Invariant | Status | Severity | Affected Files |
|--------|--------|-----------|--------|----------|---------------|
| MC-1 | 1 | TxnRecordSafeWhileLive | PENDING REPAIR (RR-001) | — | `session_catalog_mongod.cpp:239–334` |
| MC-2 | 2a | NoWaitersStuckAfterKillComplete | FALSE POSITIVE (mutex-protected) | — | `session_catalog.cpp:359–376` |
| MC-3 | 2b | NoOrphanKillRequest | REPRODUCTION FAILED (code audit: real) | MEDIUM | `session_catalog_mongod.cpp:683–686` |
| MC-4 | 3 | NoRunningOpDropped | REPRODUCTION FAILED (code audit: real) | MEDIUM | `logical_session_cache_impl.cpp:356–398` |
| MC-5 | 4a | NoDanglingImageWithoutTxnRecord | REPRODUCTION FAILED (code audit: by design) | MEDIUM | `session_catalog_mongod.cpp:244–291` |

---

## Phase 4 Confirmation Summary (2026-06-08)

| Bug ID | Phase 4 Status | Confidence | Note |
|--------|---------------|------------|------|
| MC-1 | PENDING REPAIR (RR-001) | High (spec artifact) | `DiskReapTxn` fires without modeling `findRemovedSessions` re-check at `session_catalog_mongod.cpp:321` |
| MC-2 | FALSE POSITIVE | High | mutex holds across all three operations; intermediate state unreachable |
| MC-3 | REPRODUCTION FAILED | Medium | Bug stands on code audit; requires `registerChange` to throw |
| MC-4 | REPRODUCTION FAILED | Medium | Bug stands on code audit; backSwap omits runningOpSessions at line 394 |
| MC-5 | REPRODUCTION FAILED | Medium | Bug stands on code audit; explicitly by-design trade-off |

See `spec/confirmed-bugs.md` for full per-bug confirmation details and reproduction test results.  
See `spec/repair-requests/RR-001.md` for the MC-1 spec repair request.

---

## Model Checking Statistics

| Run | Config | States Checked | Traces | Duration | Result |
|-----|--------|---------------|--------|----------|--------|
| MC_base_r1 | MC.cfg | 707 | — | 2s | Violation: MCWaitersConstraint (config bug, fixed) |
| MC_base_r2 | MC.cfg | 3,765 | — | 3s | Violation: CheckoutImpliesInCatalog (spec bug, fixed) |
| MC_base_r3 | MC.cfg | 54,516 | — | 3s | Violation: KillCheckoutRequiresToken (spec bug, fixed) |
| MC_base_r4 | MC.cfg | — | — | — | Crashed (disk full — off-heap BFS) |
| MC_base_sim | MC.cfg | 10.2B | 82.4M | 30min | CLEAN (no violations) |
| MC_base_final | MC.cfg | 8.8B | 71.4M | 30min | CLEAN (after all fixes) |
| MC_hunt_family1 | MC_hunt_family1.cfg | ~4K | 104 | <1s | VIOLATION: TxnRecordSafeWhileLive |
| MC_hunt_family2a | MC_hunt_family2a.cfg | ~5K | 458 | <1s | Violation: NoWaitersStuckAfterKillComplete (invariant too strong) |
| MC_hunt_family2b | MC_hunt_family2b.cfg | ~10K | 1,005 | <1s | Violation: NoOrphanKillRequest (invariant too strong — before fix) |
| MC_hunt_family2b_r2 | MC_hunt_family2b.cfg | ~942 | 86 | <1s | VIOLATION: NoOrphanKillRequest (correct orphan after fix) |
| MC_hunt_family3 | MC_hunt_family3.cfg | ~7K | 124 | <1s | VIOLATION: NoRunningOpDropped |
| MC_hunt_family4 | MC_hunt_family4.cfg | ~8K | 125 | <1s | VIOLATION: NoDanglingImageWithoutTxnRecord |
