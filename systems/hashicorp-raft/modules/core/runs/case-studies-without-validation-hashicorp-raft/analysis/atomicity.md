# Atomicity Analysis: hashicorp-raft

## Key Atomicity Boundaries

### 1. Main Thread (Single-Threaded Event Loop)
The main Raft event loop (`run()` → `runFollower/Candidate/Leader()`) runs on a single goroutine.
All RPC handlers (`appendEntries`, `requestVote`, `requestPreVote`, `installSnapshot`) are called
from this goroutine via `processRPC()`.

**Implication**: Within a single RPC handler invocation, all operations are atomic with respect
to other Raft state changes (no interleaving with other RPCs or state changes).

**BUT**: Multiple disk writes within a handler are NOT atomic with respect to crashes.

### 2. Vote Persistence — NON-ATOMIC (The Critical Bug)

```
requestVote() handler:
  [raft.go:1665-1669]
  Step 1: r.setState(Follower)                    — in-memory only
  Step 2: r.setCurrentTerm(req.Term)               — PERSISTS to stable (panics on failure)

  [... ~58 lines of checks ...]

  [raft.go:1727-1729]
  Step 3: r.persistVote(req.Term, candidateBytes)  — PERSISTS to stable (2 writes!)
    Step 3a: stable.SetUint64(keyLastVoteTerm, term)  — first write
    Step 3b: stable.Set(keyLastVoteCand, candidate)   — second write

  Step 4: resp.Granted = true                      — in-memory, sent via RPC response
```

**Crash windows**:
- Between Step 2 and Step 3: currentTerm persisted but vote not recorded
- Between Step 3a and Step 3b: lastVoteTerm updated but candidate not
- After Step 3 but before Step 4 response sent: vote persisted but response not sent (safe — voter just times out)

### 3. electSelf() — Term Increment + Vote Persistence

```
electSelf():
  [raft.go:1982-1984]
  Step 1: newTerm = r.getCurrentTerm() + 1
  Step 2: r.setCurrentTerm(newTerm)               — PERSISTS

  [raft.go:2022-2026]
  Step 3: r.persistVote(req.Term, req.Addr)        — PERSISTS (self-vote)
  Step 4: Send own vote to respCh
  Step 5: Launch goroutines to ask peers
```

**Crash window**: Between Step 2 and Step 3: term incremented and persisted, but self-vote not recorded.
On recovery, the node has a higher term but no record of voting for itself.

### 4. appendEntries() — Log Truncation + Append

```
appendEntries():
  [raft.go:1465-1468]
  Step 1: r.setState(Follower)                     — in-memory
  Step 2: r.setCurrentTerm(a.Term)                 — PERSISTS

  [raft.go:1526-1533]
  Step 3: r.logs.DeleteRange(entry.Index, lastLogIdx) — PERSISTS (truncates conflicting)

  [raft.go:1540-1545]
  Step 4: r.logs.StoreLogs(newEntries)             — PERSISTS (appends new)

  [raft.go:1559-1560]
  Step 5: r.setLastLog(last.Index, last.Term)      — in-memory cache update
```

**Crash windows**:
- Between Step 3 and Step 4: Log truncated but new entries not written. On recovery, log is shorter than expected.
  (The raft.go:1542 TODO acknowledges this: "leaving r.getLastLog() in the wrong state if there was a truncation above")
- Between Step 4 and Step 5: Entries written but cache not updated. On recovery this is fine since cache is rebuilt.

### 5. Replication Goroutine — Separate from Main Thread

```
Per-follower replication runs on its own goroutine.
Uses s.currentTerm (snapshot from leader election time), NOT r.getCurrentTerm().
```

**Implication**:
- The replication goroutine cannot see state changes from the main thread in real-time
- It communicates via channels (triggerCh, stopCh) and atomic operations (s.nextIndex)
- The `commitment.match()` call from replication updates leader's commit tracking

### 6. Commitment — Locked but Cross-Goroutine

```
commitment struct has its own sync.Mutex.
Called from:
  - Main thread: newCommitment(), setConfiguration(), getCommitIndex()
  - Replication goroutines: match() — one per follower
```

**Implication**: Commit index advancement can happen while leader is processing RPCs.
This is safe because the main thread only reads commitIndex via `getCommitIndex()`.

## For TLA+ Modeling

### What to Model as Atomic
- Each RPC handler invocation (requestVote, appendEntries) — these are single-threaded
- Each step within an RPC where persistence happens — model persistence separately

### What to Model as Interleaved (Non-Atomic)
- The gap between `setCurrentTerm()` and `persistVote()` in requestVote
- The gap between log truncation and log append in appendEntries
- Crash/recovery at ANY point between persistent operations
- Message delivery order between different server pairs

### What to Abstract
- In-memory cache updates (setLastLog, etc.) — these are rebuilt on recovery
- Channel operations (they're implementation detail, the logic is what matters)
- Replication goroutine details — model as leader sending AppendEntries when it wants
- Heartbeat mechanism — model as regular AppendEntries with empty entries
