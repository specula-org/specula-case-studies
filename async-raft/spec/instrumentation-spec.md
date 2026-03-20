# Instrumentation Spec: async-raft

Action-to-code mapping for generating trace events compatible with `Trace.tla`.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": 1234567890,
  "event": {
    "name": "<action_name>",
    "nid": "<server_id>",
    "state": {
      "term": 1,
      "role": "Follower",
      "votedFor": "",
      "commitIndex": 0,
      "lastLogIndex": 0,
      "lastLogTerm": 0
    },
    "msg": {
      "from": "<source_id>",
      "to": "<dest_id>",
      "term": 1,
      "type": "<msg_type>",
      ...
    }
  }
}
```

### State Fields

| Impl Field | TLA+ Variable | Getter |
|-----------|---------------|--------|
| `self.current_term` | `currentTerm[i]` | Direct field access |
| `self.target_state` / state enum | `state[i]` | Map State enum → "Follower"/"Candidate"/"Leader" |
| `self.voted_for` | `votedFor[i]` | `Option<NodeId>` → "" if None, else NodeId string |
| `self.commit_index` | `commitIndex[i]` | Direct field access |
| `self.last_log_index` | `LastLogIndex(i)` | Direct field access |
| `self.last_log_term` | `LastLogTerm(i)` | Direct field access |

### Message Fields

| Impl Field | TLA+ Field | Notes |
|-----------|-----------|-------|
| `msg.term` / `req.term` | `mterm` | Message/request term |
| `msg.leader_id` / `msg.candidate_id` | `msource` | Sender ID |
| `self.id` (receiver) | `mdest` | Receiver ID |
| `msg.prev_log_index` | `mprevLogIndex` | For AppendEntries |
| `msg.prev_log_term` | `mprevLogTerm` | For AppendEntries |
| `msg.leader_commit` | `mcommitIndex` | For AppendEntries |
| `res.vote_granted` | `mvoteGranted` | For VoteResponse |
| `data.success` | `msuccess` | For AppendEntriesResponse |

## Section 2: Action-to-Code Mapping

### 1. Timeout

- **Spec action**: `Timeout(i)`
- **Code location**: `core/mod.rs:786-789` (CandidateState::run — term increment + self-vote)
- **Trigger point**: After `self.core.current_term += 1` and `self.core.voted_for = Some(self.core.id)`, before spawning vote requests
- **Trace event name**: `Timeout`
- **Fields**: state (term, role=Candidate, votedFor=self.id, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: The election is driven by CandidateState::run's outer loop. Each iteration is one election attempt. Capture state after term increment.

### 2. HandleRequestVoteRequest

- **Spec action**: `HandleRequestVoteRequest(i, m)`
- **Code location**: `core/vote.rs:15-93` (handle_vote_request)
- **Trigger point**: After processing the vote request (after all branches resolve), before returning the VoteResponse
- **Trace event name**: `HandleRequestVoteRequest`
- **Fields**: state (full), msg (from=candidate_id, to=self.id, term=msg.term, granted=response.vote_granted, lastLogTerm=msg.last_log_term, lastLogIndex=msg.last_log_index)
- **Notes**: Bug Family 2 — the buggy log comparison at line 53 is the key check to validate. Capture full post-state including votedFor.

### 3. HandleRequestVoteResponse

- **Spec action**: `HandleRequestVoteResponse(i, m)`
- **Code location**: `core/vote.rs:99-137` (handle_vote_response)
- **Trigger point**: After processing the response, before returning
- **Trace event name**: `HandleRequestVoteResponse`
- **Fields**: state (weak: term, role), msg (from=target, to=self.id, term=res.term, granted=res.vote_granted)
- **Notes**: For self-vote (target == self.id), the trace wrapper should emit the event but the Trace.tla will skip it as a no-op.

### 4. BecomeLeader

- **Spec action**: `BecomeLeader(i)`
- **Code location**: `core/mod.rs:588-602` (LeaderState::run entry, after spawning replication streams)
- **Trigger point**: After `self.core.set_target_state(State::Leader)` resolves (i.e., at the start of LeaderState::run before the event loop)
- **Trace event name**: `BecomeLeader`
- **Fields**: state (weak: term, role=Leader)
- **Notes**: Bug Family 3 — optimistic match_index initialization happens in spawn_replication_stream (replication.rs:27-28). The trace doesn't need to capture matchIndex; the spec models it.

### 5. ClientRequest

- **Spec action**: `ClientRequest(i)`
- **Code location**: `core/client.rs:228-241` (append_payload_to_log)
- **Trigger point**: After `self.core.last_log_index = entry.index` (line 239)
- **Trace event name**: `ClientRequest`
- **Fields**: state (full: term, role, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Only emit for Normal payloads (not ConfigChange). The commit_initial_leader_entry (line 47-90) also calls append_payload_to_log; emit for that too as a ClientRequest event.

### 6. SendReplicateEntries

- **Spec action**: `ReplicateEntries(i, j)`
- **Code location**: `replication/mod.rs` (ReplicationStream sends entries via network.append_entries)
- **Trigger point**: Before calling `self.network.append_entries(target, rpc)` in the replication stream
- **Trace event name**: `SendReplicateEntries`
- **Fields**: state (weak: term, role), msg (from=self.id, to=target, term=rpc.term, prevLogIndex=rpc.prev_log_index, prevLogTerm=rpc.prev_log_term)
- **Notes**: The replication stream runs in a separate tokio task. The `nid` field should be the leader's ID (the one that spawned the stream). Include prevLogIndex to distinguish from heartbeats.

### 7. SendHeartbeat

- **Spec action**: `SendHeartbeat(i, j)`
- **Code location**: `replication/mod.rs` (ReplicationStream sends empty AppendEntries as heartbeat)
- **Trigger point**: Before calling `self.network.append_entries(target, rpc)` when `rpc.entries.is_empty()`
- **Trace event name**: `SendHeartbeat`
- **Fields**: state (weak: term, role), msg (from=self.id, to=target, term=rpc.term)
- **Notes**: async-raft uses empty AppendEntries as heartbeats (same code path as replication). Distinguish by checking if entries is empty. Also used in handle_client_read_request (client.rs:144-164).

### 8. HandleAppendEntriesRequest

- **Spec action**: `HandleAppendEntriesRequest(i, m)`
- **Code location**: `core/append_entries.rs:14-167` (handle_append_entries_request)
- **Trigger point**: After processing the request (after all branches), before returning AppendEntriesResponse
- **Trace event name**: `HandleAppendEntriesRequest`
- **Fields**: state (full), msg (from=leader_id, to=self.id, term=msg.term, success=response.success, prevLogIndex=msg.prev_log_index, prevLogTerm=msg.prev_log_term)
- **Notes**: Bug Family 3 — the unconditional commit_index update at line 28 is critical. The post-state commitIndex will reflect msg.leader_commit, NOT min(leaderCommit, lastNewEntry).

### 9. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `core/replication.rs:107-196` (handle_update_match_index, via handle_replica_event)
- **Trigger point**: After updating matchIndex/matchTerm (line 119-121), before commit index calculation
- **Trace event name**: `HandleAppendEntriesResponse`
- **Fields**: state (weak: term, role), msg (from=target, to=self.id, matchIndex=match_index, matchTerm=match_term, success=true/false)
- **Notes**: The response comes via ReplicaEvent::UpdateMatchIndex from the replication stream. The leader's RaftCore processes it. Use weak validation because commit_index may change separately.

### 10. AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `core/replication.rs:138-166` (handle_update_match_index, commit index calculation)
- **Trigger point**: After `self.core.commit_index = std::cmp::min(commit_index_c0, commit_index_c1)` (line 166)
- **Trace event name**: `AdvanceCommitIndex`
- **Fields**: state (weak + commitIndex: term, role, commitIndex)
- **Notes**: This happens within handle_update_match_index, immediately after the matchIndex update. May need to be combined with HandleAppendEntriesResponse or emitted separately.

### 11. ClientReadRequest

- **Spec action**: `ClientReadRequest(i)`
- **Code location**: `core/client.rs:105-139` (handle_client_read_request setup)
- **Trigger point**: After computing c0_needed/c1_needed and self-confirming (line 122)
- **Trace event name**: `ClientReadRequest`
- **Fields**: state (weak: term, role), readNeeded=c0_needed
- **Notes**: Bug Family 1 — the buggy quorum formula at lines 109-113. Capture the computed c0_needed to validate against spec.

### 12. ClientReadConfirm

- **Spec action**: `ClientReadConfirm(i, m)`
- **Code location**: `core/client.rs:166-204` (response handling loop, each iteration)
- **Trigger point**: After processing each heartbeat response in the loop
- **Trace event name**: `ClientReadConfirm`
- **Fields**: state (weak: term, role), msg (from=target, to=self.id, term=data.term)
- **Notes**: Bug Family 6 — lines 181-184 set Follower but don't break. The post-state role may show "Follower" but the loop continues. Capture each response separately.

### 13. ClientReadComplete

- **Spec action**: `ClientReadComplete(i)`
- **Code location**: `core/client.rs:200-202` (quorum reached, send Ok)
- **Trigger point**: After sending `tx.send(Ok(()))`
- **Trace event name**: `ClientReadComplete`
- **Fields**: state (weak: term, role)
- **Notes**: If Bug Family 6 fires, this event may emit with role="Follower".

### 14. HandleInstallSnapshotRequest

- **Spec action**: `HandleInstallSnapshotRequest(i, m)`
- **Code location**: `core/install_snapshot.rs:17-58` (handle_install_snapshot_request)
- **Trigger point**: After finalize_snapshot_installation (line 114-140) completes, or after rejecting
- **Trace event name**: `HandleInstallSnapshotRequest`
- **Fields**: state (full), msg (from=leader_id, to=self.id, term=req.term, lastIncludedIndex=req.last_included_index, lastIncludedTerm=req.last_included_term)
- **Notes**: Bug Family 4 — after finalization, last_log_index is clobbered (line 135). The multi-chunk streaming protocol can be collapsed: only emit on `req.done = true` (finalization).

### 15. SendInstallSnapshot

- **Spec action**: `SendInstallSnapshot(i, j)`
- **Code location**: `replication/mod.rs` (triggered by NeedsSnapshot event)
- **Trigger point**: Before sending the InstallSnapshotRequest to the target
- **Trace event name**: `SendInstallSnapshot`
- **Fields**: state (weak: term, role), msg (from=self.id, to=target, term=current_term, lastIncludedIndex, lastIncludedTerm)
- **Notes**: The snapshot data itself is not modeled in TLA+.

### 16. HandleInstallSnapshotResponse

- **Spec action**: `HandleInstallSnapshotResponse(i, m)`
- **Code location**: `replication/mod.rs` (after receiving snapshot response in replication stream)
- **Trigger point**: After processing the response
- **Trace event name**: `HandleInstallSnapshotResponse`
- **Fields**: state (weak: term, role), msg (from=target, to=self.id, term=response.term)
- **Notes**: The response arrives in the replication stream and may trigger RevertToFollower.

### 17. TakeSnapshot

- **Spec action**: `TakeSnapshot(i)`
- **Code location**: `core/mod.rs:358-409` (trigger_log_compaction_if_needed)
- **Trigger point**: After successful log compaction completes (via tx_compaction channel)
- **Trace event name**: `TakeSnapshot`
- **Fields**: state (weak), snapshotIndex=new_snapshot_index
- **Notes**: Log compaction runs asynchronously. Emit when the compaction task completes and update_snapshot_state is called.

### 18. ChangeMembership

- **Spec action**: `ChangeMembership(i, newMembers)`
- **Code location**: `core/admin.rs:86-178` (change_membership)
- **Trigger point**: After entering joint consensus state (line 143-144) and appending the config entry
- **Trace event name**: `ChangeMembership`
- **Fields**: state (weak), members=[list of new member IDs]
- **Notes**: Bug Family 5 — non-voters are not moved to the nodes map. The membership change lifecycle is complex; only emit when joint consensus is entered.

### 19. FinalizeJointConsensus

- **Spec action**: `FinalizeJointConsensus(i)`
- **Code location**: `core/admin.rs:194-229` (finalize_joint_consensus)
- **Trigger point**: After cutting over to new membership (line 203-206) and appending uniform config entry
- **Trace event name**: `FinalizeJointConsensus`
- **Fields**: state (weak), members=[list of final member IDs]
- **Notes**: This completes the joint consensus phase.

## Section 3: Special Considerations

### State Access

- **RaftCore fields**: All state fields (`current_term`, `voted_for`, `last_log_index`, etc.) are direct struct fields on `RaftCore`. They are accessed within the single-threaded core task — no locking needed.
- **ReplicationStream state**: Runs in a separate tokio task. The match_index/match_term updates are communicated via `ReplicaEvent::UpdateMatchIndex` channel events. Trace events for replication actions should capture the leader's term from the replication stream's stored copy.

### Concurrency and Event Ordering

- **Single-threaded core**: `RaftCore` processes all events sequentially via `tokio::select!` in the state machine loop. This guarantees no concurrent modifications to core state.
- **Replication streams**: Each follower has its own spawned task. Events from replication streams arrive via `mpsc` channel and are processed one at a time by the core. Trace events from replication tasks may interleave with core events.
- **Async state machine replication**: `replicate_to_state_machine` runs in a separate `tokio::spawn`. Its completion is awaited via `FuturesOrdered`. Trace events for SM replication are not modeled (out of scope).

### Bootstrap State

- **Initial term**: async-raft starts with `current_term = 0` (not 1 like braft). `TraceInit` uses term=0.
- **Initial membership**: Derived from `initialize()` call or from storage recovery. For trace validation, assume `Server` set matches the trace.
- **Voted_for**: Starts as `None` (empty string "" in trace JSON).

### Serialization Notes

- **NodeId**: `u64` in Rust. Use string representation in JSON (e.g., `"1"`, `"2"`, `"3"`). Map to TLA+ Server constants (s1, s2, s3) via the TraceServer extraction.
- **Option<NodeId> for voted_for**: `None` → `""` (empty string), `Some(id)` → `"<id>"`. Trace.tla's `TraceVotedFor` maps `""` → `Nil`.
- **Log entries**: Not serialized individually in trace events. Only `lastLogIndex` and `lastLogTerm` are captured as state fields. The spec reconstructs log contents from action semantics.
- **Membership config**: Serialize `members` as a JSON array of NodeId strings. `members_after_consensus` is `null` if not in joint consensus, else a JSON array.
