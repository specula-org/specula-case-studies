# Bug Archaeology: hashicorp-raft

## Bug Pattern Classification

### Category A: Confirmed Bugs (Fixed or Acknowledged)

| ID | Source | Summary | Root Cause | Affected Component | Commit/Issue |
|----|--------|---------|------------|-------------------|--------------|
| B1 | Issue #661 | **Non-atomic vote persistence enables split-brain** | `persistVote()` writes lastVoteTerm and lastVoteCand in 2 separate ops; crash between them loses vote record | requestVote, persistVote | #661 (OPEN, confirmed) |
| B2 | Issue #94, Commit 441bd09 | **Incorrect log comparison in RequestVote** | Compared lastLogIndex even when terms differ (should only compare index when terms equal) | requestVote | 441bd09 |
| B3 | Commit 0f31a01 | **AppendEntries truncates non-conflicting entries** | Blanket DeleteRange of overlapping entries created crash window where committed entries could be lost | appendEntries | 0f31a01 (Diego Ongaro) |
| B4 | Issue #79 | **Removing leader causes divergent logs** | When leader removes itself, `r.peers` set to nil → quorum becomes 1 → entries committed with single node agreement | configuration change, processLog | #79 |
| B5 | Commit f887341 | **Race on currentTerm update to replicators** | Replication goroutine read `r.getCurrentTerm()` racily; fixed by caching term in `followerReplication.currentTerm` | replication | f887341 |
| B6 | Commit 901ac15 | **Self-vote not persisted** | `electSelf()` didn't call `persistVote()` for own vote | electSelf | 901ac15 |
| B7 | Commit 538e56c | **Non-atomic read of lastLogIndex/lastLogTerm** | Index and Term read separately without lock → inconsistent view | state | 538e56c |
| B8 | Issue #268 | **Shutdown deadlock** | Channel operations during shutdown could deadlock | shutdown | #268 |
| B9 | Issue #74, Commit 32051c1 | **Node can't vote for current leader** | Request from current leader rejected despite being valid | requestVote | 32051c1 |
| B10 | Commit 670fc01 | **compactLogs removes all logs in snapshot** | Off-by-one: deleted logs that should have been retained | snapshot/compaction | 670fc01 |

### Category B: Suspected Weak Spots (Not Yet Confirmed)

| ID | Component | Why Suspicious | Evidence |
|----|-----------|----------------|----------|
| W1 | requestVote term update + vote persistence ordering | `setCurrentTerm(req.Term)` (line 1669) persists term BEFORE `persistVote()` (line 1727). Crash window: term persisted but vote not | #661 describes this exact gap |
| W2 | Configuration change during election | `votesNeeded` computed at start of `runCandidate()` using `r.quorumSize()`. If config changes mid-election, quorum may be wrong | Multiple config change issues: #524, #534, #481 |
| W3 | Pre-vote to real-vote transition | After pre-vote succeeds, `electSelf()` increments term. Between pre-vote and real vote, state could change | Complex interaction, no explicit test coverage |
| W4 | Leader self-removal quorum calculation | `commitment.setConfiguration()` rebuilds matchIndexes; if voter count drops, commit index may advance prematurely | #79 root cause |
| W5 | appendEntries setLastLog after partial store | Line 1542-1543 TODO: "leaving r.getLastLog() in the wrong state if there was a truncation above" | Explicit TODO in code |

### Category C: Implementation Deviations from Raft Paper

| ID | Deviation | Reason | Risk |
|----|-----------|--------|------|
| D1 | **PreVote phase** | Prevent disruption from partitioned nodes (§9.6 of thesis) | May interact with config changes; non-voters treated specially |
| D2 | **Leader lease / checkLeaderLease** | Performance: avoid read-only RPCs | If contact tracking is wrong, could serve stale reads |
| D3 | **Non-atomic vote persistence** | StableStore API lacks transactions | #661: crash between 2 writes causes double-voting |
| D4 | **candidateFromLeadershipTransfer flag** | Allow voting despite existing leader during transfers | Flag persists across election restarts (reset in defer) |
| D5 | **Pipeline replication mode** | Performance: batch AppendEntries | Falls back to standard mode on error |
| D6 | **Separate heartbeat goroutine** | Prevent disk IO from blocking heartbeats | Uses cached `s.currentTerm`, not live term |
| D7 | **startIndex in commitment** | Raft commitment rule: only commit entries from current term | Correct per paper §5.4.2, but implementation detail |
| D8 | **LogBarrier / LogNoop types** | Assert leadership and force FSM catch-up | Leader dispatches noop on election (paper §8) |

## Critical Insight: The Non-Atomic Vote Persistence Bug (#661)

This is the highest-priority modeling target because:

1. **It's a confirmed safety violation** — a test case demonstrates split-brain
2. **It's STILL UNFIXED** in the current codebase (issue is closed but the code is unchanged)
3. **It requires crash recovery modeling** — can't be found by normal testing easily
4. **The root cause is in `persistVote()`** (raft.go:2131-2138): two separate `StableStore` calls

### The Crash Window (raft.go:1665-1732)
```
Line 1669: r.setCurrentTerm(req.Term)     // Persists currentTerm to stable storage
           ↓ CRASH WINDOW ↓               // currentTerm persisted, but vote NOT
Line 1727: r.persistVote(req.Term, ...)   // Persists lastVoteTerm + lastVoteCand
```

After crash+restart:
- `currentTerm = T+1` (persisted)
- `lastVoteTerm = T` (old, not updated)
- `lastVoteCand = old_candidate`
- Node effectively "forgot" it voted → can vote again in same term → split-brain
