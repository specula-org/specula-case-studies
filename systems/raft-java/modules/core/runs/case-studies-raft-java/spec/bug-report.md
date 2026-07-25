# Bug Report — raft-java (wenweihu86/raft-java)

## Summary

- Bug families tested: 4 (persistence, monotonicity, snapshot, config change)
- Bugs found: 2
- Configs run: MC_hunt_persist.cfg, MC_hunt_monotonicity.cfg, MC_hunt_snapshot.cfg, MC_hunt_configchange.cfg
- Convergence: 485M states (BFS depth 20) + 141M states simulation (622K traces), 0 errors on core properties

---

## Bug 1: Non-Atomic Persistence in startVote (Double-Vote After Crash)

- **Bug Family**: 1 — Non-atomic persistence
- **Severity**: Critical
- **Invariant violated**: NoOrphanedElectionRPCs
- **Config**: MC_hunt_persist.cfg
- **Counterexample**: 6 states, output file: `spec/output/MC_hunt_persist_r3.out`

### Trace Summary

1. **State 1**: Init — all servers at term 0, Follower
2. **State 2**: s1 starts PreVote, becomes PreCandidate
3. **States 3–4**: s1 receives PreVote quorum (handlers via MCNext)
4. **State 5**: s1 calls `startVote()` — `currentTerm` goes 0→1, `votedFor=s1`. **But `persistedTerm` stays at 0** and `persistedVotedFor` stays at Nil. RequestVoteRequests at term 1 are sent to s2 and s3.
5. **State 6**: s1 crashes — recovers from `persistedTerm=0`, `persistedVotedFor=Nil`. `currentTerm` reverts to 0. But RequestVoteRequests at term 1 are still in the message bag.

**Violation**: `NoOrphanedElectionRPCs` — `currentTerm[s1] (0) < m.mterm (1)` for s1's own RequestVoteRequest.

**Practical impact**: After recovery at term 0, s1 can receive a RequestVoteRequest from another candidate at term 1 and vote for that candidate. This means two different candidates (s1 and the other) both have votes at term 1, potentially leading to two leaders in the same term (ElectionSafety violation).

### Root Cause

`RaftNode.java:490-518` (`startVote()`): increments `currentTerm` (line 497) and sets `votedFor` (line 501) **in memory only**. No call to `raftLog.updateMetaData()`. Compare with `stepDown()` (line 307) which correctly persists via `updateMetaData()`.

### Affected Code

- `RaftNode.java:497-501`: `startVote()` — missing `raftLog.updateMetaData()` after term/votedFor update
- `RaftNode.java:298-315`: `stepDown()` — correctly calls `updateMetaData()` (reference for fix pattern)

### Recommendation

Add `raftLog.updateMetaData(currentTerm, votedFor, null)` after line 501 in `startVote()`, matching the pattern in `stepDown()`.

---

## Bug 2: MatchIndex Monotonicity Violation (Stale Heartbeat Response)

- **Bug Family**: 2 — CommitIndex/MatchIndex monotonicity
- **Severity**: High
- **Property violated**: MonotonicMatchIndexProp
- **Config**: MC_hunt_monotonicity.cfg
- **Counterexample**: 16 states, output file: `spec/output/MC_hunt_monotonicity_r3.out`

### Trace Summary

1. **States 1–8**: s2 wins election at term 1, becomes Leader.
2. **State 10**: s2 sends AppendEntries(s2→s1) as heartbeat (empty entries). This heartbeat response will report `mmatchIndex=0`.
3. **State 11**: s2 appends a ClientRequest (log entry at index 1).
4. **State 12**: s2 sends AppendEntries(s2→s1) with the new entry. This response will report `mmatchIndex=1`.
5. **State 15**: s2 handles the second AE response (with entry): `matchIndex[s2][s1]` goes 0→1. Correct.
6. **State 16**: s2 handles the first AE response (stale heartbeat): `matchIndex[s2][s1]` goes **1→0**. Regression!

**Violation**: `MonotonicMatchIndexProp` — `matchIndex'[s2][s1] (0) < matchIndex[s2][s1] (1)` while s2 stays Leader.

**Practical impact**: The regressed `matchIndex` can cause:
- Commit index to not advance (quorum calculation uses stale matchIndex)
- Re-sending already-acknowledged entries (unnecessary network traffic)
- In worst case, interacting with Bug Family 2's commitIndex regression to create inconsistent commit state

### Root Cause

`RaftNode.java:276`: `peer.setMatchIndex(responseLastLogIndex)` — sets matchIndex **unconditionally** without checking if the new value is >= the current value. A stale heartbeat response (sent before a replication, received after) resets matchIndex backward.

### Affected Code

- `RaftNode.java:276`: `peer.setMatchIndex()` — missing `Math.max()` guard
- `RaftNode.java:277`: `peer.setNextIndex()` — same issue, also set unconditionally

### Recommendation

Replace the unconditional set with a monotonicity guard:
```java
// Before (buggy):
peer.setMatchIndex(responseLastLogIndex);
peer.setNextIndex(peer.getMatchIndex() + 1);

// After (fixed):
if (responseLastLogIndex > peer.getMatchIndex()) {
    peer.setMatchIndex(responseLastLogIndex);
    peer.setNextIndex(peer.getMatchIndex() + 1);
}
```

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 3 — Snapshot state desync | MC_hunt_snapshot.cfg | 78M+ (BFS depth 19, still growing) | Not testable — config has ConfigChangeLimit=0, but SnapshotConfigConsistencyInv requires config changes to trigger (snapshot config differs from current config only after ProposeConfigChange) |
| 5 — Config change safety | MC_hunt_configchange.cfg | 87M+ (BFS depth 17, still growing) | No violation found — state space too large for exhaustive exploration. ElectionSafety holds across explored states. May require more servers (>3) or specific partition patterns to trigger split-brain from multi-server config change. |

---

## Spec Fixes During Validation

The following spec and invariant changes were needed to achieve convergence:

### Invariant Fixes (Case A)
- **LeaderCompleteness**: Made snapshot-aware (entries in snapshot are exempt) and term-aware (stale leaders don't need entries committed at higher terms)
- **LogMatching**: Adjusted for snapshot-truncated logs using absolute index ranges
- **LeaderAppendOnlyProp**: Uses absolute indices for append-only check across snapshot truncations
- **LeaderCommitCurrentTermLogsProp**: Uses snapshot-adjusted index for log access

### Spec Fixes (Case B — Snapshot Index Handling)
- **TakeSnapshot**: Was mixing absolute (commitIndex) and relative (Len(log)) indices; fixed to use relative coordinates
- **AppendEntries, HandleAppendEntriesRequest, AdvanceCommitIndex, BecomeLeader, HandleInstallSnapshotRequest**: All fixed to consistently use absolute indices externally and convert to relative for log access
- Added `AbsLastLogIndex(i)` and `AbsLogTerm(i, absIdx)` helpers for consistent absolute index operations
- All SubSeq calls guarded against empty/short logs after snapshot truncation
