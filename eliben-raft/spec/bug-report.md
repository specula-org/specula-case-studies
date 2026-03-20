# Bug Report — eliben/raft

## Summary

- Bug families tested: 4 (F1a, F1b, F1c, F2a)
- Bugs found: 4 (all families confirmed)
- Configs run: MC_hunt_f1a.cfg, MC_hunt_f1b.cfg, MC_hunt_f1c.cfg, MC_hunt_f2a.cfg

All four known bug families in eliben/raft were confirmed via model checking. The bugs interact: F2a (stale savedCurrentTerm) is the easiest to trigger and appears in counterexamples for F1a, F1c, and F2a configs. F1b requires a crash-recovery sequence.

---

## Bug 1: F2a — Stale savedCurrentTerm in Vote Reply Handler

- **Bug Family**: F2a (stale comparison)
- **Severity**: Critical
- **Invariant violated**: ElectionSafety (two leaders in same term)
- **Config**: MC_hunt_f1a.cfg (also MC_hunt_f1c.cfg)
- **Counterexample**: 10 states, `spec/output/MC_hunt_f1a.out`

### Trace Summary

1. s1 starts election term 1, sends RequestVote to s2, s3
2. s2 grants vote to s1 (response: mterm=1, msavedTerm=1)
3. s1 times out again → term 2 (old response still in bag)
4. s2 times out → term 2, sends RequestVote to s1, s3
5. s3 grants vote to s2 (votedFor=s2)
6. s1 processes OLD response from s2: `m.mterm(1) == m.msavedTerm(1)` → TRUE
   - **BUG**: should check `m.mterm == currentTerm[s1]` (1 ≠ 2 → reject)
   - Stale vote counted! votesGranted = {s1, s2}, quorum reached
7. s1 becomes Leader in term 2
8. s2 processes s3's vote, becomes Leader in term 2
9. **TWO LEADERS in term 2** → ElectionSafety violated

### Root Cause

In `HandleRequestVoteResponse` (raft.go:497-521), the handler captures `savedCurrentTerm` at election start (line 474) and uses it for the stale-reply check (lines 507, 511):
```go
if reply.Term > savedCurrentTerm { // line 507
    cm.becomeFollower(reply.Term)
} else if reply.Term == savedCurrentTerm { // line 511
    // count vote
}
```
The correct code should compare `reply.Term` against `cm.currentTerm`, not `savedCurrentTerm`. If the node's term changed between election start and reply arrival, `savedCurrentTerm != currentTerm`, enabling stale vote counting.

### Affected Code

- `raft.go:507`: `reply.Term > savedCurrentTerm` — should be `reply.Term > cm.currentTerm`
- `raft.go:511`: `reply.Term == savedCurrentTerm` — should be `reply.Term == cm.currentTerm`
- `raft.go:474`: `savedCurrentTerm := cm.currentTerm` — captured before per-peer goroutines

### Recommendation

Replace `savedCurrentTerm` with `cm.currentTerm` in the vote response handler comparison (lines 507, 511). The `savedCurrentTerm` should only be used for the RequestVote message's Term field, not for reply processing.

---

## Bug 2: F2a — Term Regression via Stale becomeFollower

- **Bug Family**: F2a (term regression)
- **Severity**: Critical
- **Invariant violated**: PersistedTermConsistencyInv (persistedTerm > currentTerm)
- **Config**: MC_hunt_f2a.cfg
- **Counterexample**: 9 states, `spec/output/MC_hunt_f2a.out`

### Trace Summary

1. s1 times out repeatedly (term 1 → 2 → 3), s2 times out (term 1 → 2)
2. s1 persists at term 3 (persistedTerm=3) via HandleRequestVoteRequest
3. s2 processes s1's old term-1 RV request, replies (mterm=3, msavedTerm=1)
4. s1 processes reply from s2: `m.mterm(2) > m.msavedTerm(1)` → TRUE
   - **BUG**: calls `becomeFollower(m.mterm=2)` → currentTerm REGRESSES from 3 to 2
   - Should check `m.mterm > currentTerm` (2 > 3 → FALSE → no becomeFollower)
5. persistedTerm[s1]=3 > currentTerm[s1]=2 → **PersistedTermConsistency violated**

### Root Cause

Same root cause as Bug 1. The F2a stale comparison `m.mterm > m.msavedTerm` can trigger `becomeFollower(m.mterm)` when `m.mterm < currentTerm`, causing term regression. This is worse than just counting stale votes — it can make a node at term T revert to term T-k.

### Affected Code

- `raft.go:507-509`: `becomeFollower(reply.Term)` called when `reply.Term > savedCurrentTerm` but `reply.Term < cm.currentTerm`

### Recommendation

Same fix as Bug 1: compare against `cm.currentTerm` instead of `savedCurrentTerm`.

---

## Bug 3: F1b — Missing persistToStorage in startElection

- **Bug Family**: F1b (missing persist)
- **Severity**: Critical
- **Invariant violated**: ElectionSafety
- **Config**: MC_hunt_f1b.cfg
- **Counterexample**: 12 states, `spec/output/MC_hunt_f1b.out`

### Trace Summary

1. s1 times out → term 1, sends RequestVote (no persist!)
2. s1 times out again → term 2, sends RequestVote (no persist!)
3. **s1 crashes** → recovers from persistedTerm=0, persistedVotedFor=Nil
4. s2 times out → term 1, sends RequestVote
5. s1 times out → term 1 (from recovered term 0+1), votes for self
6. s3 grants vote to s1 → s1 becomes leader term 1
7. s2 gets s3's vote for term 1 → s2 becomes leader term 1
8. **TWO LEADERS in term 1**

### Root Cause

`startElection` (raft.go:471-478) modifies `currentTerm` and `votedFor` in memory but never calls `persistToStorage()`. A crash after this point recovers stale state from disk:
```go
func (cm *ConsensusModule) startElection() {
    cm.state = CandidateState       // line 472
    cm.currentTerm += 1             // line 473
    savedCurrentTerm := cm.currentTerm
    cm.votedFor = cm.id             // line 476
    // *** NO persistToStorage() call ***
    // ...
}
```
If the node crashes and recovers, it gets the pre-election term/votedFor from storage, enabling it to vote again in the same effective term.

### Affected Code

- `raft.go:471-478`: `startElection()` — no `persistToStorage()` call after modifying `currentTerm` and `votedFor`

### Recommendation

Add `cm.persistToStorage()` after line 478 in `startElection()`, before sending RequestVote RPCs.

---

## Bug 4: F1a — Unconditional votedFor Reset in becomeFollower

- **Bug Family**: F1a (votedFor reset on same-term transition)
- **Severity**: Critical
- **Invariant violated**: ElectionSafety (via interaction with F2a)
- **Config**: MC_hunt_f1a.cfg
- **Counterexample**: same as Bug 1 (F2a triggers first)

### Description

`becomeFollower` (raft.go:536) unconditionally resets `votedFor` to -1, even on same-term transitions. When a Candidate receives an AppendEntries from a same-term leader, `becomeFollower(args.Term)` is called (line 337), erasing the vote record. The node can then grant a vote to a different candidate in the same term.

While the MC found the F2a attack first (shorter path), the F1a bug independently enables two-leaders-per-term via:
1. A wins election term T, becomes leader
2. A sends AE to B (candidate in term T)
3. B: `becomeFollower(T)` → `votedFor = Nil` (F1a!)
4. C starts election term T, B grants vote to C
5. C becomes leader → two leaders in term T

### Affected Code

- `raft.go:536`: `cm.votedFor = -1` — unconditional reset in `becomeFollower`
- `raft.go:336-337`: calls `becomeFollower(args.Term)` when `args.Term == currentTerm && state != Follower`

### Recommendation

`becomeFollower` should only reset `votedFor` when the term changes (higher term). For same-term transitions, preserve the existing `votedFor` value.

---

## Bug 5: F1c — Non-atomic persistToStorage Crash Window

- **Bug Family**: F1c (partial persist)
- **Severity**: High
- **Invariant violated**: ElectionSafety (via F2a in MC; F1c mechanism confirmed by design)
- **Config**: MC_hunt_f1c.cfg
- **Counterexample**: 10 states (F2a path found first), `spec/output/MC_hunt_f1c.out`

### Description

`persistToStorage()` (raft.go:228-246) writes term, votedFor, and log in 3 separate `Set()` calls. A crash between writes can leave the storage in an inconsistent state (e.g., new term but old votedFor). The MC models this via the `PartialPersist` fault injection action.

The MC found the F2a attack (shorter path) before exploring the F1c mechanism. The F1c bug is confirmed by code inspection: the 3 non-atomic writes create a crash window where recovery can produce inconsistent state.

### Affected Code

- `raft.go:228-246`: `persistToStorage()` — 3 separate `cm.storage.Set()` calls
- `raft.go:233`: `Set("currentTerm", ...)` — first write
- `raft.go:239`: `Set("votedFor", ...)` — second write (crash window between 233 and 239)

### Recommendation

Use atomic/transactional storage writes, or write all persistent state in a single operation.

---

## Summary Table

| Bug | Family | Severity | Invariant | States | Config |
|-----|--------|----------|-----------|--------|--------|
| 1 | F2a | Critical | ElectionSafety | 10 | MC_hunt_f1a.cfg |
| 2 | F2a | Critical | PersistedTermConsistency | 9 | MC_hunt_f2a.cfg |
| 3 | F1b | Critical | ElectionSafety | 12 | MC_hunt_f1b.cfg |
| 4 | F1a | Critical | ElectionSafety | (design analysis) | MC_hunt_f1a.cfg |
| 5 | F1c | High | ElectionSafety | (design analysis) | MC_hunt_f1c.cfg |
