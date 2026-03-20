# Modeling Brief: eliben/raft

## 1. System Overview

- **System**: eliben/raft — Educational Go Raft consensus library (blog series companion)
- **Language**: Go, ~1,064 LOC core logic (part3/raft/)
- **Protocol**: Raft (Ongaro & Ousterhout, 2014) — elections, log replication, persistence, conflict resolution optimization
- **Key architectural choices**:
  - Single mutex (`cm.mu`) protects all ConsensusModule state
  - RPC reply goroutines capture state snapshots (`savedCurrentTerm`) before round-trips, revalidate after
  - `becomeFollower()` unconditionally resets `votedFor = -1`, even on same-term transitions (raft.go:536)
  - `persistToStorage()` writes currentTerm, votedFor, and log in three separate `Set` calls (raft.go:228-246)
  - `startElection()` modifies persistent state but does NOT call `persistToStorage()` (raft.go:471-478)
- **Concurrency model**: Main state machine protected by single mutex; background goroutines for election timer, heartbeat loop, commit channel sender, and per-peer RPC handlers
- **Not implemented**: PreVote, snapshots, configuration changes, leadership transfer

## 2. Bug Families

### Family 1: Vote Safety Violations (HIGH)

**Mechanism**: Multiple independent paths where the single-vote-per-term invariant can be violated — through votedFor reset, missing persistence, or non-atomic persistence.

**Evidence**:
- Code analysis: raft.go:532-540 — `becomeFollower()` resets `votedFor = -1` unconditionally. Called at line 337 when a Candidate receives AppendEntries from the same-term leader. Since the term doesn't change, the node can subsequently grant a vote to a different candidate in the same term, enabling two leaders.
- Code analysis: raft.go:471-478 — `startElection()` increments `currentTerm` and sets `votedFor = cm.id` but never calls `persistToStorage()`. Crash-recovery allows re-voting in the same term.
- Code analysis: raft.go:228-246 — `persistToStorage()` writes currentTerm (line 233), then votedFor (line 239), then log (line 245) in separate `Set` calls. Crash between currentTerm and votedFor writes leaves inconsistent persistent state.

**Affected code paths**:
- `becomeFollower()` (raft.go:532-540) — called from 5 locations
- `startElection()` (raft.go:471-528) — persistence gap
- `persistToStorage()` (raft.go:228-246) — non-atomic writes
- `RequestVote` handler (raft.go:270-298) — grants vote based on `votedFor == -1`

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor`, `persistedLog` (separate from volatile state)
- Actions: Split `HandleRequestVoteRequest` into grant-with-higher-term path that calls `becomeFollower` (resets votedFor). Model `Crash` action that recovers from persisted state. Model `StartElection` without persisting (current behavior) to check if it enables double-vote.
- Granularity: `persistToStorage` should be split into 2-3 atomic steps (term write, votedFor write, log write) with `Crash` possible between each.
- Key invariant: `ElectionSafety` — at most one leader per term. The `becomeFollower` votedFor reset (F1a) may be the simplest path to violation.

**Priority**: High
**Rationale**: Three independent mechanisms that each threaten the most fundamental Raft safety property. The becomeFollower votedFor reset (F1a) is a live bug in the current code — no crash needed. Model checking can explore all three paths systematically.

---

### Family 2: Stale State in Asynchronous RPC Replies (HIGH)

**Mechanism**: State captured before an RPC round-trip is used after the reply arrives without verifying the node's state hasn't changed. The round-trip creates a window where term changes, elections, or state transitions can invalidate the captured snapshot.

**Evidence**:
- Issue #25 (OPEN): raft.go:511 — `reply.Term == savedCurrentTerm` check passes, but `savedCurrentTerm != cm.currentTerm` (a new election incremented the term). Node becomes leader with votes from term T while `currentTerm` is T+1. Can produce two leaders in the same term.
- Issue #14 (FIXED, commit acfa211): AE reply handler compared `reply.Term > savedCurrentTerm` instead of `reply.Term > cm.currentTerm`, causing term regression.
- Issue #13 (FIXED, PR #15): Leader heartbeat goroutine sent AEs after stepping down — no state guard at top of `leaderSendAEs()`.
- Code analysis: raft.go:607-608, 622 — `savedCurrentTerm` captured at line 607 is used to construct AE at line 622 after the lock is released. If the term changed, AE is sent with a stale term.
- Code analysis: raft.go:483-486 — RequestVote goroutine reads log state lazily (not at election-start time), creating inconsistent (term, lastLogIndex, lastLogTerm) tuples.

**Affected code paths**:
- `startElection()` reply handlers (raft.go:497-521)
- `leaderSendAEs()` reply handlers (raft.go:632-698)

**Suggested modeling approach**:
- Variables: No additional variables needed — the stale-state pattern is captured by the interleaving of actions.
- Actions: Model `StartElection` as spawning pending vote requests. Model `HandleVoteReply` as a separate action where the node may have changed term since sending. Include the guards present in the code (state check, term comparison) and verify they are sufficient.
- Key: The `startElection` + `HandleVoteReply` interleaving where a second election fires between send and receive is the critical path.

**Priority**: High
**Rationale**: Issue #25 is an open, unacknowledged bug. Issues #13 and #14 were confirmed production bugs from the same pattern. The stale-state pattern is systematic and affects both election and replication paths.

---

### Family 3: Shutdown Race Conditions (LOW)

**Mechanism**: Concurrent shutdown creates races between `Stop()`, channel closure, and background goroutines that send on those channels after releasing the mutex.

**Evidence**:
- Code analysis: raft.go:670-672 — After `cm.mu.Unlock()`, `leaderSendAEs` goroutine sends on `newCommitReadyChan` and `triggerAEChan`. If `Stop()` (line 193) closes `newCommitReadyChan` between the unlock and the send, Go panics with "send on closed channel".
- Historical: commit a525c4b — Fixed deadlock where `Stop()` held `cm.mu` while waiting on WaitGroup.
- Historical: commit c42d400 — Fixed deadlock in `leaderSendAEs()` where `defer cm.mu.Unlock()` held the lock across channel sends.
- Code analysis: raft.go:556, 527, 539 — Leader heartbeat and election timer goroutines not tracked by any WaitGroup; can outlive `Shutdown()`.

**Priority**: Low (for TLA+ modeling)
**Rationale**: Shutdown races are Go concurrency bugs, not protocol logic issues. Better verified by Go race detector and stress tests.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Leader election (RequestVote) | Family 1 & 2: core safety property at risk | Standard Raft election with `votedFor` tracking |
| Log replication (AppendEntries) | Context for commit advancement | Standard Raft replication with `nextIndex`/`matchIndex` |
| `becomeFollower` votedFor reset | Family 1: live bug — resets votedFor on same-term transition | Model `becomeFollower` as resetting `votedFor` to Nil even when `term = currentTerm` |
| Stale vote reply (Issue #25) | Family 2: open bug — leader elected with wrong-term votes | Model election with asynchronous RPC: vote request sent, term can change before reply processed |
| Non-atomic persistence + crash | Family 1: crash between writes violates vote safety | Split `persistToStorage` into 2+ steps. Add `Crash` action recovering from persisted state |
| Missing persist in startElection | Family 1: no persist after term+votedFor change | Model `StartElection` without persistence write |
| Commit advancement (Section 5.4.2) | Validate correctness of leader commit logic | Standard Raft commit with current-term-only rule |
| Stale AE term in leaderSendAEs | Family 2: AEs constructed with captured-then-stale term | Model AE construction as separate step from AE processing |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Shutdown / Stop() | Family 3: Go concurrency bug, not protocol logic. Better found by race detector. |
| Channel buffering | Implementation detail of Go channels; no protocol semantics |
| CommitEntry.Term semantic | Minor: current-term vs entry-term in commit notification. Doesn't affect consensus. |
| Election timer reset overshoot | Liveness concern only; `becomeFollower` resets timer when not hearing from leader. Not a safety issue. |
| Snapshots, config changes, PreVote | Not implemented in this codebase. |
| RPCProxy fault injection | Testing infrastructure, not production code. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| becomeFollower votedFor reset | (modify existing votedFor handling) | Model unconditional votedFor reset on same-term becomeFollower | Family 1 |
| Non-atomic persistence | `persistedTerm`, `persistedVotedFor`, `persistedLog` | Model crash between separate persistence writes | Family 1 |
| Missing startElection persist | `electionPersisted` flag or omit persist step | Model crash after term increment but before persist | Family 1 |
| Asynchronous RPC replies | `pendingVoteRequests`, `pendingAERequests` | Model state changes between RPC send and reply processing | Family 2 |
| Crash and recovery | (recover from persisted* variables) | Validate persistence correctness | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Family 1, Family 2 |
| LogMatching | Safety | If two logs contain an entry with the same index and term, the logs are identical through that index | Standard |
| LeaderCompleteness | Safety | If an entry is committed in a given term, it is present in the logs of all leaders for higher terms | Standard |
| VoteOncePerTerm | Safety | Each server votes for at most one candidate per term (persistent votedFor invariant) | Family 1 |
| PersistenceConsistency | Safety | After crash recovery, (persistedTerm, persistedVotedFor) form a valid pair — if term T is persisted, votedFor reflects a vote in term T or is Nil | Family 1 |
| NoStaleTermLeader | Safety | A node that becomes leader has currentTerm equal to the term for which it received a majority of votes | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1a | becomeFollower resets votedFor on same-term AE (raft.go:337+536) | ElectionSafety (two leaders in same term) | 1 |
| F1b | startElection doesn't persist term+votedFor (raft.go:471-478) | VoteOncePerTerm after crash-recovery | 1 |
| F1c | Non-atomic persistToStorage crash window (raft.go:228-246) | PersistenceConsistency, VoteOncePerTerm | 1 |
| F2a | Issue #25: stale vote reply — leader elected for wrong term (raft.go:511) | NoStaleTermLeader, ElectionSafety | 2 |
| F2c | Stale savedCurrentTerm in AE construction (raft.go:607-622) | ElectionSafety (phantom leader heartbeats) | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| F3a | Send on closed channel during concurrent shutdown (raft.go:670-672) | Go race detector + stress test with concurrent Stop() and Submit() |
| F3b | Leader/election goroutines outlive Shutdown() (raft.go:556, 527, 539) | Goroutine leak detector after Shutdown() returns |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| F4a | Election timer reset on all becomeFollower calls, not just AE/vote-grant (raft.go:537) | Only reset `electionResetEvent` in AE handler and vote-grant path, not in becomeFollower |
| F5a | CommitEntry.Term uses server's currentTerm instead of entry.Term (raft.go:728, 743) | Use `entry.Term` at line 743 instead of `savedTerm` |
| F6a | Issue #16: out-of-order AE replies can temporarily regress nextIndex/matchIndex | Add monotonicity guard: `if ni + len(entries) > cm.nextIndex[peerId]` |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/eliben-raft/analysis-report.md`
- **Key source files**:
  - `artifact/raft/part3/raft/raft.go` (748 lines — state machine, RPC handlers, election, replication)
  - `artifact/raft/part3/raft/server.go` (269 lines — RPC transport, connection management)
  - `artifact/raft/part3/raft/storage.go` (47 lines — persistence interface, in-memory impl)
- **GitHub issues**: #25 (stale vote reply, open), #14 (stale term comparison, fixed), #13 (leader heartbeat race, fixed), #16 (nextIndex regression, won't fix)
- **Key commits**: `acfa211` (fix #14), `b3696d9` (fix #13), `c42d400` (deadlock fix), `65fc436` (nextIndex init), `edd6314` (data race)
- **Reference**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
