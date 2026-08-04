# Instrumentation Spec: Apache Ratis `ratis-server`

This document maps `base.tla` actions to source instrumentation points for trace generation. Trace events are NDJSON records under `../traces/trace.ndjson` by default and are consumed by `Trace.tla`.

## 1. Trace Event Schema

Each emitted line should use this envelope:

```json
{
  "tag": "trace",
  "event": {
    "name": "RaftLogBase.appendEntry.cacheAndQueue",
    "nid": "s1",
    "index": 3,
    "kind": "valid",
    "result": "SUCCESS",
    "msg": {
      "source": "s2",
      "peer": "s3",
      "index": 3
    },
    "state": {
      "term": 2,
      "role": "Leader",
      "votedFor": "s1",
      "leaderId": "s1",
      "commitIndex": 2,
      "metadataCommitIndex": 2,
      "flushIndex": 2,
      "lastWrittenIndex": 3,
      "durableLog": [0, 1, 2],
      "snapshotIndex": -1,
      "snapshotInProgressIndex": -1,
      "currentConf": ["s1", "s2"],
      "durableConf": ["s1", "s2"],
      "leaseEnabled": false,
      "leaseFresh": false,
      "readResult": "none"
    }
  }
}
```

Common state fields captured after every event:

| Trace field | Implementation source | TLA+ variable |
|---|---|---|
| `term` | `ServerState.getCurrentTerm()` | `currentTerm[nid]` |
| `role` | `RoleInfo.getCurrentRole()` / `DivisionInfo.getCurrentRole()` | `role[nid]` |
| `votedFor` | `ServerState.getVotedFor()` or tracing shadow | `votedFor[nid]` |
| `leaderId` | `ServerState.getLeaderId()` | `leaderId[nid]` |
| `commitIndex` | `RaftLog.getLastCommittedIndex()` | `commitIndex[nid]` |
| `metadataCommitIndex` | latest metadata entry commit index, or tracing shadow | `metadataCommitIndex[nid]` |
| `flushIndex` | `RaftLog.getFlushIndex()` | `flushIndex[nid]` |
| `lastWrittenIndex` | `SegmentedRaftLogWorker.lastWrittenIndex`, via tracing accessor/shadow | `lastWrittenIndex[nid]` |
| `durableLog` | flushed/recoverable log indices, via worker/storage tracing accessor | `diskLog[nid]` |
| `snapshotIndex` | `RaftLog.getSnapshotIndex()` / latest installed snapshot | `snapshotIndex[nid]` |
| `snapshotInProgressIndex` | `SnapshotInstallationHandler.getInProgressInstallSnapshotIndex()` | `snapshotInProgressIndex[nid]` |
| `currentConf` | `ServerState.getRaftConf().getCurrentPeers()` | `currentConf[nid]` |
| `durableConf` | storage `.conf` or tracing shadow updated after durable config write | `durableConf[nid]` |
| `leaseEnabled` | `LeaderLease.isEnabled()` or tracing shadow | `leaseEnabled[nid]` |
| `leaseFresh` | `LeaderStateImpl.hasLease()` result or tracing shadow | `leaseFresh[nid]` |
| `readResult` | tracing shadow for ReadIndex success/pending/failure | `readResult[nid]` |

Event-specific message fields:

| Field | Meaning |
|---|---|
| `msg.source` | RPC/request sender, candidate, leader, or follower peer depending on event |
| `msg.peer` | secondary peer argument for follower/appender/config actions |
| `msg.index` | log, snapshot, commit, readIndex, or config index used by the action |
| `result` | AppendEntries/lease reply result: `SUCCESS`, `NOT_LEADER`, `HIGHER_TERM`, or `INCONSISTENCY` |
| `kind` | vote-reply lastEntry kind: `valid`, `empty`, or `missing` |

## 2. Action-to-Code Mapping

| Spec action | Trace event name | Code location | Trigger point | Required event fields | Notes |
|---|---|---|---|---|---|
| `ServerState_initElection_ELECTION` | `ServerState.initElection.ELECTION` | `ServerState.java:228-240` | After `persistMetadata()` in the `Phase.ELECTION` branch | common state | Captures term increment and self vote. |
| `LeaderElection_submitRequestVote` | `LeaderElection.submitRequestVote` | `LeaderElection.java:485-493` | After constructing/submitting each `RequestVoteRequestProto` | `msg.source`, `msg.peer` | `Trace.tla` can silently synthesize this only when the next requestVote handler event requires it, but direct instrumentation is preferred. |
| `ServerProtoUtils_setVoteReplyLastEntryKind` | `ServerProtoUtils.setVoteReplyLastEntryKind` | `LeaderElection.java:601-619`, `RaftServerImpl.java:1532-1533` | When constructing a vote reply's `lastEntry` evidence | `kind`, common state | Use `missing` for default `(0,0)`, `empty` for explicit empty log, `valid` otherwise. |
| `RaftServerImpl_requestVote_Grant` | `RaftServerImpl.requestVote.grant` | `RaftServerImpl.java:1496-1542`, `VoteContext.java:54-163`, `ServerState.java:254-257` | After reply is built and after `future.join()` | `msg.source`, common state | `msg.source` is candidate id. |
| `RaftServerImpl_requestVote_Reject` | `RaftServerImpl.requestVote.reject` | `RaftServerImpl.java:1496-1542`, `VoteContext.java:54-163` | After reject reply is built | `msg.source`, common state | Emits even when rejection is due to conf, term, listener, or log comparison. |
| `LeaderElection_waitForResults` | `LeaderElection.waitForResults.pass` | `LeaderElection.java:506-599` | Immediately before returning `PASSED`/`SINGLE_MODE_PASSED` | common state | Captures accepted vote set through state shadow if available. |
| `RaftLogBase_appendEntry_CacheAndQueue` | `RaftLogBase.appendEntry.cacheAndQueue` | `RaftLogBase.java:169-213`, `SegmentedRaftLog.java:430-444` | After cache append and worker enqueue | `index`, common state | One event per log index. |
| `SegmentedRaftLogWorker_WriteLog_execute` | `SegmentedRaftLogWorker.WriteLog.execute` | `SegmentedRaftLogWorker.java:549-562` | After `lastWrittenIndex` is advanced and `flushIfNecessary()` returns | `index`, common state | Captures write-visible but not necessarily durable boundary. |
| `SegmentedRaftLogWorker_flushIfNecessary_Start` | `SegmentedRaftLogWorker.flushIfNecessary.start` | `SegmentedRaftLogWorker.java:368-392` | Immediately after flush future is created and before async/sync completion handling | common state | Snapshot `flushInFlightCovered` from current `lastWrittenIndex`. |
| `SegmentedRaftLogWorker_asyncFlushOutStream_Fail` | `SegmentedRaftLogWorker.asyncFlushOutStream.fail` | `SegmentedRaftLogWorker.java:402-409` | In async callback when exception is non-null | common state | Scenario 1 hunt event. |
| `SegmentedRaftLogWorker_asyncFlushOutStream_Complete` | `SegmentedRaftLogWorker.asyncFlushOutStream.complete` | `SegmentedRaftLogWorker.java:402-409`, `SegmentedRaftLogWorker.java:422-430` | After successful force and state-machine-data flush completion | common state | Normal trace path should use the captured force-start index. |
| `SegmentedRaftLogWorker_asyncFlushOutStream_CompleteLateOrFailed` | `SegmentedRaftLogWorker.asyncFlushOutStream.completeLateOrFailed` | `SegmentedRaftLogWorker.java:402-409` | If instrumenting the suspected faulty behavior for hunt traces | common state | Not expected in normal validation traces. |
| `LeaderStateImpl_updateCommit` | `LeaderStateImpl.updateCommit` | `LeaderStateImpl.java:946-949`, `LeaderStateImpl.java:1015-1023`, `RaftLogBase.java:122-135` | After `ServerState.updateCommitIndex` returns true | `index`, common state | `index` is the new committed index. |
| `RaftLogBase_appendMetadata` | `RaftLogBase.appendMetadata` | `RaftLogBase.java:217-235`, `LeaderStateImpl.java:1028-1031` | After `lastMetadataEntry.set(entry)` | common state | Capture `metadataCommitIndex` from entry metadata. |
| `CrashAndRecover` | `CrashAndRecover` | `ServerState.java:129-142`, `RaftStorageImpl.java:105-123`, `ServerState.java:425-429` | After restart/recovery reconstructed term/vote/log/conf/snapshot | common state | Harness may be a test wrapper rather than production code patch. |
| `RaftStorageImpl_formatEmptyStorage` | `RaftStorageImpl.formatEmptyStorage` | `RaftStorageImpl.java:95-123` | After `format()` returns | common state | Scenario 2 only; use in controlled recovery tests. |
| `LeaderStateImpl_sendAppendEntries` | `LeaderStateImpl.sendAppendEntries` | `LogAppenderBase.java:83-103`, `LogAppenderDefault.java:80-105`, `LeaderStateImpl.java:650-657` | Immediately after `appendEntries(proto)` returns or before handler event if tracing both sides | `msg.source`, `msg.peer`, `msg.index`, common state | Direct event is preferred; `Trace.tla` can synthesize only for handler-oriented traces. |
| `RaftServerImpl_appendEntriesAsync_RejectSnapshot` | `RaftServerImpl.appendEntries.rejectSnapshot` | `RaftServerImpl.java:1639-1731`, `RaftServerImpl.java:1739-1745` | When inconsistency reply is built because snapshot is in progress | `msg.source`, `msg.index`, common state | Captures the exclusion path. |
| `RaftServerImpl_appendEntriesAsync_Success` | `RaftServerImpl.appendEntries.success` | `RaftServerImpl.java:1639-1731`, `ServerState.java:397-410` | After append future success and commit update/reply construction | `msg.source`, `msg.index`, common state | For heartbeat use `msg.index = -1`. |
| `RaftServerImpl_appendEntriesAsync_AcceptDuringSnapshotFault` | `RaftServerImpl.appendEntries.acceptDuringSnapshotFault` | `RaftServerImpl.java:1739-1745` | Only in fault-instrumented hunt harness | `msg.source`, `msg.index`, common state | Should not appear in ordinary traces. |
| `SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot` | `SnapshotInstallationHandler.notifyStateMachineToInstallSnapshot` | `SnapshotInstallationHandler.java:253-396` | After `inProgressInstallSnapshotIndex` is set and reads are failed | `msg.source`, `index`, common state | `index` is `firstAvailableLogIndex`. |
| `SnapshotInstallationHandler_checkAndInstallSnapshot_AppendChunk` | `SnapshotInstallationHandler.checkAndInstallSnapshot.appendChunk` | `SnapshotInstallationHandler.java:174-250` | After `snapshotManager.appendSnapshot` and chunk index increment | `index`, common state | `index` is `lastIncludedIndex` for the chunk. |
| `SnapshotInstallationHandler_checkAndInstallSnapshot_FinalChunkPublish` | `SnapshotInstallationHandler.checkAndInstallSnapshot.finalChunkPublish` | `SnapshotInstallationHandler.java:229-250`, `ServerState.java:425-429`, `SegmentedRaftLogWorker.java:261-267` | After `state.reloadStateMachine(lastIncluded)` | common state | Captures log purge/worker queue clear. |
| `SnapshotInstallationHandler_notifyStateMachine_Complete` | `SnapshotInstallationHandler.notifyStateMachine.complete` | `SnapshotInstallationHandler.java:331-386` | After async notification reply causes reload and clears in-progress index | common state | Captures notification-mode completion. |
| `RaftServerImpl_sendReadIndexAsync` | `RaftServerImpl.sendReadIndexAsync` | `RaftServerImpl.java:1099-1118` | After deciding pending vs failed ReadIndex forwarding | `index`, common state | `index` is requested read index/min index. |
| `LeaderStateImpl_getReadIndex_LeaseFastPath` | `LeaderStateImpl.getReadIndex.leaseFastPath` | `LeaderStateImpl.java:1181-1218`, `LeaderStateImpl.java:1229-1249` | Just before returning completed readIndex due to disabled heartbeat check or valid lease | `index`, common state | Scenario 4. |
| `LeaderLease_enableForTarget` | `LeaderLease.enableForTarget` | `LeaderLease.java:42-49`, `LeaderStateImpl.java:1202-1205` | Controlled test/harness event when leader lease is enabled | common state | Do not emit in default configs when lease disabled. |
| `LogAppenderDefault_receiveAppendEntriesReply_Timestamp` | `LogAppenderDefault.receiveAppendEntriesReply.timestamp` | `LogAppenderDefault.java:94-105` | After `updateLastRespondedAppendEntriesSendTime(sendTime)` and before `handleReply` | `msg.peer`, `result`, common state | `result` must be the reply result that will be processed later. |
| `LeaderLease_extend` | `LeaderLease.extend` | `LeaderLease.java:68-83`, `LeaderStateImpl.java:1238-1243` | After lease timestamp is set | common state | Capture `leaseFresh`. |
| `LogAppenderDefault_handleReply_NotLeaderOrHigherTerm` | `LogAppenderDefault.handleReply.notLeaderOrHigherTerm` | `LogAppenderDefault.java:192-225`, `LeaderStateImpl.java:460-478` | After step-down cleanup for `NOT_LEADER` or higher term | common state | Capture listener failure and lease disable. |
| `LeaderStateImpl_stop` | `LeaderStateImpl.stop` | `LeaderStateImpl.java:460-478` | After pending reads/listeners failed and lease disabled | common state | Can be emitted for leadership transfer or shutdown. |
| `LeaderStateImpl_startSetConfiguration` | `LeaderStateImpl.startSetConfiguration` | `LeaderStateImpl.java:518-553` | After staging state is installed and new senders started | `msg.peer`, common state | `msg.peer` is the staged peer used by the abstract spec. |
| `LeaderStateImpl_markAttemptedSnapshot` | `LeaderStateImpl.markAttemptedSnapshot` | `LogAppenderDefault.java:160-175` | After snapshot attempt flag is set | `msg.peer`, common state | Used by catch-up gate. |
| `LeaderStateImpl_checkProgress_CaughtUp` | `LeaderStateImpl.checkProgress.caughtUp` | `LeaderStateImpl.java:828-840`, `LeaderStateImpl.java:863-887` | When `BootStrapProgress.CAUGHTUP` is observed/applied | `msg.peer`, common state | Requires match index, conf index, recent response, attempted snapshot. |
| `LeaderStateImpl_applyOldNewConf` | `LeaderStateImpl.applyOldNewConf` | `LeaderStateImpl.java:624-640` | After `server.getState().setRaftConf(conf)` | common state | Captures in-memory config before durable append completes. |
| `LeaderStateImpl_configAck` | `LeaderStateImpl.configAck` | `LeaderStateImpl.java:946-983`, `RaftConfigurationImpl.java:264-282` | When follower match index acknowledges the config entry | `msg.peer`, common state | Use alongside normal AppendEntries reply instrumentation. |
| `LeaderStateImpl_commitOldNewConf` | `LeaderStateImpl.commitOldNewConf` | `LeaderStateImpl.java:1034-1074`, `RaftConfigurationImpl.java:264-282` | After old/new config entry commits with joint majority | common state | Captures durable config transition. |
| `ServerState_updateConfiguration_BeforeAppendDurable` | `ServerState.updateConfiguration.beforeAppendDurable` | `RaftServerImpl.java:1691-1696`, `ServerState.java:397-410` | Immediately after `state.updateConfiguration(entries)` and before append futures join | `msg.peer`, common state | Scenario 5 follower-side early visibility. |
| `LeaderStateImpl_commitConfigWithoutOldMajorityFault` | `LeaderStateImpl.commitConfigWithoutOldMajorityFault` | `LeaderStateImpl.java:946-983`, `RaftConfigurationImpl.java:264-282` | Only in fault-instrumented hunt harness | common state | Should not appear in normal validation traces. |
| `LoseMessage` | `LoseMessage` | harness/network shim | When a queued abstract RPC is intentionally dropped | common state optional | MC-only fault; ordinary implementation traces usually omit it. |

## 3. Special Considerations

- Add tracing accessors or shadows for private fields that are otherwise hard to read: `SegmentedRaftLogWorker.lastWrittenIndex`, durable/flushed log indices, latest metadata commit index, durable `.conf`, and lease freshness.
- Emit post-state snapshots after the modeled state transition. For async callbacks, the event must be inside the callback after the state write being modeled.
- For `RequestVote` and `AppendEntries`, instrument both send and receive paths when possible. `Trace.tla` has tightly constrained silent send actions only to support traces that record handler-side events first.
- Do not emit fault event names in ordinary trace validation runs. The `*.completeLateOrFailed`, `*.acceptDuringSnapshotFault`, and `*.commitConfigWithoutOldMajorityFault` events are for hunt harnesses.
- Keep `nid` as the server whose local state is validated. Use `msg.source` for remote sender/candidate/leader and `msg.peer` for follower/config peer arguments.
- Use the same peer string values as the TLA+ constants in cfg (`s1`, `s2`, `s3` in the starter configs), or override cfg constants for larger traces.
