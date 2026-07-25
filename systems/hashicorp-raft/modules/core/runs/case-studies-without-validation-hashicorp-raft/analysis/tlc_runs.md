# TLC Model Checking Runs

| Run | Config | Result | Duration | States | Notes |
|-----|--------|--------|----------|--------|-------|
| 1 | 3 nodes, term≤4, log≤3, msgs≤15, +crash recovery | **ElectionSafety VIOLATED** | 45s | 50M generated, 10.9M distinct | Split-brain found in 10-state trace via Issue #661 bug |

## Run 1: ElectionSafety Violation (Non-Atomic Vote Persistence)

### Trace Summary (10 states)
1. **Initial**: All servers Follower, term 0
2. **s1 Timeout**: s1 starts election in term 1, votes for itself
3. **s2 HandleRequestVoteCrashAfterTermPersist**: s2 receives s1's vote request. Grants vote, sends response, persists currentTerm=1 via setCurrentTerm(), BUT crashes before persistVote() completes. persistedVoteTerm stays at 0. s2 is now dead.
4. **s3 Timeout**: s3 starts election in term 1, votes for itself
5. **s1 receives s2's vote**: s1 has votes {s1, s2} = quorum (s2's response was sent before crash)
6. **s1 BecomeLeader**: s1 is Leader in term 1
7. **s2 Restart**: On recovery, currentTerm=1 (persisted), but votedFor=Nil because persistedVoteTerm=0 < persistedTerm=1 — vote record lost!
8. **s2 votes for s3**: s2 receives s3's RequestVote for term 1. Since votedFor=Nil, grants vote to s3 — double-voting!
9. **s3 has quorum**: s3 has votes {s2, s3} = quorum
10. **s3 BecomeLeader**: **SPLIT-BRAIN: Both s1 and s3 are Leaders in term 1!**

### Root Cause
The `requestVote()` handler in raft.go:1604-1734 has a crash window between:
- Line 1669: `r.setCurrentTerm(req.Term)` — persists currentTerm to stable storage
- Line 1727: `r.persistVote(req.Term, candidateBytes)` — persists vote (2 separate writes)

If a crash occurs between these two operations, on recovery:
- currentTerm is at the new value (was persisted)
- votedFor is effectively Nil (persistedVoteTerm < persistedTerm)
- The server can vote again for a different candidate in the same term

### Code References
- `setCurrentTerm()`: raft.go:2142-2148
- `persistVote()`: raft.go:2131-2138 (TWO separate writes: SetUint64 then Set)
- `requestVote()` crash window: raft.go:1665-1732 (58 lines between term persist and vote persist)
- Recovery logic: Implicit — `GetUint64(keyLastVoteTerm)` at raft.go:1687, compared to currentTerm at line 1699
