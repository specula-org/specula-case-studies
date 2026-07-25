# Bug Report — MongoDB Session Lifecycle

## Summary

- Bug families tested: 5 (F1: Reaper destroys prepared txn, F2: Step-down deadlock, F3: Lock hierarchy deadlock, F4: Failover state races, F5: Kill/reap accounting)
- Bugs found: 1
- Configs run: MC_hunt_reaper.cfg, MC_hunt_disk.cfg, MC_hunt_endsession.cfg, MC_hunt_stepdown.cfg, MC_hunt_reaper_nofault.cfg

## Bug 1: endSessions() Removes Session with Prepared Transaction

- **Bug Family**: F5 — Kill/reap accounting and lifecycle ordering bugs
- **Severity**: Medium-High
- **Invariant violated**: EndSessionSafety
- **Config**: MC_hunt_endsession.cfg
- **Counterexample**: 5 states (spec/output/MC_hunt_endsession_bfs_r2.out)

### Trace Summary

| State | Action | Key Change |
|-------|--------|------------|
| 1 | Initial | All sessions idle, in cache, node is primary |
| 2 | CheckOutSession(t1, s1) | Thread t1 checks out session s1 |
| 3 | BeginTransaction(t1) | Transaction started on s1 (txnState = "inProgress") |
| 4 | PrepareTransaction(t1) | Transaction prepared on s1 (txnState = "prepared") |
| 5 | **EndSession(s1)** | **s1 removed from config.system.sessions while prepared txn is active** |

At state 5, `sessionInCache[s1] = FALSE` but `txnState[s1] = "prepared"`, violating EndSessionSafety: a session with a prepared transaction should not be removed from the session tracking collection.

### Root Cause

`LogicalSessionCacheImpl::endSessions()` at `logical_session_cache_impl.cpp:457-465` accepts any session ID and marks it for ending **without checking the transaction state**:

```cpp
void LogicalSessionCacheImpl::endSessions(const LogicalSessionIdSet& sessions) {
    for (const auto& lsid : sessions) {
        uassert(ErrorCodes::InvalidOptions,
                str::stream() << "Cannot specify a child session id " << lsid,
                isParentSessionId(lsid));  // Only checks child session constraint
    }
    stdx::lock_guard<stdx::mutex> lk(_mutex);
    _endingSessions.insert(begin(sessions), end(sessions));
}
```

The only validation is that child session IDs cannot be passed. There is no check for prepared (or in-progress) transactions. During the next `_refresh()` cycle (lines 348-406), the session is unconditionally removed from `config.system.sessions`.

This contrasts with `killOldestTransaction()` (kill_sessions_local.cpp:248), which explicitly filters out prepared transactions — showing MongoDB is aware of the need for this guard, but it's missing from the `endSessions()` path.

### Impact

When a session with a prepared transaction is ended:
1. Session removed from `config.system.sessions` during next refresh cycle
2. Session no longer tracked by the logical session cache
3. Session appears "expired" to the reaper (not refreshed)
4. Reaper targets it for reaping (though `canBeReaped()` currently prevents actual reap of prepared txns)

**Current defense in depth**: The reaper's `canBeReaped()` check (`!transactionIsOpen()`) prevents the session from actually being reaped. However:
- This relies on the reaper check being correct and never bypassed — exactly the pattern that caused SERVER-105751
- The session metadata in `config.system.sessions` is lost, creating tracking inconsistency
- If any future reaper path bypasses `canBeReaped()` (as happened in SERVER-105751), this becomes a data loss vector

### Affected Code

- `logical_session_cache_impl.cpp:457-465`: `endSessions()` — missing prepared txn check
- `logical_session_cache_impl.cpp:348-406`: `_refresh()` — unconditionally removes ended sessions from disk
- `logical_session_cache_impl.cpp:406`: `removeRecords()` — deletes from config.system.sessions

### Recommendation

Add a prepared transaction guard to `endSessions()`:
```cpp
void LogicalSessionCacheImpl::endSessions(const LogicalSessionIdSet& sessions) {
    // ... existing child session check ...
    stdx::lock_guard<stdx::mutex> lk(_mutex);
    for (const auto& lsid : sessions) {
        // Check if session has an open transaction via SessionCatalog
        // If prepared or in-progress, skip or return error
        _endingSessions.insert(lsid);
    }
}
```

Alternatively, add the guard in `_refresh()` before removing ended sessions from disk — similar to how the reaper checks `canBeReaped()` before reaping.

---

## Design Limitation: Non-Atomic Disk Deletion (F1)

- **Type**: Known design limitation (not a new bug)
- **Invariant**: DiskConsistency (weakened to check only in idle state)
- **Config**: MC_hunt_disk.cfg, MC_hunt_reaper.cfg (via ReaperFailBetweenDeletes fault injection)
- **Counterexample**: 4 states

The reaper deletes session records in two steps: image records first (`session_catalog_mongod.cpp:253-270`), then transaction records (`session_catalog_mongod.cpp:272-294`). If the node fails between these two operations, image records are deleted but transaction records persist, creating an inconsistent disk state.

This is a known design choice — the two deletions are not wrapped in a multi-document transaction for performance reasons. The inconsistency is self-healing (next successful reaper run cleans up both records). The DiskConsistency invariant was intentionally weakened to tolerate the transient intermediate state during normal two-step deletion.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| F1: Reaper destroys prepared txn (normal path) | MC_hunt_reaper_nofault.cfg | 3,930 BFS + 150M sim | No violation — `canBeReaped()` guard is effective |
| F1: Reaper via bypass (SERVER-105751 pattern) | MC_hunt_reaper.cfg | 323 BFS | Confirmed by fault injection (expected) |
| F2: Step-down deadlock / killsRequested leak | MC_hunt_stepdown.cfg | 10,939 BFS + 193M sim | No violation |
| F3: Lock hierarchy deadlock | — | — | Not testable — lock hierarchy not modeled (per modeling brief decision) |
| F4: Failover state races | — | — | Not testable — resource stash/unstash not modeled |

## Spec Fixes During Bug Hunting

| Fix | Type | Description |
|-----|------|-------------|
| DiskConsistency | Case A (invariant weakened) | Added `reaperPhase = "idle" =>` guard — normal two-step deletion creates a legitimate intermediate state |
| CheckInSession | Case B (spec fixed) | Added `{s, t} \notin killTokens` guard — prevented impossible path where kill-checkout session is released via normal checkin without decrementing killsRequested. Real code handles this via RAII kill token in `_releaseSession()` (session_catalog.cpp:374-377) |
