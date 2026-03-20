# Instrumentation Spec: raft-java

Action-to-code mapping for trace validation of wenweihu86/raft-java.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<ISO-8601 timestamp>",
  "event": {
    "name": "<spec action name>",
    "nid": "<server ID string, e.g., s1>",
    "state": {
      "term": <int>,
      "role": "<Follower|PreCandidate|Candidate|Leader>",
      "votedFor": "<server ID or empty string for Nil>",
      "commitIndex": <int>,
      "lastLogIndex": <int>,
      "lastLogTerm": <int>
    },
    "msg": {  // optional, for message events
      "from": "<server ID>",
      "to": "<server ID>",
      "type": "<message type>",
      "term": <int>,
      // ... additional message-specific fields
    },
    "config": ["s1", "s2", ...]  // optional, for config change events
  }
}
```

### State Fields

| Implementation Getter | TLA+ Variable | Capture Timing |
|----------------------|---------------|----------------|
| `raftNode.getCurrentTerm()` | `currentTerm[nid]` | After action |
| `raftNode.getState()` | `state[nid]` | After action |
| `raftNode.getVotedFor()` | `votedFor[nid]` | After action |
| `raftNode.getCommitIndex()` | `commitIndex[nid]` | After action |
| `raftNode.getRaftLog().getLastLogIndex()` | `LastLogIndex(nid)` | After action |
| `getLastLogTerm()` | `LastLogTerm(nid)` | After action |

### Role Mapping

| Java State | TLA+ Constant |
|-----------|---------------|
| `NodeState.STATE_FOLLOWER` | `"Follower"` |
| `NodeState.STATE_PRE_CANDIDATE` | `"PreCandidate"` |
| `NodeState.STATE_CANDIDATE` | `"Candidate"` |
| `NodeState.STATE_LEADER` | `"Leader"` |

### Server ID Mapping

Map `localServer.getServerId()` (int) to string: `"s" + serverId`.

## Section 2: Action-to-Code Mapping

### 2.1 StartPreVote

- **Code location**: `RaftNode.java:459-484` (`startPreVote()`)
- **Trigger point**: After `state = NodeState.STATE_PRE_CANDIDATE` (line 467), before sending RPCs
- **Event name**: `"StartPreVote"`
- **Fields**: state (full)
- **Notes**: Capture state after state transition but before RPCs are submitted to thread pool

### 2.2 HandlePreVoteRequest

- **Code location**: `RaftConsensusServiceImpl.java:34-63` (`preVote()`)
- **Trigger point**: Before `return responseBuilder.build()` (all return paths: lines 41, 44, 50, 59)
- **Event name**: `"HandlePreVoteRequest"`
- **Fields**: state (weak: term + role), msg (from=request.serverId, to=localServer)
- **Notes**: Multiple return paths — instrument before each return, or instrument once at entry and capture before returning

### 2.3 HandlePreVoteResponse

- **Code location**: `RaftNode.java:576-618` (`PreVoteResponseCallback.success()`)
- **Trigger point**: After lock acquired (line 577), after processing response
- **Event name**: `"HandlePreVoteResponse"`
- **Fields**: state (weak), msg (from=peer, to=localServer)
- **Notes**: Line 579 sets `peer.setVoteGranted()` BEFORE staleness check — this is Bug Family 4

### 2.4 StartVote

- **Code location**: `RaftNode.java:490-518` (`startVote()`)
- **Trigger point**: After `votedFor = localServer.getServerId()` (line 501), before sending RPCs
- **Event name**: `"StartVote"`
- **Fields**: state (weak: term + role), votedFor
- **Notes**: This is the Bug Family 1 hotspot — no persistence call here

### 2.5 HandleRequestVoteRequest

- **Code location**: `RaftConsensusServiceImpl.java:66-99` (`requestVote()`)
- **Trigger point**: Before `return responseBuilder.build()` (line 95)
- **Event name**: `"HandleRequestVoteRequest"`
- **Fields**: state (weak), votedFor, msg (from=request.serverId, to=localServer)
- **Notes**: Line 84 checks `votedFor == 0` only (not `|| votedFor == candidateId`)

### 2.6 HandleRequestVoteResponse

- **Code location**: `RaftNode.java:640-684` (`VoteResponseCallback.success()`)
- **Trigger point**: After processing response, before lock release
- **Event name**: `"HandleRequestVoteResponse"`
- **Fields**: state (weak), msg (from=peer, to=localServer)
- **Notes**: Line 643 sets `peer.setVoteGranted()` — shared with PreVote (Bug Family 4)

### 2.7 BecomeLeader

- **Code location**: `RaftNode.java:697-706` (`becomeLeader()`)
- **Trigger point**: After `state = NodeState.STATE_LEADER` (line 698)
- **Event name**: `"BecomeLeader"`
- **Fields**: state (weak)
- **Notes**: Called from within VoteResponseCallback when quorum reached (line 675)

### 2.8 ClientRequest

- **Code location**: `RaftNode.java:144-194` (`replicate()`)
- **Trigger point**: After `raftLog.append(entries)` (line 158), before submitting RPCs
- **Event name**: `"ClientRequest"`
- **Fields**: state (full), entryType
- **Notes**: Only emit for `ENTRY_TYPE_DATA`; config changes use `ProposeConfigChange`

### 2.9 AppendEntries

- **Code location**: `RaftNode.java:196-250` (`appendEntries()` — request building)
- **Trigger point**: After building request (line 250), before RPC call (line 253)
- **Event name**: `"AppendEntries"`
- **Fields**: state (weak), msg (from=localServer, to=peer, term, prevLogIndex, prevLogTerm, entriesCount, commitIndex)
- **Notes**: Same method handles both heartbeat and replication

### 2.10 HandleAppendEntriesRequest

- **Code location**: `RaftConsensusServiceImpl.java:101-190` (`appendEntries()`)
- **Trigger point**: Before `return responseBuilder.build()` (lines 111, 134, 145, 155, 186)
- **Event name**: `"HandleAppendEntriesRequest"`
- **Fields**: state (full), msg (from=request.serverId, to=localServer)
- **Notes**: Multiple return paths. The `advanceCommitIndex` call (lines 154, 181) is inline.
  Bug Family 2: line 315 unconditionally sets commitIndex — capture AFTER this call.

### 2.11 HandleAppendEntriesResponse

- **Code location**: `RaftNode.java:255-294` (response handling in `appendEntries()`)
- **Trigger point**: After processing response, before lock release
- **Event name**: `"HandleAppendEntriesResponse"`
- **Fields**: state (weak), msg (from=peer, to=localServer, success, matchIndex)
- **Notes**: Bug Family 2: line 276 unconditionally sets matchIndex. Capture AFTER update.

### 2.12 AdvanceCommitIndex

- **Code location**: `RaftNode.java:737-776` (`advanceCommitIndex()` — leader side)
- **Trigger point**: After `commitIndex = newCommitIndex` (line 762)
- **Event name**: `"AdvanceCommitIndex"`
- **Fields**: state (full)
- **Notes**: Only the leader-side has this as a separate action. Follower-side is inline in HandleAppendEntriesRequest.

### 2.13 SendInstallSnapshot

- **Code location**: `RaftNode.java:789-857` (`installSnapshot()` — leader sends)
- **Trigger point**: After first chunk sent successfully
- **Event name**: `"SendInstallSnapshot"`
- **Fields**: state (weak), msg (from=localServer, to=peer)
- **Notes**: Multi-chunk transfer. Emit event once at the start.

### 2.14 HandleInstallSnapshotRequest

- **Code location**: `RaftConsensusServiceImpl.java:192-309` (`installSnapshot()`)
- **Trigger point**: After `request.getIsLast()` processing (line 279), after state machine apply
- **Event name**: `"HandleInstallSnapshotRequest"`
- **Fields**: state (weak), msg (from=request.serverId, to=localServer)
- **Notes**: Bug Family 3: lines 279-301 do NOT update config/commitIndex. Capture shows stale values.

### 2.15 HandleInstallSnapshotResponse

- **Code location**: `RaftNode.java:834-848` (response handling in `installSnapshot()`)
- **Trigger point**: After `peer.setNextIndex()` (line 845)
- **Event name**: `"HandleInstallSnapshotResponse"`
- **Fields**: state (weak), msg (from=peer, to=localServer, success)

### 2.16 TakeSnapshot

- **Code location**: `RaftNode.java:317-397` (`takeSnapshot()`)
- **Trigger point**: After successful snapshot (line 364), before log truncation
- **Event name**: `"TakeSnapshot"`
- **Fields**: state (weak), snapshotIndex, snapshotTerm
- **Notes**: Runs on a scheduled timer. Capture after snapshot metadata is written.

### 2.17 ProposeConfigChange

- **Code location**: `RaftClientServiceImpl.java:147` (addPeers → replicate), `RaftClientServiceImpl.java:206` (removePeers → replicate)
- **Trigger point**: Before `raftNode.replicate(configurationData, ENTRY_TYPE_CONFIGURATION)`
- **Event name**: `"ProposeConfigChange"`
- **Fields**: state (full), config (new configuration server list)
- **Notes**: The replicate call appends a ConfigEntry log entry

## Section 3: Special Considerations

### 3.1 Concurrency and Lock Boundaries

Most state access is serialized by `RaftNode.lock`. However:
- `appendEntries()` (RaftNode.java:196) releases and re-acquires the lock multiple times
- RPC callbacks (`PreVoteResponseCallback`, `VoteResponseCallback`) run in the thread pool
- Heartbeat timer and election timer run on `ScheduledExecutorService`

**Recommendation**: Emit trace events inside the lock (after state changes, before lock release) to ensure consistent state snapshots.

### 3.2 Server ID Mapping

raft-java uses integer server IDs (`localServer.getServerId()`). The trace spec expects string IDs (`"s1"`, `"s2"`, etc.).

**Mapping**: `"s" + String.valueOf(serverId)` in the trace emitter.

### 3.3 VotedFor Encoding

`votedFor = 0` in Java means "no vote" (Nil in TLA+). In trace JSON, encode as empty string `""`.
Non-zero votedFor should be encoded as the server ID string (e.g., `"s1"`).

### 3.4 Log Entry Type Mapping

| Java Type | TLA+ Constant |
|-----------|---------------|
| `EntryType.ENTRY_TYPE_DATA` | `"ValueEntry"` |
| `EntryType.ENTRY_TYPE_CONFIGURATION` | `"ConfigEntry"` |

### 3.5 Bug Family 1: Persistence Gap Observation

To observe the persistence gap in `startVote()`:
- Emit `"StartVote"` event AFTER in-memory state update (line 501)
- Note that `persistedTerm` and `persistedVotedFor` have NOT been updated
- A subsequent crash before any `stepDown` call will recover from stale persisted state
- The trace can show: StartVote → (no persist) → Crash → Recovery with old term/votedFor

### 3.6 Bug Family 2: CommitIndex Regression

To observe commitIndex regression:
- The `HandleAppendEntriesRequest` event captures commitIndex AFTER the unconditional set (line 315)
- Compare consecutive commitIndex values for the same server — a decrease confirms the bug
- Also check `HandleAppendEntriesResponse` for matchIndex regression (line 276)

### 3.7 Multiple Return Paths

Several handlers have multiple return paths (`appendEntries` handler has 5). Options:
1. **Single instrumentation point**: wrap the entire method body, emit before final return
2. **Per-path instrumentation**: emit at each return with a subtype field
3. **Recommended**: use a single point after lock release with state captured under lock

### 3.8 Thread Pool and Async Events

`appendEntries()` calls for different peers are submitted to the thread pool concurrently. This means:
- Multiple `AppendEntries` events for different peers may interleave
- The trace file must use a thread-safe writer (synchronized or ConcurrentLinkedQueue → flush)
- Events from different peers for the same leader are independent and can appear in any order
