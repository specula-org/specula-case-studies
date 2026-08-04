# Instrumentation Spec

Target source: `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-system`

Trace consumers: `Trace.tla` and `Trace.cfg`

## 1. Trace Event Schema

Emit one NDJSON object per spec action:

```json
{"tag":"trace","event":{"name":"<spec action>","nid":"s1","state":{}}}
```

Common envelope fields:

| Field | Required | Meaning |
|---|---:|---|
| `tag` | yes | Must be `"trace"`. |
| `event.name` | yes | Exactly one of the spec action names below. |
| `event.nid` | yes | Main server ID, matching `Server` constants such as `"s1"`. |
| `event.leader` | action-specific | Leader/appender server ID when different from `nid`. |
| `event.follower` | action-specific | Follower/progress peer ID for appender and read heartbeat actions. |
| `event.candidate` | action-specific | Candidate ID for vote events. |
| `event.newPeer` | action-specific | New peer ID for configuration change events. |
| `event.value` | action-specific | Abstract value token: `"v1"`, `"v2"`, `"CONFIG_OLD_NEW"`, or `"CONFIG_NEW"`. |
| `event.newTerm`, `event.observedTerm`, `event.commitIndex`, `event.matchIndex`, `event.purgeTo` | action-specific | Numeric action parameters used by `Trace.tla`. |
| `event.state` | yes | Post-action state snapshot. |

Common `event.state` fields. Capture every field that is cheap at the hook point; `Trace.tla` validates any captured field:

| State field | Spec variable | Implementation source |
|---|---|---|
| `role` | `role[nid]` | `RaftServerImpl.getRole()/Info.getCurrentRole()` |
| `currentTerm` | `volatileTerm[nid]` | `ServerState.getCurrentTerm()` |
| `persistedTerm` | `persistedTerm[nid]` | metadata shadow field around `ServerState.persistMetadata()` / `RaftLog.loadMetadata()` |
| `votedFor` | `votedFor[nid]` | `ServerState.getVotedFor()` |
| `leaderId` | `leaderId[nid]` | `ServerState.getLeaderId()` |
| `leaderStateAlive` | `leaderStateAlive[nid]` | `role.getLeaderState().isPresent()` and `LeaderStateImpl.isRunning()` |
| `logStart`, `logEnd`, `flushIndex`, `commitIndex` | log frontier variables | `RaftLog.getStartIndex()`, `getNextIndex()-1`, `getFlushIndex()`, `getLastCommittedIndex()` |
| `appliedIndex` | `appliedIndex[nid]` | `StateMachine.getLastAppliedTermIndex().getIndex()` |
| `repliedIndex` | `repliedIndex[nid]` | `ReplyFlusher.getRepliedIndex()` |
| `snapshotIndex`, `installedSnapshotIndex`, `installingSnapshot` | snapshot frontier variables | `RaftLog.getSnapshotIndex()`, `SnapshotInstallationHandler` fields |
| `configLogIndex`, `configStored`, `peerRole`, `caughtUp` | configuration variables | `RaftConfigurationImpl.getLogEntryIndex()`, local conf store, `RaftPeerRole`, `FollowerInfoImpl.isCaughtUp()` |
| `nextIndex`, `matchIndex` | `nextIndex[nid]`, `matchIndex[nid]` for follower-local events | `FollowerInfoImpl.getNextIndex()/getMatchIndex()` when `nid` is the progress peer |
| `followerNextIndex`, `followerMatchIndex`, `followerConfigStored`, `followerCaughtUp` | progress/config variables for `event.follower` | leader-side `FollowerInfoImpl` plus follower config shadow |
| `pendingReadIndex`, `readCompletedIndex` | read variables | `LeaderStateImpl.getReadIndex` listener state and read completion hook |
| `acceptedLeaderTerm` | `acceptedLeaderTerm[nid]` | shadow max accepted AppendEntries leader term |
| `entryIndex`, `entryTerm`, `entryValue` | log content validation | append/config/snapshot action's affected entry |
| `lastReplyResult` | `lastReplyStatus[nid]` | `AppendEntriesReplyProto.getResult()` |

Use `""`, `"null"`, or `"none"` for absent `leaderId`/`votedFor`; `Trace.tla` maps them to `NoLeader`/`NoVote`.

## 2. Action-to-Code Mapping

| Spec action / event name | Code location | Trigger point | Fields |
|---|---|---|---|
| `ServerState_initElection_ELECTION` | `ServerState.java:228-237` | After `persistMetadata()` in the `Phase.ELECTION` branch. | Common state; include `currentTerm`, `votedFor`, `persistedTerm`, `role`, `leaderId`. |
| `RaftServerImpl_requestVote_Grant` | `RaftServerImpl.java:1496-1542` | After reply construction when `voteGranted=true`. | `candidate`; common state; include `votedFor`, `persistedTerm`, `entryIndex` if last-entry state is captured. |
| `RaftServerImpl_changeToLeader` | `RaftServerImpl.java:650-658` | After `leader.start()`. | Common state; include `role`, `leaderId`, `leaderStateAlive`. |
| `RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure` | `RaftServerImpl.java:638-647`, `RaftServerImpl.java:1662-1665` | In the `catch (IOException e)` path after volatile term/role changed and before returning exceptional future. | `leader`, `newTerm`; common state; include persisted metadata shadow. |
| `ServerState_persistMetadata` | `ServerState.java:243-245` | Immediately after successful `getLog().persistMetadata(...)`. | Common state; include `persistedTerm`, `votedFor`. |
| `LeaderStateImpl_submitStepDownEvent` | `LeaderStateImpl.java:738-740`, `LeaderStateImpl.java:156-158` | After `eventQueue.submit(...)` returns. | `observedTerm`; common state; include queued-step-down shadow fields. |
| `LeaderStateImpl_stepDown` | `LeaderStateImpl.java:742-758` | After `changeToFollowerAndPersistMetadata(...).get(...)` returns. | Common state; include `role`, `currentTerm`, `persistedTerm`, `leaderStateAlive`. |
| `RaftServerImpl_appendTransaction` | `RaftServerImpl.java:869-924` | After `state.appendLog(context)` and pending request insertion succeeds. | `value`; common state; include `entryIndex`, `entryTerm`, `entryValue`, `logEnd`, `flushIndex`. |
| `GrpcLogAppender_appendLog` | `GrpcLogAppender.java:392-418` | After `pendingRequests.put(request)` and `increaseNextIndex(pending)`, before `sendRequest`. | `follower`; leader common state; `followerNextIndex`, `followerMatchIndex`; pending request callId/first index if available. |
| `RaftServerImpl_appendEntriesAsync_RegisterInFlight` | `RaftServerImpl.java:1652-1696`, `ServerImplUtils.java:145-150` | After `appendLogTermIndices.append(...)` registers a new future, before physical append future completes. | Common state; include request `leader`, `entryIndex`, `entryTerm`, `entryValue`, `acceptedLeaderTerm`. |
| `ServerImplUtils_NavigableIndices_append_ComposeExisting` | `ServerImplUtils.java:153-164` | At `alreadyExists(...) == true`, after reverting new map entries. | Common state; include request `leader`, `entryIndex`, `entryTerm`, `entryValue`. |
| `RaftServerImpl_appendEntriesAsync_InconsistencyReply` | `RaftServerImpl.java:1681-1688`, `RaftServerImpl.java:1739-1771` | Immediately before returning the INCONSISTENCY reply. | Common state; `lastReplyResult="INCONSISTENCY"`. |
| `SegmentedRaftLog_appendImpl_CompletePhysicalAppend` | `SegmentedRaftLog.java:464-486` | After futures for truncate/append have completed successfully. | Common state; include `entryIndex`, `entryTerm`, `entryValue`, `logEnd`, `flushIndex`, `configStored` for config entries. |
| `RaftServerImpl_appendEntriesAsync_ReplyOriginal` | `RaftServerImpl.java:1709-1730` | After SUCCESS reply is constructed for the original request. | Common state; `lastReplyResult="SUCCESS"`, reply match/next if captured. |
| `RaftServerImpl_appendEntriesAsync_ReplyComposed` | `RaftServerImpl.java:1694-1696`, `RaftServerImpl.java:1725-1727`, `ServerImplUtils.java:148` | After SUCCESS reply is constructed for a composed request that reused an older future. | Common state; include composed request entry fields and reply result. |
| `ServerImplUtils_NavigableIndices_removeExisting` | `ServerImplUtils.java:169-173` | After `removeExisting(...)` removes the in-flight range. | Common state; in-flight shadow fields may be omitted. |
| `GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS` | `GrpcLogAppender.java:487-539`, `FollowerInfoImpl.java:93-119` | After SUCCESS branch updates match/next and calls `onFollowerSuccessAppendEntries`. | `follower`; leader state; `followerNextIndex`, `followerMatchIndex`, `lastReplyResult`. |
| `GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream` | `GrpcLogAppender.java:487-539`, `GrpcLogAppender.java:556-557` | Same hook as SUCCESS, but when `pendingRequests.remove(reply)` returns null or stream/callId shadow says stale. | `follower`, `matchIndex`; progress fields. |
| `GrpcLogAppender_timeoutAppendRequest` | `GrpcLogAppender.java:448-456` | After pending request removal and timer stop. | Common state; include `lastReplyResult`, pending shadow if available. |
| `GrpcLogAppender_resetClient` | `GrpcLogAppender.java:206-232`, `LogAppenderBase.java:193-208` | After `pendingRequests.clear()` and next-index computation. | Common state; include `nextIndex`, `matchIndex`, stream epoch shadow. |
| `LeaderStateImpl_updateCommit` | `LeaderStateImpl.java:946-1025`, `RaftLogBase.java:122-134` | After `server.getState().updateCommitIndex(...)` returns true and `updateCommit(entriesToCommit)` completes. | `commitIndex`; common state; include committed entry fields. |
| `StateMachineUpdater_applyEntry` | `ServerState.java:413-418`, `ReadRequests.java:104-120` | After the updater applies an entry and invokes `ReadRequests` applied-index consumer. | Common state; include `appliedIndex`. |
| `ReplyFlusher_flush` | `ReplyFlusher.java:127-148` | After `repliedIndex.updateToMax(...)` and held replies complete. | Common state; include `repliedIndex`. |
| `LeaderStateImpl_getReadIndex` | `LeaderStateImpl.java:1173-1217` | After immediate completion or after listener creation and heartbeat trigger. | Common state; include `pendingReadIndex`, heartbeat-check/lease shadow if available. |
| `ReadIndexHeartbeats_HeartbeatAck` | `ReadIndexHeartbeats.java:49-82`, `ReadIndexHeartbeats.java:139-157` | After `HeartbeatAck.receive(...)` acknowledges and possibly completes listener. | `follower`; common state; include acked read index if shadowed. |
| `ReadRequests_waitToAdvance_CompleteRead` | `RaftServerImpl.java:1147-1152`, `ReadRequests.java:58-84` | After `waitToAdvance` future completes and before/after state-machine query reply construction. | Common state; include `readCompletedIndex`, `pendingReadIndex`. |
| `GrpcLogAppender_installSnapshot_Notify` | `GrpcLogAppender.java:241-253`, `LogAppenderBase.java:225-233` | After notification request is sent or queued to the follower. | `follower`; progress/snapshot fields. |
| `SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0` | `SnapshotInstallationHandler.java:193-209` | After requestIndex 0 sets `nextChunkIndex` and `chunk0CallId`. | Common state; include snapshot chunk shadow fields. |
| `SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize` | `SnapshotInstallationHandler.java:229-240`, `ServerState.java:425-430` | After final chunk publishes snapshot and `state.reloadStateMachine(...)` returns. | Common state; include `snapshotIndex`, `installedSnapshotIndex`, `logStart`, `commitIndex`, `configStored`. |
| `SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload` | `SnapshotInstallationHandler.java:322-386`, `ServerState.java:425-430` | After async notification reports installed snapshot and reload completes. | Common state; same frontier fields as finalize. |
| `ConfigurationManager_removeConfigurations_PurgeLog` | `ConfigurationManager.java:96-103`, `ServerState.java:393-395` | After truncation/purge removes configuration entries. | `purgeTo`; common state; include `logStart`, `snapshotIndex`, `configStored`. |
| `RaftLogBase_open_Restart` | `ServerState.java:129-142`, `RaftLogBase.java:263-273` | After restart initialization loads metadata and opens raft log. | Common state; include `currentTerm`, `persistedTerm`, `votedFor`, `role`, `commitIndex`. |
| `RaftServerImpl_setConfigurationAsync_Start` | `RaftServerImpl.java:1388-1456` | After `leaderState.startSetConfiguration(...)` returns pending request. | `newPeer`; common state; include staging shadow fields. |
| `LeaderStateImpl_checkProgress_CaughtUp` | `LeaderStateImpl.java:828-887` | After `FollowerInfoImpl.catchUp()` is called in successful staging. | `follower`; leader common state; `followerCaughtUp`, `followerConfigStored`, `followerMatchIndex`. |
| `LeaderStateImpl_applyOldNewConf` | `LeaderStateImpl.java:624-639`, `LeaderStateImpl.java:1303-1308` | After transitional old/new config is appended and set in `ServerState`. | Common state; include `configLogIndex`, `entryIndex`, `entryValue="CONFIG_OLD_NEW"`. |
| `LeaderStateImpl_replicateNewConf` | `LeaderStateImpl.java:1034-1044`, `LeaderStateImpl.java:1064-1073` | After stable new config is appended and senders updated. | Common state; include `configLogIndex`, `entryIndex`, `entryValue="CONFIG_NEW"`. |
| `ServerState_updateConfiguration_PromoteListener` | `ServerState.java:397-410`, `RaftConfigurationImpl.java:152-159`, `PeerConfiguration.java:122-128` | After a listener server joins voting conf and `changeToFollowerAndPersistMetadata(..., "setRaftConf")` completes. | Common state; include `peerRole`, `role`, `configStored`. |

## 3. Special Considerations

- Persisted metadata is not directly exposed by public getters. Add a small tracing shadow around `ServerState.persistMetadata()` and `RaftLog.loadMetadata()` so `persistedTerm` and `persistedVote` can be emitted without scraping files.
- `appendLogTermIndices` composition state is implementation-private. Trace hooks around `ServerImplUtils.NavigableIndices.append`, `alreadyExists`, and `removeExisting` should emit a compact shadow: start index, term, value token, original/composed leader, and whether the physical append future completed.
- Ratis uses futures and multiple threads. Emit events at the exact post-state points listed above; do not collapse register, physical append, and reply into one event.
- For `ReadIndexHeartbeats`, capture the listener's `minCallId` and the reply callId if possible. `Trace.tla` requires the reply callId to be at least the pending request callId when validating a heartbeat ack.
- For snapshot notification/reload, keep `firstAvailableLogIndex`, `snapshotIndex`, `logStart`, and config shadow fields in the same event. Most trace mismatches on this path come from capturing before `ServerState.reloadStateMachine(...)` updates the log frontier.
- For old gRPC replies, emit `GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream` only when the local tracing shadow says the reply did not match a live pending request or stream epoch. Normal matching replies use `GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS`.
- Keep trace IDs as the same strings used in `Trace.cfg`: `"s1"`, `"s2"`, `"s3"` for model runs. A harness can map real `RaftPeerId` values to those model IDs at trace-start bootstrap.
