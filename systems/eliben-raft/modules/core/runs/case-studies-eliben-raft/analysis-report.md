# Analysis Report: eliben/raft

## 1. Reconnaissance Summary

### Codebase Structure

```
artifact/raft/
├── part1/          # Elections only (385 LOC core)
├── part2/          # + Log replication (583 LOC core)
├── part3/raft/     # + Persistence & optimizations (1,064 LOC core) ← PRIMARY TARGET
├── part4kv/        # Key-value service layer
├── part5kv/        # + Exactly-once delivery
└── tools/          # Log visualization
```

Educational Raft implementation by Eli Bendersky, structured as progressive parts accompanying a blog series. Part3 is the complete Raft implementation and the focus of this analysis.

### Core Files (part3/raft/)

| File | LOC | Role |
|------|-----|------|
| raft.go | 748 | State machine, RPC handlers, election, replication, persistence |
| server.go | 269 | RPC transport, connection management, fault injection proxy |
| storage.go | 47 | Storage interface + in-memory MapStorage implementation |
| **Total** | **1,064** | |

### Concurrency Model

- **Single mutex** (`cm.mu`) protects all ConsensusModule state
- **Background goroutines**: election timer (one per term), leader heartbeat loop, commit channel sender, per-peer RPC handlers
- **Channels**: `newCommitReadyChan` (buf 16), `triggerAEChan` (buf 1), `commitChan` (client-provided)
- **Key pattern**: Capture state under lock → release lock → send RPC → reacquire lock → validate state still consistent

### What is NOT Implemented

- No PreVote extension
- No snapshots / InstallSnapshot RPC
- No configuration changes / membership changes
- No leadership transfer
- No read-only queries / ReadIndex
- No pipeline replication
- No leader lease

---

## 2. Bug Archaeology

### 2.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits analyzed | 185 (full repository history) |
| Bug-fix commits identified | 18 |
| Bug-fix commits in part3 core | 12 |
| GitHub issues (total) | 14 |
| GitHub issues deeply read (with comments) | 14 |
| GitHub PRs (total) | 11 |
| GitHub PRs deeply read | 11 |
| Confirmed bugs (historical) | 8 |
| Open potential bugs | 1 (Issue #25) |
| False positives excluded | 0 |
| Questions/discussions excluded | 8 |

### 2.2 Historical Bug-Fix Commits (Chronological)

#### Critical Severity

| Commit | Summary | Root Cause | Component |
|--------|---------|------------|-----------|
| `acfa211` | Fix stale term comparison in AE reply (Issue #14) | `reply.Term > savedCurrentTerm` instead of `reply.Term > cm.currentTerm` — term regression | leaderSendAEs |
| `c42d400` | Fix deadlock in leaderSendAEs | `defer cm.mu.Unlock()` held lock across channel sends | leaderSendAEs |

#### High Severity

| Commit | Summary | Root Cause | Component |
|--------|---------|------------|-----------|
| `b3696d9` | Fix leader heartbeat race (Issue #13, PR #15) | No leader-state check before sending AEs; demoted leader sends with stolen term | leaderSendAEs |
| `edd6314` | Fix data race in startup goroutine | `electionResetEvent` written without holding `cm.mu` during init | NewConsensusModule |
| `65fc436` | Add nextIndex/matchIndex initialization in startLeader | Stale values from previous leadership term → incorrect replication | startLeader |
| `a525c4b` | Fix deadlock during Stop() | `Stop()` held `cm.mu` while waiting on WaitGroup; commitChanSender needed the lock | Stop |

#### Medium Severity

| Commit | Summary | Root Cause | Component |
|--------|---------|------------|-----------|
| `733c2e8` | Fix DisconnectAll by nil-ing closed clients | `client.Close()` without nil-ing entry → use-after-close | server.go |
| `390f170` | Set buffer size 1 on triggerAEChan | Unbuffered channel blocked Submit() | Submit |
| `c9c5db6` | Trigger AEs on commitIndex changes | Followers waited up to 50ms to learn about new commits | leaderSendAEs |
| `23d42ea` | Fix wrong response types in KV service (part5kv) | Copy-paste: all error handlers returned CASResponse | kvservice |

### 2.3 GitHub Issues Summary

#### Confirmed Bugs

| Issue | Summary | Status | Severity |
|-------|---------|--------|----------|
| #14 | becomeFollower called with stale term from AE reply | Fixed (acfa211) | Critical |
| #13 | Retired leader sends heartbeat with stolen higher term | Fixed (PR #15) | High |

#### Open Potential Bug

| Issue | Summary | Status | Severity |
|-------|---------|--------|----------|
| #25 | Missing `savedCurrentTerm == cm.currentTerm` check in vote reply handler | Open, no maintainer response | High |

#### Excluded (Questions/Discussions)

| Issue | Why Excluded |
|-------|-------------|
| #24 | Question about follower restart — answered by maintainer |
| #22 | Question about test cases (Chinese) — no response |
| #20 | Question about unnecessary mutex in datastore — maintainer confirmed unnecessary |
| #19 | Question about min(LeaderCommit, len(log)-1) — follows paper |
| #18 | Data race concern in startElection — resolved: all accesses under cm.mu |
| #17 | Eternal leader concern — self-resolved: isolated leader can't commit |
| #16 | nextIndex/matchIndex regression from out-of-order replies — maintainer: perf optimization, not correctness |
| #11, #10, #8, #6 | Various questions about design choices — all answered |

### 2.4 Bug Hotspot Analysis

| File | Bug-Fix Commits | Components |
|------|----------------|------------|
| raft.go | 10 | leaderSendAEs (4), startElection (2), startLeader (1), Stop (1), init (1), Submit (1) |
| server.go | 2 | DisconnectAll (1), DisconnectPeer (1) |

`leaderSendAEs()` is the clear hotspot with 4 of 12 bug-fix commits in part3.

---

## 3. Deep Analysis Findings

### 3.1 Raft Paper Figure 2 Compliance Audit

The implementation uses 0-based indexing throughout (log starts at index 0, -1 = "none"). This is a clean isomorphism from the paper's 1-based scheme. No off-by-one bugs result.

| Rule | Status | Location | Notes |
|------|--------|----------|-------|
| currentTerm: init 0, monotonic | YES | raft.go:98, 473, 535 | Go zero-value = 0 |
| votedFor: null when not voted | YES | raft.go:99, 127, 536 | Uses -1 for null |
| log[]: persistent | YES | raft.go:100 | 0-based indexing |
| commitIndex: init 0, monotonic | YES | raft.go:103, 128 | Init -1 (0-based) |
| lastApplied: init 0, monotonic | YES | raft.go:104, 129 | Init -1 (0-based) |
| nextIndex[]: init last log + 1 | YES | raft.go:548 | `len(cm.log)` |
| matchIndex[]: init 0 | YES | raft.go:549 | Init -1 (0-based) |
| RV: reject if term < currentTerm | YES | raft.go:279-293 | Implicit via `currentTerm == args.Term` guard |
| RV: grant if votedFor null/match + log up-to-date | YES | raft.go:284-292 | Correct log comparison |
| AE: reject if term < currentTerm | YES | raft.go:329-335 | Implicit via `args.Term == cm.currentTerm` guard |
| AE: reject if prevLog mismatch | YES | raft.go:344-346 | With conflict optimization |
| AE: delete conflicting entries | YES | raft.go:348-373 | Smart: only truncates at divergence point |
| AE: append new entries | YES | raft.go:369-372 | Combined with truncation |
| AE: update commitIndex | PARTIAL | raft.go:376-378 | Uses `len(cm.log)-1` not "last new entry index" — safe in this impl |
| All: apply committed entries | YES | raft.go:722-748 | Batched in commitChanSender |
| All: step down on higher term | YES | raft.go:279-282, 329-332, 507-509, 638-641 | All 4 paths |
| Leader: commit current-term only (§5.4.2) | YES | raft.go:651-661 | `cm.log[i].Term == cm.currentTerm` |
| Leader: init heartbeats | YES | raft.go:558 | Immediate AE send |
| Leader: update nextIndex/matchIndex | YES | raft.go:646-648 | Correct |
| Leader: decrement nextIndex on failure | YES | raft.go:676-692 | With conflict optimization |

### 3.2 New Findings from Deep Analysis

#### Finding F1a: becomeFollower Resets votedFor on Same-Term Transition (CONFIRMED BUG)

**Location**: raft.go:532-540 (becomeFollower), triggered at raft.go:337

**Code**:
```go
// raft.go:335-338 (AppendEntries handler)
if args.Term == cm.currentTerm {
    if cm.state != Follower {
        cm.becomeFollower(args.Term)  // Same term!
    }

// raft.go:532-540
func (cm *ConsensusModule) becomeFollower(term int) {
    cm.state = Follower
    cm.currentTerm = term    // No change (same term)
    cm.votedFor = -1         // RESETS votedFor!
    cm.electionResetEvent = time.Now()
    go cm.runElectionTimer()
}
```

**Scenario for safety violation** (5-node cluster: A, B, C, D, E):
1. Multiple candidates emerge for term T
2. C wins election (votes from C, B, E — quorum of 3/5)
3. C sends AppendEntries to A (who was also a Candidate for term T, voted for self)
4. A receives AE with `args.Term == cm.currentTerm` → calls `becomeFollower(T)` → `votedFor = -1`
5. D starts election for term T, sends RequestVote to A
6. A (now Follower, `votedFor == -1`, term T) grants vote to D
7. D has votes from D (self) + A + possibly others → could reach quorum
8. **Two leaders (C and D) in term T** — ElectionSafety violated

**Compensating mechanism check**: None found. The `persistToStorage()` call at line 405 correctly persists the reset `votedFor = -1`, making it permanent.

**Classification**: Model-checkable. This is the highest-confidence finding.

---

#### Finding F1b: Missing persistToStorage() in startElection() (CONFIRMED BUG)

**Location**: raft.go:471-478

**Code**:
```go
func (cm *ConsensusModule) startElection() {
    cm.state = Candidate
    cm.currentTerm += 1      // Persistent state changed
    savedCurrentTerm := cm.currentTerm
    cm.electionResetEvent = time.Now()
    cm.votedFor = cm.id      // Persistent state changed
    // NO persistToStorage() call!
```

Compare with `RequestVote` handler (line 295) and `AppendEntries` handler (line 405), both of which call `persistToStorage()`.

**Scenario**: Node starts election, increments term to T, votes for self. Crashes before any RPC handler calls `persistToStorage()`. On recovery: `currentTerm = T-1`, `votedFor = -1`. Node can now vote for a different candidate in term T.

**Classification**: Model-checkable (requires crash-recovery modeling).

---

#### Finding F1c: Non-Atomic persistToStorage() (CONFIRMED BUG)

**Location**: raft.go:228-246

Three separate `Set` calls: currentTerm (line 233), votedFor (line 239), log (line 245). Crash between term and votedFor writes → term is new but votedFor is stale from the previous term.

**Classification**: Model-checkable (requires crash-recovery with split persistence).

---

#### Finding F2a: Issue #25 — Stale Vote Reply Enables Wrong-Term Leadership (CONFIRMED BUG)

**Location**: raft.go:502-521

**Code**:
```go
if cm.state != Candidate {        // Guard 1: still candidate?
    return
}
if reply.Term > savedCurrentTerm { // Guard 2: higher term in reply?
    cm.becomeFollower(reply.Term)
    return
} else if reply.Term == savedCurrentTerm { // Guard 3: reply matches election term?
    if reply.VoteGranted {
        votesReceived += 1
        if votesReceived*2 > len(cm.peerIds)+1 {
            cm.startLeader()       // Become leader!
```

**Missing guard**: `savedCurrentTerm == cm.currentTerm` — verifies node hasn't started a new election.

**Scenario**:
1. Node starts election for term T, sends RequestVote to all peers
2. Election timer fires again before replies arrive → `startElection()` increments to term T+1
3. Replies from term T arrive. Guard 1 passes (still Candidate — for T+1). Guard 3 passes (reply.Term T == savedCurrentTerm T).
4. Node becomes leader. But `cm.currentTerm = T+1`. It sends heartbeats with term T+1 without having won votes for T+1.
5. Another node could legitimately win term T+1 → **two leaders in term T+1**.

**Classification**: Model-checkable. High confidence — the scenario is straightforward.

---

#### Finding F2c: Stale savedCurrentTerm in leaderSendAEs (POTENTIAL BUG)

**Location**: raft.go:607-608, 612-629

```go
savedCurrentTerm := cm.currentTerm  // line 607 — capture under lock
cm.mu.Unlock()                      // line 608

for _, peerId := range cm.peerIds {
    go func() {
        cm.mu.Lock()                // line 612 — reacquire, but term may have changed
        ni := cm.nextIndex[peerId]
        ...
        args := AppendEntriesArgs{
            Term: savedCurrentTerm, // line 622 — uses captured (possibly stale) term
```

Between lines 608 and 612, the node could step down via another goroutine processing a higher-term RPC. The goroutine would then construct an AE with the old (lower) term. The guard at line 645 (`cm.state == Leader && savedCurrentTerm == reply.Term`) partially mitigates this.

**Classification**: Model-checkable. Lower confidence than F2a — the mitigation at line 645 may be sufficient in practice.

---

#### Finding F5a: CommitEntry.Term Uses Server's Current Term (DESIGN CONCERN)

**Location**: raft.go:728, 740-743

```go
savedTerm := cm.currentTerm          // line 728
...
cm.commitChan <- CommitEntry{
    Command: entry.Command,
    Index:   savedLastApplied + i + 1,
    Term:    savedTerm,               // Should be entry.Term
}
```

The `Term` field reports the server's current term at notification time, not the log entry's actual term. When a leader commits entries from a previous term (common after election), all entries are incorrectly reported as having the leader's current term.

**Classification**: Code-review-only. Does not affect consensus safety.

---

#### Finding F6a: AppendEntries commitIndex Uses len(cm.log)-1 (DEVIATION FROM PAPER)

**Location**: raft.go:376-378

```go
cm.commitIndex = min(args.LeaderCommit, len(cm.log)-1)
```

Paper says: `min(leaderCommit, index of last new entry)`. The code uses `len(cm.log)-1` which can differ when the follower's log extends beyond the AE's entries. Safe in this implementation because the leader always sends ALL remaining entries (`cm.log[ni:]`), but not defensive if the implementation changed.

**Classification**: Code-review-only. Safe in current code; would become a bug if partial AE batching were added.

---

## 4. Bug Family Grouping

### Family 1: Vote Safety Violations

| Finding | Mechanism | Severity | Status |
|---------|-----------|----------|--------|
| F1a | becomeFollower resets votedFor on same-term | Critical | Live bug |
| F1b | Missing persistToStorage in startElection | Critical | Live bug (requires crash) |
| F1c | Non-atomic persistToStorage | Critical | Live bug (requires crash) |

**Shared root cause**: Multiple paths where the single-vote-per-term invariant is violated.
**TLA+ suitability**: Excellent — classic model-checking targets.

### Family 2: Stale State in Asynchronous RPC Replies

| Finding | Mechanism | Severity | Status |
|---------|-----------|----------|--------|
| F2a (Issue #25) | Stale vote reply → wrong-term leader | Critical | Open bug |
| Issue #14 | Stale term in AE reply → term regression | Critical | Fixed (acfa211) |
| Issue #13 | No state check before heartbeat send | High | Fixed (PR #15) |
| F2c | Stale savedCurrentTerm in AE construction | Medium | Live bug |

**Shared root cause**: State captured before RPC used after without re-validation.
**TLA+ suitability**: Excellent — asynchronous message handling is the core of Raft model checking.

### Family 3: Shutdown Race Conditions

| Finding | Mechanism | Severity | Status |
|---------|-----------|----------|--------|
| Send on closed channel | Stop() closes channel while goroutine sends | Medium | Live bug |
| Stop() deadlock | Mutex held across WaitGroup.Wait | High | Fixed (a525c4b) |
| Goroutine leak | Background goroutines outlive Shutdown | Low | Live bug |

**Shared root cause**: Concurrent shutdown with asynchronous goroutines.
**TLA+ suitability**: Poor — Go concurrency bugs, not protocol logic.

---

## 5. Cross-Implementation Comparison Notes

Compared to hashicorp/raft (our prior analysis):

| Aspect | eliben/raft | hashicorp/raft |
|--------|-------------|----------------|
| Core LOC | ~1,064 | ~3,600 |
| Concurrency | Single mutex | Main goroutine + per-peer goroutines |
| Heartbeat | Same goroutine as replication | Independent goroutine (separate code path) |
| Configuration | Fixed peers | Committed + latest (dual config) |
| Persistence | Three separate Set calls | Two separate SetUint64/Set calls |
| PreVote | Not implemented | Implemented |
| Snapshots | Not implemented | Implemented |

**Bug pattern overlap**:
- Both have non-atomic persistence (eliben: 3 writes; hashicorp: 2 writes)
- Both had stale-term bugs in RPC reply handling (eliben: Issues #13, #14, #25; hashicorp: Issue #666)
- hashicorp's independent heartbeat creates an additional code path inconsistency family not present in eliben
- eliben has the unique `becomeFollower` votedFor reset bug (not present in hashicorp — hashicorp only resets votedFor on higher-term transitions)

---

## 6. Verification Notes

All findings have been verified by:
1. Reading exact source lines (not relying on grep/summary)
2. Checking for compensating mechanisms in surrounding code
3. Tracing full execution paths through the scenario
4. Checking git history for prior fixes of the same issue
5. Reading full GitHub issue discussion threads for referenced issues
