# Instrumentation Spec: vesoft-inc/nebula Raft

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object with the following structure:

```json
{
  "tag": "trace",
  "ts": 1234567890,
  "event": {
    "name": "<spec action name>",
    "nid": "<server-id>",
    "state": {
      "term": 3,
      "role": "Follower",
      "commitIndex": 5,
      "lastLogIndex": 7,
      "lastLogTerm": 3,
      "votedFor": "s1"
    },
    "msg": {
      "from": "<source-server-id>",
      "to": "<dest-server-id>",
      "term": 3,
      "type": "RequestVoteRequest"
    }
  }
}
```

### State Fields

| Implementation field | TLA+ variable | Getter |
|---------------------|---------------|--------|
| `term_` | `term[s]` | `RaftPart::termId()` or direct field access |
| `role_` | `role[s]` | `RaftPart::roleStr(role_)` → "Follower"/"Candidate"/"Leader" |
| `committedLogId_` | `commitIndex[s]` | Direct field access |
| `lastLogId_` | `LastLogIndex(s)` | Direct field access (note: Len(log[s]) in spec) |
| `lastLogTerm_` | `LastLogTerm(s)` | Direct field access |
| `votedAddr_` | `votedFor[s]` | Encode as string "host:port" or server ID; "" for Nil |
| `votedTerm_` | `votedTerm[s]` | Direct field access |
| `isBlindFollower_` | `blindFollower[s]` | Direct field access |
| `commitInThisTerm_` | `commitInThisTerm[s]` | Direct field access |

### Message Fields

| Implementation field | TLA+ field | Notes |
|---------------------|-----------|-------|
| `req.get_candidate_addr/port()` | `msg.from` | Vote request source |
| `req.get_leader_addr/port()` | `msg.from` | AppendEntries/Heartbeat source |
| `req.get_current_term()` | `msg.term` | Message term |
| `req.get_is_pre_vote()` | `msg.preVote` | Pre-vote flag |
| `req.get_committed_log_id()` | `msg.commitIndex` | Leader's commit index |

## Section 2: Action-to-Code Mapping

### 1. Timeout

- **Spec action**: `Timeout(i)` / `BlindFollowerTimeout(i)`
- **Code location**: `RaftPart.cpp:1143-1155` (`needToStartElection`)
- **Trigger point**: After line 1150 (`role_ = Role::CANDIDATE`)
- **Trace event name**: `"Timeout"`
- **Fields**: state (term, role=Candidate, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Captures both normal timeout and blind follower bypass. The `isBlindFollower_` field in state distinguishes them.

### 2. SendPreVote

- **Spec action**: `SendPreVote(i)`
- **Code location**: `RaftPart.cpp:1157-1195` (`prepareElectionRequest` with `isPreVote=true`)
- **Trigger point**: After line 1192 (hosts assigned, request prepared)
- **Trace event name**: `"SendPreVote"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Pre-vote does NOT increment own term (line 1181-1182). The request term is term_+1 but the node's term_ is unchanged.

### 3. SendRequestVote

- **Spec action**: `SendRequestVote(i)`
- **Code location**: `RaftPart.cpp:1157-1195` (`prepareElectionRequest` with `isPreVote=false`)
- **Trigger point**: After line 1187 (`votedTerm_ = term_`)
- **Trace event name**: `"SendRequestVote"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm, votedFor=self)
- **Notes**: Formal vote increments term (line 1184: `++term_`) and records self-vote (lines 1186-1187).

### 4. HandlePreVoteRequest

- **Spec action**: `HandlePreVoteRequest(i, m)`
- **Code location**: `RaftPart.cpp:1465-1576` (`processAskForVoteRequest`, pre-vote path)
- **Trigger point**: After line 1574 (response set, before return) for grant; after reject response for reject
- **Trace event name**: `"HandlePreVoteRequest"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm, votedFor), msg (from=candidate, term=req.term)
- **Notes**: Pre-vote grant does NOT change state (lines 1572-1575), but rejection due to higher actual term DOES cause step-down (lines 1522-1528, Family 5 bug). Must capture state AFTER potential step-down.

### 5. HandleRequestVoteRequest

- **Spec action**: `HandleRequestVoteRequest(i, m)`
- **Code location**: `RaftPart.cpp:1465-1607` (`processAskForVoteRequest`, formal path)
- **Trigger point**: After line 1601 (`resp.current_term_ref() = term_`) — final state
- **Trace event name**: `"HandleRequestVoteRequest"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm, votedFor), msg (from=candidate, term=req.term)
- **Notes**: Multiple paths: reject (term too low, log stale, already voted) vs grant (lines 1595-1601). Must capture state after all updates including potential step-down.

### 6. HandlePreVoteResponse

- **Spec action**: `HandlePreVoteResponse(i, m)`
- **Code location**: `RaftPart.cpp:1218-1289` (`processElectionResponses` with `isPreVote=true`)
- **Trigger point**: After response processing (line 1289)
- **Trace event name**: `"HandlePreVoteResponse"`
- **Fields**: state (term, role), msg (from=responder, term=resp.term)
- **Notes**: Weak validation (term + role only). May cause step-down if higher term (lines 1268-1272).

### 7. HandleRequestVoteResponse

- **Spec action**: `HandleRequestVoteResponse(i, m)`
- **Code location**: `RaftPart.cpp:1218-1289` (`processElectionResponses` with `isPreVote=false`)
- **Trigger point**: After response processing (line 1289)
- **Trace event name**: `"HandleRequestVoteResponse"`
- **Fields**: state (term, role), msg (from=responder, term=resp.term)
- **Notes**: Weak validation. May transition to Leader (handled separately by BecomeLeader event).

### 8. BecomeLeader

- **Spec action**: `BecomeLeader(i)`
- **Code location**: `RaftPart.cpp:1370-1398` (`handleElectionResponses`)
- **Trigger point**: After line 1384 (`onElected` task scheduled)
- **Trace event name**: `"BecomeLeader"`
- **Fields**: state (term, role=Leader, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: This is separate from HandleRequestVoteResponse because the code does additional setup (host reset, leader init) after the response processing.

### 9. ClientRequest

- **Spec action**: `ClientRequest(i)`
- **Code location**: `RaftPart.cpp:874-906` (`appendLogsInternal`)
- **Trigger point**: After WAL write succeeds (line 903: `lastId = wal_->lastLogId()`)
- **Trace event name**: `"ClientRequest"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Also covers the noop log appended during sendHeartbeat (RaftPart.cpp:2044-2048). If the noop is not separately instrumented, use SilentClientRequest in trace validation.

### 10. AppendEntries

- **Spec action**: `AppendEntries(i, j)`
- **Code location**: `RaftPart.cpp:918-1000` (`replicateLogs`)
- **Trigger point**: After Host::appendLogs is called (line 961-962)
- **Trace event name**: `"AppendEntries"`
- **Fields**: msg (from=leader, to=follower, term), state (term, role) — weak validation
- **Notes**: Multiple followers receive in parallel. One event per follower.

### 11. HandleAppendEntriesRequest

- **Spec action**: `HandleAppendEntriesRequest(i, m)`
- **Code location**: `RaftPart.cpp:1610-1827` (`processAppendLogRequest`)
- **Trigger point**: After line 1826 (`lastMsgRecvDur_.reset()`) — final state after all updates
- **Trace event name**: `"HandleAppendEntriesRequest"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm), msg (from=leader)
- **Notes**: Strong validation. This is where follower commitIndex advances (lines 1787-1822).

### 12. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `RaftPart.cpp:1002-1136` (`processAppendLogResponses`)
- **Trigger point**: After commit (line 1082-1083: `committedLogId_ = lastCommitId`)
- **Trace event name**: `"HandleAppendEntriesResponse"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm), msg (from=follower)
- **Notes**: Strong validation. This is where leader commitIndex advances. Step-down path (lines 1025-1037) is also captured.

### 13. SendHeartbeat

- **Spec action**: `SendHeartbeat(i, j)`
- **Code location**: `RaftPart.cpp:2041-2123` (`sendHeartbeat`)
- **Trigger point**: After line 2080 (heartbeat sent to host)
- **Trace event name**: `"SendHeartbeat"`
- **Fields**: msg (from=leader, to=follower, term), state (term, role) — weak validation
- **Notes**: One event per follower. The empty log append (lines 2044-2048) is NOT part of this event.

### 14. HandleHeartbeatRequest

- **Spec action**: `HandleHeartbeatRequest(i, m)`
- **Code location**: `RaftPart.cpp:1895-1952` (`processHeartbeatRequest`)
- **Trigger point**: After line 1947 (`lastMsgRecvDur_.reset()`)
- **Trace event name**: `"HandleHeartbeatRequest"`
- **Fields**: state (term, role, commitIndex, lastLogIndex, lastLogTerm), msg (from=leader)
- **Notes**: Strong validation. KEY: commitIndex should NOT change (Family 4).

### 15. HandleHeartbeatResponse

- **Spec action**: `HandleHeartbeatResponse(i, m)`
- **Code location**: `RaftPart.cpp:2091-2122` (`sendHeartbeat` callback)
- **Trigger point**: After response processing
- **Trace event name**: `"HandleHeartbeatResponse"`
- **Fields**: state (term, role), msg (from=follower)
- **Notes**: Weak validation. Step-down path if higher term (lines 2105-2109).

### 16. Crash

- **Spec action**: `Crash(i)`
- **Code location**: Not instrumented directly — triggered by test harness
- **Trigger point**: Before server shutdown
- **Trace event name**: `"Crash"`
- **Fields**: nid only (no state — server is crashing)
- **Notes**: Emitted by test harness, not by production code.

### 17. Restart

- **Spec action**: `Restart(i)`
- **Code location**: `RaftPart.cpp:400-454` (`start`)
- **Trigger point**: After line 448 (`startTimeMs_` set)
- **Trace event name**: `"Restart"`
- **Fields**: state (term, role=Follower, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Term is recovered from WAL lastLogTerm (line 414). votedFor/votedTerm are zeroed (volatile, never persisted).

### 18. StartSnapshot

- **Spec action**: `StartSnapshot(i, j)`
- **Code location**: `Host.cpp:348-379` (`startSendSnapshot`)
- **Trigger point**: After line 355 (`sendingSnapshot_ = true`)
- **Trace event name**: `"StartSnapshot"`
- **Fields**: msg (from=leader, to=follower), state (term, role)
- **Notes**: Marks the beginning of snapshot transfer.

### 19. CompleteSnapshot

- **Spec action**: `CompleteSnapshot(i, j)`
- **Code location**: `Host.cpp:358-374` (snapshot callback)
- **Trigger point**: After line 372 (`sendingSnapshot_ = false`)
- **Trace event name**: `"CompleteSnapshot"`
- **Fields**: msg (from=leader, to=follower), state (term, role)
- **Notes**: Fires regardless of success/failure. Key for Family 3: callback fires even after leadership change.

## Section 3: Special Considerations

### 1. Server Identity

Nebula uses `HostAddr` (host:port pairs) to identify servers. The trace harness must map these to simple string IDs (e.g., "s1", "s2", "s3") that match the TLA+ `Server` constant. Maintain a consistent mapping from the first encounter of each address.

### 2. Concurrency: Multiple Threads

Nebula uses multiple thread types:
- **Worker threads**: Handle AppendLog, RequestVote, Snapshot requests
- **IO threads**: Handle heartbeat sending
- **Background timer**: statusPolling (election/heartbeat scheduling)
- **Per-host replication**: Host objects manage per-peer replication state

Events from different threads may interleave. The trace harness should:
- Use a single mutex-protected trace writer per partition
- Capture state under `raftLock_` to ensure consistency
- The state snapshot must be taken AFTER all updates within the locked section

### 3. Heartbeat Empty Log

`sendHeartbeat()` (RaftPart.cpp:2044-2048) appends an empty log if not currently replicating. This log append goes through the normal `appendLogAsync` path and is NOT part of the heartbeat RPC. The trace harness can either:
- Emit a separate `ClientRequest` event for this append, or
- Let the trace spec handle it via `SilentClientRequest`

### 4. Pre-Vote vs Formal Vote

Both pre-vote and formal vote use the same RPC (`AskForVote`), distinguished by `is_pre_vote` field. The trace must emit distinct event names:
- `"SendPreVote"` / `"HandlePreVoteRequest"` / `"HandlePreVoteResponse"` for pre-vote
- `"SendRequestVote"` / `"HandleRequestVoteRequest"` / `"HandleRequestVoteResponse"` for formal

Check `req.get_is_pre_vote()` to determine which event name to use.

### 5. Election Flow Atomicity

In Nebula, `statusPolling` calls `leaderElection(true).get()` then `leaderElection(false).get()` synchronously. The trace sees individual message send/receive events, not the blocking `.get()` call. The `BecomeLeader` event is emitted from `handleElectionResponses`, separate from the vote response handling.

### 6. Non-Persisted State

`votedFor` and `votedTerm` are volatile class members (never written to stable storage). After crash+restart:
- `term` = WAL's `lastLogTerm()` (may differ from pre-crash `term_`)
- `votedFor` = `""` (Nil)
- `votedTerm` = `0`

The `Restart` event must capture these post-recovery values, not pre-crash values.

### 7. Lease State

`leaseExpired` and `commitInThisTerm` are spec-level abstractions. The trace does not directly observe lease state. If needed for debugging:
- `commitInThisTerm_` is a boolean field in `RaftPart` (directly observable)
- Lease validity is computed from timing (RaftPart.cpp:2254-2268) — capture `lastMsgAcceptedTime_` and `lastMsgAcceptedCostMs_` as optional fields

### 8. Snapshot State

Snapshot events span multiple RPC calls (batched data transfer). The trace harness should emit:
- `StartSnapshot`: when `sendingSnapshot_` is set to true (Host.cpp:355)
- `CompleteSnapshot`: when the snapshot callback fires (Host.cpp:358-374)

Intermediate snapshot data transfer RPCs are not traced.

### 9. Build Integration

Instrumentation is controlled by a compile-time flag:
```cmake
option(WITH_NEBULA_TRACE "Enable TLA+ trace instrumentation" OFF)
```

When enabled, trace events are written to a file specified by the `NEBULA_TRACE_FILE` environment variable. The trace writer should be initialized in `RaftPart::start()` and flushed on `stop()`.
