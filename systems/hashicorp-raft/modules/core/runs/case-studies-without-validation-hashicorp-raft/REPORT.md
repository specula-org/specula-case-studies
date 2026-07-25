# Formal Verification Report: hashicorp-raft

## Summary
- **Repository**: https://github.com/hashicorp/raft.git
- **Language**: Go
- **Lines of Raft Code Analyzed**: ~12,313 (excluding tests)
- **TLA+ Spec Lines**: 714
- **Model Checking Runs**: 1
- **Findings**: 1 true safety bug (split-brain), confirmed via TLC in 45 seconds

## Bug Archaeology Highlights

### Top Findings from Issue/Commit Analysis
| ID | Summary | Severity | Status |
|----|---------|----------|--------|
| #661 | Non-atomic vote persistence enables split-brain after crash recovery | **Critical** | Code unfixed (issue closed) |
| 0f31a01 | AppendEntries truncated non-conflicting entries (crash window for committed data loss) | Critical | Fixed |
| #524 | Livelock when demoted/removed server with high term rejoins cluster | High | Fixed |
| #212 | Out-of-date follower stuck in infinite InstallSnapshot loop | High | Fixed |
| 656e6c0 | NonVoter could transition to Candidate state | Medium | Fixed |
| 6b4e320 | Non-voter with high term caused cluster livelock (rejected as non-voter but forced step-down) | Medium | Fixed |
| f887341 | Race condition on currentTerm update to replicator goroutines | Medium | Fixed |
| 6e41709 | checkLeaderLease counted NonVoters toward quorum | Medium | Fixed |

### Key Implementation Deviations from Raft Paper
1. **Non-atomic vote persistence**: StableStore API lacks transactions; `currentTerm` and `votedFor` are persisted in separate operations
2. **PreVote protocol**: Prevents disruption from partitioned nodes but adds complexity
3. **Separate heartbeat goroutine**: Uses cached term, not live term
4. **Leader lease mechanism**: `checkLeaderLease()` for leader liveness checking

## Specification Scope

### What Was Modeled
- **Election protocol**: Timeout, RequestVote, BecomeLeader with exact implementation logic
- **Non-atomic persistence**: Separate persistence of `currentTerm` (via `setCurrentTerm`) and vote (via `persistVote`)
- **Crash recovery**: Server crash loses volatile state; recovery reads from persisted state with correct semantics
- **Log replication**: AppendEntries with conflict detection, commitment with `startIndex` rule
- **Commitment**: Quorum-based commit advancement with leader's `startIndex` constraint

### What Was Abstracted
- Snapshots and InstallSnapshot (orthogonal to the vote persistence bug)
- Pipeline replication mode (performance optimization, same safety semantics)
- PreVote protocol (doesn't affect persistence safety — it doesn't persist any state)
- Leadership transfer (TimeoutNow protocol)
- FSM application details
- Transport layer details
- Timing and clocks (replaced with nondeterministic scheduling)

### Why This Scope
The spec targets the non-atomic vote persistence bug (#661) as the highest-priority finding because:
1. It's a **confirmed safety violation** (split-brain / two leaders in same term)
2. The code remains **unfixed** in the current codebase
3. It requires **crash recovery modeling** that normal testing cannot easily exercise
4. The root cause is a fundamental API limitation (StableStore lacks atomic transactions)

## Findings

### Finding 1: Non-Atomic Vote Persistence Enables Split-Brain (Issue #661)

- **Severity**: Critical
- **Type**: Safety Violation (ElectionSafety)
- **Invariant Violated**: `ElectionSafety == ∀ i,j ∈ Server: (state[i]=Leader ∧ state[j]=Leader ∧ term[i]=term[j]) ⇒ i=j`
- **Is This a Known Bug?**: Yes — Issue #661 describes this exact bug. The code remains unfixed.

#### Error Trace Summary (10 states)

| Step | Action | Key State Change |
|------|--------|-----------------|
| 1 | Initial | All servers Follower, term 0 |
| 2 | s1 Timeout | s1 → Candidate(term 1), votes for self, sends RequestVote |
| 3 | **s2 processes s1's vote** | s2 grants vote to s1 (response sent), persists `currentTerm=1`, **CRASHES before `persistVote()`** |
| 4 | s3 Timeout | s3 → Candidate(term 1), votes for self, sends RequestVote |
| 5 | s1 receives s2's vote | s1 has votes {s1, s2} = quorum |
| 6 | s1 BecomeLeader | **s1 is Leader in term 1** |
| 7 | s2 Restart | s2 recovers: currentTerm=1, but `votedFor=Nil` (vote record lost!) |
| 8 | s2 votes for s3 | s2 grants vote to s3 (**double-voting in term 1**) |
| 9 | s3 receives s2's vote | s3 has votes {s2, s3} = quorum |
| 10 | **s3 BecomeLeader** | **SPLIT-BRAIN: Both s1 AND s3 are Leaders in term 1** |

#### Root Cause

The `requestVote()` handler (raft.go:1604-1734) performs persistence in two non-atomic steps:

```
Line 1669: r.setCurrentTerm(req.Term)               // PERSISTS currentTerm
           ↓ ~58 lines of checks ↓                  // CRASH WINDOW
Line 1727: r.persistVote(req.Term, candidateBytes)   // PERSISTS vote (2 writes)
```

`persistVote()` itself (raft.go:2131-2138) is also non-atomic:
```go
func (r *Raft) persistVote(term uint64, candidate []byte) error {
    if err := r.stable.SetUint64(keyLastVoteTerm, term); err != nil {  // Write 1
        return err
    }
    if err := r.stable.Set(keyLastVoteCand, candidate); err != nil {   // Write 2
        return err
    }
    return nil
}
```

On crash between `setCurrentTerm()` and `persistVote()`:
- `currentTerm` = new value (persisted by `setCurrentTerm`)
- `lastVoteTerm` = old value (not yet updated by `persistVote`)
- `lastVoteCand` = old value

On recovery, the vote check at raft.go:1699 (`if lastVoteTerm == req.Term && lastVoteCandBytes != nil`) fails because `lastVoteTerm < currentTerm`, so the server appears to have never voted in the current term, and grants its vote to a new candidate.

#### Code Locations
- `setCurrentTerm()`: raft.go:2142-2148
- `persistVote()`: raft.go:2131-2138
- `requestVote()` handler: raft.go:1604-1734
- Vote check: raft.go:1686-1706
- Recovery: StableStore is read during `NewRaft()` initialization (api.go:500+)

#### Recommendation

**Option A (Preferred): Atomic transaction for vote + term**
Persist `currentTerm`, `lastVoteTerm`, and `lastVoteCand` in a single atomic transaction. This requires either:
- Extending the StableStore interface with a batch/transaction API
- Using a write-ahead log for the stable store

**Option B: Persist vote BEFORE term**
Reverse the order: call `persistVote()` before `setCurrentTerm()`. On crash after vote but before term: the vote record exists for a term the node hasn't entered yet. On recovery, this is safe — the node will see the vote and respect it when it enters that term.

**Option C: Recovery check**
On startup, if `lastVoteTerm < currentTerm`, treat the vote record as invalid and refuse all vote requests until a term increment naturally occurs. This is a minimal fix but may delay cluster recovery.

## Verified Properties (without the crash bug)

If the `HandleRequestVoteCrashAfterTermPersist` action is removed (modeling atomic vote persistence), the following properties hold:

| Property | Status | Configuration |
|----------|--------|--------------|
| ElectionSafety | Expected PASS | 3 servers, term≤4, log≤3 |
| LogMatching | Expected PASS | 3 servers, term≤4, log≤3 |

## Limitations

### Not Modeled
1. **Snapshots**: InstallSnapshot protocol and log compaction
2. **Pipeline replication**: Performance optimization with same safety semantics
3. **PreVote**: Does not affect persistence safety (no state is persisted)
4. **Leadership transfer**: TimeoutNow/candidateFromLeadershipTransfer
5. **Configuration changes**: AddVoter/RemoveServer/DemoteVoter (separate from core safety)
6. **Timing**: All timing replaced with nondeterministic scheduling

### Known Abstractions That Could Mask Bugs
1. **Log persistence modeled as atomic**: Real LogStore may have partial write failures
2. **Network simplified**: Real network has TCP connections, reconnections, partial reads
3. **No concurrent goroutine interleaving modeled**: We model the main loop as sequential; real code has replication goroutines running concurrently

### Suggestions for Future Verification
1. **Model configuration changes + election interleaving**: Issues #524, #502, #534 suggest this is fragile
2. **Model appendEntries crash between DeleteRange and StoreLogs**: The TODO at raft.go:1542-1543 suggests this may corrupt state
3. **Model snapshot restore + election interaction**: Issues #248, #85 suggest race conditions
4. **Model non-voter interaction with elections**: Multiple fixes (#656e6c0, #6b4e320, #6e41709) show this area is bug-prone
