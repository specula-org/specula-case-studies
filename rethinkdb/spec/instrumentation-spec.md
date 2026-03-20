# Instrumentation Spec: RethinkDB Raft

Maps TLA+ spec actions to source code locations for trace collection.

**Source files**:
- `src/clustering/generic/raft_core.tcc` (primary — all protocol logic)
- `src/clustering/generic/raft_core.hpp` (type definitions)

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "raft",
  "event": "<event_name>",
  "node": "<member_id_str>",
  "ts": <monotonic_ns>,
  "state": {
    "currentTerm": <uint64>,
    "role": "follower" | "candidate" | "leader",
    "commitIndex": <uint64>,
    "lastLogIndex": <uint64>,
    "lastLogTerm": <uint64>,
    "votedFor": "<member_id_str>" | null
  },
  ... (event-specific fields)
}
```

### State Fields Mapping

| Implementation getter/field | TLA+ variable | Capture timing |
|---|---|---|
| `ps().current_term` | `currentTerm[s]` | Every event |
| `mode` | `state[s]` | Every event |
| `ps().commit_index` / `committed_state.get_ref().log_index` | `commitIndex[s]` | Every event |
| `ps().log.get_latest_index()` | `Len(log[s])` | Every event |
| `ps().log.get_entry_term(latest_index)` | `LastTerm(s)` | Every event |
| `ps().voted_for` | `votedFor[s]` | Every event |

### Message Fields

| Implementation field | TLA+ field | Used in events |
|---|---|---|
| `request.term` | `m.term` | RV/AE send/recv |
| `request.candidate_id` | `m.from` | RV recv |
| `request.last_log_index` | `m.lastLogIndex` | RV recv |
| `request.last_log_term` | `m.lastLogTerm` | RV recv |
| `reply.vote_granted` | `m.voteGranted` | RV response |
| `request.leader_id` | `m.from` | AE recv |
| `request.entries.prev_index` | `m.prevLogIndex` | AE recv |
| `request.entries.prev_term` | `m.prevLogTerm` | AE recv |
| `request.leader_commit` | `m.leaderCommit` | AE recv |
| `reply.success` | `m.success` | AE response |

## Section 2: Action-to-Code Mapping

### 1. Timeout

- **Spec action**: `Timeout(s)`
- **Trace event**: `"timeout"`
- **Code location**: `raft_core.tcc:1034` — `on_watchdog()`
- **Trigger point**: After mode transition to candidate (`raft_core.tcc:1298`)
- **Fields**: state (post-transition, should show candidate)
- **Notes**: The watchdog fires in a coroutine; instrument inside the spawned coroutine after `mode = mode_t::candidate` in `candidate_and_leader_coro()` (line 1298). State capture must happen after `update_term` in `candidate_run_election` (line 1512).

### 2. RequestVote (send)

- **Spec action**: `RequestVote(s, t)`
- **Trace event**: `"request_vote_send"`
- **Code location**: `raft_core.tcc:1556` — `network->send_rpc(peer, request_wrapper, ...)` in `candidate_run_election`
- **Trigger point**: Before `send_rpc` call
- **Fields**: `from` = `this_member_id`, `to` = `peer`, `msg_term` = `request.term`
- **Notes**: Inside the spawned coroutine per peer. Must capture before the send to get the outgoing message fields.

### 3. HandleRequestVoteRequest (recv)

- **Spec action**: `HandleRequestVoteRequest(s, m)`
- **Trace event**: `"request_vote_recv"`
- **Code location**: `raft_core.tcc:404-520` — `on_request_vote_rpc()`
- **Trigger point**: After `reply_out` is set, before function return (line ~519)
- **Fields**: `node` = `this_member_id`, `from` = `request.candidate_id`, `msg_term` = `request.term`, `vote_granted` = `reply_out->vote_granted`, state (post-action)
- **Notes**: Multiple return points in this function. Instrument at each: line 439 (rejection), 457 (stale term), 477 (already voted), 495 (not up-to-date), 519 (granted). Use a common emit function before each `return`/end.

### 4. HandleRequestVoteResponse

- **Spec action**: `HandleRequestVoteResponse(s, m)`
- **Trace event**: `"request_vote_response"`
- **Code location**: `raft_core.tcc:1579-1598` — vote reply handling in `candidate_run_election`
- **Trigger point**: After processing reply, inside the mutex reacquisition block (line ~1574)
- **Fields**: `node` = `this_member_id`, `from` = `peer`, `vote_granted` = `reply->vote_granted`, state (post-action)
- **Notes**: Must capture after `candidate_or_leader_note_term` check (line 1579) and vote counting. If elected (mode becomes leader), the state snapshot should reflect leader.

### 5. StartVirtualHeartbeat

- **Spec action**: `StartVirtualHeartbeat(leader, follower)`
- **Trace event**: `"virtual_heartbeat_start"`
- **Code location**: `raft_core.tcc:888-953` — `on_connected_members_change()`
- **Trigger point**: After `virtual_heartbeat_sender = member_id` (line 928)
- **Fields**: `from` = `member_id` (leader), `to` = `this_member_id` (follower), `term` = `term`
- **Notes**: This runs in a spawned coroutine (line 900). Instrument inside the coroutine after the sender is set and watchdog blockers are initialized.

### 6. StopVirtualHeartbeat

- **Spec action**: `StopVirtualHeartbeat(leader, follower)`
- **Trace event**: `"virtual_heartbeat_stop"`
- **Code location**: `raft_core.tcc:944-953` — `on_connected_members_change()` else branch
- **Trigger point**: After `virtual_heartbeat_sender = raft_member_id_t()` (line 947)
- **Fields**: `from` = `member_id` (old sender), `to` = `this_member_id` (follower)
- **Notes**: Capture the `member_id` before it's cleared from `virtual_heartbeat_sender`.

### 7. ClientRequest

- **Spec action**: `ClientRequest(s, v)`
- **Trace event**: `"client_request"`
- **Code location**: `raft_core.tcc:183-212` — `propose_change()`
- **Trigger point**: After `leader_append_log_entry` (line 207)
- **Fields**: `node` = `this_member_id`, `value` = `<serialized change>`, state (post-action)
- **Notes**: The value field can be a hash or identifier for the change, not the full serialized form.

### 8. AppendEntries (send)

- **Spec action**: `AppendEntries(s, t)`
- **Trace event**: `"append_entries_send"`
- **Code location**: `raft_core.tcc:1855` — `network->send_rpc(peer, request_wrapper, ...)` in `leader_send_updates`
- **Trigger point**: Before `send_rpc` call (after request construction, line ~1848)
- **Fields**: `from` = `this_member_id`, `to` = `peer`, `msg_term` = `request.term`, `prevLogIndex` = `request.entries.prev_index`, `entries_count` = number of entries
- **Notes**: Also instrument the install-snapshot path (line 1786) with a separate event `"install_snapshot_send"` if snapshots are in scope.

### 9. HandleAppendEntriesRequest (recv)

- **Spec action**: `HandleAppendEntriesRequest(s, m)`
- **Trace event**: `"append_entries_recv"`
- **Code location**: `raft_core.tcc:626-735` — `on_append_entries_rpc()`
- **Trigger point**: Before function return (line ~734)
- **Fields**: `node` = `this_member_id`, `from` = `request.leader_id`, `msg_term` = `request.term`, `success` = `reply_out->success`, `prevLogIndex` = `request.entries.prev_index`, state (post-action)
- **Notes**: Multiple return paths: line 639 (rejected by on_rpc_from_leader), 657 (log mismatch), 734 (success). Use a single emit point at the end with `reply_out->success` to distinguish.

### 10. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(s, m)`
- **Trace event**: `"append_entries_response"`
- **Code location**: `raft_core.tcc:1885-1908` — reply handling in `leader_send_updates`
- **Trigger point**: After processing reply (after matchIndex/nextIndex update, line ~1908)
- **Fields**: `node` = `this_member_id`, `from` = `peer`, `success` = `reply->success`, state (post-action)
- **Notes**: Must capture after `leader_update_match_index` (line 1898) to reflect commit index advancement.

### 11. CompleteStepDown

- **Spec action**: `CompleteStepDown(s)`
- **Trace event**: `"complete_step_down"`
- **Code location**: `raft_core.tcc:1996-2014` — spawned coroutine in `candidate_or_leader_note_term`
- **Trigger point**: After `update_term` (line 2013)
- **Fields**: `node` = `this_member_id`, `new_term` = `term`, state (post-action, should show follower)
- **Notes**: The coroutine may find that the term was already updated (line 2001 check). Only emit if the step-down actually executes.

### 12. ProposeConfigChange

- **Spec action**: `ProposeConfigChange(s, newVoters)`
- **Trace event**: `"propose_config_change"`
- **Code location**: `raft_core.tcc:216-257` — `propose_config_change()`
- **Trigger point**: After `leader_append_log_entry` (line 244)
- **Fields**: `node` = `this_member_id`, `new_config` = `[member_id_str, ...]`, state (post-action)
- **Notes**: Capture the `new_config` parameter's voting members as a JSON array.

### 13. LeaderContinueReconfiguration

- **Spec action**: `LeaderContinueReconfiguration(s)`
- **Trace event**: `"continue_reconfiguration"`
- **Code location**: `raft_core.tcc:1942-1977` — `leader_continue_reconfiguration()`
- **Trigger point**: After `leader_append_log_entry` for C_new (line 1975)
- **Fields**: `node` = `this_member_id`, state (post-action)
- **Notes**: Only emit when the C_new entry is actually appended (the `else if` branch at line 1958).

### 14. LeaderStepDownAfterConfigChange

- **Spec action**: `LeaderStepDownAfterConfigChange(s)`
- **Trace event**: `"step_down_config_change"`
- **Code location**: `raft_core.tcc:1949-1957` — step-down path in `leader_continue_reconfiguration()`
- **Trigger point**: After `candidate_or_leader_note_term` call (line 1957)
- **Fields**: `node` = `this_member_id`, `new_term` = `ps().current_term + 1`
- **Notes**: This is the `if` branch at line 1949. The gratuitous term increment is a side effect.

### 15. Crash

- **Spec action**: `Crash(s)`
- **Trace event**: `"crash"`
- **Code location**: External (test harness or signal handler)
- **Trigger point**: Before server shutdown
- **Fields**: `node` = `this_member_id`
- **Notes**: Crash events are injected by the test harness, not the Raft code itself. The harness should emit this event before destroying the `raft_member_t`.

## Section 3: Special Considerations

### 3.1 Coroutine Concurrency

RethinkDB uses cooperative coroutines (`coro_t`) with a single mutex serializing all Raft operations. The key challenge is that `candidate_or_leader_note_term` (line 1980) spawns a coroutine that defers the actual step-down. Between the call and the coroutine execution, other actions can interleave.

**Instrumentation approach**: Emit `"complete_step_down"` only inside the spawned coroutine (lines 1996-2014), after the term update. The `DiscoverHigherTerm` action in the spec is not directly traced — it's implicit in the RPC handler that triggered it. The trace spec handles this via the `SilentCompleteStepDown` action.

### 3.2 Virtual Heartbeats

Virtual heartbeats are not traditional RPCs — they are connection-state changes observed via `get_connected_members()`. The `on_connected_members_change` callback (line 888) fires on each change.

**Instrumentation approach**: Instrument inside the coroutine spawned at line 900 (start) and at the else branch line 944 (stop). The VHB "sender" must be captured before `virtual_heartbeat_sender` is cleared.

### 3.3 State Snapshot Timing

The state snapshot (`state` field in events) must be captured **after** the action completes (post-state), since the trace spec validates post-state. For `on_request_vote_rpc`, this means after `write_current_term_and_voted_for` (line 503). For `on_append_entries_rpc`, this means after `update_commit_index` (line 728).

### 3.4 Member ID Serialization

`raft_member_id_t` is a UUID. For trace purposes, serialize as the first 4 hex characters of the UUID string (consistent with the debug logging at line 21: `uuid_to_str(mid.uuid).substr(0, 4)`). The trace spec maps these short IDs to the Server set.

### 3.5 Bootstrap State

All servers start with `current_term = 0`, `mode = follower`, empty log, and `commit_index = 0`. This matches `raft_persistent_state_t::make_initial()` (line 36-52). The `TraceInit` in the trace spec uses these defaults.

### 3.6 Multiple Return Points

Several functions have multiple return points (e.g., `on_request_vote_rpc` has 5 return paths). Use a helper macro or function that emits the trace event before each return. Example:

```cpp
#ifdef RETHINKDB_TLA_TRACE
#define RAFT_TRACE_EVENT(event_name, extra_fields) \
    raft_trace_emit(this_member_id, event_name, mode, ps(), extra_fields)
#endif
```

### 3.7 Thread Safety

All Raft operations are serialized by `mutex`, so no concurrent trace emission issues exist. However, the spawned coroutines (watchdog callback, note_term callback) acquire the mutex before acting, so trace emission should happen inside the mutex-holding region.

### 3.8 Config Serialization

For config change events, serialize the `raft_config_t::voting_members` set as a JSON array of member ID strings. The `new_config` field maps to the spec's `newVoters` parameter.

## Section 4: Snapshot Events (Family 5)

### 16. SendInstallSnapshot (send)

- **Spec action**: `SendInstallSnapshot(s, t)`
- **Trace event**: `"install_snapshot_send"`
- **Code location**: `raft_core.tcc:1786` — `network->send_rpc(peer, request_wrapper, ...)` in `leader_send_updates` (InstallSnapshot path)
- **Trigger point**: Before `send_rpc` call (after request construction, line ~1780)
- **Fields**: `from` = `this_member_id`, `to` = `peer`, `msg_term` = `request.term`, `lastIncludedIndex` = `request.last_included_index`
- **Notes**: This path is taken when `next_index <= ps().log.prev_index` (line 1764).

### 17. HandleInstallSnapshotRequest (recv)

- **Spec action**: `HandleInstallSnapshotRequest(s, m)`
- **Trace event**: `"install_snapshot_recv"`
- **Code location**: `raft_core.tcc:523-623` — `on_install_snapshot_rpc()`
- **Trigger point**: Before function return (line ~622)
- **Fields**: `node` = `this_member_id`, `from` = `request.leader_id`, `msg_term` = `request.term`, `lastIncludedIndex` = `request.last_included_index`, state (post-action)
- **Notes**: Three cases (old snapshot, partial overlap, full replace). Emit event at all three return points with a common helper.

### 18. HandleInstallSnapshotResponse

- **Spec action**: `HandleInstallSnapshotResponse(s, m)`
- **Trace event**: `"install_snapshot_response"`
- **Code location**: `raft_core.tcc:1814-1827` — reply handling in `leader_send_updates`
- **Trigger point**: After processing reply (after matchIndex update, line ~1827)
- **Fields**: `node` = `this_member_id`, `from` = `peer`, state (post-action)

### 19. TakeSnapshot

- **Spec action**: `TakeSnapshot(s)`
- **Trace event**: `"take_snapshot"`
- **Code location**: `raft_core.tcc:1181-1194` — inside `update_commit_index`
- **Trigger point**: After `write_snapshot` call (line 1193)
- **Fields**: `node` = `this_member_id`, `snapshotIndex` = `new_commit_index`, state (post-action)
- **Notes**: This is conditional on `should_take_snapshot`. Only emit when the snapshot is actually taken.

### 3.9 Snapshot State Fields

Add to the state snapshot in each event:

| Implementation getter/field | TLA+ variable | Capture timing |
|---|---|---|
| `ps().log.prev_index` | `snapshotIndex[s]` | Every event |
| `ps().log.prev_term` | `snapshotTerm[s]` | Every event |

### 3.10 Absolute Log Index

With snapshots, the absolute log index is `snapshotIndex + Len(local_log)`. The `lastLogIndex` field in the state snapshot should be the **absolute** index (`ps().log.get_latest_index()`), not the local log length. This already matches the implementation's getter.
