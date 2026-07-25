# Instrumentation Spec: ScyllaDB Raft Library

Maps TLA+ spec actions to source code locations for trace harness generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": <nanosecond_timestamp>,
  "event": {
    "name": "<action_name>",
    "nid": "<server_id>",
    "state": {
      "term": <int>,
      "role": "Follower"|"Candidate"|"Leader",
      "commitIndex": <int>,
      "lastLogIndex": <int>,
      "lastLogTerm": <int>
    },
    "msg": { ... }  // optional, for message-related events
  }
}
```

### State Fields

| Impl field | TLA+ variable | Accessor |
|-----------|--------------|---------|
| `_current_term` | `currentTerm` | `fsm::get_current_term()` |
| `_state` (variant index) | `state` | `fsm::is_leader()` / `is_follower()` / `is_candidate()` |
| `_commit_idx` | `commitIndex` | `fsm::commit_idx()` |
| `_log.last_idx()` | `LastLogIndex` | `fsm::log_last_idx()` |
| `_log.last_term()` | `LastLogTerm` | `fsm::log_last_term()` |

### Message Fields (for message events)

| Impl field | TLA+ field | Notes |
|-----------|-----------|-------|
| `from` (sender server_id) | `msg.from` | RPC source |
| `to` (receiver server_id) | `msg.to` | RPC destination |
| `current_term` | `msg.term` | Term in message |
| `prev_log_idx` | `msg.prevLogIdx` | AppendEntries only |
| `prev_log_term` | `msg.prevLogTerm` | AppendEntries only |
| `leader_commit_idx` | `msg.leaderCommitIdx` | AppendEntries/ReadQuorum |
| `entries.size()` | `msg.numEntries` | AppendEntries only |
| `vote_granted` | `msg.voteGranted` | VoteReply only |
| `read_id` | `msg.readId` | ReadQuorum only |

## 2. Action-to-Code Mapping

### 2.1 Timeout

| Field | Value |
|-------|-------|
| **Spec action** | `Timeout` |
| **Code location** | `fsm.cc:607-611` (tick → become_candidate path) |
| **Trigger point** | After `become_candidate()` completes (after vote requests queued) |
| **Trace event** | `"Timeout"` |
| **Fields** | `nid`, `state` (post-state with Candidate role, new term) |
| **Notes** | Only fires when `is_past_election_timeout()` is true and no stable leader |

### 2.2 BecomeLeader

| Field | Value |
|-------|-------|
| **Spec action** | `BecomeLeader` |
| **Code location** | `fsm.cc:160-190` |
| **Trigger point** | After `become_leader()` completes (after dummy entry appended) |
| **Trace event** | `"BecomeLeader"` |
| **Fields** | `nid`, `state` (post-state with Leader role) |
| **Notes** | Fires after dummy entry append, so lastLogIndex is +1 from before |

### 2.3 ClientRequest

| Field | Value |
|-------|-------|
| **Spec action** | `ClientRequest` |
| **Code location** | `fsm.cc:106-107` (log.emplace_back in add_entry) |
| **Trigger point** | After `_log.emplace_back()` completes |
| **Trace event** | `"ClientRequest"` |
| **Fields** | `nid`, `state` |
| **Notes** | Only for non-configuration entries. Skip add_entry for configuration type. |

### 2.4 AppendEntries (send)

| Field | Value |
|-------|-------|
| **Spec action** | `AppendEntries` |
| **Code location** | `fsm.cc:941` (send_to in replicate_to) |
| **Trigger point** | After `send_to(progress.id, std::move(req))` |
| **Trace event** | `"AppendEntries"` |
| **Fields** | `nid` (leader), `msg.from`, `msg.to`, `msg.term`, `msg.prevLogIdx`, `msg.prevLogTerm`, `msg.numEntries`, `msg.leaderCommitIdx` |
| **Notes** | May fire multiple times per replicate_to call (pipeline mode) |

### 2.5 HandleAppendEntriesRequest

| Field | Value |
|-------|-------|
| **Spec action** | `HandleAppendEntriesRequest` |
| **Code location** | `fsm.cc:633-670` (append_entries) |
| **Trigger point** | After entire append_entries() completes (after reply queued) |
| **Trace event** | `"HandleAppendEntriesRequest"` |
| **Fields** | `nid` (follower), `state`, `msg.from` (leader) |
| **Notes** | State captured AFTER commit index update and log append |

### 2.6 HandleAppendEntriesResponse

| Field | Value |
|-------|-------|
| **Spec action** | `HandleAppendEntriesResponse` |
| **Code location** | `fsm.cc:672-776` (append_entries_reply) |
| **Trigger point** | After append_entries_reply() completes |
| **Trace event** | `"HandleAppendEntriesResponse"` |
| **Fields** | `nid` (leader), `state`, `msg.from` (follower), `msg.success`, `msg.matchIdx` |
| **Notes** | Post-state may reflect commit advancement from maybe_commit() |

### 2.7 HandleRequestVoteRequest

| Field | Value |
|-------|-------|
| **Spec action** | `HandleRequestVoteRequest` |
| **Code location** | `fsm.cc:778-831` (request_vote) |
| **Trigger point** | After request_vote() completes (after reply queued) |
| **Trace event** | `"HandleRequestVoteRequest"` |
| **Fields** | `nid`, `state`, `msg.from` (candidate), `msg.voteGranted` |
| **Notes** | Skip prevote requests (is_prevote=true) — not modeled |

### 2.8 HandleRequestVoteResponse

| Field | Value |
|-------|-------|
| **Spec action** | `HandleRequestVoteResponse` |
| **Code location** | `fsm.cc:833-862` (request_vote_reply) |
| **Trigger point** | After request_vote_reply() completes |
| **Trace event** | `"HandleRequestVoteResponse"` |
| **Fields** | `nid` (candidate), `state`, `msg.from` (voter), `msg.voteGranted` |
| **Notes** | May trigger BecomeLeader — capture state AFTER potential transition |

### 2.9 MaybeCommit

| Field | Value |
|-------|-------|
| **Spec action** | `MaybeCommit` |
| **Code location** | `fsm.cc:425-510` (maybe_commit) |
| **Trigger point** | After _commit_idx is advanced (fsm.cc:450) |
| **Trace event** | `"MaybeCommit"` |
| **Fields** | `nid`, `state` |
| **Notes** | Only emit when commit index actually advances. May fire recursively after leave_joint. |

### 2.10 BroadcastReadQuorum

| Field | Value |
|-------|-------|
| **Spec action** | `BroadcastReadQuorum` |
| **Code location** | `fsm.cc:1052-1063` (broadcast_read_quorum) |
| **Trigger point** | After all read_quorum messages queued |
| **Trace event** | `"BroadcastReadQuorum"` |
| **Fields** | `nid`, `state`, `readId` (the new read id) |
| **Notes** | Also called from start_read_barrier (fsm.cc:1096-1115) |

### 2.11 HandleReadQuorumRequest

| Field | Value |
|-------|-------|
| **Spec action** | `HandleReadQuorumRequest` |
| **Code location** | `fsm.hh:552-556` (step follower read_quorum) |
| **Trigger point** | After advance_commit_idx and reply queued |
| **Trace event** | `"HandleReadQuorumRequest"` |
| **Fields** | `nid`, `state`, `msg.from`, `msg.readId` |

### 2.12 HandleReadQuorumResponse

| Field | Value |
|-------|-------|
| **Spec action** | `HandleReadQuorumResponse` |
| **Code location** | `fsm.cc:1065-1094` (handle_read_quorum_reply) |
| **Trigger point** | After handle_read_quorum_reply() completes |
| **Trace event** | `"HandleReadQuorumResponse"` |
| **Fields** | `nid`, `state`, `msg.from`, `msg.readId`, `maxReadIdWithQuorum` |

### 2.13 SendInstallSnapshot

| Field | Value |
|-------|-------|
| **Spec action** | `SendInstallSnapshot` |
| **Code location** | `fsm.cc:901-905` (send install_snapshot in replicate_to) |
| **Trigger point** | After `send_to(progress.id, install_snapshot{...})` |
| **Trace event** | `"SendInstallSnapshot"` |
| **Fields** | `nid`, `msg.from`, `msg.to`, `msg.snapshotIdx`, `msg.snapshotTerm` |

### 2.14 HandleInstallSnapshot

| Field | Value |
|-------|-------|
| **Spec action** | `HandleInstallSnapshot` |
| **Code location** | `fsm.hh:544-546` → `fsm.cc:982-1018` (apply_snapshot) |
| **Trigger point** | After apply_snapshot() returns |
| **Trace event** | `"HandleInstallSnapshot"` |
| **Fields** | `nid`, `state`, `msg.from`, snapshot fields |
| **Notes** | Post-state reflects new snapshotIdx and truncated log |

### 2.15 TakeLocalSnapshot

| Field | Value |
|-------|-------|
| **Spec action** | `TakeLocalSnapshot` |
| **Code location** | `fsm.cc:982-1018` (apply_snapshot with local=true) |
| **Trigger point** | After apply_snapshot() returns for local snapshot |
| **Trace event** | `"TakeLocalSnapshot"` |
| **Fields** | `nid`, `state`, `snapshotIdx`, `snapshotTerm` |
| **Notes** | Called from applier_fiber (server.cc:1419-1451) |

### 2.16 Crash

| Field | Value |
|-------|-------|
| **Spec action** | `Crash` |
| **Code location** | Server shutdown / io_fiber abort |
| **Trigger point** | After server stops (volatile state lost) |
| **Trace event** | `"Crash"` |
| **Fields** | `nid`, `state` (post-crash: Follower) |
| **Notes** | In testing, inject via server::abort() or stop() |

### 2.17 UpdateTerm

| Field | Value |
|-------|-------|
| **Spec action** | `UpdateTerm` |
| **Code location** | `fsm.hh:578-612` (step term comparison) |
| **Trigger point** | After become_follower + update_current_term |
| **Trace event** | `"UpdateTerm"` |
| **Fields** | `nid`, `state`, new term |
| **Notes** | Fires when msg.current_term > _current_term in step() dispatch |

### 2.18 ProposeConfigChange

| Field | Value |
|-------|-------|
| **Spec action** | `ProposeConfigChange` |
| **Code location** | `fsm.cc:69-121` (add_entry for configuration) |
| **Trigger point** | After configuration entry appended to log |
| **Trace event** | `"ProposeConfigChange"` |
| **Fields** | `nid`, `state`, `newVoters` (list of voter server IDs) |

## 3. Special Considerations

### 3.1 State Snapshot Timing

All state snapshots are captured AFTER the action completes. This means:
- `HandleAppendEntriesRequest` state includes the commit index update from `advance_commit_idx`
- `HandleAppendEntriesResponse` state may include commit advancement from `maybe_commit`
- `BecomeLeader` state includes the dummy entry in the log

### 3.2 Term Update Deduplication

The `step()` dispatch in `fsm.hh:559-612` handles term updates before dispatching to state-specific handlers. When `msg.current_term > _current_term`, the server becomes a follower and updates its term. This fires as a separate `UpdateTerm` event before the subsequent handler event.

For trace validation, the order is:
1. `UpdateTerm` event (term change + become follower)
2. Handler event (e.g., `HandleAppendEntriesRequest`)

### 3.3 PreVote Filtering

PreVote is not modeled in the spec (per modeling brief §3.2). The harness should NOT emit events for:
- `become_candidate(true)` (prevote candidacy)
- `request_vote()` with `is_prevote=true`
- `request_vote_reply()` for prevote responses

Only emit events for real elections (`is_prevote=false`).

### 3.4 Silent MaybeCommit

`maybe_commit()` is called from multiple places:
- `advance_stable_idx()` → `maybe_commit()` (after leader's own entries become stable)
- `append_entries_reply()` → `maybe_commit()` (after follower ack)
- `maybe_commit()` → `maybe_commit()` (recursive after leave_joint)

Only emit `MaybeCommit` event when commit index actually advances (new_commit_idx > _commit_idx). The recursive call from leave_joint should emit a second event.

### 3.5 Server ID Mapping

ScyllaDB uses UUID-based `server_id`. The harness must map these to short string IDs (e.g., "s1", "s2", "s3") that match the TLA+ `Server` constant set. Use order of first encounter in the trace for deterministic mapping.

### 3.6 Bootstrap and Initial State

The spec initializes all servers at term=0 with empty logs. The implementation's FSM constructor (fsm.cc:23-45) may start with a non-zero term and existing log entries loaded from persistence. The harness should emit the initial state as the first trace event if it differs from the spec default, or the `TraceInit` in Trace.tla should be adjusted.

### 3.7 Configuration Entries in Log

When `add_entry(configuration)` is called (fsm.cc:69-121), the entry contains a `configuration` object with `current` and `previous` member sets. The harness should extract the voter IDs from both sets and include them in the `ProposeConfigChange` event's `newVoters` field (the `current` set of the joint config, which is C_new).
