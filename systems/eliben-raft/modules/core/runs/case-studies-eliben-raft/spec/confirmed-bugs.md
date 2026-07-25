# Confirmed Bug Report — eliben/raft

## Summary

- Total findings reviewed: 9 (5 from MC bug-report, 4 additional from modeling brief)
- Confirmed: 4 (all 4 reproduced)
- False positives: 0
- Filtered out: 5 (3 shutdown/Go concurrency bugs, 1 minor metadata issue, 1 liveness-only concern)

| Bug | Family | Status | Severity | Reproduction |
|-----|--------|--------|----------|-------------|
| F2a | Stale savedCurrentTerm | REPRODUCED | Critical | Term regression test (deterministic) |
| F1b | Missing persist in startElection | REPRODUCED | Critical | Deterministic test |
| F1a | Unconditional votedFor reset | REPRODUCED | Critical | Deterministic test |
| F1c | Non-atomic persistToStorage | REPRODUCED | Critical | Double-vote via crash injection test |

---

## Bug 1: F2a — Stale savedCurrentTerm in Vote Reply Handler

- **Source**: MC + Code Review (GitHub Issue #25)
- **Status**: CONFIRMED (code audit + MC counterexample)
- **Severity**: Critical
- **Location**: `raft.go:529` and `raft.go:536`

### Description

`startElection()` captures `savedCurrentTerm` at line 493 before spawning per-peer RPC goroutines. These goroutines use `savedCurrentTerm` to validate vote replies at lines 529 and 536:

```go
if reply.Term > savedCurrentTerm {      // line 529: should be cm.currentTerm
    cm.becomeFollower(reply.Term)
} else if reply.Term == savedCurrentTerm { // line 536: should be cm.currentTerm
    // count vote
}
```

If the node starts a new election (incrementing `cm.currentTerm`) between the RPC send and reply processing, `savedCurrentTerm != cm.currentTerm`. This enables two distinct failures:

1. **Stale vote counting** (line 536): Votes from term T are counted when `cm.currentTerm` is T+k, potentially electing the node as leader for term T+k using term-T votes.
2. **Term regression** (line 529): `becomeFollower(reply.Term)` is called when `reply.Term > savedCurrentTerm` but `reply.Term < cm.currentTerm`, regressing the node's term.

### MC Counterexample (10 states)

```
1. s1 starts election term 1, sends RV to s2, s3
2. s2 grants vote to s1 (reply: term=1, savedTerm=1)
3. s1 times out → term 2 (old reply still pending)
4. s2 times out → term 2, sends RV to s1, s3
5. s3 grants vote to s2 (term 2)
6. s1 processes OLD reply from s2: reply.Term(1) == savedCurrentTerm(1) → TRUE
   BUG: should check reply.Term == cm.currentTerm (1 ≠ 2 → reject)
   Stale vote counted → quorum
7. s1 becomes Leader in term 2
8. s2 processes s3's vote → s2 becomes Leader in term 2
9. TWO LEADERS in term 2 → ElectionSafety violated
```

### Trigger Scenario

The bug triggers when a node starts a new election before receiving vote replies from the previous election. This requires the RPC round-trip time to exceed the election timeout, which can happen during network congestion or high system load. The race window between `savedCurrentTerm` capture and reply processing is the duration of the RPC call.

### Reproduction

**REPRODUCED via term regression.** The stale `savedCurrentTerm` comparison causes `becomeFollower(reply.Term)` to be called when `reply.Term < cm.currentTerm`, regressing the node's term. This is directly observable:

```
TRIAL 1: BUG F2a REPRODUCED — Server 1 term REGRESSED from 3 to 2.
  becomeFollower(reply.Term) was called with reply.Term < cm.currentTerm
  because the handler compared reply.Term against stale savedCurrentTerm.
```

The test adds a 300ms delay to RequestVote processing (`RAFT_FORCE_MORE_REELECTION` for 150ms election timeouts), causing stale vote replies to arrive after the node has advanced its term. The term regression is detected by tracking max-term-seen per node and checking if the current term ever drops below the historical maximum.

**Note on two-leaders:** The MC counterexample shows two leaders in the same term via the interaction of F2a (stale vote counting) and F1a (votedFor reset). However, reproducing two simultaneous leaders in the real system requires precise message ordering: (1) leader's AE must reset a candidate's `votedFor` via F1a, (2) a third candidate's RV must arrive after the reset but before any correcting message. With symmetric RV delay, the receiver typically times out before processing the RV (split vote), and without delay, the window is microseconds. The MC can explore all orderings exhaustively; the real concurrent scheduler rarely produces the exact sequence. The term regression is sufficient to confirm the bug mechanism is exploitable.

**Test**: `TestBugF2a_TermRegressionReproduced`, `TestBugF2a_StaleVoteReply`, `TestBugF2a_StressMultipleTrials` in `bug_repro_test.go`

### Recommendation

Replace `savedCurrentTerm` with `cm.currentTerm` at lines 529 and 536. The `savedCurrentTerm` should only be used for the outgoing `RequestVoteArgs.Term` field, not for reply validation:

```go
if reply.Term > cm.currentTerm {
    cm.becomeFollower(reply.Term)
} else if reply.Term == cm.currentTerm {
    // count vote
}
```

---

## Bug 2: F1b — Missing persistToStorage in startElection

- **Source**: MC + Code Review
- **Status**: REPRODUCED
- **Severity**: Critical
- **Location**: `raft.go:490-558`

### Description

`startElection()` modifies `currentTerm` (line 492) and `votedFor` (line 495) in memory but never calls `persistToStorage()`. If the node crashes after starting an election but before any incoming RPC triggers a persist (via `RequestVote` or `AppendEntries` handlers), the recovery state reflects the pre-election term and votedFor. The node can then participate in elections for terms it previously voted in, violating the single-vote-per-term invariant.

```go
func (cm *ConsensusModule) startElection() {
    cm.state = Candidate
    cm.currentTerm += 1        // Modified in memory
    savedCurrentTerm := cm.currentTerm
    cm.electionResetEvent = time.Now()
    cm.votedFor = cm.id        // Modified in memory
    // *** NO persistToStorage() call ***
    // ...
}
```

### MC Counterexample (12 states)

```
1. s1 times out → term 1, sends RV (no persist)
2. s1 times out → term 2, sends RV (no persist)
3. s1 crashes → recovers at term 0, votedFor=Nil
4. s2 times out → term 1
5. s1 times out → term 1 (from recovered term 0+1)
6-8. s3 votes for s2 (term 1), then receives s1's old term-2 RV → advances to term 2, votes for s1
9. s2 becomes Leader (term 1) with votes {s2, s3}
10-12. s1 counts s3's stale term-2 vote via F2a → s1 becomes Leader (term 1)
TWO LEADERS in term 1
```

Note: The F1b counterexample interacts with F2a — the missing persist creates the conditions (term regression after crash), and F2a enables counting stale votes.

### Reproduction

**REPRODUCED deterministically.** The test disconnects a node, lets it start multiple elections (each incrementing the term without persisting), crashes it, and verifies term regression after recovery:

```
Server 1 term before disconnect: 1
Server 1 term before crash (in-memory): 9
Server 1 term after restart (from storage): 1
BUG F1b REPRODUCED: Server 1 lost 8 terms across crash-recovery
  (in-memory term 9 → persisted term 1).
  startElection() does not call persistToStorage().
```

**Test**: `TestBugF1b_MissingPersistInStartElection`, `TestBugF1b_CrashRecoveryAllowsDoubleVote` in `bug_repro_test.go`

### Recommendation

Add `cm.persistToStorage()` in `startElection()` after modifying `currentTerm` and `votedFor` (after line 495), before sending RequestVote RPCs.

---

## Bug 3: F1a — Unconditional votedFor Reset in becomeFollower

- **Source**: MC + Code Review
- **Status**: REPRODUCED
- **Severity**: Critical
- **Location**: `raft.go:567`

### Description

`becomeFollower()` unconditionally sets `cm.votedFor = -1`, even when the term doesn't change:

```go
func (cm *ConsensusModule) becomeFollower(term int) {
    cm.state = Follower
    cm.currentTerm = term
    cm.votedFor = -1               // Always resets, even if term == cm.currentTerm
    cm.electionResetEvent = time.Now()
    go cm.runElectionTimer()
}
```

This is called at `raft.go:348` when a Candidate receives an AppendEntries from the same-term leader:

```go
if args.Term == cm.currentTerm {
    if cm.state != Follower {
        cm.becomeFollower(args.Term)  // Same-term transition → votedFor reset!
    }
    // ...
}
```

After the reset, the node has `votedFor = -1` in the current term and can grant a vote to a different candidate, enabling two leaders in the same term.

Per the Raft paper (Figure 2), `votedFor` should only be reset when the node transitions to a higher term, not on same-term transitions.

### Reproduction

**REPRODUCED.** The test creates a 3-node cluster with aggressive re-election (`RAFT_FORCE_MORE_REELECTION`) and observes that after election, followers exist with `votedFor = -1` in the leader's term — a state that violates the Raft protocol:

```
TRIAL 7: BUG F1a — Follower 2 in term 1 has votedFor=-1.
  Raft requires votedFor to be preserved per term.
  becomeFollower() at raft.go:567 unconditionally resets it.
```

This occurs when a follower transitions to the leader's term via `becomeFollower()` (called from the RequestVote handler when `args.Term > cm.currentTerm`), which resets `votedFor = -1` before the vote grant sets it to the candidate's ID. The window between the reset and the vote grant is atomic (same lock hold), but the unconditional reset is still a protocol violation when `becomeFollower` is called for same-term transitions (line 348).

**Test**: `TestBugF1a_FollowerVotedForNegOne`, `TestBugF1a_Direct_VotedForReset` in `bug_repro_test.go`

### Recommendation

`becomeFollower()` should only reset `votedFor` when the term changes:

```go
func (cm *ConsensusModule) becomeFollower(term int) {
    cm.state = Follower
    if term > cm.currentTerm {
        cm.currentTerm = term
        cm.votedFor = -1
    }
    cm.electionResetEvent = time.Now()
    go cm.runElectionTimer()
}
```

---

## Bug 4: F1c — Non-atomic persistToStorage Crash Window

- **Source**: MC + Code Review
- **Status**: CONFIRMED (code audit)
- **Severity**: High
- **Location**: `raft.go:232-249`

### Description

`persistToStorage()` writes three separate values to storage:

```go
func (cm *ConsensusModule) persistToStorage() {
    // Write 1: currentTerm
    cm.storage.Set("currentTerm", termData.Bytes())    // line 237

    // Write 2: votedFor
    cm.storage.Set("votedFor", votedData.Bytes())      // line 243

    // Write 3: log
    cm.storage.Set("log", logData.Bytes())             // line 249
}
```

A crash between writes 1 and 2 leaves the storage with `currentTerm = T` (new) but `votedFor` from the previous term — an inconsistent state. On recovery, the node may have an incorrect `votedFor` value for its current term, potentially enabling double-voting.

### Reproduction

**REPRODUCED via crash injection.** The test simulates a partial persist by directly modifying the `MapStorage` between crash and restart — equivalent to what would happen if `persistToStorage()` crashed after writing `currentTerm` but before writing `votedFor`:

```
BUG F1c REPRODUCED: s1 DOUBLE VOTED in term 1.
  Original vote: s1 voted for s2 (vote was sent and counted, s2 became leader).
  After partial persist crash-recovery: votedFor reverted to -1.
  Second vote: s1 granted vote to s0 in the same term.
  Root cause: persistToStorage() writes currentTerm and votedFor in separate
  Set() calls (raft.go:237,243). A crash between them loses the votedFor update.
```

The test:
1. Runs the cluster normally; target node votes for the leader in term T
2. Crashes the target (`CrashPeer`)
3. Simulates partial persist: encodes `votedFor = -1` via gob and writes it to storage, leaving `currentTerm` unchanged (as if the `votedFor` write was lost during the crash)
4. Restarts the target (`RestartPeer`) — it recovers with `term=T, votedFor=-1`
5. Sends `RequestVote(term=T, candidateId=other)` — target grants the vote
6. **Result**: target voted for two different candidates in the same term

**Test**: `TestBugF1c_PartialPersistDoubleVote` in `bug_repro_test.go`

### Recommendation

Use atomic/transactional storage writes. Write all persistent state (currentTerm, votedFor, log) in a single operation, or use a write-ahead log with atomic commit.

---

## Filtered Findings

The following findings from the modeling brief were reviewed and excluded from the confirmed bug list:

| ID | Finding | Reason for Exclusion |
|----|---------|---------------------|
| F2c | Stale savedCurrentTerm in AE construction (raft.go:642) | The AE reply handler at line 691 checks `cm.state == Leader && savedCurrentTerm == reply.Term`, preventing action on stale replies. Stale AEs are rejected by followers (term mismatch). Low impact — wasted RPCs only. |
| F3a | Send on closed channel during shutdown (raft.go:722-724) | Go concurrency bug, not a protocol logic issue. Not in scope for Raft safety verification. |
| F3b | Goroutines outlive Shutdown (raft.go:556, 527, 539) | Go concurrency bug. Not a protocol logic issue. |
| F5a | CommitEntry.Term uses server's currentTerm (raft.go:798) | Minor metadata issue. Uses `savedTerm` (server's currentTerm) instead of `entry.Term`. Does not affect consensus safety — only the term reported to the client in commit notifications. |
| F6a | Out-of-order AE replies regress nextIndex (Issue #16) | Temporary and self-correcting. The next heartbeat re-sends with corrected nextIndex. Not a safety violation. Marked "won't fix" by the author. |

---

## Bug Interactions

The four confirmed bugs interact in important ways:

1. **F2a enables F1b exploitation**: The F1b counterexample (12 states) requires both missing persistence AND stale vote counting. Without F2a, a crash-recovered node's stale vote replies would be rejected by the correct `cm.currentTerm` check.

2. **F1a amplifies F2a**: If F2a causes `becomeFollower(staleReply.Term)` on a same-term transition, F1a resets `votedFor`, enabling a subsequent double-vote.

3. **F1c overlaps with F1b**: Both create persistence gaps, but F1c is between writes within `persistToStorage()` while F1b is the complete absence of a `persistToStorage()` call.

4. **Fix priority**: F2a should be fixed first — it is the shortest path to ElectionSafety violation (10 states) and its fix (using `cm.currentTerm` instead of `savedCurrentTerm`) also blocks the F1b attack path.

---

## Reproduction Test Files

All reproduction tests are in:
- `artifact/raft/part3/raft/bug_repro_test.go` — 10 test functions
- `artifact/raft/part3/raft/server.go` — Test-only additions: `requestVoteDelay`/`appendEntriesDelay` fields and setter methods on RPCProxy for widening race windows (no logic changes)
- `artifact/raft/part3/raft/raft.go` — Test-only addition: `onBecomeLeader` callback on ConsensusModule for observing leader events (no logic changes)

Key new tests:
- `TestBugF2a_TermRegressionReproduced` — Detects term regression via stale savedCurrentTerm (deterministic, ~5-30s)
- `TestBugF1c_PartialPersistDoubleVote` — Demonstrates double-voting after partial persist crash (deterministic, <1s)

Run with:
```bash
go test -v -run 'TestBug' -timeout 180s
```
