# Modeling Targets: hashicorp-raft

## Prioritized Targets for TLA+ Modeling

### Target 1: Non-Atomic Vote Persistence (HIGHEST PRIORITY)
- **Component**: `requestVote()`, `persistVote()`, `setCurrentTerm()`
- **Bug**: Issue #661 — confirmed safety violation (split-brain)
- **Why model**: Crash between `setCurrentTerm()` and `persistVote()` allows double-voting
- **What to model**:
  - Separate persistence of currentTerm and votedFor
  - Crash at any point during requestVote handling
  - Recovery from persisted state
  - Show that two leaders can be elected in the same term
- **Key code**: raft.go:1665-1732, raft.go:2131-2138, raft.go:2142-2148

### Target 2: Election Logic with PreVote
- **Component**: `runCandidate()`, `electSelf()`, `preElectSelf()`, `requestVote()`, `requestPreVote()`
- **Why model**: PreVote is not in the original Raft paper; its interaction with term management and crash recovery is under-tested
- **What to model**:
  - PreVote does NOT increment term (raft.go:2064 — uses `r.getCurrentTerm() + 1` without persisting)
  - Transition from pre-vote win to `electSelf()` which DOES increment term
  - `candidateFromLeadershipTransfer` flag bypasses leader check in voting
- **Key code**: raft.go:286-441, raft.go:1977-2128

### Target 3: AppendEntries Log Handling
- **Component**: `appendEntries()` in raft.go:1441-1581
- **Why model**: Historical bug (commit 0f31a01) showed truncation of non-conflicting entries; current code has a TODO about leaving getLastLog in wrong state
- **What to model**:
  - Conflict detection: compare entry-by-entry, truncate only on term mismatch
  - The exact skip-duplicates / truncate-conflicts / append-new logic
  - Interaction with configuration log entries during truncation
  - Crash between truncation and append (the TODO at line 1542-1543)
- **Key code**: raft.go:1506-1561

### Target 4: Commitment and Quorum Calculation
- **Component**: `commitment.go`, `dispatchLogs()`, leader loop commit advancement
- **Why model**: The `startIndex` mechanism ensures only current-term entries advance commit. Config changes alter quorum dynamically.
- **What to model**:
  - `recalculate()` uses sorted matchIndexes, median for quorum (line 98)
  - `startIndex` prevents committing entries from previous terms directly
  - `setConfiguration()` changes voter set mid-term
- **Key code**: commitment.go:35-104, raft.go:456-465

### Target 5: Configuration Change + Leader Self-Removal
- **Component**: Configuration changes via log entries, `processConfigurationLogEntry()`, `appendConfigurationEntry()`
- **Why model**: Issue #79 showed leader self-removal causes quorum to become 1, committing entries without proper agreement
- **What to model**: How configuration change log entries affect quorum calculation before being committed
- **Key code**: raft.go:1204-1241, raft.go:1586-1601, commitment.go:53-63

## Modeling Strategy

Given the targets above, the TLA+ spec will focus on:

1. **Core election + voting with crash recovery** (Targets 1 & 2)
   - This is the primary focus: model the exact persistence ordering
   - Include crash/recovery as first-class actions
   - Show the split-brain bug from #661

2. **Log replication + commit** (Targets 3 & 4)
   - Model AppendEntries with the exact conflict/duplicate/new detection
   - Model commitment with startIndex

3. **Abstract away**: snapshots, pipeline mode, FSM application, transport details, leadership transfer (these don't affect the safety bugs we're targeting)

## Scope Decision
- **3 servers** (minimum for quorum, sufficient for split-brain)
- **Bounded log length** (2-3 entries sufficient for log matching bugs)
- **Bounded terms** (3-4 terms sufficient for crash/recovery scenarios)
- **Include**: crashes, network partitions, message loss
- **Exclude**: snapshots, pipeline, batching, timing, FSM
