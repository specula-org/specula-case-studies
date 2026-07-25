# Instrumentation Spec: eliben/raft

Maps TLA+ spec actions to source code locations for trace generation.

**Source**: `artifact/raft/part3/raft/raft.go`
**Trace format**: NDJSON, one event per line

## 1. Trace Event Schema

### Common Envelope

Every trace event has:

```json
{
  "event": "<EventName>",
  "node": <server_id>,
  "term": <currentTerm>,
  "role": "<Follower|Candidate|Leader>",
  "ts": <unix_timestamp_ns>
}
```

### Optional State Fields

Captured when available (strong validation):

| Field | Type | TLA+ Variable | Description |
|-------|------|---------------|-------------|
| `commitIndex` | int | `commitIndex` | Committed log index (1-indexed in TLA+, 0-indexed in code — add 1) |
| `lastLogIndex` | int | `LastLogIndex(i)` | Length of log (= `len(cm.log)` → TLA+ `Len(log[i])`) |
| `lastLogTerm` | int | `LastLogTerm(i)` | Term of last log entry |
| `votedFor` | int | `votedFor` | Who this server voted for (-1 = Nil) |

### Message Fields

For message events (`from`/`to` identify sender/receiver):

| Field | Type | Description |
|-------|------|-------------|
| `from` | int | Message sender |
| `to` | int | Message recipient |
| `msgTerm` | int | Term in the message |

## 2. Action-to-Code Mapping

### Timeout (startElection)

| Field | Value |
|-------|-------|
| **Spec action** | `Timeout(i)` |
| **Trace event** | `"Timeout"` |
| **Code location** | `raft.go:471-478` (startElection) |
| **Trigger point** | After `cm.votedFor = cm.id` (line 476), before sending RPCs |
| **State capture** | term (after increment), role="Candidate", votedFor=cm.id |
| **Notes** | Capture AFTER state update. `currentTerm` is already incremented at line 473. |

### HandleRequestVoteRequest

| Field | Value |
|-------|-------|
| **Spec action** | `HandleRequestVoteRequest(i, m)` |
| **Trace event** | `"HandleRequestVoteRequest"` |
| **Code location** | `raft.go:270-298` (RequestVote) |
| **Trigger point** | After `cm.persistToStorage()` (line 295), before return |
| **State capture** | term, role, votedFor, lastLogIndex, lastLogTerm, commitIndex |
| **Message fields** | from=args.CandidateId, msgTerm=args.Term |
| **Notes** | Capture AFTER persist — state reflects grant/reject decision. votedFor will be the candidate ID if granted, or unchanged if rejected. |

### HandleRequestVoteResponse

| Field | Value |
|-------|-------|
| **Spec action** | `HandleRequestVoteResponse(i, m)` |
| **Trace event** | `"HandleRequestVoteResponse"` |
| **Code location** | `raft.go:497-521` (inside startElection goroutine) |
| **Trigger point** | After processing reply, inside `cm.mu.Lock()` section (line 498-521) |
| **State capture** | term, role (weak validation — async goroutine) |
| **Message fields** | from=peerId, msgTerm=reply.Term, voteGranted=reply.VoteGranted |
| **Notes** | Captured inside the goroutine after lock. If becomeFollower was called, role will be "Follower". Include `savedCurrentTerm` for F2a debugging. |

### BecomeLeader

| Field | Value |
|-------|-------|
| **Spec action** | `BecomeLeader(i)` |
| **Trace event** | `"BecomeLeader"` |
| **Code location** | `raft.go:544-551` (startLeader) |
| **Trigger point** | After `cm.state = Leader` (line 545), after nextIndex/matchIndex init |
| **State capture** | term, role="Leader", commitIndex, lastLogIndex |
| **Notes** | This is called from inside HandleRequestVoteResponse when quorum is reached. Must be a separate event from HandleRequestVoteResponse. |

### ClientRequest

| Field | Value |
|-------|-------|
| **Spec action** | `ClientRequest(i)` |
| **Trace event** | `"ClientRequest"` |
| **Code location** | `raft.go:164-179` (Submit) |
| **Trigger point** | After `cm.persistToStorage()` (line 170), before unlock |
| **State capture** | term, role, lastLogIndex (after append), commitIndex |
| **Notes** | Only emitted when `cm.state == Leader`. |

### AppendEntries (send)

| Field | Value |
|-------|-------|
| **Spec action** | `AppendEntries(i, j)` |
| **Trace event** | `"AppendEntries"` |
| **Code location** | `raft.go:611-630` (inside leaderSendAEs per-peer goroutine) |
| **Trigger point** | After constructing `args`, before `cm.server.Call()` (line 631) |
| **State capture** | from=cm.id, to=peerId, msgTerm=savedCurrentTerm |
| **Message fields** | prevLogIndex=args.PrevLogIndex, prevLogTerm=args.PrevLogTerm, numEntries=len(entries), leaderCommit=args.LeaderCommit |
| **Notes** | One event per peer. `savedCurrentTerm` captured at line 607. |

### HandleAppendEntriesRequest

| Field | Value |
|-------|-------|
| **Spec action** | `HandleAppendEntriesRequest(i, m)` |
| **Trace event** | `"HandleAppendEntriesRequest"` |
| **Code location** | `raft.go:321-408` (AppendEntries handler) |
| **Trigger point** | After `cm.persistToStorage()` (line 405), before return |
| **State capture** | term, role, votedFor, commitIndex, lastLogIndex, lastLogTerm |
| **Message fields** | from=args.LeaderId, msgTerm=args.Term, success=reply.Success |
| **Notes** | Capture AFTER all state changes and persist. votedFor may be Nil after F1a becomeFollower on same-term transition. |

### HandleAppendEntriesResponse

| Field | Value |
|-------|-------|
| **Spec action** | `HandleAppendEntriesResponse(i, m)` |
| **Trace event** | `"HandleAppendEntriesResponse"` |
| **Code location** | `raft.go:632-698` (inside leaderSendAEs reply handler) |
| **Trigger point** | After processing reply, before unlock |
| **State capture** | term, role (weak validation — async goroutine) |
| **Message fields** | from=peerId, success=reply.Success, matchIndex (if success) |
| **Notes** | If commitIndex changed (line 665), capture new commitIndex too. |

### AdvanceCommitIndex

| Field | Value |
|-------|-------|
| **Spec action** | `AdvanceCommitIndex(i)` |
| **Trace event** | `"AdvanceCommitIndex"` |
| **Code location** | `raft.go:651-663` (embedded in HandleAppendEntriesResponse) |
| **Trigger point** | When `cm.commitIndex != savedCommitIndex` (line 665) |
| **State capture** | term, role, commitIndex (new value) |
| **Notes** | Only emitted when commitIndex actually advances. This event may be merged into HandleAppendEntriesResponse in practice — the Trace spec handles both separately and via SilentAdvanceCommitIndex. |

### Crash

| Field | Value |
|-------|-------|
| **Spec action** | `Crash(i)` |
| **Trace event** | `"Crash"` |
| **Code location** | Test harness (not in production code) |
| **Trigger point** | After calling `cm.Stop()` and before calling `NewConsensusModule()` with old storage |
| **State capture** | node (which server crashed) |
| **Notes** | Crash events come from the test harness, not the raft module itself. The harness must stop the server, then recreate it with the same Storage to simulate crash-recovery. |

## 3. Special Considerations

### Index Mapping

The implementation uses 0-indexed Go slices. The TLA+ spec uses 1-indexed sequences. When capturing trace events:
- `commitIndex`: code value + 1 = TLA+ value (code -1 → TLA+ 0)
- `lastLogIndex`: code `len(cm.log)` = TLA+ `Len(log[i])`
- `prevLogIndex`: code value + 1 = TLA+ value (code -1 → TLA+ 0)

### Goroutine Interleaving

The implementation uses multiple goroutines per server:
- **Election timer**: `runElectionTimer()` runs in background
- **Heartbeat loop**: `startLeader()` spawns a goroutine for heartbeats
- **Per-peer RPC**: `startElection()` and `leaderSendAEs()` spawn per-peer goroutines

Trace events from different goroutines may interleave. The trace harness should capture events inside the mutex to ensure a consistent ordering. Key: all state mutations are protected by `cm.mu`, so tracing inside the lock gives a serializable order.

### savedCurrentTerm Capture

For F2a debugging, the trace should capture `savedCurrentTerm` alongside `currentTerm` in:
- `HandleRequestVoteResponse` events (line 474 vs line 498)
- `HandleAppendEntriesResponse` events (line 607 vs line 633)

This allows trace analysis to detect cases where savedCurrentTerm != currentTerm at reply processing time.

### becomeFollower votedFor Reset

For F1a debugging, the `HandleAppendEntriesRequest` event should capture `votedFor` AFTER all state changes. When `args.Term == currentTerm && state != Follower`, `becomeFollower` resets `votedFor` to -1. The trace event's `votedFor` field will show -1 (Nil), which the Trace spec validates.

### Persistence State

The trace does not directly observe persisted state (it's in the Storage interface). For F1b debugging, add optional fields:
- `persistedTerm`: value in storage after event
- `persistedVotedFor`: value in storage after event

These can be captured by wrapping the MapStorage implementation to expose its state, or by reading it after each traced event.

### Bootstrap State

The implementation starts with:
- `currentTerm = 0` (or restored from storage)
- `votedFor = -1` (Nil)
- Empty log
- `commitIndex = -1` (→ TLA+ 0)
- `state = Follower`

TraceInit matches these values. If a trace starts from a recovered node (with pre-existing storage), TraceInit should be adjusted to match the recovered state.
