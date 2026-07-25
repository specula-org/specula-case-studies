# Instrumentation Spec: goraft/raft

Action-to-code mapping for trace validation harness generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object written as one line to an NDJSON file:

```json
{
  "event": "<EventName>",
  "node": "<server-id>",
  "from": "<source-server>",
  "to": "<dest-server>",
  "state": {
    "term": <uint64>,
    "role": "<follower|candidate|leader|snapshotting>",
    "commitIndex": <uint64>,
    "lastLogIndex": <uint64>,
    "lastLogTerm": <uint64>
  },
  "pre": {
    "term": <uint64>,
    "role": "<role>"
  },
  "msg": { ... }
}
```

### State Fields

Captured at every event in `state`:

| Implementation field | TLA+ variable | Getter |
|---|---|---|
| `s.currentTerm` | `currentTerm[node]` | `s.Term()` |
| `s.state` | `state[node]` | `s.State()` |
| `s.log.commitIndex` | `commitIndex[node]` | `s.log.CommitIndex()` |
| `s.log.currentIndex()` | `LastLogIndex(node)` | `s.log.currentIndex()` |
| `s.log.currentTerm()` | `LastLogTerm(node)` | `s.log.currentTerm()` |

### Pre-state Fields

Captured at event start in `pre` (used by TraceInit for first event):

| Field | Description |
|---|---|
| `pre.term` | `s.currentTerm` before the action |
| `pre.role` | `s.State()` before the action |

### Message Fields (event-specific)

| Field | Description | Used by |
|---|---|---|
| `msg.term` | Message term | RV, AE |
| `msg.candidateName` | Candidate ID | RV request |
| `msg.lastLogIndex` | Candidate's last log index | RV request |
| `msg.lastLogTerm` | Candidate's last log term | RV request |
| `msg.voteGranted` | Vote result | RV response |
| `msg.prevLogIndex` | AE prev log index | AE request |
| `msg.entries` | Number of entries | AE request |
| `msg.success` | AE result | AE response |
| `msg.matchIndex` | Follower's last index | AE response |

## Section 2: Action-to-Code Mapping

### Timeout

- **Spec action**: `Timeout(i)`
- **Code location**: `server.go:710-714` (followerLoop timeout branch)
- **Trigger point**: After `s.setState(Candidate)` at line 713
- **Event name**: `Timeout`
- **Fields**: `node`, `state` (post-state as Candidate)
- **Notes**: Only fires when `s.promotable()` returns true (server.go:712)

### RequestVote

- **Spec action**: `RequestVote(i)`
- **Code location**: `server.go:744-757` (candidateLoop doVote branch)
- **Trigger point**: After `s.votedFor = s.name` at line 748, before sending RPCs
- **Event name**: `RequestVote`
- **Fields**: `node`, `state` (new term after increment)
- **Notes**: Self-vote happens at line 748. The RPC sends happen in goroutines (lines 754-757).

### HandleRequestVoteRequest

- **Spec action**: `HandleRequestVoteRequest(i, m)`
- **Code location**: `server.go:1066-1099` (processRequestVoteRequest)
- **Trigger point**: After return (line 1071, 1082, 1091, or 1098)
- **Event name**: `HandleRequestVoteRequest`
- **Fields**: `node`, `from` (candidate), `state`, `msg.term`, `msg.candidateName`, `msg.voteGranted`
- **Notes**: Capture after the full function returns. `from` = `req.CandidateName`.

### HandleRequestVoteResponse

- **Spec action**: `HandleRequestVoteResponse(i, m)`
- **Code location**: `server.go:1033-1050` (processVoteResponse)
- **Trigger point**: After function returns
- **Event name**: `HandleRequestVoteResponse`
- **Fields**: `node`, `from` (voter), `state`, `msg.term`, `msg.voteGranted`
- **Notes**: Called from candidateLoop select (server.go:784-788). `from` = response source.

### BecomeLeader

- **Spec action**: `BecomeLeader(i)`
- **Code location**: `server.go:772-776` (candidateLoop quorum check)
- **Trigger point**: After `s.setState(Leader)` at line 774
- **Event name**: `BecomeLeader`
- **Fields**: `node`, `state` (Leader)
- **Notes**: Fires when `votesGranted == s.QuorumSize()` (line 772).

### ClientRequest

- **Spec action**: `ClientRequest(i)`
- **Code location**: `server.go:900-925` (processCommand)
- **Trigger point**: After `s.log.appendEntry(entry)` at line 913
- **Event name**: `ClientRequest`
- **Fields**: `node`, `state`
- **Notes**: Includes the NOP command (server.go:828). Distinguish via command type.

### AppendNOP

- **Spec action**: `AppendNOP(i)`
- **Code location**: `server.go:825-829` (leaderLoop, async NOP)
- **Trigger point**: After `s.log.appendEntry(entry)` inside `processCommand` for NOPCommand
- **Event name**: `AppendNOP`
- **Fields**: `node`, `state`
- **Notes**: The NOP is sent via `go func() { s.Do(NOPCommand{}) }()`. The trace event fires when processCommand executes, which may be after other events. Check `command.(NOPCommand)` to distinguish from regular ClientRequest.

### Replicate

- **Spec action**: `Replicate(i, j)`
- **Code location**: `peer.go:170-182` (flush, entries != nil branch)
- **Trigger point**: Before `p.sendAppendEntriesRequest(...)` at line 178
- **Event name**: `Replicate`
- **Fields**: `from` (leader), `to` (peer), `msg.prevLogIndex`, `msg.entries` (count)
- **Notes**: `from` = `p.server.Name()`, `to` = `p.Name`. Only when `entries != nil` (line 177).

### HandleAppendEntriesRequest

- **Spec action**: `HandleAppendEntriesRequest(i, m)`
- **Code location**: `server.go:938-984` (processAppendEntriesRequest)
- **Trigger point**: After the function returns (line 944, 967, 973, 979, or 984)
- **Event name**: `HandleAppendEntriesRequest`
- **Fields**: `node`, `from` (leader), `state`, `msg.term`, `msg.prevLogIndex`, `msg.success`
- **Notes**: `from` = `req.LeaderName`. State may change (Candidate -> Follower, term update).

### HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `server.go:990-1031` (processAppendEntriesResponse)
- **Trigger point**: After the function returns
- **Event name**: `HandleAppendEntriesResponse`
- **Fields**: `node`, `from` (follower), `state`, `msg.term`, `msg.success`, `msg.matchIndex`
- **Notes**: `from` = `resp.peer` (set at peer.go:252). Includes commit advancement.

### AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `server.go:1013-1030` (inline in processAppendEntriesResponse)
- **Trigger point**: After `s.log.setCommitIndex(commitIndex)` at line 1028
- **Event name**: `AdvanceCommitIndex`
- **Fields**: `node`, `state` (commitIndex updated)
- **Notes**: Fires only when `commitIndex > committedIndex` (line 1025). This is inside processAppendEntriesResponse — emit a SEPARATE event for commit advancement.

### SendSnapshotRequest

- **Spec action**: `SendSnapshotRequest(i, j)`
- **Code location**: `peer.go:180` (flush, entries == nil branch)
- **Trigger point**: Before `p.sendSnapshotRequest(...)` at line 180
- **Event name**: `SendSnapshotRequest`
- **Fields**: `from` (leader), `to` (peer), `msg.lastIndex`, `msg.lastTerm`
- **Notes**: Triggered when `entries == nil` in flush().

### HandleSnapshotRequest

- **Spec action**: `HandleSnapshotRequest(i, m)`
- **Code location**: `server.go:1267-1281` (processSnapshotRequest)
- **Trigger point**: After `s.setState(Snapshotting)` at line 1278
- **Event name**: `HandleSnapshotRequest`
- **Fields**: `node`, `state` (Snapshotting)
- **Notes**: Only fires on success (line 1278). Rejection (line 1274) could be a separate event or skipped.

### SendSnapshotRecoveryRequest

- **Spec action**: `SendSnapshotRecoveryRequest(i, j)`
- **Code location**: `peer.go:269-298` (sendSnapshotRequest, success branch)
- **Trigger point**: Before sending recovery request (~line 285)
- **Event name**: `SendSnapshotRecoveryRequest`
- **Fields**: `from` (leader), `to` (peer), `msg.lastIndex`, `msg.lastTerm`

### HandleSnapshotRecoveryRequest

- **Spec action**: `HandleSnapshotRecoveryRequest(i, m)`
- **Code location**: `server.go:1289-1313` (processSnapshotRecoveryRequest)
- **Trigger point**: After `s.log.compact(...)` at line 1310
- **Event name**: `HandleSnapshotRecoveryRequest`
- **Fields**: `node`, `state`, `msg.lastIndex`, `msg.lastTerm`
- **Notes**: State stays Snapshotting after this handler (no setState call). currentTerm is overwritten at line 1302.

### SendHeartbeat

- **Spec action**: `SendHeartbeat(i, j)`
- **Code location**: `peer.go:170-182` (flush, when sending empty AE as heartbeat)
- **Trigger point**: Before `p.sendAppendEntriesRequest(...)` at line 178 (empty entries)
- **Event name**: `SendHeartbeat`
- **Fields**: `from` (leader), `to` (peer), `msg.term` (may be stale)
- **Notes**: A heartbeat is an AE with zero entries. Distinguish from Replicate by checking `len(entries) == 0`. `msg.term` = `p.server.currentTerm` at line 173 (read without lock).

### Crash

- **Spec action**: `Crash(i)`
- **Code location**: N/A (external event — test harness triggers crash/restart)
- **Trigger point**: After server restart completes
- **Event name**: `Crash`
- **Fields**: `node`, `state` (post-recovery state)
- **Notes**: The test harness must stop the server, then restart it. The trace event captures the post-restart state (term=0, votedFor=Nil, state=Follower).

## Section 3: Special Considerations

### Concurrent Heartbeat Goroutines

Each peer has an independent heartbeat goroutine (`peer.go:138-168`). These goroutines:
- Read `p.server.currentTerm` without holding the server mutex (peer.go:173)
- Read `p.server.snapshot` without lock (peer.go:180)
- Send responses back to the server via `sendAsync` (peer.go:254)

**Implication**: Heartbeat events may interleave with state machine events in unpredictable order. The trace preprocessor should:
1. Order events by timestamp within each server
2. Allow heartbeat events to appear between state machine events
3. Use weak validation for heartbeat-related events

### Non-Atomic State Updates

Several state updates are non-atomic:
- `updateCurrentTerm()` (server.go:545-577): stops heartbeats, changes state, then updates term/votedFor under mutex
- `processRequestVoteRequest()`: may call updateCurrentTerm then set votedFor
- `processSnapshotRecoveryRequest()`: updates term (1302), commitIndex (1303), snapshot (1306-1307), log (1310) sequentially

**Implication**: If tracing captures state mid-update, intermediate states may not match spec expectations. Place trace points AFTER all state mutations complete.

### Bootstrap / Initial State

goraft servers start with:
- `currentTerm = 0`
- `votedFor = ""`  (empty string, maps to Nil in spec)
- `state = Initialized` (transitions to Follower on `Start()`)
- `log = <<>>` (empty)
- `commitIndex = 0` (may be non-zero if config file exists)

The first trace event should capture this initial state in its `pre` field. If servers use self-join for bootstrap (`s.log.currentIndex() == 0 && req.NodeName() == s.Name()` at server.go:686-689), the bootstrap entry must be traced.

### Serialization Quirks

- Go's `encoding/json` omits zero-value fields by default. Use explicit field tags or always include state fields.
- Server names are strings (e.g., `"s1"`, `"s2"`). Map to TLA+ model values via the trace Server set.
- `votedFor` is an empty string `""` when unset. Map to `Nil` in the trace preprocessor.

### Event Dedup

The heartbeat goroutine fires periodically. Multiple heartbeats to the same peer may occur between state changes. The trace preprocessor should NOT deduplicate these — each heartbeat is a distinct event that may carry different state.

### Log Entries in Messages

AppendEntries requests carry log entries. For trace validation, the entries in the trace must match the spec's log entries. Capture entry terms and types in the trace:
```json
"msg": {
  "entries": [{"term": 1, "type": "value"}, {"term": 2, "type": "nop"}]
}
```

If full entries are too verbose, capture just the count and let the spec reconstruct from the leader's log state.
