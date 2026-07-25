# Bug Report: MongoDB RaftMongoReplTimestamp

## Summary

| Bug ID | Family | Severity | Invariant | Method | States | Status |
|--------|--------|----------|-----------|--------|--------|--------|
| MRT-1 | 2 (Flusher TOCTOU) | HIGH | LastDurableImpliesInOplog | BFS, 3s | 170K | Confirmed (SERVER-50949) |
| MRT-2 | 3 (WC Loss) | CRITICAL | AcknowledgedWriteNeverRolledBack | BFS, 6m45s | 134M | Confirmed (SERVER-113256) |

Bug Families 1 (Holes) and 5 (Recovery) explored 370M+ states each with no violations.

## Convergence

Converged in 2 rounds. One spec fix applied during convergence:
- **Crash action**: `committedSnapshot` (volatile `_currentCommittedSnapshot`) was incorrectly preserved across crashes. Fixed to reset to NilOpTime on crash. (Case B — spec modeling issue.)

## Bug MRT-1: Journal Flusher TOCTOU (SERVER-50949)

### Invariant
```tla
LastDurableImpliesInOplog ==
    \A s \in Server :
        /\ state[s] /= "Down"
        /\ lastDurable[s] /= NilOpTime
        => /\ lastDurable[s].index <= Len(log[s])
           /\ LogTerm(s, lastDurable[s].index) = lastDurable[s].term
```

### Counterexample (9 states, BFS, 3 seconds)

1. **Init**: All servers at term 0, empty logs.
2. **BecomePrimary(n1)**: n1 elected at term 1.
3. **ClientWrite(n1)**: n1 writes 2 entries, log = `<<[term:1],[term:1]>>`, lastApplied = {1,2}.
4. **BecomePrimary(n2)**: n2 elected at term 2, writes 1 entry.
5. **AppendOplog(n3,n2)**: n3 replicates from n2.
6. **ClientWrite(n1)**: n1 still thinks it's leader at term 1 (partition). No state change (term mismatch with precondition already covered above).
7. **JournalFlusherCapture(n1)**: Flusher snapshots lastApplied = **{1,2}**.
8. **RollbackOplog(n1,n2)**: n1 discovers n2's higher-term log, rolls back entry 2. log = `<<[term:1]>>`, lastApplied = {1,1}. **journalFlusherSnapshot still = {1,2}**.
9. **JournalFlusherFlush(n1)**: Flusher sets lastDurable = {1,2} from stale snapshot. But log only has 1 entry! **lastDurable.index=2 > Len(log)=1**.

### Root Cause

`_setMyLastDurableOpTimeAndWallTimeForward` (replication_coordinator_impl.cpp:1740-1747) only checks `opTime > lastDurable` (forward-only), but does NOT check that the opTime refers to an entry that still exists in the oplog. Between capture and flush, rollback can truncate the log, making the captured snapshot stale.

### Affected Code
- `replication_coordinator_impl.cpp:1693-1708` (`_setMyLastDurableOpTimeAndWallTime`)
- `replication_coordinator_impl.cpp:1740-1747` (`_setMyLastDurableOpTimeAndWallTimeForward`)

### Impact
lastDurable points beyond the oplog — downstream consumers (commit point calculation, snapshot reads) may use an invalid optime, potentially leading to incorrect durability guarantees.

---

## Bug MRT-2: Write Concern Loss During Stepdown (SERVER-113256)

### Invariant
```tla
AcknowledgedWriteNeverRolledBack ==
    \A opTime \in acknowledged : opTime \notin rolledBack
```

### Counterexample (15 states, BFS, 6 min 45s)

1. **Init**: All servers at term 0, empty logs.
2. **BecomePrimary(n1)**: n1 elected at term 1.
3. **BecomePrimary(n2)**: n2 elected at term 2 (n1 doesn't know).
4. **ClientWrite(n2)**: n2 writes at term 2.
5. **ClientWriteWithWC(n1)**: n1 writes at term 1 with w:majority. writeConcernWaiters = [{1,1}].
6-7. **AppendOplog(n3,n1)**: n3 replicates n1's term-1 entry.
8. **RollbackOplog(n1,n2)**: n1 discovers n2's higher term, rolls back its term-1 entry. **rolledBack = [{1,1}]**. BUT writeConcernWaiters STILL contains [{1,1}].
9. **BecomePrimary(n1)**: n1 wins election at term 3 with {n1,n3} votes.
10. **ClientWrite(n1)**: n1 writes new entry at term 3, index 1.
11-12. **AppendOplog + PersistOplog**: n3 replicates and persists.
13. **AdvanceCommitPoint**: commitPoint advances to {3,1}. committedSnapshot = {3,1}.
14. **LearnCommitPoint**: n3 learns commit point.
15. **WriteConcernSatisfied(n1)**: Check: committedSnapshot.curr={3,1} >= {1,1}. **TRUE**. Acknowledged = [{1,1}], but that entry was rolled back!

### Root Cause

`_doneWaitingForReplication` (replication_coordinator_impl.cpp:2240-2273) returns `true` when `_currentCommittedSnapshot >= opTime`, without verifying that the opTime's entry is still in the log with the same term. The early return on line 2273 bypasses the term-aware validation in `_topCoord->haveTaggedNodesReachedOpTime()`.

The WC waiter survives rollback because the Stepdown action clears waiters, but RollbackOplog does not. After re-election with a new term, the committed snapshot at the same index (but different term) satisfies the stale waiter.

### Affected Code
- `replication_coordinator_impl.cpp:2222-2292` (`_doneWaitingForReplication`)
- Early return at line 2273 bypasses term check

### Impact
**Data loss**: Client receives "majority committed" acknowledgment for a write that was subsequently rolled back. This violates the fundamental w:majority durability guarantee. The client believes the data is safe, but it has been lost.

---

## Bug Family 1 (Holes): No Violations Found

**Config**: MC_hunt_holes.cfg (MaxPrepareCount=2, MaxLogLen=3)
**Invariants**: StableNeverExceedsAllDurable, HolesBlockAllDurable, PreparedTxnPinsStable
**Coverage**: 370M+ states generated, depth 22, no violations.

The oplog hole tracking and prepared transaction pinning logic is correctly modeled.

## Bug Family 5 (Recovery): No Violations Found

**Config**: MC_hunt_recovery.cfg (MaxRestartTimes=2, MaxRecoveryCrashCount=2)
**Invariants**: NeverRollbackCommitted, CommittedSnapshotNeverRollback, LastDurableImpliesInOplog, LastAppliedBound, LastDurableBound
**Coverage**: 398M+ states generated, depth 26, no violations.

After the convergence fix (Crash resets committedSnapshot), the recovery sequence correctly maintains all invariants, including under crash-during-recovery scenarios.

---

## Model Checking Statistics

| Config | States Generated | Distinct | Depth | Duration | Result |
|--------|-----------------|----------|-------|----------|--------|
| MC.cfg (convergence) | 829M (BFS) + 592M (sim) | 77M + 6.6M traces | 19 | ~30 min | PASS (after fix) |
| MC_hunt_flusher | 170K | 38K | 9 | 3s | **VIOLATION** |
| MC_hunt_writeconcern | 134M | 12M | 15 | 6m 45s | **VIOLATION** |
| MC_hunt_holes | 370M+ | 27M+ | 22 | >20 min | PASS |
| MC_hunt_recovery | 398M+ | 57M+ | 26 | >20 min | PASS |
