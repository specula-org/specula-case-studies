# Instrumentation Spec: Apache Kudu Raft Consensus

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "event": {
    "name": "<action_name>",
    "nid": "<server_uuid>",
    "state": {
      "term": <int>,
      "role": "Follower"|"Candidate"|"Leader",
      "votedFor": "<uuid>"|"",
      "commitIndex": <int>,
      "lastLogIndex": <int>,
      "lastLogTerm": <int>
    },
    "msg": { ... }
  }
}
```

### State Fields

| Implementation getter | TLA+ variable | Type |
|---|---|---|
| `cmeta_->current_term()` / `CurrentTermUnlocked()` | `currentTerm` | int |
| `cmeta_->active_role()` — map `LEADER`→"Leader", `FOLLOWER`→"Follower", else→"Candidate" | `state` | string |
| `cmeta_->voted_for()` / `GetVotedForCurrentTermUnlocked()` — empty string if no vote | `votedFor` | string |
| `pending_->GetCommittedIndex()` | `commitIndex` | int |
| `queue_->GetLastOpIdInLog().index()` | `LastLogIndex` | int |
| `queue_->GetLastOpIdInLog().term()` | `LastLogTerm` | int |

### Message Fields (AppendEntries)

| Implementation field | TLA+ field | Type |
|---|---|---|
| `request->caller_uuid()` | `msg.from` | string |
| `peer_uuid()` (receiver) | `msg.to` | string |
| `request->caller_term()` | `msg.term` | int |
| `request->preceding_id().index()` | `msg.prevLogIndex` | int |
| `request->preceding_id().term()` | `msg.prevLogTerm` | int |
| `request->committed_index()` | `msg.commitIndex` | int |
| `request->ops_size()` | `msg.numEntries` | int |

### Message Fields (Vote)

| Implementation field | TLA+ field | Type |
|---|---|---|
| `request->candidate_uuid()` | `msg.from` | string |
| `peer_uuid()` (receiver) | `msg.to` | string |
| `request->candidate_term()` | `msg.term` | int |
| `request->is_pre_election()` | `msg.preElection` | bool |
| `response->vote_granted()` | `msg.voteGranted` | bool |

## Section 2: Action-to-Code Mapping

### 1. BecomeCandidate (real election)

- **Spec action**: `Timeout(i)`
- **Code location**: `raft_consensus.cc:509-511`
- **Trigger point**: After `HandleTermAdvanceUnlocked` and `SetVotedForCurrentTermUnlocked` succeed (line 511), before `election->Run()` (line 558)
- **Trace event name**: `BecomeCandidate`
- **Fields**: state (full), no msg
- **Notes**: Self-vote is implicit (votedFor = self). Term is incremented. Only for `mode != PRE_ELECTION`.

### 2. PreVote

- **Spec action**: `PreVote(i)`
- **Code location**: `raft_consensus.cc:533-543`
- **Trigger point**: After VoteRequestPB is constructed with `is_pre_election=true`, before `election->Run()` (line 558)
- **Trace event name**: `PreVote`
- **Fields**: state (full), no msg
- **Notes**: Term is NOT incremented. `candidate_term = currentTerm + 1` in the request but `currentTerm` is unchanged in state snapshot.

### 3. HandleRequestVoteRequest

- **Spec action**: `HandleRequestVoteRequest(i, m)`
- **Code location**: `raft_consensus.cc:1718-1871`
- **Trigger point**: After the function completes (after term advance, vote recording, and response send), at the return statement
- **Trace event name**: `HandleRequestVoteRequest`
- **Fields**: state (full), msg (from=candidate_uuid, to=peer_uuid, term=candidate_term, preElection=is_pre_election, voteGranted=response.vote_granted)
- **Notes**: Must capture state AFTER term advance (line 1860) and vote recording. The four cases (withhold, reject, grant-real, grant-pre) all emit the same event name.

### 4. HandleRequestVoteResponse

- **Spec action**: `HandleRequestVoteResponse(i, m)`
- **Code location**: `leader_election.cc:329-371` (VoteResponseRpcCallback) and `raft_consensus.cc:2690-2820` (DoElectionCallback)
- **Trigger point**: In `VoteResponseRpcCallback`, after vote is recorded (line 370). For self-vote: in `StartElection` after `counter.RegisterVote` (line 525).
- **Trace event name**: `HandleRequestVoteResponse`
- **Fields**: state (full), msg (from=voter_uuid, to=candidate_uuid, voteGranted, term=responder_term)
- **Notes**: Self-vote emits a separate trace event with msg.from = msg.to. For the DoElectionCallback (won/lost), use a separate `BecomeLeader` event.

### 5. BecomeLeader

- **Spec action**: `BecomeLeader(i)`
- **Code location**: `raft_consensus.cc:691-735` (BecomeLeaderUnlocked)
- **Trigger point**: After `AppendNewRoundToQueueUnlocked(round)` (line 731), when `leader_is_ready_` is set TRUE (line 732)
- **Trace event name**: `BecomeLeader`
- **Fields**: state (full — includes the NO_OP in lastLogIndex), no msg
- **Notes**: State snapshot must include the NO_OP that was just appended (lastLogIndex incremented).

### 6. SendEntries

- **Spec action**: `SendEntries(i, j)`
- **Code location**: `consensus_peers.cc` (peer sends request via `SendNextRequest`)
- **Trigger point**: After `RequestForPeer` builds the request but before RPC is sent
- **Trace event name**: `SendEntries`
- **Fields**: state (weak — term, role only), msg (to=peer_uuid, term, prevLogIndex, prevLogTerm, numEntries, commitIndex)
- **Notes**: Multiple code paths invoke this (initial send, retry). The trace should use the request's `caller_term` and `preceding_id` fields.

### 7. SendHeartbeat

- **Spec action**: `SendHeartbeat(i, j)`
- **Code location**: `consensus_peers.cc` (heartbeat path in `SendNextRequest` — status-only request with no ops)
- **Trigger point**: Before heartbeat RPC is sent
- **Trace event name**: `SendHeartbeat`
- **Fields**: state (weak), msg (to=peer_uuid, term)
- **Notes**: A heartbeat in Kudu is an AppendEntries with 0 ops. Distinguished from `SendEntries` by `request->ops_size() == 0`.

### 8. HandleAppendEntriesRequest

- **Spec action**: `HandleAppendEntriesRequest(i, m)`
- **Code location**: `raft_consensus.cc:1377-1693` (UpdateReplica)
- **Trigger point**: After `FillConsensusResponseOKUnlocked(response)` (line 1656), before releasing the lock
- **Trace event name**: `HandleAppendEntriesRequest`
- **Fields**: state (full — commitIndex reflects apply_up_to), msg (from=caller_uuid, to=peer_uuid, term=caller_term, prevLogIndex=preceding_id.index, prevLogTerm=preceding_id.term)
- **Notes**: Must capture state AFTER commit index advancement (line 1646). The `commitIndex` in the state snapshot reflects `apply_up_to`. For rejected requests (term too low, LMP mismatch), state snapshot still has updated term if applicable.

### 9. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `consensus_queue.cc:1161-1351` (ResponseFromPeer)
- **Trigger point**: After watermark advancement (line 1295), before `NotifyObserversOfCommitIndexChange` (line 1346)
- **Trace event name**: `HandleAppendEntriesResponse`
- **Fields**: state (weak), msg (from=responder_uuid, matchIndex=peer->last_received.index, success)
- **Notes**: State is captured from the queue's perspective (leader term, mode). The `matchIndex` comes from `peer->last_received.index()` after update.

### 10. AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `raft_consensus.cc:898-920` (NotifyCommitIndex callback)
- **Trigger point**: After `pending_->AdvanceCommittedIndex(commit_index)` (line 916)
- **Trace event name**: `AdvanceCommitIndex`
- **Fields**: state (full — commitIndex reflects the new value)
- **Notes**: This is triggered by the PeerMessageQueue observer callback. The `commitIndex` in the trace should be the new committed value.

### 11. ProposeConfigChange

- **Spec action**: `ProposeConfigChange(i, s)`
- **Code location**: `raft_consensus.cc:1900-2088` (BulkChangeConfig)
- **Trigger point**: After `ReplicateConfigChangeUnlocked` succeeds (line 2079-2084), before releasing lock
- **Trace event name**: `ProposeConfigChange`
- **Fields**: state (full — lastLogIndex includes the config entry), msg (to=target_server_uuid)
- **Notes**: `s` (the server being added/removed) is mapped to `msg.to`. The new config is not explicitly traced — it's derived from the log entry.

### 12. StepDown

- **Spec action**: `StepDown(i)`
- **Code location**: `raft_consensus.cc:576-599` (StepDown)
- **Trigger point**: After `HandleTermAdvanceUnlocked(currentTerm + 1)` succeeds (line 592)
- **Trace event name**: `StepDown`
- **Fields**: state (full — term is incremented, role becomes Follower)
- **Notes**: Kudu's StepDown bumps term (non-standard). The state snapshot should reflect `term = old_term + 1` and `role = "Follower"`.

## Section 3: Special Considerations

### State Access

- **currentTerm, votedFor**: Accessed via `cmeta_` which requires holding `lock_`. The trace harness must capture state inside the lock scope.
- **commitIndex**: Comes from `pending_->GetCommittedIndex()` which requires its own lock. For `HandleAppendEntriesRequest`, capture after `AdvanceCommittedIndex` calls inside the main lock scope.
- **lastLogIndex/lastLogTerm**: From `queue_->GetLastOpIdInLog()` which reads from the log cache. Must be captured while log state is consistent (inside lock).

### Concurrency

- **Peer threads**: Each peer has its own thread for sending RPCs. `SendEntries` and `SendHeartbeat` events from different peers may interleave arbitrarily.
- **Observer callbacks**: `NotifyCommitIndex` and `NotifyTermChange` are dispatched asynchronously from `ResponseFromPeer`. The trace may show `AdvanceCommitIndex` events between `HandleAppendEntriesResponse` events.
- **Election thread**: Elections run on a thread pool (`raft_pool_token_`). `DoElectionCallback` may execute concurrently with `UpdateReplica`.

### Lock Ordering

The trace harness must respect Kudu's lock ordering: `update_lock_` before `lock_`. For `HandleRequestVoteRequest`, state is captured inside `lock_` (line 1773). For `HandleAppendEntriesRequest` (UpdateReplica), state is captured inside `lock_` (line 1478).

### Bootstrap State

Kudu consensus starts with `term=0`, empty log, all nodes as Follower. This matches the base spec `Init`. If trace starts from a non-zero state (e.g., after bootstrap replay), `TraceInit` must be adjusted to match.

### Serialization Notes

- UUIDs are byte strings in protobuf; trace should emit them as hex or pre-mapped short names (e.g., "s1", "s2", "s3").
- Empty `votedFor` should be serialized as `""` (empty string), not omitted, to distinguish from "not yet voted" vs. JSON field absence.
- `lastLogIndex` and `lastLogTerm` of 0 indicate an empty log.
