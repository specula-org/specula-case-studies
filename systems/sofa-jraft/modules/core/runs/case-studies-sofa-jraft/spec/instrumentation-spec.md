# Instrumentation Spec: sofastack/sofa-jraft

Action-to-code mapping for generating trace events compatible with `Tracesofajraft.tla`.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<monotonic_ms>",
  "event": {
    "name": "<spec_action_name>",
    "nid": "<server_id>",
    "state": {
      "term": <long>,
      "role": "Follower" | "Candidate" | "Leader",
      "votedFor": "<peer_id>" | "",
      "commitIndex": <long>,
      "lastLogIndex": <long>,
      "lastLogTerm": <long>
    },
    "msg": { ... }  // optional, present for message-related events
  }
}
```

### State Fields

| Implementation getter | TLA+ variable | Captured at |
|---|---|---|
| `NodeImpl.currTerm` | `currentTerm` | Every event |
| `NodeImpl.state` (→ "Follower"/"Candidate"/"Leader") | `state` | Every event |
| `NodeImpl.votedId.toString()` (empty string if null/empty) | `votedFor` | Every event |
| `BallotBox.lastCommittedIndex` | `commitIndex` | Every event |
| `LogManager.getLastLogIndex()` | `lastLogIndex` | Every event |
| `LogManager.getLastLogId().getTerm()` | `lastLogTerm` | Every event |

### Message Fields

| Implementation field | TLA+ field | Notes |
|---|---|---|
| `request.getServerId()` / source peer | `msg.from` | Sender ID |
| `request.getPeerId()` / dest peer | `msg.to` | Receiver ID |
| `request.getTerm()` / `response.getTerm()` | `msg.term` | Message term |
| `response.getSuccess()` | `msg.success` | For AppendEntries responses |
| `response.getLastLogIndex()` | `msg.matchIndex` | For success responses |
| `request.getLastLogIndex()` | `msg.lastLogIndex` | For vote requests |
| `request.getLastLogTerm()` | `msg.lastLogTerm` | For vote requests |
| `request.getPrevLogIndex()` | `msg.prevLogIndex` | For AppendEntries requests (replicate only) |
| `response.getGranted()` | `msg.granted` | For vote responses |

## 2. Action-to-Code Mapping

### Election Actions

#### `BecomeCandidate` → `ElectSelf(i)`

- **Code location**: `NodeImpl.java:1163-1235` (`electSelf()`)
- **Trigger point**: After `this.state = State.STATE_CANDIDATE` (line 1181), before unlock (line 1191)
- **Trace event name**: `BecomeCandidate`
- **Fields**: state (captures new term, role=Candidate, votedFor=self)
- **Notes**: State snapshot must be taken AFTER term increment (line 1182) and votedId assignment (line 1183). The persist happens later (line 1227) — trace event captures in-memory state, not persisted.

#### `HandleRequestVoteRequest` → `HandleRequestVoteRequestAtomic(i, m)`

- **Code location**: `NodeImpl.java:1802-1878` (`handleRequestVoteRequest()`)
- **Trigger point**: After the `do { ... } while(false)` block completes (line 1866), before building the response (line 1868)
- **Trace event name**: `HandleRequestVoteRequest`
- **Fields**: state + msg {from: candidateId, to: serverId, term: request.getTerm()}
- **Notes**: Uses the Atomic variant for trace validation (non-crash path). The trace captures post-stepDown state. votedFor may be the candidate (grant) or empty (reject).

#### `HandleRequestVoteResponse` → `HandleRequestVoteResponse(i, m)`

- **Code location**: `NodeImpl.java:2584-2618` (`handleRequestVoteResponse()`)
- **Trigger point**: After processing the response (line 2609-2613), inside the try block
- **Trace event name**: `HandleRequestVoteResponse`
- **Fields**: state + msg {from: peerId (voter), to: serverId (candidate), term: response.getTerm(), granted: response.getGranted()}
- **Notes**: Self-vote is logged separately (from=to=self) and skipped during trace validation. Transport failures produce an event with no matching message in the bag.

#### `BecomeLeader` → `BecomeLeader(i)`

- **Code location**: `NodeImpl.java:1261-1298` (`becomeLeader()`)
- **Trigger point**: After `this.state = State.STATE_LEADER` (line 1267)
- **Trace event name**: `BecomeLeader`
- **Fields**: state (captures role=Leader, same term)
- **Notes**: This event should fire BEFORE the noop/config-flush log entries are appended.

### Replication Actions

#### `SendAppendEntries` → `AppendEntries(i, j)`

- **Code location**: `Replicator.java:1629-1710` (`sendEntries()`)
- **Trigger point**: After building the request, before sending via RPC
- **Trace event name**: `SendAppendEntries`
- **Fields**: state + msg {from: leaderId, to: peerId, term: request.getTerm(), prevLogIndex: request.getPrevLogIndex()}
- **Notes**: Only for replicate (non-empty entries). The `prevLogIndex` field disambiguates replicate from heartbeat in the trace spec.

#### `SendHeartbeat` → `SendHeartbeat(i, j)`

- **Code location**: `Replicator.java:1711-1728` (`sendHeartbeat()`)
- **Trigger point**: Inside `sendEmptyEntries(true)`, after building request
- **Trace event name**: `SendHeartbeat`
- **Fields**: state + msg {from: leaderId, to: peerId, term: request.getTerm()}
- **Notes**: No `prevLogIndex` field in event — this distinguishes heartbeat from replicate.

#### `HandleAppendEntriesRequest` → `HandleAppendEntriesRequest(i, m)`

- **Code location**: `NodeImpl.java:1944-2100` (`handleAppendEntriesRequest()`)
- **Trigger point**: After `checkStepDown()` (line 1980), before returning response
- **Trace event name**: `HandleAppendEntriesRequest`
- **Fields**: state + msg {from: serverId (leader), to: self, term: request.getTerm(), prevLogIndex: request.getPrevLogIndex() (only for replicate)}
- **Notes**: Both heartbeat and replicate share this handler. Use presence of `prevLogIndex` in trace to distinguish.

#### `HandleAppendEntriesResponseSuccess` → `HandleAppendEntriesResponseSuccess(i, m)`

- **Code location**: `Replicator.java:1519-1559` (success path in `onAppendEntriesReturned()`)
- **Trigger point**: After `r.nextIndex += entriesSize` (line 1553)
- **Trace event name**: `HandleAppendEntriesResponseSuccess`
- **Fields**: state + msg {from: peerId (follower), to: leaderId, term: response.getTerm(), success: true, matchIndex: nextIndex-1}
- **Notes**: This is the path with the incomplete term check bug (Family 2). Log the event regardless of whether the term check passed.

#### `HandleAppendEntriesResponseFailure` → `HandleAppendEntriesResponseFailure(i, m)`

- **Code location**: `Replicator.java:1454-1517` (failure path in `onAppendEntriesReturned()`)
- **Trigger point**: After processing the failure (decrement nextIndex or stepDown)
- **Trace event name**: `HandleAppendEntriesResponseFailure`
- **Fields**: state + msg {from: peerId (follower), to: leaderId, term: response.getTerm(), success: false}
- **Notes**: If term > leader term, this triggers stepDown. Capture post-stepDown state.

#### `HandleHeartbeatResponse` → `HandleHeartbeatResponse(i, m)`

- **Code location**: `Replicator.java:1176-1269` (`onHeartbeatReturned()`)
- **Trigger point**: After processing (line 1257-1263 for success, line 1232-1239 for stepDown)
- **Trace event name**: `HandleHeartbeatResponse`
- **Fields**: state + msg {from: peerId (follower), to: leaderId, term: response.getTerm()}
- **Notes**: Has correct term check. Capture post-stepDown state if term was higher.

#### `HandleInstallSnapshotResponse` → `HandleInstallSnapshotResponse(i, m)`

- **Code location**: `Replicator.java:711-765` (`onInstallSnapshotReturned()`)
- **Trigger point**: After processing the response (line 747 for success, line 753 for failure)
- **Trace event name**: `HandleInstallSnapshotResponse`
- **Fields**: state + msg {from: peerId (follower), to: leaderId, term: response.getTerm(), success: response.getSuccess()}
- **Notes**: This is where the missing term check bug lives (Family 2). Log the response term even though the code ignores it.

#### `AdvanceCommitIndex` → `AdvanceCommitIndex(i)`

- **Code location**: `BallotBox.java:99-143` (`commitAt()`)
- **Trigger point**: After `this.lastCommittedIndex = lastCommittedIndex` (line 137), inside the lock
- **Trace event name**: `AdvanceCommitIndex`
- **Fields**: state (captures new commitIndex)
- **Notes**: This fires from the Replicator thread context (via `commitAt`). The nid should be the leader's ID.

### Configuration Actions

#### `ProposeConfigChange` → `ProposeConfigChange(i, newPeers)`

- **Code location**: `NodeImpl.java:506-536` (`ConfigurationCtx.nextStage()` STAGE_CATCHING_UP → STAGE_JOINT)
- **Trigger point**: After `unsafeApplyConfiguration()` (line 512-514)
- **Trace event name**: `ProposeConfigChange`
- **Fields**: state + msg {newPeers: serialized peer list}
- **Notes**: The newPeers field must be deserializable to a set of server IDs matching the spec's Server constant.

## 3. Special Considerations

### State Access

- **`votedFor`**: `NodeImpl.votedId` is a `PeerId`. Serialize as `toString()` or empty string for null/empty. The trace spec maps empty string to `Nil`.
- **`commitIndex`**: Accessed via `BallotBox.lastCommittedIndex`. This requires either a getter or a shadow field since BallotBox uses StampedLock.
- **`lastLogIndex`/`lastLogTerm`**: Accessed via `LogManager.getLastLogIndex()` and `LogManager.getLastLogId(false).getTerm()`. Use `false` (not flush) for consistency with in-memory state.

### Concurrency

- **Replicator thread**: `onAppendEntriesReturned`, `onHeartbeatReturned`, `onInstallSnapshotReturned` run on the Replicator's ThreadId lock. State snapshot must be taken under NodeImpl.readLock to ensure consistency.
- **BallotBox**: `commitAt()` runs under StampedLock.writeLock. The `AdvanceCommitIndex` event should capture state after the lock is released.
- **Disruptor threads**: Log persistence callbacks run on Disruptor threads. Trace events from these threads may interleave with main thread events — the silent actions in the trace spec handle this.

### Bootstrap / Initial State

- sofa-jraft starts with `term=0`, no log entries, all nodes as Followers.
- If using `BootstrapCluster`, the initial state may differ (term=1, config entry at index 1). Adjust `TraceInit` in the trace spec accordingly.

### Serialization

- Java `PeerId.toString()` includes `ip:port:priority`. For trace purposes, use a simplified node ID (e.g., "s1", "s2", "s3") that matches the Server constant in the spec.
- Zero-value fields may be omitted in JSON serialization. The trace spec handles this: absence of `prevLogIndex` indicates a heartbeat.
