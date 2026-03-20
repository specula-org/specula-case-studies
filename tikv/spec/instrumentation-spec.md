# Instrumentation Spec: tikv/raft-rs

Action-to-code mapping for generating trace harness patches.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a single JSON line (NDJSON) with this structure:

```json
{
  "event": "<EventName>",
  "node": "<server_id>",
  "state": {
    "term": <u64>,
    "role": "<Follower|Candidate|PreCandidate|Leader>",
    "commit": <u64>,
    "lastLogIndex": <u64>,
    "lastLogTerm": <u64>,
    "persisted": <u64>,
    "votedFor": <u64|null>,
    "leaderId": <u64|null>
  },
  ...event-specific fields...
}
```

### State Fields Mapping

| Implementation getter | TLA+ variable | Notes |
|---|---|---|
| `self.term` | `currentTerm[i]` | Core term |
| `self.state` (StateRole enum) | `state[i]` | Map to string: Follower/Candidate/PreCandidate/Leader |
| `self.raft_log.committed` | `commitIndex[i]` | Committed index |
| `self.raft_log.last_index()` | `LastLogIndex(i)` | Last log index |
| `self.raft_log.last_term()` | `LastLogTerm(i)` | Last log entry's term |
| `self.raft_log.persisted` | `persisted[i]` | Persisted index |
| `self.vote` | `votedFor[i]` | 0 = Nil |
| `self.leader_id` | `leaderId[i]` | 0 = Nil |

### Message Fields Mapping

| Implementation field | TLA+ field | Notes |
|---|---|---|
| `m.from` | `msource` / `logline.from` | Source server ID |
| `m.to` | `mdest` / `logline.to` | Destination server ID |
| `m.term` | `mterm` | Message term |
| `m.index` (in AppendResp) | `mindex` | Response index |
| `m.reject` | `mreject` | Boolean reject flag |
| `m.commit` | `mcommit` / `mcommitIndex` | Commit index carried in message |
| `m.log_term` | `mprevLogTerm` / `mlastLogTerm` | Log term field |
| `m.entries` | `mentries` | Entry array |

## Section 2: Action-to-Code Mapping

### Election Actions

#### 1. Timeout
- **Spec action**: `Timeout(i)`
- **Code location**: `raft.rs:1103-1113` (`tick_election`)
- **Trigger point**: After `self.step(m)` returns (line 1111)
- **Trace event name**: `Timeout`
- **Fields**: `node`, `state` (post-state)
- **Notes**: `hup()` is called internally. The trace event fires after the campaign messages are queued. Capture state after `step(MsgHup)` completes.

#### 2. BecomeLeader
- **Spec action**: `BecomeLeader(i)`
- **Code location**: `raft.rs:1226-1277` (`become_leader`)
- **Trigger point**: After `become_leader()` returns (line 1277)
- **Trace event name**: `BecomeLeader`
- **Fields**: `node`, `state` (post-state)
- **Notes**: Called from `poll()` when vote quorum reached (raft.rs:2274). The noop entry is already appended. Capture state after append.

#### 3. HandleRequestPreVoteRequest
- **Spec action**: `HandleRequestPreVoteRequest(i, m)`
- **Code location**: `raft.rs:1485-1529` (within `step()`, MsgRequestPreVote branch)
- **Trigger point**: After vote response is sent (line 1511 or 1526)
- **Trace event name**: `HandleRequestPreVoteRequest`
- **Fields**: `node`, `from` (m.from), `state` (post-state), `granted` (boolean)
- **Notes**: PreVote does NOT change term or votedFor. State should still show same term.

#### 4. HandleRequestPreVoteResponse
- **Spec action**: `HandleRequestPreVoteResponse(i, m)`
- **Code location**: `raft.rs:2316-2329` (`step_candidate`, MsgRequestPreVoteResponse branch)
- **Trigger point**: After `poll()` returns (line 2328)
- **Trace event name**: `HandleRequestPreVoteResponse`
- **Fields**: `node`, `from` (m.from), `state` (post-state), `granted` (!m.reject)
- **Notes**: If PreVote quorum won, this may trigger `campaign(CAMPAIGN_ELECTION)` internally. The post-state may show Candidate (not PreCandidate) if quorum was reached.

#### 5. HandleRequestVoteRequest
- **Spec action**: `HandleRequestVoteRequest(i, m)`
- **Code location**: `raft.rs:1485-1529` (within `step()`, MsgRequestVote branch)
- **Trigger point**: After vote response is sent (line 1511 or 1526)
- **Trace event name**: `HandleRequestVoteRequest`
- **Fields**: `node`, `from` (m.from), `state` (post-state), `granted` (boolean)
- **Notes**: May change term if m.term > self.term. votedFor changes on grant.

#### 6. HandleRequestVoteResponse
- **Spec action**: `HandleRequestVoteResponse(i, m)`
- **Code location**: `raft.rs:2316-2329` (`step_candidate`, MsgRequestVoteResponse branch)
- **Trigger point**: After `poll()` returns (line 2328)
- **Trace event name**: `HandleRequestVoteResponse`
- **Fields**: `node`, `from` (m.from), `state` (post-state), `granted` (!m.reject)
- **Notes**: If vote quorum won, `become_leader()` + `bcast_append()` fire. The post-state will show Leader if quorum reached.

### Log Replication Actions

#### 7. ClientRequest
- **Spec action**: `ClientRequest(i)`
- **Code location**: `raft.rs:2063-2143` (MsgPropose in `step_leader`)
- **Trigger point**: After `bcast_append()` (line 2142)
- **Trace event name**: `ClientRequest`
- **Fields**: `node`, `state` (post-state), `entries` (array of {type, index, term})
- **Notes**: Multiple entries may be batched. Capture after append + broadcast.

#### 8. HandleAppendEntriesRequest
- **Spec action**: `HandleAppendEntriesRequest(i, m)`
- **Code location**: `raft.rs:2499-2558` (`handle_append_entries`)
- **Trigger point**: After response is sent (line 2557)
- **Trace event name**: `HandleAppendEntriesRequest`
- **Fields**: `node`, `from` (m.from), `state` (post-state), `accepted` (boolean)
- **Notes**: Also triggered from `step_follower` MsgAppend path (line 2373-2374). Follower resets election timer and sets leader_id. Captures state after log modification.

#### 9. HandleAppendEntriesResponse
- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `raft.rs:1769-1863` (`handle_append_response`)
- **Trigger point**: After matchIndex/nextIndex update (line 1841)
- **Trace event name**: `HandleAppendEntriesResponse`
- **Fields**: `node`, `from` (m.from), `state` (post-state), `accepted` (!m.reject), `matchIndex` (updated match)
- **Notes**: If transfer target matches (line 1852-1863), MsgTimeoutNow may be sent. Capture state before potential TimeoutNow send.

#### 10. SendHeartbeat
- **Spec action**: `SendHeartbeat(i, j)`
- **Code location**: `raft.rs:919-935` (`bcast_heartbeat`) / individual `send_heartbeat`
- **Trigger point**: After heartbeat message queued
- **Trace event name**: `SendHeartbeat`
- **Fields**: `node` (sender), `to` (recipient), `state` (post-state)
- **Notes**: bcast_heartbeat sends to all followers. Instrument per-peer or batch. For trace validation, one event per recipient is simpler.

#### 11. HandleHeartbeatRequest
- **Spec action**: `HandleHeartbeatRequest(i, m)`
- **Code location**: `raft.rs:2562-2573` (`handle_heartbeat`)
- **Trigger point**: After heartbeat response sent (line 2573)
- **Trace event name**: `HandleHeartbeatRequest`
- **Fields**: `node`, `from` (m.from), `state` (post-state)
- **Notes**: Updates commitIndex via `commit_to(m.commit)`. May step down on higher term.

#### 12. HandleHeartbeatResponse
- **Spec action**: `HandleHeartbeatResponse(i, m)`
- **Code location**: `raft.rs:1866-1910` (`handle_heartbeat_response`)
- **Trigger point**: After `pr.recent_active = true` (line 1881)
- **Trace event name**: `HandleHeartbeatResponse`
- **Fields**: `node`, `from` (m.from), `state` (post-state)
- **Notes**: Also handles ReadIndex Safe mode confirmation (lines 1894-1910). Capture early to avoid mixing with read handling.

### Leader Transfer Actions

#### 13. TransferLeadership
- **Spec action**: `TransferLeadership(i, j)`
- **Code location**: `raft.rs:1924-1978` (`handle_transfer_leader`)
- **Trigger point**: After `self.lead_transferee = Some(lead_transferee)` (line 1966)
- **Trace event name**: `TransferLeadership`
- **Fields**: `node` (leader), `target` (transferee ID), `state` (post-state)
- **Notes**: If target's log is up-to-date, MsgTimeoutNow is sent immediately (line 1969).

#### 14. HandleTimeoutNowRequest
- **Spec action**: `HandleTimeoutNowRequest(i, m)`
- **Code location**: `raft.rs:2398-2418` (step_follower, MsgTimeoutNow branch)
- **Trigger point**: After `self.hup(true)` (line 2410)
- **Trace event name**: `HandleTimeoutNowRequest`
- **Fields**: `node`, `from` (m.from), `state` (post-state)
- **Notes**: Skips PreVote (CAMPAIGN_TRANSFER). Post-state will show Candidate.

### CheckQuorum / Priority Actions

#### 15. CheckQuorum
- **Spec action**: `CheckQuorum(i)`
- **Code location**: `raft.rs:2052-2061` (MsgCheckQuorum in `step_leader`)
- **Trigger point**: After `check_quorum_active()` returns (line 2053)
- **Trace event name**: `CheckQuorum`
- **Fields**: `node`, `state` (post-state), `quorumActive` (boolean)
- **Notes**: If quorum lost, node becomes follower. Capture state after potential step-down.

### Persistence Actions

#### 16. PersistEntries
- **Spec action**: `PersistEntries(i)`
- **Code location**: `raft.rs:1060-1082` (`on_persist_entries`)
- **Trigger point**: After `maybe_persist` succeeds and matchIndex updated (line 1078)
- **Trace event name**: `PersistEntries`
- **Fields**: `node`, `state` (post-state), `persistedIndex` (new persisted), `persistedTerm` (term of persisted entry)
- **Notes**: Called from `on_persist_ready` (raw_node.rs:649-650). For leader, matchIndex[self] advances. For follower, only persisted changes. This is the key async persistence event.

#### 17. AdvanceCommitIndex
- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `raft.rs:939-950` (`maybe_commit`)
- **Trigger point**: After `maybe_commit()` returns true
- **Trace event name**: `AdvanceCommitIndex`
- **Fields**: `node`, `state` (post-state with new commit)
- **Notes**: Called after matchIndex updates. May trigger `bcast_append()` if commit advanced.

#### 18. Crash
- **Spec action**: `Crash(i)`
- **Code location**: N/A (external event — process killed)
- **Trigger point**: Before restart (pre-recovery state)
- **Trace event name**: `Crash`
- **Fields**: `node`
- **Notes**: Crash events are external. The harness should emit this when test framework kills/restarts a node. Post-crash state is reconstructed from persisted state.

## Section 3: Special Considerations

### 1. Async Persistence vs Immediate Persistence

raft-rs has two persistence models:
- **Leader**: sends AppendEntries BEFORE persisting locally. Own `pr.matched = persisted` (not `last_index`).
- **Follower**: receives AppendEntries and persists via Ready flow.

The `PersistEntries` event is triggered by `on_persist_ready()` -> `on_persist_entries()`. It is called AFTER the write completes, so the trace event represents "persistence done."

**Key**: Leader's matchIndex[self] advances ONLY on PersistEntries, not on append_entry. This is critical for trace validation — the spec models this split correctly.

### 2. Message Ordering

raft-rs queues messages in `self.msgs` during `step()` calls. Messages are extracted via `Ready` and delivered by the transport layer. The trace must capture message events at the receiver side (when `step()` processes the message), not at the sender.

Exception: `SendHeartbeat` is captured at the sender because heartbeats are periodic leader actions.

### 3. Term Changes During step()

The `step()` function (raft.rs:1346-1537) handles term changes BEFORE dispatching to step_leader/step_candidate/step_follower. If m.term > self.term, the node becomes a follower first, then processes the message. The post-state in the trace will reflect the term change.

### 4. PreVote Term Behavior

PreVote messages carry `self.term + 1` as their term, but the sender's actual term does NOT change. The trace for `Timeout` (when PreVote) should show the same term as before, not term+1.

PreVote responses from other nodes also do NOT change the receiver's term (raft.rs:1386-1397).

### 5. BecomeLeader Noop Entry

`become_leader()` appends a noop entry (raft.rs:1267). The `BecomeLeader` trace event should be captured AFTER this append, so `lastLogIndex` includes the noop.

### 6. Configuration Change Events

Configuration changes are complex multi-step operations. The trace should capture:
- `ProposeConfChange`: at leader, after append (raft.rs:2118)
- `ApplyConfChange`: after `apply_conf_change()` returns (raft.rs:2805-2817)
- `AutoLeaveJoint`: after auto-leave entry appended (raft.rs:999-1003)

These are not included in the initial instrumentation; add after basic trace validation works.

### 7. Self-Vote Handling

In `campaign()` (raft.rs:1293), the node votes for itself via `poll()`. This is NOT a separate trace event — it's part of the `Timeout` event. The vote grant for self is implicit in the election start.

### 8. Batch Message Processing

A single `step()` call may produce multiple outgoing messages (e.g., `bcast_append` sends to all peers). The trace should capture one event per inbound message, not per outbound message.

### 9. Environment Variable for Trace File

Use `RAFT_TRACE_FILE` environment variable to control trace output:
```rust
if let Ok(path) = std::env::var("RAFT_TRACE_FILE") {
    // Write NDJSON to path
}
```

### 10. Server ID Mapping

raft-rs uses `u64` IDs. The trace uses these directly. The TLA+ spec maps them via model constants (e.g., `s1 = 1, s2 = 2, s3 = 3`). The Trace.cfg Server set must match the IDs in the trace file.
