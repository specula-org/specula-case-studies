# SOFAJraft Instrumentation Specification

This document maps TLA+ spec actions to source code locations for trace generation. It serves as the context handoff from spec generation to harness generation.

## Section 1: Trace Event Schema

### Event Envelope

All trace events are NDJSON format with the following structure:

```json
{
  "event": "<action_name>",
  "nodeId": "server_id",
  "timestamp": <unix_ns>,
  "state": {
    "currentTerm": <int>,
    "state": "<LEADER|FOLLOWER|CANDIDATE>",
    "commitIndex": <int>,
    "lastAppliedIndex": <int>,
    "votedFor": "<server_id|null>",
    ...
  },
  "message": {
    "type": "<msg_type>",
    "from": "<server_id>",
    "to": "<server_id>",
    ...
  }
}
```

### State Fields (Captured at Every Event)

| Implementation Field | TLA+ Variable | Notes |
|--|--|--|
| `currentTerm` | `currentTerm[s]` | Read from NodeImpl.currentTerm field |
| `role` | `state[s]` | Mapped: "leader"→LEADER, "follower"→FOLLOWER, "candidate"→CANDIDATE |
| `votedFor` | `votedFor[s]` | Read from NodeImpl.votedFor field, null if Nil |
| `commitIndex` | `commitIndex[s]` | Read from BallotBox or Node's tracking |
| `lastAppliedIndex` | `lastAppliedIndex[s]` | Read from FSMCallerImpl.lastAppliedIndex |
| `log.size()` | `Len(log[s])` | Log entry count |
| `lastIncludedIndex` | `lastIncludedIndex[s]` | Read from RaftRawNode or log manager |

### Message Fields (Captured for RPC Events)

| Message Field | TLA+ Field | Notes |
|--|--|--|
| `term` | Message.term | From RequestVote, AppendEntries, etc. |
| `type` | Message.type | RequestVote, AppendEntries, InstallSnapshot, or responses |
| `from` | Message.from | Source server ID |
| `to` | Message.to | Destination server ID |
| `lastLogIndex` | Message.lastLogIndex | For RequestVote |
| `lastLogTerm` | Message.lastLogTerm | For RequestVote |
| `leaderCommit` | Message.leaderCommit | For AppendEntries |
| `prevLogIndex` | Message.prevLogIndex | For AppendEntries |
| `prevLogTerm` | Message.prevLogTerm | For AppendEntries |
| `success` | Message.success | For AppendEntries response |
| `matchIndex` | Message.matchIndex | For replication response |
| `lastIncludedIndex` | Message.lastIncludedIndex | For InstallSnapshot |
| `lastIncludedTerm` | Message.lastIncludedTerm | For InstallSnapshot |

---

## Section 2: Action-to-Code Mapping

### ElectSelf

| Aspect | Value |
|--|--|
| **Spec Action** | `ElectSelf(s)` |
| **Code Location** | NodeImpl.java:1178-1218 |
| **Function** | `void electSelf()` |
| **Trigger Point** | **AFTER** lines 1199 (term increment + vote for self), **BEFORE** line 1218 (persist) |
| **Trace Event Name** | `ElectSelf` |
| **Fields to Capture** | state, currentTerm, votedFor |
| **Notes** | Capture state AFTER memory write but BEFORE persistence (models Family 1 window) |

### PersistTermAndVote

| Aspect | Value |
|--|--|
| **Spec Action** | `PersistTermAndVote(s)` |
| **Code Location** | NodeImpl.java:1218 (metaStorage.setTerm/VotedFor) |
| **Function** | `void electSelf()` or `void handleRequestVoteRequest()` |
| **Trigger Point** | **AFTER** metaStorage write succeeds |
| **Trace Event Name** | `PersistTermAndVote` |
| **Fields to Capture** | persistentTerm, persistentVotedFor (read from stable store) |
| **Notes** | Silent action in trace - optional event for debugging persistence windows |

### HandleRequestVoteRequest

| Aspect | Value |
|--|--|
| **Spec Action** | `HandleRequestVoteRequest(s, src, term, candidateId, lastLogIndex, lastLogTerm)` |
| **Code Location** | NodeImpl.java:1802-1873 |
| **Function** | `void handleRequestVoteRequest(PeerId peerId, RequestVoteRequest request)` |
| **Trigger Point** | **BEFORE** unlock at line 1841 (ABA window), capture after relock at line 1846 |
| **Trace Event Name** | `HandleRequestVoteRequest` |
| **Fields to Capture** | state, currentTerm, votedFor, response fields (term, voteGranted) |
| **Message Fields** | from, term, lastLogIndex, lastLogTerm |
| **Notes** | Capture lock state before/after unlock window (Family 3). ABA check happens at line 1848. |

### HandleRequestVoteResponse

| Aspect | Value |
|--|--|
| **Spec Action** | `HandleRequestVoteResponse(s, src, term, voteGranted, matchIdx)` |
| **Code Location** | NodeImpl.java:2584-2616 |
| **Function** | `void handleRequestVoteResponse(PeerId peerId, RequestVoteResponse response)` |
| **Trigger Point** | **AFTER** vote is recorded in votesReceived and state is updated |
| **Trace Event Name** | `HandleRequestVoteResponse` |
| **Fields to Capture** | state, currentTerm, votesReceived (count) |
| **Message Fields** | from, term, voteGranted |
| **Notes** | Track votes for election safety (Family 8). Capture after re-check at line 2610. |

### BecomeLeader

| Aspect | Value |
|--|--|
| **Spec Action** | `BecomeLeader(s)` |
| **Code Location** | NodeImpl.java:2587-2616 |
| **Function** | `void becomeLeader()` (called from handleRequestVoteResponse) |
| **Trigger Point** | **AFTER** quorum check, **BEFORE** nextIndex/matchIndex reset |
| **Trace Event Name** | `BecomeLeader` |
| **Fields to Capture** | state (changed to LEADER), currentTerm, nextIndex initialized |
| **Notes** | Election safety (Family 6). Verify quorum invariant holds. |

### HandleAppendEntriesRequest

| Aspect | Value |
|--|--|
| **Spec Action** | `HandleAppendEntriesRequest(s, src, term, leaderCommit, prevLogIndex, prevLogTerm, entries)` |
| **Code Location** | NodeImpl.java:1944-2060 |
| **Function** | `void handleAppendEntriesRequest(PeerId peerId, AppendEntriesRequest request)` |
| **Trigger Point** | **AFTER** term check (line 1951), **AFTER** log matching check (line 1992) |
| **Trace Event Name** | `HandleAppendEntriesRequest` |
| **Fields to Capture** | state, currentTerm, votedFor, log size, commitIndex, leaderId |
| **Message Fields** | from (src), term, prevLogIndex, prevLogTerm, leaderCommit, entries (optional) |
| **Notes** | Log matching (Family 5, 9). Leader conflict detection (Family 2). Capture state after AppendEntries modifies log. |

### HandleAppendEntriesResponse

| Aspect | Value |
|--|--|
| **Spec Action** | `HandleAppendEntriesResponse(s, src, term, success, matchIdx)` |
| **Code Location** | Replicator.java:1531-1544 |
| **Function** | `void onAppendEntriesReturned(long prevLogIndex, Status status, AppendEntriesResponse response)` |
| **Trigger Point** | **AFTER** BallotBox.commitAt() / nextIndex update (line 1542-1544) |
| **Trace Event Name** | `HandleAppendEntriesResponse` |
| **Fields to Capture** | state, currentTerm, nextIndex[src], matchIndex[src], commitIndex |
| **Message Fields** | from (src), term, success, matchIndex |
| **Notes** | Replication state races (Family 5). Capture after nextIndex updated. |

### HandleInstallSnapshotRequest

| Aspect | Value |
|--|--|
| **Spec Action** | `HandleInstallSnapshotRequest(s, src, term, lastIncludedIdx, lastIncludedTerm)` |
| **Code Location** | Replicator.java:622-708 (receiver side), NodeImpl for state |
| **Function** | `void onInstallSnapshot(RaftRawNode node, InstallSnapshotRequest request)` |
| **Trigger Point** | **AFTER** snapshot installed and log truncated (line 700), **BEFORE** nextIndex update |
| **Trace Event Name** | `HandleInstallSnapshotRequest` |
| **Fields to Capture** | state, currentTerm, lastIncludedIndex, lastIncludedTerm, log size (after truncation), commitIndex |
| **Message Fields** | from (src), term, lastIncludedIndex, lastIncludedTerm |
| **Notes** | Snapshot state machine separation (Family 5). Log truncation race (Family 9). |

### AdvanceCommitIndex

| Aspect | Value |
|--|--|
| **Spec Action** | `AdvanceCommitIndex(s)` |
| **Code Location** | BallotBox.java:115-122 (commitAt) |
| **Function** | `long commitAt(long index, long term)` |
| **Trigger Point** | **AFTER** new commit index is calculated and set |
| **Trace Event Name** | `AdvanceCommitIndex` |
| **Fields to Capture** | state (must be leader), currentTerm, commitIndex, matchIndex (for verification) |
| **Notes** | Quorum safety (Family 8). Capture after each ballot update. |

### ApplyCommittedEntries

| Aspect | Value |
|--|--|
| **Spec Action** | `ApplyCommittedEntries(s)` |
| **Code Location** | FSMCallerImpl.java:520-576 |
| **Function** | `void doCommitted(long committedIndex)` |
| **Trigger Point** | **AFTER** loop applies entries (line 542-555), **BEFORE** closure callbacks |
| **Trace Event Name** | `ApplyCommittedEntries` |
| **Fields to Capture** | state, lastAppliedIndex (updated), commitIndex |
| **Notes** | FSM application safety (Family 9). Capture state after entry application. Log truncation race — entry may not exist at line 542. |

### Crash

| Aspect | Value |
|--|--|
| **Spec Action** | `Crash(s)` |
| **Code Location** | System crash (arbitrary point) |
| **Function** | (No specific function - represents unplanned crash) |
| **Trigger Point** | **BEFORE** crash, capture in-memory state |
| **Trace Event Name** | `Crash` |
| **Fields to Capture** | currentTerm (in-memory), votedFor (in-memory), lastAppliedIndex (in-memory) |
| **Notes** | Non-atomic persistence (Family 1). Trace should record in-memory state at crash. Recovery will compare with persistent storage. |

---

## Section 3: Special Considerations

### Bootstrap and Initial State

- Traces should capture initial state: all servers start as followers, term=0, votedFor=Nil, empty logs
- If trace includes bootstrap entries or initial configuration, capture those in state field

### Non-Atomic Persistence Windows (Family 1)

- **Electself (NodeImpl:1178-1218)**: Memory write at 1178-1179, persist at 1218
  - Instrument both points; two events in trace allow TLC to explore crash between them
  - Event 1: `ElectSelf` (memory state after line 1199)
  - Event 2: `PersistTermAndVote` (persistent state after metaStorage call succeeds)

- **HandleRequestVoteRequest (NodeImpl:1859-1860)**: votedId in memory, then persist
  - Similar two-point instrumentation

- **FSMCallerImpl:578-583**: lastAppliedIndex.set() then logManager.setAppliedId()
  - Two events: `ApplyCommittedEntries` (memory), then silent `PersistLastApplied`

### ABA Races and Lock/Unlock Windows (Family 3)

- **HandleRequestVoteRequest (NodeImpl:1840-1850)**: unlock at 1841, relock at 1846
  - Capture state BEFORE unlock (cached), then AFTER relock
  - Check ABA condition at line 1848 — record if term changed

### Snapshot-Replication Interleaving (Family 5)

- **InstallSnapshot (Replicator:740, 759)**: Sets `nextIndex = lastIncludedIndex + 1`
- **AppendEntriesResponse (Replicator:1542-1544)**: Updates `nextIndex` from match result
  - Both events must be in trace; TLC will explore concurrent firing order

### Vote Counting Races (Family 8)

- **BallotBox.grant() (line 115-122)**: Called per replicator
  - Instrument every grant() call; capture votesReceived set before/after
  - Allow TLC to explore concurrent ordering

### Retry and Error Recovery (Family 10)

- **Replicator.onAppendEntriesReturned error path**: Retry logic
  - Capture `appendEntriesRetries[peer]` counter at each retry attempt
  - Allow bounded retries to prevent infinite loops

### Thread Concurrency Notes

- **Replicator threads** (one per follower): Run concurrently with Node
  - Instrument each replicator action as a separate event sequence
  - Order relative to Node actions is non-deterministic (TLC explores all orders)

- **FSMCaller event loop** (Disruptor ring): Processes tasks asynchronously
  - Instrument task application, not Disruptor internals
  - Capture state after task completes

- **BallotBox.grant()**: Called by multiple replicators concurrently
  - No locks between replicators; TLC will explore all interleavings
  - Instrument per-call

### Snapshot Reader Lifecycle (Family 3)

- **resetInflights() (Replicator:1392)**: Sets reader to null
- **installSnapshot() (line 636)**: Checks reader != null
  - Between check and use, another thread's resetInflights() can set reader to null
  - Instrument both check and use; TLC explores race

---

## Section 4: Validation Checklist

Before harness generation:

- [ ] Every action in base.tla has an entry in Section 2
- [ ] Every code location cite is from the actual source file (sofa-jraft artifact/)
- [ ] State fields list all variables modified by the action
- [ ] Message fields match the RPC types in the protocol
- [ ] Trigger points are precise (line numbers, before/after operations)
- [ ] Post-state validation fields are captured (for Trace.tla ValidatePostState)
- [ ] Special considerations document all Family 1-11 code windows
- [ ] Silent actions (persistence, recovery) are marked as optional events

---

## Section 5: Implementation Notes for Harness Generation

### Instrumentation Points

1. Use AspectJ or bytecode instrumentation to inject capture code at specified locations
2. Each instrument point emits one NDJSON event with state + message fields
3. State capture should be synchronous (block until JSON written)
4. Use thread-local buffers to avoid contention

### Serialization

- Node IDs: Use server names directly from trace (e.g., "s1", "s2", "s3")
- Roles: Uppercase "LEADER", "FOLLOWER", "CANDIDATE"
- Terms/indices: Integers, not strings
- Null fields: Omit rather than null (reduces JSON size)
- Message types: Short names (RequestVote, AppendEntries, InstallSnapshot)

### Verification

- After generating traces, run Trace.cfg to validate against base spec
- Every event must match a base spec action
- State fields must match spec variables (term, state, role, indices, etc.)
- If ValidatePostState fails, check:
  1. State capture timing (before/after operation)
  2. Field mapping (implementation field → TLA+ variable)
  3. Message field mapping consistency

---

## References

- Base spec: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/sofa-jraft/spec/base.tla`
- Trace spec: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/sofa-jraft/spec/Trace.tla`
- Modeling brief (bug families): `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/sofa-jraft/modeling-brief.md`
- Source code: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/sofa-jraft/artifact/sofa-jraft`
