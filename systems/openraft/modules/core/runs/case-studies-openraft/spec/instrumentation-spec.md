# Instrumentation Spec: openraft

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "node": <server_id>,
  "source": <source_server_id>,     // for message events
  "dest": <dest_server_id>,         // for message events
  "target": <target_server_id>,     // for replication events
  "post": {
    "term": <nat>,
    "state": "<Follower|Candidate|Leader>",
    "commitIndex": <nat>,
    "lastLogIndex": <nat>,
    "lastLogTerm": <nat>
  },
  // event-specific fields below
}
```

### State Fields

| Implementation getter | TLA+ variable | Type | Notes |
|---|---|---|---|
| `state.vote_ref().leader_id().term` | `currentTerm[node]` | Nat | Term from vote |
| `state.vote_ref().leader_id().node_id` | `votedFor[node]` | Server | Node ID from vote |
| `state.vote_ref().is_committed()` | `voteCommitted[node]` | BOOLEAN | Committed flag |
| `state.server_state` | `state[node]` | String | "Leader"/"Candidate"/"Follower" |
| `state.committed().index()` | `commitIndex[node]` | Nat | Committed index |
| `state.last_log_id().index()` | `LastLogIndex(node)` | Nat | Last log index |
| `state.last_log_id().leader_id.term` | `LastLogTerm(node)` | Nat | Last log term |
| `state.snapshot_meta.last_log_id.index()` | `snapshot[node].lastIndex` | Nat | Snapshot index |
| `state.purge_upto().index()` | `purgedUpTo[node]` | Nat | Purge boundary |

### Message Fields (event-specific)

| Field | TLA+ field | Used by |
|---|---|---|
| `logline.source` | `m.msource` | All message events |
| `logline.dest` or `logline.node` | `m.mdest` | All message events |
| `logline.target` | Target server | ReplicateEntries, SendInstallSnapshot |
| `logline.newVoters` | `newVoters` | ProposeConfigChange |

## Section 2: Action-to-Code Mapping

### 1. Elect

- **Spec action**: `Elect(i)`
- **Code location**: `engine/engine_impl.rs:200-220` (`Engine::elect`)
- **Trigger point**: After `vote_handler().update_vote()` at line 213 (self-vote succeeds)
- **Event name**: `"Elect"`
- **Fields**: `node`, `post` (strong: term, state, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Captures state AFTER self-vote and BEFORE VoteRequest sends. Term is already incremented.

### 2. HandleVoteRequest

- **Spec action**: `HandleVoteRequest(i, m)`
- **Code location**: `engine/engine_impl.rs:239-290` (`Engine::handle_vote_req`)
- **Trigger point**: After `vote_handler().update_vote()` at line 283, before response sent
- **Event name**: `"HandleVoteRequest"`
- **Fields**: `node`, `source` (requester), `post` (weak: term, state)
- **Notes**: Source is `req.vote.leader_id().node_id`. State may change (Follower if granting).

### 3. HandleVoteResponse

- **Spec action**: `HandleVoteResponse(i, m)`
- **Code location**: `engine/engine_impl.rs:293-352` (`Engine::handle_vote_resp`)
- **Trigger point**: After processing response (line 314 grant or line 348 reject)
- **Event name**: `"HandleVoteResponse"`
- **Fields**: `node`, `source` (responder), `post` (weak: term, state)
- **Notes**: Captures post-state including potential step-down. Source is response sender.

### 4. EstablishLeader

- **Spec action**: `EstablishLeader(i)`
- **Code location**: `engine/engine_impl.rs:646-672` (`Engine::establish_leader`)
- **Trigger point**: After `update_vote()` commits the vote (line 663) and blank log appended (line 671)
- **Event name**: `"EstablishLeader"`
- **Fields**: `node`, `post` (strong: term, state=Leader, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: lastLogIndex includes the blank log entry. This is called from `handle_vote_resp` when quorum reached.

### 5. ClientRequest

- **Spec action**: `ClientRequest(i)`
- **Code location**: `engine/handler/leader_handler/mod.rs:56-102` (`LeaderHandler::leader_append_entries`)
- **Trigger point**: After entries appended and IO accepted (line 78-81)
- **Event name**: `"ClientRequest"`
- **Fields**: `node`, `post` (strong)
- **Notes**: Only emit for non-membership entries. Membership entries use ProposeConfigChange.

### 6. SendHeartbeat

- **Spec action**: `SendHeartbeat(i)`
- **Code location**: `engine/handler/leader_handler/mod.rs:105-110` (`LeaderHandler::send_heartbeat`)
- **Trigger point**: After BroadcastHeartbeat command pushed (line 109)
- **Event name**: `"SendHeartbeat"`
- **Fields**: `node`, `post` (term only)
- **Notes**: This is a broadcast; no per-follower target field needed.

### 7. ReplicateEntries

- **Spec action**: `ReplicateEntries(i, j)`
- **Code location**: `engine/handler/replication_handler/mod.rs:372-406` (`ReplicationHandler::send_to_target`)
- **Trigger point**: After Replicate command pushed
- **Event name**: `"ReplicateEntries"`
- **Fields**: `node`, `target` (follower j), `post` (term only)
- **Notes**: Emit once per target server. Match on `Inflight::Logs` case (line 381).

### 8. HandleAppendEntries

- **Spec action**: `HandleAppendEntries(i, m)`
- **Code location**: `engine/engine_impl.rs:358-382` (`Engine::handle_append_entries`)
- **Trigger point**: After `append_entries()` helper completes (line 368)
- **Event name**: `"HandleAppendEntries"`
- **Fields**: `node`, `source` (leader), `post` (weak: term, state)
- **Notes**: Source is the leader's node_id from the vote in the message. Covers both accept and reject paths.

### 9. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `engine/handler/replication_handler/mod.rs:171-198` (`update_matching`) and `228-243` (`update_conflicting`)
- **Trigger point**: After progress update
- **Event name**: `"HandleAppendEntriesResponse"`
- **Fields**: `node`, `source` (follower), `post` (weak: term, state)
- **Notes**: Two code paths (success/failure). Emit at both `update_matching` and `update_conflicting`.

### 10. AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `engine/handler/replication_handler/mod.rs:204-220` (`try_commit_quorum_accepted`)
- **Trigger point**: After `update_local_committed()` succeeds (line 215)
- **Event name**: `"AdvanceCommitIndex"`
- **Fields**: `node`, `post` (strong: includes new commitIndex)
- **Notes**: Only emit when commitIndex actually changes. Guard: line 215 returns Some.

### 11. TriggerSnapshot

- **Spec action**: `TriggerSnapshot(i)`
- **Code location**: `engine/handler/snapshot_handler/mod.rs:30-44` (`trigger_snapshot`)
- **Trigger point**: After `set_building_snapshot(true)` (line 40)
- **Event name**: `"TriggerSnapshot"`
- **Fields**: `node`, `post` (term only)
- **Notes**: Emit only when actually triggered (not when already building).

### 12. PurgeLog

- **Spec action**: `PurgeLog(i)`
- **Code location**: `engine/handler/log_handler/mod.rs:31-49` (`purge_log`)
- **Trigger point**: After `state.purge_log(&upto)` (line 47) and PurgeLog command pushed
- **Event name**: `"PurgeLog"`
- **Fields**: `node`, `post` (term only, plus `purgedUpTo` field)
- **Notes**: Include `purgedUpTo` in the event for validation.

### 13. SendInstallSnapshot

- **Spec action**: `SendInstallSnapshot(i, j)`
- **Code location**: `engine/handler/replication_handler/mod.rs:391-396` (`send_to_target` Snapshot case)
- **Trigger point**: After Replicate command for snapshot pushed
- **Event name**: `"SendInstallSnapshot"`
- **Fields**: `node`, `target` (follower j), `post` (term only)
- **Notes**: Match on `Inflight::Snapshot` case specifically.

### 14. HandleInstallSnapshot

- **Spec action**: `HandleInstallSnapshot(i, m)`
- **Code location**: `engine/engine_impl.rs:404-433` (`handle_install_full_snapshot`)
- **Trigger point**: After `install_full_snapshot()` returns (line 424)
- **Event name**: `"HandleInstallSnapshot"`
- **Fields**: `node`, `source` (leader), `post` (weak: term, state)
- **Notes**: Covers both accept (install) and reject (vote too old) paths.

### 15. HandleInstallSnapshotResponse

- **Spec action**: `HandleInstallSnapshotResponse(i, m)`
- **Code location**: Replication task response handling (replication/mod.rs)
- **Trigger point**: After processing InstallSnapshot response
- **Event name**: `"HandleInstallSnapshotResponse"`
- **Fields**: `node`, `source` (follower), `post` (weak: term, state)
- **Notes**: Handled in the replication task, not the engine. May need instrumentation in `ReplicationCore::main()`.

### 16. ProposeConfigChange

- **Spec action**: `ProposeConfigChange(i, newVoters)`
- **Code location**: `engine/handler/replication_handler/mod.rs:63-91` (`append_membership`)
- **Trigger point**: After membership log entry appended (line 75-77)
- **Event name**: `"ProposeConfigChange"`
- **Fields**: `node`, `newVoters` (array of server IDs), `post` (strong)
- **Notes**: `newVoters` is the new voter set from the membership change request.

### 17. CommitConfigChange

- **Spec action**: `CommitConfigChange(i)`
- **Code location**: Same as ProposeConfigChange but for step 2 (joint → uniform)
- **Trigger point**: After uniform config log entry appended
- **Event name**: `"CommitConfigChange"`
- **Fields**: `node`, `post` (strong)
- **Notes**: Distinguish from ProposeConfigChange by checking if previous config was joint (Len > 1).

### 18. LeaseExpire

- **Spec action**: `LeaseExpire(i)`
- **Code location**: Not directly observable — lease expiry is checked on VoteRequest receipt
- **Trigger point**: N/A (modeled as non-deterministic in spec)
- **Event name**: `"LeaseExpire"`
- **Fields**: `node`
- **Notes**: Lease expiry is implicit in the implementation. The trace harness should emit this event when `is_expired()` returns true for the first time. Alternatively, omit from traces and rely on the spec's silent action handling.

### 19. Crash

- **Spec action**: `Crash(i)`
- **Code location**: External to engine (simulated in test harness)
- **Trigger point**: When test kills/stops the Raft node
- **Event name**: `"Crash"`
- **Fields**: `node`
- **Notes**: Test harness must explicitly emit this event. No post-state (volatile state lost).

### 20. Restart

- **Spec action**: `Restart(i)`
- **Code location**: `storage/helper.rs:88-225` (`get_initial_state`)
- **Trigger point**: After `get_initial_state()` completes and node resumes
- **Event name**: `"Restart"`
- **Fields**: `node`, `post` (weak: term, state — especially state=Leader for survivor)
- **Notes**: Critical for Bug Family 5. Must capture whether node resumes as Leader (committed vote for self).

### 21. LeaderStepDown

- **Spec action**: `LeaderStepDown(i)`
- **Code location**: `engine/engine_impl.rs:446-464` (`leader_step_down`)
- **Trigger point**: After state transitions to Follower
- **Event name**: `"LeaderStepDown"`
- **Fields**: `node`, `post` (weak: term, state=Follower)
- **Notes**: Triggered when leader discovers it's no longer in the membership.

## Section 3: Special Considerations

### Engine/Runtime Separation

The openraft Engine is a pure state machine — all protocol logic runs synchronously within Engine methods, producing Command objects for the Runtime to execute. Instrumentation should be placed INSIDE the Engine methods (after state updates, before Commands are pushed), not in the Runtime's command execution loop.

### Concurrency Model

The Engine runs single-threaded within `RaftCore`. Replication tasks run on separate async tasks but only communicate with the core via channels. Trace events from the Engine are naturally ordered; events from replication tasks (HandleInstallSnapshotResponse) may need sequence numbers for ordering.

### Vote Representation

Openraft votes are `{leader_id: {term, node_id}, committed: bool}`. The trace should decompose this into separate `term`, `votedFor`, and `voteCommitted` fields to match the spec variables.

### Log Indexing

The spec uses `purgedUpTo`-relative indexing. The trace should report ABSOLUTE log indices (not relative to purge). The spec's `LastLogIndex(i) = Len(log[i]) + purgedUpTo[i]` matches the implementation's absolute indexing.

### Config Representation

Joint configs are represented as a sequence of voter sets: `<<{1,2,3}, {1,2,4}>>`. Uniform configs: `<<{1,2,3}>>`. The trace should serialize configs as arrays of arrays of server IDs.

### Lease Events

Lease expiry is implicit in the implementation (checked lazily on VoteRequest). The trace harness has two options:
1. Emit `LeaseExpire` events when the internal timer fires
2. Omit lease events and let the spec's `SilentLeaseExpire` (or `LeaseExpire` action without trace event) handle it

Option 2 is simpler but may cause state space issues in trace validation. Prefer option 1 for determinism.

### Bootstrap State

The default `TraceInit` assumes all servers start at term 0 with empty logs. If the test scenario starts with pre-existing state (e.g., cluster already initialized), `TraceInit` must be customized to match the initial state captured in the first trace event.
