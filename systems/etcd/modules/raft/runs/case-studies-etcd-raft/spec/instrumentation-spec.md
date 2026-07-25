# Instrumentation Spec: etcd-io/raft

## 1. Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "node": "<server_id>",
  "state": {
    "term": <uint64>,
    "vote": <uint64|0>,
    "state": "<Follower|PreCandidate|Candidate|Leader>",
    "lead": <uint64|0>,
    "commitIndex": <uint64>,
    "lastLogIndex": <uint64>,
    "lastLogTerm": <uint64>
  },
  "msg": { ... }  // optional, for message-related events
}
```

### State Fields Mapping

| Implementation Field | TLA+ Variable | Getter |
|---------------------|---------------|--------|
| `r.Term` | `currentTerm[s]` | direct |
| `r.Vote` | `votedFor[s]` | direct (0 = Nil) |
| `r.state` | `state[s]` | `r.state.String()` |
| `r.lead` | `lead[s]` | direct (0 = Nil) |
| `r.raftLog.committed` | `commitIndex[s]` | direct |
| `r.raftLog.lastIndex()` | `Len(log[s])` | method call |
| `r.raftLog.lastEntryID().term` | `LastLogTerm(s)` | method call |

### Message Fields Mapping

| Implementation Field | TLA+ Field | Notes |
|---------------------|------------|-------|
| `m.Type` | `mtype` | Map pb.MsgType to spec constants |
| `m.Term` | `mterm` | |
| `m.From` | `msource` | |
| `m.To` | `mdest` | |
| `m.Index` | `mprevLogIndex` (MsgApp) / `mmatchIndex` (MsgAppResp) | Context-dependent |
| `m.LogTerm` | `mprevLogTerm` (MsgApp) | |
| `m.Entries` | `mentries` | Serialize as `[{term, value}]` |
| `m.Commit` | `mcommitIndex` | |
| `m.Reject` | `mreject` | |
| `m.Context` | `mctx` | ReadIndex context (bytes -> int) |

## 2. Action-to-Code Mapping

### Election Actions

| Spec Action | Code Location | Trigger Point | Event Name | Key Fields |
|-------------|--------------|---------------|------------|------------|
| `Timeout` | `raft.go:849-858` (tickElection) | After `r.Step(MsgHup)` returns | `"timeout"` | state (post-transition) |
| `HandleRequestVoteRequest` | `raft.go:1204-1254` | After vote grant/reject decision | `"handle_vote_request"` | state, msg (the request), grant (bool) |
| `HandleRequestVoteResponse` | `raft.go:1691-1706` (stepCandidate) | After `r.poll()` | `"handle_vote_response"` | state, msg, votesGranted count |
| `BecomeLeader` | `raft.go:933-971` | After `becomeLeader()` returns | `"become_leader"` | state |
| `HandlePreVoteRequest` | `raft.go:1204-1254` (MsgPreVote case) | After decision | `"handle_prevote_request"` | state, msg, grant |
| `HandlePreVoteResponse` | `raft.go:1691-1701` (PreCandidate case) | After `r.poll()` | `"handle_prevote_response"` | state, msg |

### Log Replication Actions

| Spec Action | Code Location | Trigger Point | Event Name | Key Fields |
|-------------|--------------|---------------|------------|------------|
| `ClientRequest` | `raft.go:1286-1344` (MsgProp in stepLeader) | After `r.appendEntry()` returns | `"client_request"` | state, entries appended |
| `AppendEntries` | `raft.go:616-659` (maybeSendAppend) | After `r.send(MsgApp)` | `"send_append"` | msg |
| `HandleAppendEntriesRequest` | `raft.go:1786-1828` | After response sent | `"handle_append_request"` | state, msg (request), success |
| `HandleAppendEntriesResponse` | `raft.go:1376-1569` (stepLeader) | After match/next update | `"handle_append_response"` | state, msg, newMatch, newCommit |

### Heartbeat Actions

| Spec Action | Code Location | Trigger Point | Event Name | Key Fields |
|-------------|--------------|---------------|------------|------------|
| `SendHeartbeat` | `raft.go:722-738` (bcastHeartbeat) | After `r.bcastHeartbeatWithCtx()` | `"send_heartbeat"` | readOnlyCtx |
| `HandleHeartbeat` | `raft.go:1830-1833` | After `r.raftLog.commitTo()` | `"handle_heartbeat"` | state, msg |
| `HandleHeartbeatResponse` | `raft.go:1571-1605` (stepLeader) | After ReadIndex ack processing | `"handle_heartbeat_response"` | state, msg, readIndexAdvanced |

### ReadIndex Actions

| Spec Action | Code Location | Trigger Point | Event Name | Key Fields |
|-------------|--------------|---------------|------------|------------|
| `RequestReadIndex` | `raft.go:2142-2158` (sendMsgReadIndexResponse) | After `addRequest` or lease response | `"request_read_index"` | readOnlyOption, commitIndex, ctx |

### CheckQuorum Action

| Spec Action | Code Location | Trigger Point | Event Name | Key Fields |
|-------------|--------------|---------------|------------|------------|
| `CheckQuorum` | `raft.go:1273-1284` (stepLeader MsgCheckQuorum) | After quorum check result | `"check_quorum"` | quorumActive (bool), recentActive map |

### Persist Actions

| Spec Action | Code Location | Trigger Point | Event Name | Key Fields |
|-------------|--------------|---------------|------------|------------|
| `PersistAndSend` | `rawnode.go` (Ready/Advance cycle) | After `wal.Save()` completes, before sending msgsAfterAppend | `"persist_complete"` | persistedTerm, persistedVote, numPendingMsgs |

### Fault Actions

| Spec Action | Code Location | Trigger Point | Event Name | Key Fields |
|-------------|--------------|---------------|------------|------------|
| `Crash` | N/A (test harness simulated) | On restart after simulated crash | `"crash_recovery"` | state (from HardState) |

## 3. Special Considerations

### msgsAfterAppend Tracking

The `msgs` vs `msgsAfterAppend` split is internal to the `raft` struct (raft.go:362-377). To trace this:
- Add a counter/flag in `send()` (raft.go:512) that records whether a message went to `msgs` or `msgsAfterAppend`
- The trace event for `PersistAndSend` should capture the count of messages flushed from `msgsAfterAppend`

### ReadIndex Context Mapping

The implementation uses `[]byte` for ReadIndex contexts (read_only.go:42). Post-fix (#397), these are monotonic internal indices. For tracing:
- Record the internal index used as context
- Map to TLA+ `nextReadCtx` counter

### State Transitions

Multiple spec actions may correspond to a single implementation function. For example:
- `raft.Step()` handles term bumps before dispatching to step functions
- The trace should capture the POST-state (after all effects are applied)

### Singleton Leader ReadIndex

When `IsSingleton()` is true (raft.go:1348-1352), ReadIndex responds immediately without heartbeat quorum. This bypasses the `readOnly` queue entirely. The trace should distinguish this path.

### CheckQuorum Timing

`MsgCheckQuorum` is triggered by `tickHeartbeat()` when `electionElapsed >= electionTimeout` (raft.go:866-872). This is periodic and implicit. The harness should capture this as an explicit event by intercepting the `Step(MsgCheckQuorum)` call.
