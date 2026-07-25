# Bug Report — goraft/raft

## Summary

- Bug families tested: 5
- Bugs found: 3
- Configs run: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family4.cfg, MC_hunt_family5.cfg

---

## Bug 1: Non-Persistent currentTerm/votedFor Enables Double-Voting After Crash

- **Bug Family**: 1 (Non-persistent safety state)
- **Severity**: Critical
- **Invariant violated**: ElectionSafety
- **Config**: MC_hunt_family1.cfg
- **Counterexample**: 25 states (output/MC_hunt_family1.out)

### Trace Summary

1. Server s1 becomes leader at term 1 via normal election (s2 and s3 vote for s1)
2. s1 crashes — currentTerm reverts to 0, votedFor reverts to Nil (non-persistent)
3. s1 recovers as Follower at term 0 with votedFor=Nil
4. s2 starts election at term 2, s1 votes for s2 (legitimate — s1 doesn't remember voting in term 1)
5. s3 also starts election at term 2, s1 votes for s3 (double-vote! s1 already voted for s2 at term 2 but forgot)
6. Both s2 and s3 achieve quorum: s2 gets {s1, s2}, s3 gets {s1, s3}
7. Two leaders at term 2 — ElectionSafety violated

### Root Cause

goraft stores `currentTerm` and `votedFor` as plain struct fields in memory (server.go:118,120). The `writeConf()` function (server.go:1407-1434) only persists `commitIndex` and peer configuration — it never saves term or vote state to stable storage. After a crash and restart, these revert to zero values, allowing the server to vote again in a term it already participated in.

### Affected Code

- `server.go:118`: `currentTerm` is a plain `uint64` field, never persisted
- `server.go:120`: `votedFor` is a plain `string` field, never persisted
- `server.go:1407-1434`: `writeConf()` only saves commitIndex + peers, not term/vote

### Recommendation

Persist `currentTerm` and `votedFor` to stable storage before responding to any RPC. The Raft paper (Section 5.2) explicitly requires these fields to be persistent.

---

## Bug 2: Incorrect Log Comparison Rejects Valid Candidates

- **Bug Family**: 2 (Incorrect election safety — wrong || log comparison)
- **Severity**: Critical
- **Invariant violated**: LeaderCompleteness
- **Config**: MC_hunt_family2.cfg
- **Counterexample**: 46 states (output/MC_hunt_family2.out)

### Trace Summary

1. Leader s1 at term 1 appends entries and replicates to s2 (committed entries exist)
2. Network partition: s1 loses messages to s3
3. s3 starts election at term 2 with a shorter log but higher term
4. s2 rejects s3's vote request even though s3 has a higher last log term
5. Due to the wrong `||` comparison: `lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm` (server.go:1087), s2 rejects s3 because s2's index is larger, even though s3's term is higher
6. A candidate that should win the election (per correct Raft) is rejected
7. This leads to a scenario where a new leader is elected without all committed entries — LeaderCompleteness violated

### Root Cause

The log up-to-date check at server.go:1087 uses `||` (OR) instead of the correct lexicographic comparison. The correct Raft check is: reject if `lastTerm > req.LastLogTerm || (lastTerm == req.LastLogTerm && lastIndex > req.LastLogIndex)`. The implementation's `||` is MORE restrictive — it rejects candidates whose log has a higher term but fewer entries, which is valid in Raft.

### Affected Code

- `server.go:1087`: `if lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm` — should use lexicographic comparison

### Recommendation

Replace the log comparison with the correct lexicographic check from the Raft paper (Section 5.4.1):
```go
if lastTerm > req.LastLogTerm || (lastTerm == req.LastLogTerm && lastIndex > req.LastLogIndex) {
    // reject
}
```

---

## Bug 3: Leader Commits Previous-Term Entries Without Term Check

- **Bug Family**: 3 (Commit without term check — Figure 8 scenario)
- **Severity**: Critical
- **Invariant violated**: CommitTermSafety
- **Config**: MC_hunt_family3.cfg
- **Counterexample**: 68 states (output/MC_hunt_family3.out)

### Trace Summary

1. Leader s1 at term 1 appends and partially replicates entries
2. Leader changes: s2 becomes leader at term 2
3. s2 replicates entries from its term via AppendEntries
4. AE responses arrive with `resp.append = true` (entries replicated are from current term)
5. The median commit index computation (server.go:1014-1022) advances commitIndex to an index where the entry's term is from the PREVIOUS leader's term (term 1), not the current term (term 2)
6. CommitTermSafety violated: leader's commitIndex points to a previous-term entry

### Root Cause

The commit advancement in processAppendEntriesResponse (server.go:1008-1030) computes the median matchIndex among synced peers and sets commitIndex to that value WITHOUT checking that the entry at that index is from the current term. The Raft paper (Section 5.4.2) explicitly requires: "a leader does not commit entries from previous terms by counting replicas — only entries from the leader's current term are committed."

The goraft implementation relies on `syncedPeer` gating (server.go:1004-1006, 1009) but this only checks whether the LAST replicated entry is from the current term, not whether the commit target index itself has a current-term entry.

### Affected Code

- `server.go:1022`: `commitIndex := indices[s.QuorumSize()-1]` — no term check on the entry at this index
- `server.go:1008-1030`: Missing `log[commitIndex].term == currentTerm` guard (Raft Section 5.4.2)

### Recommendation

Add a term check before advancing commitIndex:
```go
if commitIndex > committedIndex && s.log.getEntry(commitIndex).Term() == s.currentTerm {
    s.log.setCommitIndex(commitIndex)
}
```

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 4 (Snapshot term validation) | MC_hunt_family4.cfg | 382M states, 1.3M traces | No violation — snapshot flow may require additional state transitions not reachable with current bounds |
| 5 (Stale heartbeat term) | MC_hunt_family5.cfg | 208M states, 538K traces | No violation — likely benign: followers correctly reject stale-term AEs via term check (server.go:942-944) |

## Spec Fixes During Convergence

1. **Timeout**: Clear `votesGranted` when Follower becomes Candidate (Case B — implementation creates fresh vote tracking in candidateLoop)
2. **HandleAppendEntriesRequest**: Conflict-aware log truncation — only truncate at conflicting entries, preserve existing log when AE entries already match (Raft paper Section 5.3)
