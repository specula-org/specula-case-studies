# MongoDB Session — Bug Confirmation Report

**Target**: mongodb-session  
**Phase**: 4 — Bug Confirmation  
**Date**: 2026-06-08  
**Source code**: `artifact/mongo-src/src/mongo/db/session/`

---

## Summary

| Bug ID | Status | Source | Severity | One-line verdict |
|--------|--------|--------|----------|-----------------|
| MC-1 | PENDING REPAIR (RR-001) | MC | — | Spec over-approx: `DiskReapTxn` fires without modeling `findRemovedSessions` re-check at `session_catalog_mongod.cpp:321` |
| MC-2 | FALSE POSITIVE | MC | — | mutex holds across notify_all + --killsRequested; intermediate state unreachable |
| MC-3 | REPRODUCTION FAILED | MC | Medium | Bug stands on code audit: no RAII rollback for `killsRequested` if `registerChange` throws |
| MC-4 | REPRODUCTION FAILED | MC | Medium | Bug stands on code audit: backSwap at `logical_session_cache_impl.cpp:394` omits runningOpSessions |
| MC-5 | REPRODUCTION FAILED | MC | Medium | Bug stands on code audit: acknowledged non-atomic two-phase delete by design |

---

## MC-1: Refresh-Reap Race — TxnRecord Deleted for Live Session

- **Source**: MC (actual counterexample: `spec/output/MC_hunt_family1.out`)
- **Status**: PENDING REPAIR (RR-001)
- **Repair request**: `spec/repair-requests/RR-001.md`
- **Location**: `session_catalog_mongod.cpp:239–334` (`removeSessionsTransactionRecordsIfExpired`)

### Code Audit

The disk reap path is:
1. `reapSessionsOlderThan` calls `removeExpiredTransactionSessionsFromDisk`
   (`session_catalog_mongod.cpp:341–378`)
2. That function scans `config.transactions` for entries with `lastWriteDate < possiblyExpired`
   and, for each batch, calls `removeSessionsTransactionRecordsIfExpired` (line 369–374)
3. `removeSessionsTransactionRecordsIfExpired` (lines 301–334) calls
   `sessionsCollection.findRemovedSessions(opCtx, ...)` at **line 321** to re-check
   `config.system.sessions` for each candidate session before deleting
4. Only sessions still absent from `config.system.sessions` are passed to
   `removeSessionsTransactionRecordsFromDisk` (line 333)

Critical finding: the spec's `DiskReapTxn` and `DiskReapImage` actions fire whenever
`sessionInCatalog[s] = FALSE`, without modeling step 3's `findRemovedSessions` re-check.
If a session was refreshed after memory reap (re-upserted to `config.system.sessions`),
the real disk reap's `findRemovedSessions` would see the session as present and skip it.
The spec does not model this guard.

In the counterexample: `RefreshSucceed(s1)` fires at state 12 between reap cycle 1 (ended
at state 6) and reap cycle 2 (started at state 20). When cycle 2's disk reap fires at states
23–24, the real code's `findRemovedSessions` (line 321) would see s1 as present in
`config.system.sessions` (just refreshed at state 12) and would NOT include it in
`transactionSessionIdsToReap` — so the deletes at lines 272–291 would not execute for s1.

### Developer Intent Investigation

The code comment at `session_catalog_mongod.cpp:244–251` explicitly discusses the
two-phase design tradeoff. `removeSessionsTransactionRecordsIfExpired` (line 301) does
perform a re-check of `config.system.sessions` as its first step (line 321), consistent
with safety-conscious design. No issues, PRs, or code comments suggest the developers
intended to skip this re-check. The re-check appears deliberate.

No developer commentary was found specifically discussing the TOCTOU window (refresh
between `findRemovedSessions` check and the delete), but the presence of the re-check
itself is evidence the developers were aware of the liveness concern.

### Reproduction Test

`repro/test_bug1_refresh_reap_race.py`

**Execution output (all levels):**
```
MC-1: Refresh-Reap Race Reproduction Test
==========================================

=== Level 0: Black-box race attempt ===
FAILED: Cannot connect to MongoDB at mongodb://localhost:27017: localhost:27017: [Errno 111] Connection refused

=== Level 1: Failpoint-assisted timing ===
FAILED: Cannot connect: [Errno 111] Connection refused

=== Level 2: State injection ===
FAILED: Cannot connect: [Errno 111] Connection refused

RESULT: REPRODUCTION FAILED
Reason: No MongoDB binary available; environment constraint.
```

### Reproduction Result

**REPRODUCTION FAILED — environment constraint** (no MongoDB binary in this environment).
All three levels (0/1/2) blocked at connection refused. The escalation ladder was
genuinely exhausted — no MongoDB process available.

The counterexample is a **spec artifact** (SPEC_REPAIR), not a failed reproduction:
the step `DiskReapTxn(s1)` after `RefreshSucceed(s1)` is impossible in the implementation
because `findRemovedSessions` at `session_catalog_mongod.cpp:321` would detect the refresh
and prevent the delete. See `spec/repair-requests/RR-001.md`.

### Recommendation

Repair the spec: add `sessionLastRefreshed[s] < reapCutoff` as a precondition to
`DiskReapImage` and `DiskReapTxn` in `MongoDBSession.tla`. This models the
`findRemovedSessions` re-check at `session_catalog_mongod.cpp:321`.

After repair, re-run `MC_hunt_family1.cfg` to confirm `TxnRecordSafeWhileLive` holds.

---

## MC-2: Kill Release Ordering — notify_all Before --killsRequested

- **Source**: MC (hunt config `MC_hunt_family2a.cfg`)
- **Status**: FALSE POSITIVE
- **Severity**: —
- **Location**: `session_catalog.cpp:354–377` (`_releaseSession`)

### Code Audit

The `_releaseSession` function holds `_mutex` throughout its entire body (`stdx::unique_lock ul(_mutex)` at line 359). The three operations the spec models as separate steps are in fact atomic from the perspective of any other thread:

```cpp
// session_catalog.cpp:359-377 (all under _mutex)
stdx::unique_lock<stdx::mutex> ul(_mutex);      // line 359
...
sri->checkoutOpCtx = nullptr;                   // line 371
sri->availableCondVar.notify_all();             // line 372 — under mutex
if (killToken) {
    --sri->killsRequested;                       // line 376 — under mutex
}
```

Waiters sleeping on `availableCondVar` can only re-acquire the mutex AFTER `_releaseSession`
returns. By that point, `killsRequested` has already been decremented. A waiter can never
observe a state where `notify_all()` has fired but `killsRequested > 0` — that intermediate
state is unreachable under real execution. The spec's three-step kill release decomposition
over-approximates by allowing observability of this intermediate state.

### Developer Intent Investigation

The mutex is acquired at the top of `_releaseSession` and held across all three operations.
This is a standard C++ mutex guard — the behavior is deterministic. No issue or PR suggests
the developers intended the notify and decrement to be separate observable events.

### Reproduction Test

Not applicable — classified as FALSE POSITIVE by code audit. The liveness invariant
`NoWaitersStuckAfterKillComplete` fires on a normal non-kill scenario (waiters waiting
for a checked-out session), not because of the kill-release ordering.

The real liveness concern (`NoLivelockAfterKill`) is not violated under mutex-protected semantics.

---

## MC-3: Orphan Kill Counter if registerChange Throws

- **Source**: MC (actual counterexample: `spec/output/MC_hunt_family2b_r2.out`)
- **Status**: REPRODUCTION FAILED
- **Severity**: Medium
- **Location**: `session_catalog_mongod.cpp:683–686`

### Code Audit

In `observeDirectWriteToConfigTransactions`:

```cpp
// session_catalog_mongod.cpp:683-686
shard_role_details::getRecoveryUnit(opCtx)->registerChange(
    std::make_unique<KillSessionTokenOnCommit>(ti,
                                               session.kill(ErrorCodes::Interrupted)));
```

C++ evaluates arguments before the function call. `session.kill()` (`session_catalog.cpp:447`)
increments `killsRequested` synchronously:

```cpp
// session_catalog.cpp:447-456
SessionCatalog::KillToken ObservableSession::kill(ErrorCodes::Error reason) const {
    ++_sri->killsRequested;    // incremented HERE, before registerChange
    ...
    return SessionCatalog::KillToken(getSessionId());
}
```

`KillToken` (`session_catalog.h:95-101`) has only a move constructor — no destructor to
decrement `killsRequested`. `KillSessionTokenOnCommit` (`session_catalog_mongod.cpp:645–664`)
has no destructor either.

If `registerChange` throws (e.g., due to `validateInUnitOfWork()` failing, OOM, or
RecoveryUnit state corruption), the `KillToken` is destroyed without draining
`killsRequested`. The counter stays permanently > 0. The session becomes uncheckable:
normal checkout sees `_killed()=true` (line 478), and `checkOutSessionForKill` requires
a token that no longer exists.

`RecoveryUnit::registerChange` (`recovery_unit.cpp:78-81`) calls
`validateInUnitOfWork()` and then `_changes.push_back(std::move(change))`. The
`push_back` could throw `std::bad_alloc` under memory pressure.

**Call chain**: `observeDirectWriteToConfigTransactions` ← oplog application / direct
write to `config.transactions` ← this is reachable in any context that directly modifies
`config.transactions` while holding a session.

**Existing safeguards**: None. There is no RAII guard that rolls back `killsRequested`
if `registerChange` fails.

**Trigger scenario**: Under memory pressure, a direct write to `config.transactions`
(e.g., during replication oplog application of a multi-document transaction commit)
calls `observeDirectWriteToConfigTransactions`. `session.kill()` increments
`killsRequested`. `registerChange` then throws `std::bad_alloc`. The session is
permanently unkillable: any subsequent checkout attempt blocks on the killed-but-no-token
state.

### Developer Intent Investigation

No issues or PRs discussing the exception-safety of the kill registration were found via
code inspection. The pattern of evaluating `session.kill()` as a function argument is
present in at least one place in the codebase (`session_catalog_mongod.cpp:685`). The
`KillToken` struct lacks a destructor by design (it's a move-only tag type), but no
documentation explains why RAII cleanup of `killsRequested` is not needed if the token
is never consumed.

The code comment at `session_catalog.h:95-101` documents `KillToken` as a move-only
object but does not mention exception safety. No developer commentary found asserting
that `registerChange` cannot throw or that the caller is guaranteed to be in a
no-throw context. Engineering principle violated: `killsRequested` is incremented before
a potentially-throwing operation, with no rollback mechanism.

### Reproduction Test

`repro/test_bug3_orphan_kill_counter.py`

**Execution output:**
```
MC-3: Orphan Kill Counter Reproduction Test
============================================

=== Level 0: Black-box observation ===
FAILED: Cannot connect to MongoDB at mongodb://localhost:27017: [Errno 111] Connection refused

=== Level 1: Failpoints ===
FAILED: Cannot connect: [Errno 111] Connection refused

=== Level 3: Code modification (description only) ===
  Code modification required at session_catalog_mongod.cpp:684.
  Cannot execute: source not compiled in this environment.

RESULT: REPRODUCTION FAILED
```

### Reproduction Result

**REPRODUCTION FAILED** — environment constraint (no MongoDB binary).

Levels 0 and 1 blocked at connection refused. Level 2 skipped (state injection cannot
simulate a thrown exception in C++). Level 3 code modification described but not executed.

**Does the bug stand on code audit?** Yes. The code structure confirms:
1. `session.kill()` increments `killsRequested` at `session_catalog.cpp:449` before `registerChange`
2. `KillToken` destructor does not decrement `killsRequested`
3. `registerChange` can throw (`recovery_unit.cpp:78` calls `validateInUnitOfWork()`,
   and `push_back` can throw `std::bad_alloc`)
4. No RAII guard protects against orphaned `killsRequested`

The bug is real but requires an exception in `registerChange` to manifest, which is rare
under normal memory conditions. Classification: **REPRODUCTION FAILED** (confirmed by code
audit; hard to trigger without explicit fault injection or OOM).

### Recommendation

Move `session.kill()` before `registerChange` and wrap with a scope guard:

```cpp
auto killToken = session.kill(ErrorCodes::Interrupted);
auto guard = ScopeGuard([&killToken, &catalog, opCtx] {
    // If registerChange throws: drain killsRequested by checking out + releasing with token
    if (killToken) catalog->checkOutSessionForKill(opCtx, std::move(*killToken));
});
shard_role_details::getRecoveryUnit(opCtx)->registerChange(
    std::make_unique<KillSessionTokenOnCommit>(ti, std::move(killToken)));
guard.dismiss();
```

---

## MC-4: RunningOp Sessions Silently Dropped on Refresh Failure

- **Source**: MC (actual counterexample: `spec/output/MC_hunt_family3.out`)
- **Status**: REPRODUCTION FAILED
- **Severity**: Medium
- **Location**: `logical_session_cache_impl.cpp:356–398`

### Code Audit

In `LogicalSessionCacheImpl::_refresh`:

```cpp
// line 356: gather runningOp sessions (NOT in _activeSessions)
auto runningOpSessions = _service->getActiveOpSessions();

for (const auto& it : runningOpSessions) {
    activeSessionRecords.insert(makeLogicalSessionRecord(it, _service->now()));
}
for (const auto& it : activeSessions) {
    activeSessionRecords.insert(it.second);
}

// line 371: batch refresh (both paths together)
auto refreshRes = _sessionsColl->refreshSessions(opCtx, activeSessionRecords);
activeSessionsBackSwapper.dismiss();

// lines 388-398: failure handling — ONLY activeSessions are retried
{
    stdx::lock_guard<stdx::mutex> lk(_mutex);
    LogicalSessionIdSet failedLsids;
    for (const auto& record : refreshRes.failedSessions) {
        failedLsids.insert(record.getId());
    }
    // Line 394: iterates activeSessions only — runningOpSessions are not here
    for (const auto& [lsid, record] : activeSessions) {
        if (failedLsids.count(lsid) > 0) {
            _activeSessions.emplace(lsid, record);  // retry next cycle
        }
    }
}
```

`runningOpSessions` from `getActiveOpSessions()` (line 356) are added to
`activeSessionRecords` alongside `activeSessions`. Both are passed to `refreshSessions`.
If a runningOp session fails to refresh (its LSid appears in `refreshRes.failedSessions`),
the failure handler at lines 388–398 only iterates `activeSessions` to build the retry set.
The `runningOpSessions` are NOT tracked; they are silently dropped.

**Call chain**: `_refresh` ← `_periodicRefresh` ← background job scheduler.

**Existing safeguards**: None for runningOp sessions. The `activeSessionsBackSwapper`
ScopeGuard at line 344 protects `_activeSessions` on exception, but `runningOpSessions`
are not covered by any similar guard.

**Trigger scenario**: A running operation (e.g., a long-running aggregation) has an
active session. The background refresh cycle picks it up via `getActiveOpSessions()`.
If `refreshSessions` fails for this session (e.g., network blip to config server, or
shard catalog refresh failure), the session's `lastUse` in `config.system.sessions`
is not updated. On the next refresh cycle, the session is not in `_activeSessions`
(it was never added to the retry set), so it is not refreshed. Over repeated cycles,
the TTL ticks down until the session expires and is reaped — while the operation
is still running.

### Developer Intent Investigation

The `backSwap` lambda at `logical_session_cache_impl.cpp:336–343` was introduced to
handle the case where `refreshSessions` fails mid-batch and sessions should be retried.
The lambda's ScopeGuard usage (line 344) protects `_activeSessions` but not
`runningOpSessions`. Code comment at line 333–334:

> "Create guards that in the case of a exception replace the ending or active sessions
>  that swapped out of LogicalSessionCache, and merges in any records that had been
>  added since we swapped them out."

The comment refers only to `_activeSessions` and `_endingSessions` — `runningOpSessions`
are not mentioned. This suggests the developers either did not consider the retry
path for runningOp sessions, or deliberately accepted that running operations would
not be retried (possibly assuming they would succeed via the operation's own retry path).

No issues or PRs discussing missing retry logic for `getActiveOpSessions()` were found.
Engineering principle violated: a session that fails to refresh should be retried
regardless of its source.

### Reproduction Test

`repro/test_bug4_runningop_session_drop.py`

**Execution output:**
```
MC-4: RunningOp Session Drop Reproduction Test
===============================================

=== Level 0: Black-box observation ===
FAILED: Cannot connect to MongoDB at mongodb://localhost:27017: [Errno 111] Connection refused

=== Level 1: Failpoint-assisted ===
FAILED: Cannot connect: [Errno 111] Connection refused

=== Level 2: State injection ===
FAILED: Cannot connect: [Errno 111] Connection refused

RESULT: REPRODUCTION FAILED
```

### Reproduction Result

**REPRODUCTION FAILED** — environment constraint (no MongoDB binary).

All three levels blocked at connection refused. Level 3 would require compiling MongoDB
with a conditional that forces `refreshSessions` to fail for runningOp sessions.

**Does the bug stand on code audit?** Yes. The code at lines 388–398 iterates only
`activeSessions`, not `runningOpSessions`. The omission is structural and confirmed by
reading the code. The bug requires a refresh failure, which is rare under normal
conditions but occurs under network partition or config server outage.

### Recommendation

Add runningOp sessions to the retry set on failure:

```cpp
// In the failure handler at logical_session_cache_impl.cpp:388-398
// After the activeSessions retry loop, add:
for (const auto& lsidToRetry : runningOpSessions) {
    if (failedLsids.count(lsidToRetry) > 0) {
        _activeSessions.emplace(lsidToRetry,
            makeLogicalSessionRecord(lsidToRetry, _service->now()));
    }
}
```

---

## MC-5: Non-Atomic Two-Phase Disk Reap Creates Dangling Image Records

- **Source**: MC (actual counterexample: `spec/output/MC_hunt_family4.out`)
- **Status**: REPRODUCTION FAILED
- **Severity**: Medium
- **Location**: `session_catalog_mongod.cpp:239–293` (`removeSessionsTransactionRecordsFromDisk`)

### Code Audit

`removeSessionsTransactionRecordsFromDisk` performs two sequential non-transactional deletes:

```cpp
// Phase A (lines 253-270): delete config.image_collection
write_ops::checkWriteErrors(client.remove(imageDeleteOp));

// Phase B (lines 272-291): delete config.transactions
auto sessionDeleteReply = write_ops::checkWriteErrors(client.remove(sessionDeleteOp));
```

Between Phase A and Phase B, the server has `imageRecordOnDisk=FALSE` but
`txnRecordOnDisk=TRUE`. The code explicitly acknowledges this window
(`session_catalog_mongod.cpp:244–251`):

> "We opt for this rather than performing the two sets of deletes in a single transaction
>  simply to reduce code complexity."

Any new session checkout (`RevivifySession` in the spec, `_getOrCreateSessionRuntimeInfo`
in the code) occurring in this window creates a session that has:
- No image record (already deleted by Phase A)
- Still-existing transaction record (Phase B not yet run)

If the session then starts a transaction that references its pre-image (e.g., a retryable
write that needs to check whether an earlier write succeeded), the lookup in
`config.image_collection` returns empty, but `config.transactions` still shows state.
This inconsistency can cause incorrect retryable write deduplication decisions.

**Call chain**: `removeSessionsTransactionRecordsFromDisk` ← `removeSessionsTransactionRecordsIfExpired` ← `removeExpiredTransactionSessionsFromDisk` ← `reapSessionsOlderThan` ← `_reap` ← background job.

**Existing safeguards**: The comment at lines 248–251 notes the trade-off and states
"Session reaping will rediscover the sessions to delete and try again" — but this only
handles the case where Phase A succeeds and Phase B fails (crash between phases). It
does not address the inconsistent-state window being visible to concurrent checkouts.

**Trigger scenario**: A session is being reaped (Phase A just deleted its image record).
Concurrently, a new operation from the same client reconnects with the same session ID,
calls `_getOrCreateSessionRuntimeInfo`, and finds no entry in the in-memory catalog.
It creates a new SRI. The session is then used for a retryable write. The write checks
`config.image_collection` for the pre-image — finds nothing. The write proceeds as if
no prior execution happened, possibly executing a non-idempotent operation twice.

### Developer Intent Investigation

The code comment at lines 248–251 documents this as a deliberate design choice ("to
reduce code complexity"). The comment notes the recovery path (reap will retry) but does
not acknowledge the concurrent-checkout inconsistency. The design is explicitly
**by design** for the failure recovery case, but may not have considered the concurrent-
checkout window as a problem for retryable write correctness.

No issues or PRs discussing this inconsistency window were found.

### Reproduction Test

`repro/test_bug5_nonatomic_two_phase_reap.py`

**Execution output:**
```
MC-5: Non-Atomic Two-Phase Disk Reap Reproduction Test
========================================================

=== Level 0: Black-box observation ===
FAILED: Cannot connect to MongoDB at mongodb://localhost:27017: [Errno 111] Connection refused

=== Level 1: Failpoint-assisted ===
FAILED: Cannot connect: [Errno 111] Connection refused

=== Level 2: State injection (direct inconsistent state) ===
FAILED: Cannot connect: [Errno 111] Connection refused

RESULT: REPRODUCTION FAILED
```

### Reproduction Result

**REPRODUCTION FAILED** — environment constraint (no MongoDB binary).

All three levels blocked at connection refused. Level 3 would add a `sleep()` between
lines 270 and 272 in `session_catalog_mongod.cpp` to expose the window deterministically.

**Does the bug stand on code audit?** Yes. The two-phase non-atomic delete is confirmed
by reading the code. The window is explicitly acknowledged in comments. The risk is real
under high concurrency or slow I/O.

### Recommendation

Either:
1. Make the two deletes transactional (atomic write to both collections in a single
   multi-document transaction), or
2. Add a guard that prevents `RevivifySession` for sessions currently undergoing reap
   (track in-progress reap state in the session catalog), or
3. Accept the inconsistency and document that clients must handle missing image records
   gracefully (treat absent image as "no prior execution").

The simplest safe fix is option 1, but option 3 may be sufficient if the retryable write
semantics already handle absent image records correctly.
