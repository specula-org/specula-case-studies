# Confirmed Bug Report — mongodb-rafttimestamp

## Summary

- Total findings reviewed: 5
- Confirmed: 1 (0 reproduced, 1 code-audit only — already fixed in this codebase)
- False positives: 1 (spec infidelity)
- Not actionable: 3 (1 defensive suggestion, 2 already-tracked open tickets)

## Bug MRT-1: Journal Flusher TOCTOU (SERVER-50949)

- **Source**: MC (9-state BFS counterexample, 3 seconds)
- **Status**: CONFIRMED (code audit) — FIXED in this version
- **Severity**: High
- **Location**: `replication_coordinator_impl.cpp:1693-1747` (`_setMyLastDurableOpTimeAndWallTime`, `_setMyLastDurableOpTimeAndWallTimeForward`)
- **Description**: The journal flusher thread captures `lastApplied` (now `lastWritten`) at time T1 and later sets `lastDurable` at time T2. If rollback truncates the oplog between T1 and T2, `lastDurable` is set to a stale value pointing beyond the oplog. The forward-only guard (`opTime > lastDurable`) does not check whether the optime refers to an entry that still exists.
- **Trigger scenario**: (1) Primary writes entries, flusher captures lastApplied. (2) Network partition causes rollback — oplog truncated. (3) Flusher flushes stale snapshot, setting lastDurable past the end of the oplog.
- **TLA+ counterexample**: 9 states — Init → BecomePrimary(n1) → ClientWrite(n1) → BecomePrimary(n2) → AppendOplog(n3,n2) → JournalFlusherCapture(n1) → RollbackOplog(n1,n2) → JournalFlusherFlush(n1). `LastDurableImpliesInOplog` violated: `lastDurable.index=2 > Len(log)=1`.
- **Fix status**: Fixed by two commits:
  1. **SERVER-50949** (commit `9f52be8cf5`, Oct 2020): Added `rollbackSafe=true` parameter to `getToken()` — returns empty OpTime when node is in ROLLBACK or REMOVED state.
  2. **SERVER-51425** (commit `8a6082c74e`, Nov 2020): Belt-and-suspenders — pauses the JournalFlusher thread entirely during rollback.
- **Current safeguards** (5 layers): rollbackSafe check, flusher pause during rollback, `onStepDownHook` interrupt+wait, `lastWritten.isNull()` guard (line 1593), invariant crash on `opTime > lastWrittenOpTime` (line 1594).
- **Reproduction**: Not attempted — bug is fixed in current codebase with 5 layers of protection. The TLA+ model correctly identified the historical TOCTOU pattern.
- **Recommendation**: No action needed. The fix is comprehensive.

---

## Bug MRT-2: Write Concern Loss During Stepdown (SERVER-113256)

- **Source**: MC (15-state BFS counterexample, 6 min 45s)
- **Status**: FALSE POSITIVE (spec infidelity)
- **Severity**: N/A (counterexample unreachable in real code)
- **Location**: `replication_coordinator_impl.cpp:2222-2292` (`_doneWaitingForReplication`)
- **Description**: The TLA+ model found a scenario where a write concern waiter survives across rollback and is later satisfied by a committed snapshot from a different term. However, this depends on a spec infidelity: `RollbackOplog` in the spec (base.tla:355-380) has precondition `state[i] /= "Down"` — allowing a Leader to roll back directly without stepping down. The spec also leaves `writeConcernWaiters` UNCHANGED during rollback (line 379).

### Why this is a false positive

In the real implementation, rollback REQUIRES prior stepdown. The sequence is:

1. Node learns higher term → `updateTerm` → marks node for stepdown
2. `_stepDownFinish` → `_updateMemberStateFromTopologyCoordinator` → **`setErrorAll` clears ALL write concern waiters** (catchup.cpp:251-255)
3. Node transitions to SECONDARY
4. Node enters ROLLBACK state → **`setErrorAll` fires again** (rollback_impl.cpp:415)
5. Only then can oplog truncation occur

Both state transitions (PRIMARY→SECONDARY and SECONDARY→ROLLBACK) clear all waiters. The TLA+ counterexample requires a waiter to survive across rollback, which is impossible because:

- `RollbackOplog` (spec) skips the mandatory stepdown that clears waiters
- `CanRollbackOplog` (base.tla:211-216) only checks log compatibility — no `state[i] = "Follower"` guard
- The counterexample's step 8 (`RollbackOplog(n1,n2)`) fires while n1 is still "Leader"

### Relationship to real SERVER-113256

The actual SERVER-113256 bug operates at a **different layer** than what TLA+ models. The real bug is about **command-layer write concern error suppression**: stepdown correctly signals errors to all waiters (via `setErrorAll`), but the command processing framework catches these errors and fails to propagate the `writeConcernError` field in the client response. This is a serialization/error-handling bug at the MongoDB command layer, not a replication protocol bug.

The TLA+ model correctly identified the *category* of bug (write concern loss during state transitions) but found it through an unfaithful mechanism (Leader rollback without stepdown). The real bug cannot be found by protocol-level TLA+ modeling.

### Spec fix recommendation

Add `state[i] /= "Leader"` to `RollbackOplog`'s precondition, or model the mandatory stepdown before rollback:

```tla
RollbackOplog(i, j) ==
    /\ state[i] = "Follower"  \* Cannot rollback as Leader — must step down first
    /\ state[j] /= "Down"
    /\ ...
```

---

## Finding CR-1: Missing bounds check in _updateCommittedSnapshot

- **Source**: Code review
- **Status**: NOT A BUG (defensive coding suggestion)
- **Location**: `replication_coordinator_impl.cpp:~5647`
- **Description**: `_updateCommittedSnapshot` does not explicitly check `newCommittedSnapshot <= lastApplied`. However, the sole caller (`_setStableTimestampForStorage`) passes `stableOpTime`, which is computed by `_recalculateStableOpTime` as `min(lastApplied, allDurable, commitPoint)`. The `<= lastApplied` bound is guaranteed by construction via the `min()` calculation, enforced by invariants at lines 5097-5110. No violation path exists.

---

## Finding CR-2: Oplog visibility thread lifecycle (SERVER-122142)

- **Source**: Code review (open SERVER ticket)
- **Status**: NOT APPLICABLE — architecture replaced
- **Description**: The old WiredTiger-based oplog visibility thread has been replaced in this version with `OplogVisibilityManager`, a mutex-protected class with no separate thread lifecycle. The concurrent start/stop race is eliminated by design. SERVER-122142 may apply to older MongoDB versions only.

---

## Finding CR-3: Chained secondary reads during step-up (SERVER-120205)

- **Source**: Code review (open SERVER ticket)
- **Status**: ALREADY TRACKED — not a new finding
- **Description**: Architecturally plausible race where a chained secondary reads beyond the oplog visibility timestamp during primary step-up. This is already tracked as SERVER-120205. No new insight from our analysis.

---

## Model Checking Coverage (from bug-report.md)

| Config | States | Result | Bug Family |
|--------|--------|--------|------------|
| MC.cfg (convergence) | 829M BFS + 592M sim | PASS (after committedSnapshot fix) | All |
| MC_hunt_flusher | 170K | **VIOLATION** (MRT-1) | Family 2 |
| MC_hunt_writeconcern | 134M | **VIOLATION** (MRT-2, false positive) | Family 3 |
| MC_hunt_holes | 370M+ | PASS | Family 1 |
| MC_hunt_recovery | 398M+ | PASS | Family 5 |

## Lessons Learned

1. **Spec fidelity is critical for write concern bugs**: The MRT-2 false positive arose because `RollbackOplog` abstracts away the mandatory stepdown sequence. Any spec modeling write concern loss must faithfully capture state transitions that clear waiters. This echoes the DA-28 retraction in Autobahn (Byzantine action missing TC requirement).

2. **Historical bugs confirm TLA+ modeling value**: MRT-1 was a real bug (SERVER-50949) that existed for years. The TLA+ model found it in 3 seconds with a 9-state counterexample. Even though it's already fixed, this validates the modeling approach for the journal flusher TOCTOU pattern.

3. **Command-layer bugs are outside TLA+ scope**: The real SERVER-113256 operates at the command serialization layer, not the replication protocol layer. Protocol-level TLA+ cannot find bugs in error propagation across software layers.
