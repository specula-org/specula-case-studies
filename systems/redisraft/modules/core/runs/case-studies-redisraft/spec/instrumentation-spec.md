# Instrumentation Spec: RedisRaft

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a single NDJSON line:

```json
{
  "tag": "trace",
  "event": {
    "name": "<action_name>",
    "nid": "<server_id>",
    "state": { ... },
    "msg": { ... }     // optional, for message events
  }
}
```

### State Fields

Captured at every event (after the action completes):

| Impl getter/field | TLA+ variable | JSON field |
|---|---|---|
| `me->current_term` | `currentTerm[i]` | `state.term` |
| `raft_get_state(me)` | `state[i]` | `state.role` ("Follower"/"Candidate"/"Leader") |
| `me->commit_idx` | `commitIndex[i]` | `state.commitIndex` |
| `raft_get_current_idx(me)` | `LastLogIndex(i)` | `state.lastLogIndex` |
| `raft_get_last_log_term(me)` | `LastLogTerm(i)` | `state.lastLogTerm` |
| `me->voted_for` | `votedFor[i]` | `state.votedFor` ("" for Nil, else server id) |

### Message Fields

For message events, additional fields under `msg`:

| Field | Description |
|---|---|
| `msg.from` | Source server ID |
| `msg.to` | Destination server ID |
| `msg.term` | Message term |
| `msg.success` | (AE response) whether accepted |
| `msg.matchIndex` | (AE response) follower's match index |
| `msg.prevLogIndex` | (AE request) prev log index |
| `msg.prevLogTerm` | (AE request) prev log term |
| `msg.leaderCommit` | (AE request) leader's commit index |
| `msg.voteGranted` | (RV response) vote granted |
| `msg.snapIdx` | (IS request) snapshot last index |
| `msg.snapTerm` | (IS request) snapshot last term |

## Section 2: Action-to-Code Mapping

### Election Actions

#### 1. Timeout

- **Spec action**: `Timeout(i)`
- **Code location**: `deps/raft/src/raft_server.c:523-559` (`raft_become_candidate`)
- **Trigger point**: After `raft_become_candidate()` completes (term incremented, votes sent)
- **Trace event name**: `Timeout`
- **Fields**: State (full)
- **Notes**: Capture AFTER term increment and self-vote. The `raft_election_start()` at line 414-425 decides between precandidate and candidate; we only trace the candidate path since PreVote is not modeled.

#### 2. HandleRequestVoteRequest

- **Spec action**: `HandleRequestVoteRequest(i, m)`
- **Code location**: `deps/raft/src/raft_server.c:990-1081` (`raft_recv_requestvote`)
- **Trigger point**: After response is built but before return (line 1073-1081)
- **Trace event name**: `HandleRequestVoteRequest`
- **Fields**: State (full) + Message (`from`, `to`, `term`, `voteGranted`)
- **Notes**: `msg.from` = candidate ID (`req->candidate_id`), `msg.to` = self. Capture state AFTER term update (line 1021) and vote grant (line 1057).

#### 3. HandleRequestVoteResponse

- **Spec action**: `HandleRequestVoteResponse(i, m)`
- **Code location**: `deps/raft/src/raft_server.c:1091-1149` (`raft_recv_requestvote_response`)
- **Trigger point**: After vote counting and potential state transition (line 1139-1145)
- **Trace event name**: `HandleRequestVoteResponse`
- **Fields**: State (weak: term + role only) + Message (`from`, `to`, `voteGranted`)
- **Notes**: Use weak validation because the response handler doesn't directly update commitIndex/log. `msg.from` = voter, `msg.to` = candidate (self).

#### 4. BecomeLeader

- **Spec action**: `BecomeLeader(i)`
- **Code location**: `deps/raft/src/raft_server.c:443-496` (`raft_become_leader`)
- **Trigger point**: After noop append and state transition to Leader (line 470)
- **Trace event name**: `BecomeLeader`
- **Fields**: State (full — includes noop in lastLogIndex)
- **Notes**: The noop entry (line 445-455) changes lastLogIndex. Capture AFTER the noop is appended.

### Replication Actions

#### 5. ClientRequest

- **Spec action**: `ClientRequest(i)`
- **Code location**: `deps/raft/src/raft_server.c:1184-1206` (`raft_recv_entry`, entry append)
- **Also**: `src/redisraft.c:767-788` (`handleRedisCommandAppend`, write dispatch)
- **Trigger point**: After `raft_append_entry()` completes (line 1186)
- **Trace event name**: `ClientRequest`
- **Fields**: State (full)
- **Notes**: Trace at the raft library level (`raft_recv_entry`), not the Redis command handler, to avoid re-entrancy issues.

#### 6. HandleAppendEntriesRequest

- **Spec action**: `HandleAppendEntriesRequest(i, m)`
- **Code location**: `deps/raft/src/raft_server.c:823-970` (`raft_recv_appendentries`)
- **Trigger point**: After all log updates and commit index advancement, before return (line 964-969)
- **Trace event name**: `HandleAppendEntriesRequest`
- **Fields**: State (full) + Message (`from`, `to`, `term`, `prevLogIndex`, `prevLogTerm`, `leaderCommit`)
- **Notes**: Capture AFTER truncation (line 939), append (line 950), and commit advance (line 967-968). `msg.from` = leader, `msg.to` = self.

#### 7. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `deps/raft/src/raft_server.c:725-821` (`raft_recv_appendentries_response`)
- **Trigger point**: After matchIndex/nextIndex update (line 804-814), before return
- **Trace event name**: `HandleAppendEntriesResponse`
- **Fields**: State (weak) + Message (`from`, `to`, `success`, `matchIndex`)
- **Notes**: Use weak validation — the leader's log/commitIndex aren't changed by this handler. `msg.from` = follower, `msg.to` = leader (self).

#### 8. AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `deps/raft/src/raft_server.c` — commit index computation (called from `raft_flush` or similar periodic function)
- **Trigger point**: After `commitIndex` is updated
- **Trace event name**: `AdvanceCommitIndex`
- **Fields**: State (commit: term + role + commitIndex)
- **Notes**: This may be called internally (not from an explicit RPC handler). Instrument at the point where `me->commit_idx` changes.

### Snapshot Actions (Bug Family 1)

#### 9. TakeSnapshot

- **Spec action**: `TakeSnapshot(i)`
- **Code location**: `deps/raft/src/raft_server.c:1825-1902` (`raft_begin_snapshot` + `raft_end_snapshot`)
- **Also**: `src/snapshot.c:238-424` (`initiateSnapshot` / `finalizeSnapshot`)
- **Trigger point**: After `raft_end_snapshot()` completes (line 1873, snapshot_in_progress=0)
- **Trace event name**: `TakeSnapshot`
- **Fields**: State (full) + `snapshotIdx` (= `me->snapshot_last_idx`), `snapshotTerm` (= `me->snapshot_last_term`)
- **Notes**: Trace at the raft library level after end_snapshot, not at the RedisRaft layer.

#### 10. HandleInstallSnapshotRequest

- **Spec action**: `HandleInstallSnapshotRequest(i, m)` (begin load step)
- **Code location**: `deps/raft/src/raft_server.c:1904-1956` (`raft_begin_load_snapshot`)
- **Also**: `src/snapshot.c:527-530` (`raft_begin_load_snapshot` call in `raftLoadSnapshot`)
- **Trigger point**: After `raft_begin_load_snapshot()` completes (line 1956)
- **Trace event name**: `HandleInstallSnapshotRequest`
- **Fields**: State (weak: term + role) + Message (`from`, `to`, `snapIdx`, `snapTerm`)
- **Notes**: Use weak validation — commitIndex and log are reset atomically here but lastLogIndex will be 0 (log empty). `msg.from` = leader, `msg.to` = self.

#### 11. EndLoadSnapshot

- **Spec action**: `EndLoadSnapshot(i)`
- **Code location**: `deps/raft/src/raft_server.c:1958-1975` (`raft_end_load_snapshot`)
- **Also**: `src/snapshot.c:540` (`raft_end_load_snapshot` call in `raftLoadSnapshot`)
- **Trigger point**: After `raft_end_load_snapshot()` returns (line 1975)
- **Trace event name**: `EndLoadSnapshot`
- **Fields**: State (full) + `snapshotIdx`, `snapshotTerm`
- **Notes**: After this, `snapshotLastIdx` equals `logOffset` (gap is closed).

#### 12. SendInstallSnapshot

- **Not traced** — the send side is modeled as a silent action in the trace spec. Only the receive side (`HandleInstallSnapshotRequest`) is traced.

### Membership Actions (Bug Family 3)

#### 13. ProposeAddServer

- **Spec action**: `ProposeAddServer(i, target)`
- **Code location**: `deps/raft/src/raft_server.c:1151-1199` (`raft_recv_entry` for ConfigEntry)
- **Also**: `src/raft.c:1022-1094` (`raftApplyLog` → `raftNotifyMembershipEvent`)
- **Trigger point**: After `raft_append_entry()` for the config change entry
- **Trace event name**: `ProposeAddServer`
- **Fields**: State (full) + `target` (server ID being added)
- **Notes**: The `target` field identifies which server is being added. Check `entry->type == RAFT_LOGTYPE_ADD_NODE` or `RAFT_LOGTYPE_ADD_NONVOTING_NODE`.

#### 14. ProposeRemoveServer

- **Spec action**: `ProposeRemoveServer(i, target)`
- **Code location**: `deps/raft/src/raft_server.c:1151-1199` (`raft_recv_entry` for ConfigEntry)
- **Trigger point**: After `raft_append_entry()` for the config change entry
- **Trace event name**: `ProposeRemoveServer`
- **Fields**: State (full) + `target` (server ID being removed)
- **Notes**: Check `entry->type == RAFT_LOGTYPE_REMOVE_NODE`.

### Crash/Recovery

#### 15. Crash

- **Spec action**: `Crash(i)`
- **Code location**: Not directly in code — detected on restart
- **Trigger point**: First event after server restart (when a server re-initializes)
- **Trace event name**: `Crash`
- **Fields**: State (minimal: just `nid` to identify the server)
- **Notes**: The harness should emit a `Crash` event when it detects that a server has restarted. This can be done by comparing the monotonic clock or process ID. The state after crash is the initial recovery state (Follower, commitIndex=0).

## Section 3: Special Considerations

### 1. State Capture Timing

Most events should capture state AFTER the action completes (post-state). This is critical for:
- `Timeout`: capture AFTER term increment (otherwise term is off-by-one)
- `HandleAppendEntriesRequest`: capture AFTER log truncation/append AND commit advance
- `BecomeLeader`: capture AFTER noop append (so lastLogIndex includes the noop)

### 2. Single-Threaded Event Loop

RedisRaft runs on Redis's single-threaded event loop. This means:
- No concurrent access to raft state — no need for locking around trace capture
- Background fsync thread does NOT modify raft state — safe to ignore
- The trace is naturally ordered by the event loop's execution order

### 3. Bootstrap / Initial State

RedisRaft starts with `currentTerm=0` (unlike braft which starts at 1). The `TraceInit` in the trace spec matches this. If the trace starts from a non-zero state (e.g., after recovery), the `TraceInit` must be adjusted.

### 4. Serialization Quirks

- `votedFor`: the raft library uses `RAFT_NODE_ID_NONE` (typically -1 or 0) for "not voted". Serialize as empty string `""` in the trace, which maps to `Nil` in the spec.
- Config entries: the `config` field in the log entry should serialize the set of voting node IDs. Use a JSON array: `[1, 2, 3]`.
- Entry types: serialize as strings: `"ValueEntry"`, `"ConfigEntry"`, `"NoopEntry"`.

### 5. Message Events

Message events have both a `nid` (the server processing the message) and a `msg` sub-object with `from`/`to`. The `nid` always equals `msg.to` (the receiver processes the message).

For send events that are NOT traced (e.g., `AppendEntries`, `SendInstallSnapshot`), the trace spec uses silent actions to create the messages in the bag before the receive event.

### 6. Snapshot Events

The two-step snapshot load (`HandleInstallSnapshotRequest` → `EndLoadSnapshot`) must both be traced. If only the combined event is available:
- Emit `HandleInstallSnapshotRequest` at the point of `raft_begin_load_snapshot()`
- Emit `EndLoadSnapshot` at the point of `raft_end_load_snapshot()`

This two-event sequence is critical for Bug Family 1: the trace spec needs to verify that both steps complete for the snapshot to be consistent.

### 7. Crash Detection

Since crash events aren't initiated by the code (they're external), the harness must detect server restarts. Approaches:
- **Process-level**: monitor the raft server process; emit `Crash` when a new process starts for the same server ID
- **State-level**: emit `Crash` when `currentTerm` and `state` show initialization values on the first event after a gap
- **Test-harness**: if using a test framework (e.g., Jepsen), the harness controls crashes and can emit events directly

### 8. Instrumentation Locations Summary

| # | Event | File | Line | Trigger |
|---|---|---|---|---|
| 1 | `Timeout` | `raft_server.c` | 559 | After `raft_become_candidate()` |
| 2 | `HandleRequestVoteRequest` | `raft_server.c` | 1073 | Before return from `raft_recv_requestvote()` |
| 3 | `HandleRequestVoteResponse` | `raft_server.c` | 1145 | Before return from `raft_recv_requestvote_response()` |
| 4 | `BecomeLeader` | `raft_server.c` | 496 | End of `raft_become_leader()` |
| 5 | `ClientRequest` | `raft_server.c` | 1206 | End of `raft_recv_entry()` |
| 6 | `HandleAppendEntriesRequest` | `raft_server.c` | 970 | Before return from `raft_recv_appendentries()` |
| 7 | `HandleAppendEntriesResponse` | `raft_server.c` | 821 | Before return from `raft_recv_appendentries_response()` |
| 8 | `AdvanceCommitIndex` | `raft_server.c` | varies | After `me->commit_idx` update |
| 9 | `TakeSnapshot` | `raft_server.c` | 1902 | After `raft_end_snapshot()` |
| 10 | `HandleInstallSnapshotRequest` | `raft_server.c` | 1956 | After `raft_begin_load_snapshot()` |
| 11 | `EndLoadSnapshot` | `raft_server.c` | 1975 | After `raft_end_load_snapshot()` |
| 12 | `ProposeAddServer` | `raft_server.c` | 1199 | After `raft_recv_entry()` for add config |
| 13 | `ProposeRemoveServer` | `raft_server.c` | 1199 | After `raft_recv_entry()` for remove config |
| 14 | `Crash` | N/A | N/A | External detection on restart |
