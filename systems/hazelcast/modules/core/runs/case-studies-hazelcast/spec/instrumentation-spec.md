# Instrumentation Spec: Hazelcast CP Subsystem (Raft)

Mapping between TLA+ spec actions and source code locations for trace instrumentation.

Source: `hazelcast/hazelcast @ f2fa6ae842`
Base path: `hazelcast/src/main/java/com/hazelcast/cp/internal/raft/impl/`

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is an NDJSON line with this structure:

```json
{
  "event": "<action_name>",
  "node": "<server_id>",
  "state": {
    "term": <int>,
    "role": "<FOLLOWER|CANDIDATE|LEADER>",
    "commitIndex": <long>,
    "lastLogIndex": <long>,
    "lastLogTerm": <int>,
    "votedFor": "<endpoint_id|null>"
  },
  "from": "<source_server>",     // message events only
  "to": "<dest_server>",         // message events only
  ...event-specific fields...
}
```

### State Fields Mapping

| Implementation Getter | TLA+ Variable | Captured At |
|---|---|---|
| `state.term()` | `currentTerm[node]` | Every event |
| `state.role()` | `state[node]` | Every event |
| `state.commitIndex()` | `commitIndex[node]` | Every event |
| `state.log().lastLogOrSnapshotIndex()` | `LastLogIndex(node)` | Every event |
| `state.log().lastLogOrSnapshotTerm()` | `LastLogTerm(node)` | Every event |
| `state.votedFor()` | `votedFor[node]` | Every event |

### Server ID Mapping

Server IDs in the trace use the `RaftEndpoint.toString()` format (UUID-based).
The trace preprocessor must map these to short IDs (`s1`, `s2`, ...) in order of first encounter.

## Section 2: Action-to-Code Mapping

### 1. Timeout (PreVoteTask)

- **Spec action**: `Timeout(i)`
- **Code location**: `task/PreVoteTask.java:46` (`innerRun()`)
- **Trigger point**: After `state.initPreCandidateState()` (line 63), before sending requests
- **Event name**: `"Timeout"`
- **Fields**: `node` (local endpoint), `state` (post pre-candidate init)
- **Notes**: This fires when the pre-vote phase starts, not on the timer event itself. The `term` in state is still the current term (not incremented for pre-vote).

### 2. HandlePreVoteRequest

- **Spec action**: `HandlePreVoteRequest(i, m)`
- **Code location**: `handler/PreVoteRequestHandlerTask.java:51` (`innerRun()`)
- **Trigger point**: After computing response, before `raftNode.send()` (line 58/65/72/78/83)
- **Event name**: `"HandlePreVoteRequest"`
- **Fields**: `node` (local), `from` (req.candidate()), `to` (local), `state`, `granted` (boolean)
- **Notes**: Read-only action — state should not change. Capture `granted` for trace debugging.

### 3. HandlePreVoteResponse

- **Spec action**: `HandlePreVoteResponse(i, m)`
- **Code location**: `handler/PreVoteResponseHandlerTask.java:45` (`handleResponse()`)
- **Trigger point**: After processing response. If majority → after `LeaderElectionTask.innerRun()` completes.
- **Event name**: `"HandlePreVoteResponse"`
- **Fields**: `node` (local), `from` (resp.voter()), `to` (local), `state` (post-transition), `elected` (boolean — whether real election started)
- **Notes**: If majority triggers election, state will show `CANDIDATE` with incremented term. The trace event captures the COMBINED pre-vote-response + election-start transition.

### 4. HandleVoteRequest

- **Spec action**: `HandleVoteRequest(i, m)`
- **Code location**: `handler/VoteRequestHandlerTask.java:54` (`innerRun()`)
- **Trigger point**: After computing response, before `raftNode.send()` (line 66/73/101/121)
- **Event name**: `"HandleVoteRequest"`
- **Fields**: `node` (local), `from` (req.candidate()), `to` (local), `state`, `granted` (boolean)
- **Notes**: State may change (term update, role demotion) before the response is sent.

### 5. HandleVoteResponse

- **Spec action**: `HandleVoteResponse(i, m)`
- **Code location**: `handler/VoteResponseHandlerTask.java:55` (`handleResponse()`)
- **Trigger point**: After processing. If majority → after `raftNode.toLeader()` completes (line 83).
- **Event name**: `"HandleVoteResponse"`
- **Fields**: `node` (local), `from` (resp.voter()), `to` (local), `state` (post-transition), `becameLeader` (boolean)
- **Notes**: If majority, state shows `LEADER`. The noop entry is already appended by `toLeader()`.

### 6. ClientRequest

- **Spec action**: `ClientRequest(i)`
- **Code location**: `task/ReplicateTask.java:65` (`run()`)
- **Trigger point**: After `log.appendEntries()` (line 96), before `broadcastAppendRequest()` (line 100)
- **Event name**: `"ClientRequest"`
- **Fields**: `node` (local leader), `state`
- **Notes**: Only emitted for non-membership-change operations. Membership changes use `ProposeMembershipChange`.

### 7. AppendEntries

- **Spec action**: `AppendEntries(i, j)`
- **Code location**: `RaftNodeImpl.java:663` (`sendAppendRequest()`)
- **Trigger point**: After creating AppendRequest, before `raftIntegration.send()` (line 750)
- **Event name**: `"AppendEntries"`
- **Fields**: `node` (leader), `from` (leader), `to` (follower), `state`, `prevLogIndex`, `prevLogTerm`, `entryCount`, `leaderCommitIndex`, `queryRound`
- **Notes**: Captures the message content for trace debugging. The entries themselves are not serialized (too large); use `entryCount` instead.

### 8. HandleAppendRequest

- **Spec action**: `HandleAppendRequest(i, m)`
- **Code location**: `handler/AppendRequestHandlerTask.java:64` (`innerRun()`)
- **Trigger point**: After all processing (commit update, entry append), before sending response (line 207-209)
- **Event name**: `"HandleAppendRequest"`
- **Fields**: `node` (local), `from` (req.leader()), `to` (local), `state`, `success` (boolean), `configChanged` (boolean — whether latestConfig was updated)
- **Notes**: State reflects post-processing: term may have updated, entries may have been appended/truncated, commitIndex may have advanced. The `configChanged` flag helps debug membership revert/pre-apply.

### 9. HandleAppendSuccessResponse

- **Spec action**: `HandleAppendSuccessResponse(i, m)`
- **Code location**: `handler/AppendSuccessResponseHandlerTask.java:56` (`handleResponse()`)
- **Trigger point**: After `updateFollowerIndices()` (line 70), before `checkIfQueryAckNeeded()` (line 78)
- **Event name**: `"HandleAppendSuccessResponse"`
- **Fields**: `node` (leader), `from` (resp.follower()), `to` (leader), `state`, `followerLastLogIndex` (resp.lastLogIndex()), `matchIndex` (updated value)
- **Notes**: State typically unchanged (leader stays leader). Weak validation is appropriate since commit advancement happens separately.

### 10. HandleAppendFailureResponse

- **Spec action**: `HandleAppendFailureResponse(i, m)`
- **Code location**: `handler/AppendFailureResponseHandlerTask.java:55` (`handleResponse()`)
- **Trigger point**: After processing (possible demotion or nextIndex decrement)
- **Event name**: `"HandleAppendFailureResponse"`
- **Fields**: `node` (leader), `from` (resp.follower()), `to` (leader), `state`, `newNextIndex`
- **Notes**: If `resp.term() > state.term()`, leader demotes — state will show `FOLLOWER`.

### 11. AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `RaftNodeImpl.java:1275` (`tryAdvanceCommitIndex()`)
- **Trigger point**: After `state.commitIndex(commitIndex)` is set (inside `commitEntries()`, line 1300)
- **Event name**: `"AdvanceCommitIndex"`
- **Fields**: `node` (leader), `state` (with new commitIndex), `oldCommitIndex`, `newCommitIndex`
- **Notes**: Only emitted when commit actually advances (returns true). The commitIndex in state reflects the new value.

### 12. LeaderCheckLease

- **Spec action**: `LeaderCheckLease(i)`
- **Code location**: `RaftNodeImpl.java:1374` (HeartbeatTask.innerRun, demotion branch)
- **Trigger point**: After `toFollower(state.term())` (line 1376)
- **Event name**: `"LeaderCheckLease"`
- **Fields**: `node` (former leader), `state` (post-demotion, shows FOLLOWER with same term)
- **Notes**: Only emitted when demotion actually happens. The `term` is unchanged (same-term demotion).

### 13. ProposeMembershipChange

- **Spec action**: `ProposeMembershipChange(i)`
- **Code location**: `task/MembershipChangeTask.java:83` (`run()`) → `ReplicateTask.run()` (line 96) → `preApplyRaftGroupCmd()` (line 98)
- **Trigger point**: After `preApplyRaftGroupCmd()` completes (config pre-applied)
- **Event name**: `"ProposeMembershipChange"`
- **Fields**: `node` (leader), `state`, `member` (added/removed endpoint), `mode` ("ADD"/"REMOVE"), `newConfig` (list of members after change)
- **Notes**: The latestConfig has been updated (pre-applied) by this point. Emit after `raftNode.updateGroupMembers()` in `preApplyRaftGroupCmd`.

### 14. SubmitLinearizableRead

- **Spec action**: `SubmitLinearizableRead(i)`
- **Code location**: `task/QueryTask.java:130` (`handleLinearizableRead()`)
- **Trigger point**: After `queryState.addQuery()` (line 137)
- **Event name**: `"SubmitLinearizableRead"`
- **Fields**: `node` (leader), `state`, `queryRound`, `queryCommitIndex`
- **Notes**: Only emitted for LINEARIZABLE queries with read optimization enabled.

### 15. RunQueries

- **Spec action**: `RunQueries(i)`
- **Code location**: `RaftNodeImpl.java:1313` (`tryRunQueries()`)
- **Trigger point**: After executing queries, before `queryState.reset()` (line 1335)
- **Event name**: `"RunQueries"`
- **Fields**: `node` (leader), `state`, `queryCount` (number of queries executed), `queryRound`
- **Notes**: Only emitted when queries are actually executed (queryCount > 0 and majority acked).

### 16. Crash

- **Spec action**: `Crash(i)`
- **Code location**: N/A — injected by test harness
- **Trigger point**: After recovery completes (state restored from persistent storage)
- **Event name**: `"Crash"`
- **Fields**: `node`, `state` (post-recovery)
- **Notes**: Emitted by the TEST HARNESS, not the Raft implementation itself. The harness should emit this after `RaftNodeImpl.start()` completes for the recovered node.

## Section 3: Special Considerations

### 1. Single-threaded executor

All Raft state mutations are serialized through `RaftIntegration.execute()`. This means:
- No concurrent state access within a single Raft group
- Trace events are naturally ordered per node
- Cross-node event ordering must use a global sequence number or wall-clock timestamp

### 2. Heartbeat piggybacked on AppendEntries

Hazelcast does NOT have a separate heartbeat message. Heartbeats are empty AppendEntries.
The `AppendEntries` trace event covers both heartbeats and replication.
To distinguish: check `entryCount == 0` for heartbeats.

### 3. Pre-vote term handling

Pre-vote requests carry `nextTerm = term + 1` but the node's `currentTerm` is NOT incremented.
The trace event for `Timeout` should show the CURRENT term (not nextTerm).
The spec handles this correctly (pre-vote uses `currentTerm + 1` for messages but `currentTerm` for state).

### 4. Atomic term/votedFor persistence

Hazelcast's `persistTerm(term, votedFor)` is a SINGLE call (RaftState.java:561-567).
Unlike hashicorp/raft, there is NO window where term is persisted but votedFor is not.
This means crash recovery always sees consistent term + votedFor.

### 5. Config pre-application on append

When a follower receives a config entry via AppendEntries, the config is pre-applied
AFTER the success response is sent (AppendRequestHandlerTask.java:216).
The trace event for `HandleAppendRequest` should capture state AFTER pre-application.

### 6. Bootstrap state

The implementation starts with term=0, empty log, FOLLOWER role.
`PreVoteTask` is run immediately on startup (RaftNodeImpl.java:357).
The first trace event should be `Timeout` from the initial pre-vote.

### 7. Noop entry on leader election

When a server becomes leader, it immediately appends a noop entry
(`appendEntryAfterLeaderElection`, RaftNodeImpl.java:1339-1344).
The trace event for `HandleVoteResponse` (with `becameLeader=true`) should
show the noop entry in the log state (lastLogIndex incremented).

### 8. Assert-only term check in success response

`AppendSuccessResponseHandlerTask.java:64` has an `assert` (not `if`) for term check.
In production with `-da`, this check is skipped. The instrumentation should log
when this assert WOULD have fired (i.e., `resp.term() > state.term()`) so we can
validate whether the spec's `AssertsDisabled` flag correctly models production behavior.
