# Instrumentation Spec: willemt/raft

Mapping between TLA+ spec actions and source code locations for trace harness generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "node": "<server_id>",
  "post": {
    "term": <int>,
    "state": "<follower|candidate|leader>",
    "commitIndex": <int>,
    "lastLogIndex": <int>,
    "lastLogTerm": <int>
  },
  "from": "<sender_id>",       // for message events
  "to": "<receiver_id>",       // for message events
  "msg": { ... },              // message-specific fields
  "value": "<value>"           // for client requests
}
```

### State Fields (captured at every event via `post`)

| Implementation getter | TLA+ variable | Field name |
|---|---|---|
| `raft_get_current_term(me_)` | `currentTerm[i]` | `post.term` |
| `raft_get_state(me_)` → string | `state[i]` | `post.state` |
| `raft_get_commit_idx(me_)` | `commitIndex[i]` | `post.commitIndex` |
| `raft_get_current_idx(me_)` | `LastLogIndex(i)` | `post.lastLogIndex` |
| `raft_get_last_log_term(me_)` | `LastLogTerm(i)` | `post.lastLogTerm` |

### State String Mapping

| C constant | String |
|---|---|
| `RAFT_STATE_FOLLOWER` (1) | `"follower"` |
| `RAFT_STATE_CANDIDATE` (2) | `"candidate"` |
| `RAFT_STATE_LEADER` (3) | `"leader"` |

## 2. Action-to-Code Mapping

### 2.1 Timeout

| Field | Value |
|---|---|
| **Spec action** | `Timeout(i)` |
| **Code location** | `raft_server.c:146-155` (`raft_election_start`) called from `raft_server.c:247` (`raft_periodic`) |
| **Trigger point** | After `raft_become_candidate` returns (line 154) |
| **Trace event** | `"Timeout"` |
| **Fields** | `node`, `post` (full state snapshot) |
| **Notes** | Only fires when `election_timeout_rand <= timeout_elapsed` AND not snapshotting AND is voting node. Captures state AFTER term increment and self-vote. |

### 2.2 HandleRequestVoteRequest

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteRequest(i, j, m)` |
| **Code location** | `raft_server.c:575-645` (`raft_recv_requestvote`) |
| **Trigger point** | After response is prepared (before return, line 644) |
| **Trace event** | `"HandleRequestVoteRequest"` |
| **Fields** | `to` (receiver=i), `from` (sender=j), `msg.term` (vr->term), `msg.candidateId` (vr->candidate_id), `msg.lastLogIdx` (vr->last_log_idx), `msg.lastLogTerm` (vr->last_log_term), `msg.voteGranted` (r->vote_granted), `post` |
| **Notes** | `from` is the candidate sending the RV. `msg.voteGranted` captures the response for debugging. |

### 2.3 HandleRequestVoteResponse

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteResponse(i, j, m)` |
| **Code location** | `raft_server.c:655-716` (`raft_recv_requestvote_response`) |
| **Trigger point** | After vote processing (before return, line 715) |
| **Trace event** | `"HandleRequestVoteResponse"` |
| **Fields** | `to` (candidate=i), `from` (voter=j), `msg.term` (r->term), `msg.voteGranted` (r->vote_granted), `post` |
| **Notes** | If the candidate becomes leader (line 699), `post.state` will be `"leader"`. |

### 2.4 ClientRequest

| Field | Value |
|---|---|
| **Spec action** | `ClientRequest(i, v)` |
| **Code location** | `raft_server.c:718-779` (`raft_recv_entry`) |
| **Trigger point** | After successful append (line 746, after `raft_append_entry` returns 0) |
| **Trace event** | `"ClientRequest"` |
| **Fields** | `node` (leader=i), `value` (entry ID or serialized value), `post` |
| **Notes** | Only fires on success (leader, no error). The `value` field should uniquely identify the entry. |

### 2.5 SendAppendEntries

| Field | Value |
|---|---|
| **Spec action** | `SendAppendEntries(i, j)` |
| **Code location** | `raft_server.c:882-937` (`raft_send_appendentries`) |
| **Trigger point** | After `send_appendentries` callback is invoked (line 936) |
| **Trace event** | `"SendAppendEntries"` |
| **Fields** | `from` (leader=i), `to` (peer=j), `msg.term` (ae.term), `msg.prevLogIdx` (ae.prev_log_idx), `msg.prevLogTerm` (ae.prev_log_term), `msg.leaderCommit` (ae.leader_commit), `msg.nEntries` (ae.n_entries) |
| **Notes** | Does NOT fire when `RAFT_ERR_NEEDS_SNAPSHOT` is returned (line 905). That path triggers `SendInstallSnapshot` instead. Called from multiple sites: `raft_become_leader` (line 175), `raft_recv_appendentries_response` (line 378), `raft_recv_entry` (line 763), `raft_periodic` via `raft_send_appendentries_all` (line 950). |

### 2.6 HandleAppendEntriesRequest

| Field | Value |
|---|---|
| **Spec action** | `HandleAppendEntriesRequest(i, j, m)` |
| **Code location** | `raft_server.c:385-528` (`raft_recv_appendentries`) |
| **Trigger point** | After response is prepared (before return, line 527) |
| **Trace event** | `"HandleAppendEntriesRequest"` |
| **Fields** | `to` (follower=i), `from` (leader=j), `msg.term` (ae->term), `msg.prevLogIdx` (ae->prev_log_idx), `msg.prevLogTerm` (ae->prev_log_term), `msg.leaderCommit` (ae->leader_commit), `msg.nEntries` (ae->n_entries), `msg.success` (r->success), `msg.currentIdx` (r->current_idx), `post` |
| **Notes** | This is the most critical function to instrument. The `msg.success` and `msg.currentIdx` fields capture the response for validation. |

### 2.7 HandleAppendEntriesResponse

| Field | Value |
|---|---|
| **Spec action** | `HandleAppendEntriesResponse(i, j, m)` |
| **Code location** | `raft_server.c:275-383` (`raft_recv_appendentries_response`) |
| **Trigger point** | After commit index potentially updated (before return, line 382) |
| **Trace event** | `"HandleAppendEntriesResponse"` |
| **Fields** | `to` (leader=i), `from` (follower=j), `msg.term` (r->term), `msg.success` (r->success), `msg.currentIdx` (r->current_idx), `msg.firstIdx` (r->first_idx), `post` |
| **Notes** | The commit advancement logic (lines 351-373) modifies `commitIndex` — capture in `post.commitIndex`. If leader steps down (lines 297-303), `post.state` will be `"follower"`. |

### 2.8 TakeSnapshot

| Field | Value |
|---|---|
| **Spec action** | `TakeSnapshot(i)` |
| **Code location** | `raft_server.c:1258-1291` (`raft_begin_snapshot`) + `raft_server.c:1308-1357` (`raft_end_snapshot`) |
| **Trigger point** | After `raft_end_snapshot` returns successfully (line 1356) |
| **Trace event** | `"TakeSnapshot"` |
| **Fields** | `node` (server=i), `snapshotLastIdx` (me->snapshot_last_idx), `snapshotLastTerm` (me->snapshot_last_term), `post` |
| **Notes** | The spec models begin+end as a single atomic action. Instrument at the END of the lifecycle. The snapshot metadata fields are needed because `post` doesn't include them. |

### 2.9 SendInstallSnapshot

| Field | Value |
|---|---|
| **Spec action** | `SendInstallSnapshot(i, j)` |
| **Code location** | `raft_server.c:903-904` (`send_snapshot` callback invocation) |
| **Trigger point** | After `send_snapshot` callback returns (line 904) |
| **Trace event** | `"SendInstallSnapshot"` |
| **Fields** | `from` (leader=i), `to` (peer=j), `msg.snapshotLastIdx` (me->snapshot_last_idx), `msg.snapshotLastTerm` (me->snapshot_last_term) |
| **Notes** | Triggered inside `raft_send_appendentries` when `NeedsSnapshot` condition is true. Also triggered from `raft_end_snapshot` (lines 1349-1353). |

### 2.10 HandleInstallSnapshot

| Field | Value |
|---|---|
| **Spec action** | `HandleInstallSnapshot(i, j, m)` |
| **Code location** | `raft_server.c:1359-1417` (`raft_begin_load_snapshot`) + `raft_server.c:1419-1435` (`raft_end_load_snapshot`) |
| **Trigger point** | After `raft_end_load_snapshot` returns (line 1435) |
| **Trace event** | `"HandleInstallSnapshot"` |
| **Fields** | `to` (follower=i), `from` (leader=j), `msg.snapshotLastIdx` (last_included_index), `msg.snapshotLastTerm` (last_included_term), `post` |
| **Notes** | CRITICAL: line 1383-1384 sets term/vote WITHOUT persist callbacks. The `post.term` may be LOWER than the pre-event term. This is the bug (Family 3+4). |

### 2.11 Crash

| Field | Value |
|---|---|
| **Spec action** | `Crash(i)` |
| **Code location** | Test harness (simulated crash) |
| **Trigger point** | Before stopping the server |
| **Trace event** | `"Crash"` |
| **Fields** | `node` (server=i) |
| **Notes** | Not a real code path — injected by the test harness. |

### 2.12 Recover

| Field | Value |
|---|---|
| **Spec action** | `Recover(i)` |
| **Code location** | Test harness (simulated recovery) |
| **Trigger point** | After server restart with restored persistent state |
| **Trace event** | `"Recover"` |
| **Fields** | `node` (server=i), `post` |
| **Notes** | Not a real code path — injected by the test harness. `post` captures state after recovery (volatile state reset, persistent state preserved). |

## 3. Special Considerations

### 3.1 Callback-Based Architecture

willemt/raft is a callback-based library — the user provides all I/O callbacks. The trace harness must implement these callbacks to:
1. Record trace events (the primary purpose)
2. Deliver messages between server instances (simulated network)
3. Persist term/vote/log to storage (simulated persistence)

The test harness is effectively a "Raft cluster simulator" that drives multiple `raft_server_t` instances.

### 3.2 Single-Threaded Model

All state mutations are atomic within a handler call. There are no concurrent threads, so there's no risk of interleaved trace events within a single server. Events from different servers can interleave freely.

### 3.3 Node ID Mapping

The implementation uses integer node IDs (assigned by `raft_add_node` call order). The trace must map these to TLA+ server constants. Recommended: use the node ID directly as the server constant (e.g., node 1 → `s1`, node 2 → `s2`).

### 3.4 Message Routing

The `send_requestvote` and `send_appendentries` callbacks receive the target node. The harness must:
1. Serialize the message
2. Emit a `Send*` trace event
3. Queue the message for the target server
4. On delivery: call `raft_recv_*` on the target and emit a `Handle*` trace event

### 3.5 voted_for Sentinel Value

The implementation uses `-1` for "no vote" (`raft_server.c:76`). The spec uses `Nil`. The trace must map `-1` to `null` in JSON (which maps to `Nil` in the TLA+ `Trace.tla`).

### 3.6 Log Entry Format

Implementation entries have `term`, `id`, `type`, and `data` fields. The spec simplifies to `[term, value]`. The trace should emit entries as:
```json
{"term": <int>, "value": "<entry_id_or_type>"}
```

### 3.7 Multiple Call Sites for SendAppendEntries

`raft_send_appendentries` is called from 4 locations:
- `raft_become_leader` (line 175) — initial heartbeat on becoming leader
- `raft_recv_appendentries_response` (line 378) — aggressive send of remaining entries
- `raft_recv_entry` (line 763) — send new entry to caught-up peers
- `raft_send_appendentries_all` via `raft_periodic` (line 237/950) — periodic heartbeat

All produce the same trace event. The harness should instrument the single `raft_send_appendentries` function.

### 3.8 Snapshot Lifecycle

The implementation has a two-phase snapshot API:
- `raft_begin_snapshot` → ... user serializes state ... → `raft_end_snapshot`
- `raft_begin_load_snapshot` → ... user deserializes state ... → `raft_end_load_snapshot`

The spec models each pair as a single atomic action. The harness should emit one trace event per completed lifecycle (i.e., on `end_*`).

### 3.9 Bootstrap State

The implementation starts with:
- `current_term = 0`
- `voted_for = -1` (Nil)
- `state = RAFT_STATE_FOLLOWER`
- `commit_idx = 0`
- `last_applied_idx = 0`
- Empty log
- `snapshot_last_idx = 0`, `snapshot_last_term = 0`

This matches the spec's `Init` exactly. No bootstrap fixup needed.
