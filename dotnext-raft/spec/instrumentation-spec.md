# Instrumentation Spec: dotnet/dotNext Raft

Action-to-code mapping for trace validation harness generation.

**Source root**: `src/cluster/DotNext.Net.Cluster/Net/Cluster/Consensus/Raft/`

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<ISO8601 timestamp>",
  "event": {
    "name": "<action name>",
    "nid": "<server ID>",
    "state": {
      "term": <int>,
      "role": "<Follower|Candidate|Leader>",
      "votedFor": "<server ID or empty string>",
      "commitIndex": <int>,
      "lastLogIndex": <int>,
      "lastLogTerm": <int>
    },
    "msg": { ... }
  }
}
```

### State Fields

| Implementation field | TLA+ variable | Capture method |
|---|---|---|
| `IPersistentState.Term` | `currentTerm` | `auditTrail.Term` |
| `state` (runtime type) | `state` | `state is FollowerState ? "Follower" : state is CandidateState ? "Candidate" : "Leader"` |
| `IPersistentState.IsVotedFor` | `votedFor` | Requires shadow field — `lastVotedFor` updated in `UpdateVotedForAsync` |
| `IAuditTrail.LastCommittedEntryIndex` | `commitIndex` | `auditTrail.LastCommittedEntryIndex` |
| `IAuditTrail.LastEntryIndex` | `LastLogIndex` | `auditTrail.LastEntryIndex` |
| `GetTermAsync(LastEntryIndex)` | `LastLogTerm` | `auditTrail.GetTermAsync(auditTrail.LastEntryIndex)` |

### Message Fields (per event type)

#### RequestVoteRequest
| Field | Source |
|---|---|
| `from` | local member ID |
| `to` | target member ID |
| `term` | `currentTerm` |
| `lastLogIndex` | `auditTrail.LastEntryIndex` |
| `lastLogTerm` | `GetTermAsync(LastEntryIndex)` |

#### RequestVoteResponse
| Field | Source |
|---|---|
| `from` | responder ID |
| `to` | candidate ID |
| `term` | `result.Term` |
| `voteGranted` | `result.Value` |

#### AppendEntriesRequest
| Field | Source |
|---|---|
| `from` | leader member ID |
| `to` | follower member ID |
| `term` | `currentTerm` |
| `prevLogIndex` | `precedingIndex` |
| `prevLogTerm` | term at `precedingIndex` |
| `commitIndex` | `commitIndex` |
| `entriesCount` | number of entries sent |

#### AppendEntriesResponse
| Field | Source |
|---|---|
| `from` | follower ID |
| `to` | leader ID |
| `term` | `result.Term` |
| `success` | `result.Value != HeartbeatResult.Rejected` |
| `matchIndex` | `LastEntryIndex` after append |

## Section 2: Action-to-Code Mapping

### 1. Timeout

- **Spec action**: `Timeout(i)`
- **Code location**: `RaftCluster.cs:1094-1101` (inside `MoveToCandidateState`)
- **Trigger point**: AFTER `IncrementTermAsync` and `UpdateStateAsync` (line 1096-1097)
- **Trace event name**: `Timeout`
- **Fields**: state (full — term, role, votedFor, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Emit after the term increment and state change to Candidate. The `IncrementTermAsync` atomically sets term and votedFor.

### 2. RequestVote

- **Spec action**: `RequestVote(i, j)`
- **Code location**: `CandidateState.cs:58-74` (inner `VoteAsync` per member)
- **Trigger point**: BEFORE `voter.VoteAsync()` call (line 63)
- **Trace event name**: `RequestVote`
- **Fields**: state (weak — term, role), msg (to, term, lastLogIndex, lastLogTerm)
- **Notes**: Emit once per remote member. The `lastIndex` and `lastTerm` are captured once at lines 30-31 and reused for all members.

### 3. HandleRequestVote

- **Spec action**: `HandleRequestVote(i, m)`
- **Code location**: `RaftCluster.cs:799-854` (`VoteAsync`)
- **Trigger point**: AFTER the vote decision, before releasing `transitionLock` (line 838-847)
- **Trace event name**: `HandleRequestVote`
- **Fields**: state (full), msg (from, term, lastLogIndex, lastLogTerm, voteGranted)
- **Notes**: Capture state AFTER potential step-down and vote grant. Include `result.Value` as `voteGranted` in the event. The `votedFor` shadow field must be updated before capture.

### 4. HandleRequestVoteResponse

- **Spec action**: `HandleRequestVoteResponse(i, m)`
- **Code location**: `CandidateState.cs:85-113` (inside `EndVoting` loop)
- **Trigger point**: AFTER processing each vote result (line 113, end of switch)
- **Trace event name**: `HandleRequestVoteResponse`
- **Fields**: state (weak — term, role), msg (from, term, voteGranted)
- **Notes**: Emit for each member response. For self-vote, emit with `from == to == nid`. The `result` field is nullable (`true`/`false`/`null` for unavailable).

### 5. BecomeLeader

- **Spec action**: `BecomeLeader(i)`
- **Code location**: `RaftCluster.cs:1150-1164` (inside `MoveToLeaderState`)
- **Trigger point**: AFTER `AppendNoOpEntry` and `Leader = newLeader` (line 1161)
- **Trace event name**: `BecomeLeader`
- **Fields**: state (full — term, role, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Emit after the no-op entry is appended. `lastLogIndex` should reflect the no-op. `role` should be `"Leader"`.

### 6. AppendEntries

- **Spec action**: `AppendEntries(i, j)`
- **Code location**: `LeaderState.cs:60-62` (inside `ForkHeartbeats` replicator spawn)
- **Trigger point**: BEFORE `SpawnReplicationAsync` (line 62)
- **Trace event name**: `AppendEntries`
- **Fields**: state (weak), msg (to, term, prevLogIndex, prevLogTerm, commitIndex, entriesCount)
- **Notes**: `precedingIndex = member.State.PrecedingIndex`. Include config sideband info if needed for config validation.

### 7. HandleAppendEntries

- **Spec action**: `HandleAppendEntries(i, m)`
- **Code location**: `RaftCluster.cs:636-675` (inside `AppendEntriesAsync`, after log append)
- **Trigger point**: AFTER `AppendAndCommitAsync` and config processing (line 668)
- **Trace event name**: `HandleAppendEntries`
- **Fields**: state (full), msg (from, term, prevLogIndex, success)
- **Notes**: Emit inside the `TransitionSuppressionScope` block, after both log and config processing. The `commitIndex` in state reflects the updated value. For rejected messages (term too low), emit at line 677 with success=false.

### 8. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse(i, m)`
- **Code location**: `LeaderState.cs:154-174` (inside `DoHeartbeats` response loop)
- **Trigger point**: AFTER `ProcessMemberResponse` (line 158)
- **Trace event name**: `HandleAppendEntriesResponse`
- **Fields**: state (weak — term, role), msg (from, term, success, matchIndex)
- **Notes**: Use weak validation — the leader's state may not reflect individual response processing. The `success` field maps from `MemberResponse.Successful`. For `HigherTermDetected`, the response triggers step-down and the event should still be emitted with the higher term.

### 9. AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex(i)`
- **Code location**: `LeaderState.cs:178-183` (inside `DoHeartbeats`)
- **Trigger point**: AFTER `CommitAsync` (line 181)
- **Trace event name**: `AdvanceCommitIndex`
- **Fields**: state (commit — term, role, commitIndex)
- **Notes**: Only emit when `commitQuorum >= majority` and commit actually advances. The `commitIndex` should reflect the new committed index.

### 10. ClientRequest

- **Spec action**: `ClientRequest(i, v)`
- **Code location**: `PersistentStateExtensions.cs:49-51` (`AppendAsync`)
- **Trigger point**: AFTER `AppendAsync` returns
- **Trace event name**: `ClientRequest`
- **Fields**: state (full), value (the client payload, or "nil" for no-op)
- **Notes**: This may be hard to instrument generically since client requests go through various code paths. Consider instrumenting the `AppendAsync` extension method.

### 11. Crash

- **Spec action**: `Crash(i)`
- **Code location**: `RaftCluster.cs` (dispose/shutdown path)
- **Trigger point**: On controlled shutdown or simulated crash in test
- **Trace event name**: `Crash`
- **Fields**: state (term, role only — volatile state already lost)
- **Notes**: For test scenarios, inject crash events at the test harness level. In production traces, this corresponds to process termination.

### 12. ProposeConfig

- **Spec action**: `ProposeConfig(i, newConfig)`
- **Code location**: `RaftCluster.Membership.cs:281-290` (inside `AddMemberAsync`) or `RaftCluster.Membership.cs:349-354` (inside `RemoveMemberAsync`)
- **Trigger point**: AFTER `ConfigurationStorage.AddMemberAsync` / `RemoveMemberAsync`
- **Trace event name**: `ProposeConfig`
- **Fields**: state (weak), config (new proposed member set as JSON array)
- **Notes**: Emit after the config storage mutation completes.

### 13. ApplyConfig

- **Spec action**: `ApplyConfig(i)`
- **Code location**: `LeaderState.cs:191` (inside `DoHeartbeats`)
- **Trigger point**: AFTER `configurationStorage.ApplyAsync`
- **Trace event name**: `ApplyConfig`
- **Fields**: state (weak)
- **Notes**: Only emit when the leader actually applies (has a proposal). The `ApplyAsync` call at line 191 is a no-op if `!HasProposal`.

## Section 3: Special Considerations

### 1. votedFor Shadow Field

The `IPersistentState` interface does not expose `votedFor` as a readable property — only `IsVotedFor(id)`. To capture the actual votedFor value for trace events, add a shadow field:

```csharp
// In the persistent state implementation:
private ClusterMemberId? _lastVotedFor;

// Update in UpdateVotedForAsync:
public async ValueTask UpdateVotedForAsync(ClusterMemberId id, CancellationToken token)
{
    _lastVotedFor = id;
    // ... existing persistence logic
}

// Reset on term change (in Term setter):
public long Term
{
    set { _term = value; _lastVotedFor = null; /* persist */ }
}
```

### 2. Concurrent Threads and Event Ordering

dotNext uses async/await with `ThreadPool.UnsafeQueueUserWorkItem` for state transitions. Events may interleave:

- **Follower timeout vs heartbeat**: `FollowerState.Track` fires `MoveToCandidateState` on ThreadPool. Between the timeout and lock acquisition, a heartbeat may arrive.
- **Heartbeat response processing**: `DoHeartbeats` processes responses from a `TaskCompletionPipe`. Responses arrive in non-deterministic order.
- **Vote response processing**: `EndVoting` iterates an async enumerator. Response order is non-deterministic.

**Instrumentation strategy**: Emit events inside the `transitionLock` where possible. For heartbeat/vote responses (processed without the main lock), accept non-deterministic ordering and use weak post-state validation in the trace spec.

### 3. Bootstrap State

dotNext Raft starts with:
- `Term = 0` (default)
- `votedFor = null` (no vote)
- Empty log (`LastEntryIndex = 0`)
- `commitIndex = 0`
- All servers in `Follower` state

This matches the base spec's `Init`. No bootstrap adjustment needed (unlike braft which starts at term=1).

### 4. Server Identity

dotNext uses `ClusterMemberId` (a struct wrapping a `Guid` or endpoint) for member identification. For trace events, map these to stable string identifiers (e.g., "s1", "s2", "s3") based on configuration order or a deterministic mapping.

### 5. Log Entry Values

Log entries in dotNext are binary blobs (`ReadOnlyMemory<byte>`). For trace purposes:
- No-op entries (from `AppendNoOpEntry`): trace as `value: "nil"`
- Client entries: trace as `value: "<hash or sequence number>"` — exact content doesn't matter for safety properties, but each entry needs a unique identifier

### 6. Config Sideband Events

Config changes flow through the sideband protocol:
1. `ProposeConfig` — leader proposes (traced at Membership.cs)
2. Config sent via `AppendEntries` — carried in message (traced as part of AE event)
3. `ApplyConfig` — leader applies on quorum (traced at LeaderState.cs:191)
4. Follower applies — inside `HandleAppendEntries` (traced as part of AE handler event)

For trace validation, the `HandleAppendEntries` event implicitly covers follower config processing. The `ProposeConfig` and `ApplyConfig` events on the leader side are separate trace points.

### 7. Controlled Test Environment

For initial trace validation, use integration tests (not production) with:
- 3-node cluster with fixed member IDs
- Deterministic test scenarios (e.g., start cluster, write entry, stop leader, verify new election)
- Environment variable `DOTNEXT_TRACE_FILE=path.ndjson` to activate tracing
- Test framework: xUnit (dotNext uses xUnit for its test suite)
