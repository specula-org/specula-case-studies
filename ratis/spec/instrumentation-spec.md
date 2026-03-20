# Instrumentation Spec: Apache Ratis

Maps TLA+ spec actions to source code locations for trace harness generation.

**Source root**: `ratis-server/src/main/java/org/apache/ratis/server/`

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "node": "<server_id>",
  "term": <currentTerm>,
  "role": "<FOLLOWER|CANDIDATE|LEADER>",
  "commitIndex": <commitIndex>,
  "lastLogIndex": <lastLogIndex>,
  "lastLogTerm": <lastLogTerm>,
  "flushIndex": <flushIndex>,
  ... (action-specific fields)
}
```

### State Fields (captured at every event)

| Implementation getter | TLA+ variable | Type |
|---|---|---|
| `state.getCurrentTerm()` | `currentTerm[node]` | long |
| `role.getCurrentRole()` | `role[node]` | string (FOLLOWER/CANDIDATE/LEADER) |
| `state.getLog().getLastCommittedIndex()` | `commitIndex[node]` | long |
| `state.getLog().getLastEntryTermIndex().getIndex()` | `LastLogIndex(node)` | long |
| `state.getLog().getLastEntryTermIndex().getTerm()` | `LastLogTerm(node)` | long |
| `state.getLog().getFlushIndex()` | `flushIndex[node]` | long |

### Message Fields (event-specific)

| Implementation field | TLA+ field | Used in |
|---|---|---|
| `request.getServerRequest().getRequestorId()` | `src` | HandleRequestVoteRequest, HandleAppendEntriesRequest |
| `reply.getServerReply().getReplyId()` | `src` | HandleAppendEntriesResponse |
| `request.getCandidateTerm()` / `reply.getTerm()` | `term` | Vote/AE messages |
| `reply.getResult()` | `result` | HandleAppendEntriesResponse |
| `follower.getId()` | `dst` | AppendEntries, Heartbeat, SendInstallSnapshot |

## Section 2: Action-to-Code Mapping

### Election Actions

#### 1. Timeout
- **Spec action**: `Timeout(s)`
- **Code location**: `impl/LeaderElection.java:442` — start of `askForVotes()` with phase=ELECTION
- **Trigger**: After `server.initElection(Phase.ELECTION)` completes (line 383)
- **Event name**: `"Timeout"`
- **Fields**: state fields only
- **Notes**: `initElection` increments term and sets votedFor=self. Capture state AFTER initElection.

#### 2. PreVote
- **Spec action**: `PreVote(s)`
- **Code location**: `impl/LeaderElection.java:442` — start of `askForVotes()` with phase=PRE_VOTE
- **Trigger**: After `server.initElection(Phase.PRE_VOTE)` (line 382)
- **Event name**: `"PreVote"`
- **Fields**: state fields only
- **Notes**: Pre-vote does NOT increment term. Differentiate from Timeout via phase field.

#### 3. HandleRequestVoteRequest
- **Spec action**: `HandleRequestVoteRequest(s, m)`
- **Code location**: `impl/RaftServerImpl.java:1450-1497` — `requestVote()` private method
- **Trigger**: After synchronized block completes (line 1492), before returning reply
- **Event name**: `"HandleRequestVoteRequest"`
- **Fields**: state + `src` (candidateId), `voteGranted` (boolean), `phase` (PRE_VOTE/ELECTION)
- **Notes**: State captured AFTER role/term changes. `phase` from `request.getPreVote()`.

#### 4. HandleRequestVoteResponse (become leader)
- **Spec action**: `HandleRequestVoteResponse(s, m)`
- **Code location**: `impl/LeaderElection.java:460-480` — after `waitForResults()` returns PASSED
- **Trigger**: After `changeToLeader()` completes
- **Event name**: `"HandleRequestVoteResponse"`
- **Fields**: state fields only
- **Notes**: Only emitted when election succeeds (PASSED). Capture after leader state initialized.

#### 5. HandleRequestVoteResponseHigherTerm
- **Spec action**: `HandleRequestVoteResponseHigherTerm(s, m)`
- **Code location**: `impl/LeaderElection.java:556-557` — `DISCOVERED_A_NEW_TERM` case
- **Trigger**: After `rejected()` → `changeToFollower(newTerm)`
- **Event name**: `"HandleRequestVoteResponseHigherTerm"`
- **Fields**: state fields + `src` (peer who had higher term)
- **Notes**: May also fire from `rejected()` at line 478.

### Log Replication Actions

#### 6. ClientRequest
- **Spec action**: `ClientRequest(s, v)`
- **Code location**: `impl/RaftServerImpl.java:800-850` — `appendTransaction()` or `submitClientRequestAsync()`
- **Trigger**: After `state.getLog().append()` completes
- **Event name**: `"ClientRequest"`
- **Fields**: state fields
- **Notes**: Capture after log append returns. Multiple code paths converge here.

#### 7. FlushLog
- **Spec action**: `FlushLog(s)`
- **Code location**: `raftlog/segmented/SegmentedRaftLogWorker.java:370-390` — `flushBatchedIO()`
- **Trigger**: After `flush()` completes, when flushIndex advances
- **Event name**: `"FlushLog"`
- **Fields**: state fields (specifically `flushIndex`)
- **Notes**: Async worker thread. May interleave with other events.

#### 8. AppendEntries
- **Spec action**: `AppendEntries(s, t)`
- **Code location**: `leader/LogAppenderDefault.java:59-104` — `sendAppendEntriesWithRetries()`
- **Trigger**: Before sending request (line 75), when entries are non-empty
- **Event name**: `"AppendEntries"`
- **Fields**: state + `dst` (follower), `prevLogIndex`, `prevLogTerm`, `numEntries`, `firstIndex`
- **Notes**: Distinguish from Heartbeat by non-empty entries.

#### 9. Heartbeat
- **Spec action**: `Heartbeat(s, t)`
- **Code location**: `leader/LogAppenderDefault.java:59-104` — `sendAppendEntriesWithRetries()`
- **Trigger**: Before sending request (line 75), when entries are empty
- **Event name**: `"Heartbeat"`
- **Fields**: state + `dst` (follower)
- **Notes**: Same code path as AppendEntries but with empty entries.

#### 10. HandleAppendEntriesRequest
- **Spec action**: `HandleAppendEntriesRequest(s, m)`
- **Code location**: `impl/RaftServerImpl.java:1594-1682` — `appendEntriesAsync()`
- **Trigger**: After reply is built (line 1674-1680), in thenApply handler
- **Event name**: `"HandleAppendEntriesRequest"`
- **Fields**: state + `src` (leader), `result` (SUCCESS/INCONSISTENCY/NOT_LEADER)
- **Notes**: State captured AFTER commit index update (line 1670). Result in reply proto.

#### 11. HandleAppendEntriesResponse
- **Spec action**: `HandleAppendEntriesResponse(s, m)`
- **Code location**: `leader/LogAppenderDefault.java:176-209` — `handleReply()`
- **Trigger**: After switch on result completes
- **Event name**: `"HandleAppendEntriesResponse"`
- **Fields**: state + `src` (follower), `result`, `matchIndex` (for follower), `nextIndex` (for follower)
- **Notes**: Capture matchIndex/nextIndex from FollowerInfo AFTER update.

### Commit Advancement

#### 12. AdvanceCommitIndex
- **Spec action**: `AdvanceCommitIndex(s)`
- **Code location**: `raftlog/RaftLogBase.java:122-142` — `updateCommitIndex()` when isLeader=true
- **Trigger**: After `commitIndex.updateIncreasingly()` succeeds (line 134)
- **Event name**: `"AdvanceCommitIndex"`
- **Fields**: state fields (specifically new `commitIndex`)
- **Notes**: Only emit when commitIndex actually changes (method returns true).

### Configuration Changes

#### 13. ProposeConfigChange
- **Spec action**: `ProposeConfigChange(s, newPeers)`
- **Code location**: `impl/LeaderStateImpl.java:592-601` — `applyOldNewConf()`
- **Trigger**: After joint config entry appended to log (line 598)
- **Event name**: `"ProposeConfigChange"`
- **Fields**: state + `newPeers` (list of new peer IDs), `oldPeers` (list of old peer IDs)
- **Notes**: Called from `startSetConfiguration()` (line 512) or `checkStaging()`.

#### 14. CommitJointConfig
- **Spec action**: `CommitJointConfig(s)`
- **Code location**: `impl/LeaderStateImpl.java:1031-1041` — `replicateNewConf()`
- **Trigger**: After stable config entry appended to log (line 1039)
- **Event name**: `"CommitJointConfig"`
- **Fields**: state + `newPeers` (final stable peers)
- **Notes**: Called from config change processing in `checkCommitEntries()` (line 1004).

### Reads

#### 15. ClientRead
- **Spec action**: `ClientRead(s)`
- **Code location**: `impl/LeaderStateImpl.java:1148-1187` — `getReadIndex()`
- **Trigger**: At entry to `getReadIndex()`
- **Event name**: `"ClientRead"`
- **Fields**: state + `leaseValid` (boolean), `startupEntryCommitted` (boolean)
- **Notes**: Capture whether lease path or heartbeat path was taken.

#### 16. ExtendLease
- **Spec action**: `ExtendLease(s)`
- **Code location**: `impl/LeaderLease.java:68-84` — `extend()`
- **Trigger**: After `lease.set(newLease)` (line 83)
- **Event name**: `"ExtendLease"`
- **Fields**: state only
- **Notes**: Only emit when lease is actually extended (majority check passes).

### Snapshots

#### 17. TakeSnapshot
- **Spec action**: `TakeSnapshot(s)`
- **Code location**: `impl/ServerState.java` — `takeSnapshot()` or `SnapshotManager`
- **Trigger**: After snapshot completes and indices updated
- **Event name**: `"TakeSnapshot"`
- **Fields**: state + `snapshotIndex`, `snapshotTerm`

#### 18. SendInstallSnapshot
- **Spec action**: `SendInstallSnapshot(s, t)`
- **Code location**: `leader/LogAppenderDefault.java:106-133` — `installSnapshot()`
- **Trigger**: Before sending first chunk (line 118)
- **Event name**: `"SendInstallSnapshot"`
- **Fields**: state + `dst` (follower), `snapshotIndex`, `snapshotTerm`

#### 19. HandleInstallSnapshotRequest
- **Spec action**: `HandleInstallSnapshotRequest(s, m)`
- **Code location**: `impl/SnapshotInstallationHandler.java:167-241` — `checkAndInstallSnapshot()`
- **Trigger**: After `reloadStateMachine()` completes (line 228)
- **Event name**: `"HandleInstallSnapshotRequest"`
- **Fields**: state + `src` (leader), `snapshotIndex`, `snapshotTerm`
- **Notes**: Only emit on final chunk (done=true). State after reload.

#### 20. HandleInstallSnapshotResponse
- **Spec action**: `HandleInstallSnapshotResponse(s, m)`
- **Code location**: `leader/LogAppenderDefault.java:106-133` — after `installSnapshot()` returns
- **Trigger**: After `setSnapshotIndex()` on FollowerInfo (line 128)
- **Event name**: `"HandleInstallSnapshotResponse"`
- **Fields**: state + `src` (follower), `matchIndex`, `nextIndex`

### Leadership Management

#### 21. CheckLeadership
- **Spec action**: `CheckLeadership(s)`
- **Code location**: `impl/LeaderStateImpl.java` — `checkLeadership()` when stepping down
- **Trigger**: After step-down triggered (role change to Follower)
- **Event name**: `"CheckLeadership"`
- **Fields**: state fields
- **Notes**: Only emit when leader actually steps down.

#### 22. ExpireLeaderValidity
- **Spec action**: `ExpireLeaderValidity(s)`
- **Code location**: `impl/FollowerState.java:136-142` — `roleChangeChecking()`
- **Trigger**: When `isCurrentLeaderValid()` returns false (line 94-96)
- **Event name**: `"ExpireLeaderValidity"`
- **Fields**: state only
- **Notes**: This is implicit — follower's timer expired. May be hard to instrument directly.

### Crash

#### 23. Crash
- **Spec action**: `Crash(s)`
- **Code location**: Test harness only — not instrumentable in production
- **Trigger**: When test kills/restarts server
- **Event name**: `"Crash"`
- **Fields**: state (post-recovery)
- **Notes**: Emit on recovery startup with post-recovery state. Match with Crash action.

## Section 3: Special Considerations

### Thread Interleaving
- **LogAppender threads**: One per follower, run independently. Events from different LogAppenders may interleave.
- **SegmentedRaftLogWorker**: Async disk I/O thread. FlushLog events may arrive between any other events.
- **StateMachineUpdater**: Applies committed entries. Not traced (outside model scope).
- **gRPC/Netty threads**: RPC handlers. HandleRequestVoteRequest/HandleAppendEntriesRequest run on these.

### Bootstrap State
- Ratis servers start with `currentTerm=0`, `votedFor=null`, empty log.
- `TraceInit` in the spec uses the same initial state.
- If trace begins mid-session (server already has state), the trace should include an initial state snapshot event.

### Serialization
- Server IDs: Use `RaftPeerId.toString()` for node identity.
- Null values: Omit null fields from JSON (e.g., `votedFor` when null).
- Config: Serialize peer sets as JSON arrays of string IDs.

### Pre-vote vs Election Differentiation
- Both use `requestVote()` in code. Differentiate via `request.getPreVote()` boolean.
- Pre-vote handler emits same event name but with `phase: "PRE_VOTE"` field.
- Real election emits with `phase: "ELECTION"`.

### Atomic Persistence
- `(term, votedFor)` persisted atomically via `persistMetadata()` (ServerState.java:248-250).
- Model crash between `changeToFollower()` and `persistMetadata()` if testing Family 2 crash bugs.
- For trace validation, assume persistence is atomic (matches normal operation).

### Configuration Instrumentation
- Config changes involve two log entries: joint (C_old,new) and stable (C_new).
- Both `applyOldNewConf()` and `replicateNewConf()` should emit events.
- Config entries in log have type `CONFIGURATION` — can filter log entries by type.

### FlushIndex Tracking
- `getFlushIndex()` available on `SegmentedRaftLog` (not on `RaftLog` interface).
- May need to cast or access via reflection if interface doesn't expose it.
- Alternative: instrument `SegmentedRaftLogWorker.flushBatchedIO()` directly.
