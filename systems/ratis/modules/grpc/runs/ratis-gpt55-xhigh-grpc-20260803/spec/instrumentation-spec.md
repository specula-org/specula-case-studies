# Instrumentation Spec: ratis-grpc Replication

## 1. Trace Event Schema

Emit newline-delimited JSON.  Each event must include:

- `tag`: `"ratis-grpc"`
- `event`: spec action name, for example `"SendAppendData"`
- `node`: leader id for leader-wide events, normally `"L"` in small models
- `follower`: follower id for per-follower actions, for example `"F1"`
- `state`: post-action snapshot when available

Common `state` fields consumed by `Trace.tla`:

- `matchIndex`, `nextIndex`, `snapshotIndex`
- `attemptedSnapshot`, `caughtUp`, `recentResponse`
- `streamEpoch`, `streamActive`, `pendingCount`
- `snapshotState`, `outstandingChunks`
- `streamReady`, `cancelled`
- `commitIndex`, `leaderStartIndex`, `leaderLastIndex`, `replyQueueCount`

Reply events should also include:

- `result`: `"SUCCESS"`, `"INCONSISTENCY"`, or `"NOT_LEADER"`
- `isHeartbeat`: boolean
- `callId`, `replyNextIndex`, `matchIndex`
- request boundary fields when available: `prevIndex`, `firstIndex`, `lastIndex`, `streamEpoch`

Snapshot events should also include:

- `snapshotIndex`
- `result` for unavailable/expired replies: `"SNAPSHOT_UNAVAILABLE"` or `"SNAPSHOT_EXPIRED"`

## 2. Action-to-Code Mapping

| Spec action | Code location | Trigger point | Trace event | Fields |
| --- | --- | --- | --- | --- |
| `SendAppendData` | `ratis-grpc/.../GrpcLogAppender.java:392-417`, `:459-463` | After `pendingRequests.put(request)` and `increaseNextIndex(pending)` for non-heartbeat request | `SendAppendData` | follower, callId, streamEpoch, prevIndex, firstIndex, lastIndex, state |
| `AppendAfterSnapshot` | `GrpcLogAppender.java:260-266`, `:392-417` | Same as `SendAppendData`, but only when `snapshotIndex > 0` and send starts at or above `snapshotIndex + 1` | `AppendAfterSnapshot` | follower, callId, firstIndex, lastIndex, state |
| `SendHeartbeat` | `LogAppenderBase.java:213-220`, `GrpcLogAppender.java:392-408`, `RequestMap:898-925` | After heartbeat request is put in `pendingRequests` | `SendHeartbeat` | follower, callId, streamEpoch, isHeartbeat=true, state |
| `TimeoutAppend` | `GrpcLogAppender.java:448-456` | After `pendingRequests.remove(cid, heartbeat)` succeeds | `TimeoutAppend` | follower, callId, isHeartbeat, state |
| `StreamErrorReset` | `GrpcLogAppender.java:206-231`, `:547-557` | After `resetClient(request, Event.ERROR)` completes | `StreamErrorReset` | follower, callId if known, isHeartbeat, streamEpoch, pendingCount, nextIndex, state |
| `StreamCompleteReset` | `GrpcLogAppender.java:206-231`, `:561-564` | After `resetClient(null, Event.COMPLETE)` completes | `StreamCompleteReset` | follower, streamEpoch, pendingCount, nextIndex, state |
| `Reconnect` | `GrpcLogAppender.java:405-408` | Immediately after a new `StreamObservers` is assigned | `Reconnect` | follower, streamEpoch, streamActive, state |
| `FollowerAppendSuccess` | `GrpcServerProtocolService.java:241-269`, `RaftServerImpl.java:1691-1730` | When follower constructs a SUCCESS reply | `FollowerAppendSuccess` | follower, callId, isHeartbeat, matchIndex, replyNextIndex, state |
| `FollowerAppendInconsistency` | `RaftServerImpl.java:1674-1688`, `:1739-1769` | When follower constructs an INCONSISTENCY reply | `FollowerAppendInconsistency` | follower, callId, isHeartbeat, replyNextIndex, state |
| `ReceiveSuccessWithRequest` | `GrpcLogAppender.java:487-519` | After SUCCESS branch when `pendingRequests.remove(reply)` returned a request | `ReceiveSuccessWithRequest` | follower, callId, isHeartbeat, matchIndex, state |
| `ReceiveSuccessWithoutRequest` | `GrpcLogAppender.java:487-519` | After SUCCESS branch when request lookup returned null | `ReceiveSuccessWithoutRequest` | follower, callId, isHeartbeat, matchIndex, state |
| `ReceiveInconsistencyWithRequest` | `GrpcLogAppender.java:528-535`, `:572-575`, `LogAppenderBase.java:177-190` | After INCONSISTENCY branch when request lookup returned a request | `ReceiveInconsistencyWithRequest` | follower, callId, firstIndex, replyNextIndex, state |
| `ReceiveInconsistencyWithoutRequest` | `GrpcLogAppender.java:487-535`, `:572-575`, `LogAppenderBase.java:177-190` | After INCONSISTENCY branch when request lookup returned null | `ReceiveInconsistencyWithoutRequest` | follower, callId, replyNextIndex, state |
| `CompactLeaderLog` | `LogAppender.java:205-219` plus Raft log compaction boundary | After leader start index advances enough that a follower previous entry may be unavailable | `CompactLeaderLog` | node, leaderStartIndex, leaderLastIndex |
| `TriggerSnapshot` | `GrpcLogAppender.java:261-269`, `LogAppender.java:193-203` | Immediately after `shouldInstallSnapshot` returns a concrete snapshot/notification request to send; a no-snapshot bootstrapping attempt may set `attemptedSnapshot` silently | `TriggerSnapshot` | follower, nextIndex, snapshotIndex, state |
| `SendSnapshotChunk` | `GrpcLogAppender.java:764-799`, `:594-610` | After `snapshotRequestObserver.onNext(request)` and `responseHandler.addPending(request)` | `SendSnapshotChunk` | follower, snapshotIndex, requestIndex, outstandingChunks, state |
| `FollowerSnapshotInProgress` | `RaftServerImpl.java:1739-1745` | When AppendEntries is rejected because snapshot installation is in progress | `FollowerSnapshotInProgress` | follower, callId, replyNextIndex, state |
| `SnapshotInstalled` | `GrpcLogAppender.java:704-712`, `FollowerInfoImpl.java:147-150` | After `SNAPSHOT_INSTALLED` branch updates follower progress | `SnapshotInstalled` | follower, snapshotIndex, matchIndex, nextIndex, state |
| `SnapshotAlreadyInstalled` | `GrpcLogAppender.java:687-694`, `FollowerInfoImpl.java:147-150` | After `ALREADY_INSTALLED` branch updates follower progress | `SnapshotAlreadyInstalled` | follower, snapshotIndex, matchIndex, nextIndex, state |
| `SnapshotUnavailableOrExpired` | `GrpcLogAppender.java:714-729` | After unavailable or expired snapshot reply branch | `SnapshotUnavailableOrExpired` | follower, result, attemptedSnapshot, retryRequired, state |
| `OldAppendReplyAfterSnapshot` | `GrpcLogAppender.java:487-535`, `:687-712` | Use instead of generic receive event when reply epoch or request range predates acknowledged snapshot progress | `OldAppendReplyAfterSnapshot` | follower, result, callId, firstIndex, lastIndex, snapshotIndex, state |
| `AddStagingPeer` | `LeaderStateImpl.java:518-550`, `:667-685` | After `FollowerInfoImpl` for the new peer is inserted and appender is created | `AddStagingPeer` | follower, caughtUp, nextIndex, matchIndex, state |
| `RestartAppender` | `LeaderStateImpl.java:715-728`, `:676-688` | After old sender is removed and a replacement sender is added for a peer found in the current configuration; staging-only restart removes the sender but emits no replacement `RestartAppender` | `RestartAppender` | follower, caughtUp, nextIndex, matchIndex, attemptedSnapshot, state |
| `AppendSuccessForStagingPeer` | `GrpcLogAppender.java:516-519`, `LeaderStateImpl.java:846-852` | SUCCESS branch for a follower where `!isCaughtUp(follower)` | `AppendSuccessForStagingPeer` | follower, callId, matchIndex, state |
| `SnapshotAttemptForStagingPeer` | `LogAppender.java:193-203`, `GrpcLogAppender.java:261-269` | Bootstrapping follower enters the snapshot-attempt path; emit the explicit event when a snapshot/notification is actually sent | `SnapshotAttemptForStagingPeer` | follower, attemptedSnapshot, state |
| `CheckProgress` | `LeaderStateImpl.java:828-843` | After `checkProgress(follower, committed)` computes result | `CheckProgress` | follower, caughtUp, recentResponse, attemptedSnapshot, state |
| `ApplyStagingConfiguration` | `LeaderStateImpl.java:863-887` | After all lagging followers are caught up and old-new configuration is applied | `ApplyStagingConfiguration` | node, commitIndex, state |
| `SetStreamReady` | `GrpcLogAppender.java:356-370` | Around readiness changes observed before `onNext` waits or resumes | `SetStreamReady` | follower, ready, streamReady, state |
| `CancelAppendStream` | `GrpcLogAppender.java:372-374`, `GrpcServerProtocolService.java:184-191` | After local stop or server stream cancellation path closes the stream | `CancelAppendStream` | follower, cancelled, streamActive, state |
| `SnapshotBackpressureBlock` | `StreamObserverWithTimeout.java:40-53`, `:80-107` | When outstanding snapshot send count reaches configured limit | `SnapshotBackpressureBlock` | follower, outstandingChunks, streamReady, state |
| `ResourceExhausted` | `StreamObserverWithTimeout.java:110-120` | Optional terminal test event after timeout/resource exhaustion | `ResourceExhausted` | node, state |
| `AdvanceCommitIndex` | `LeaderStateImpl.java:606-621` | After leader commit/watch indexes advance from follower proofs | `AdvanceCommitIndex` | node, commitIndex, state |

## 3. Special Considerations

- Capture post-state after the implementation update named in the trigger point.  `Trace.tla` validates primed state fields.
- For receive actions, capture whether `pendingRequests.remove(reply)` returned a request.  Use the `WithRequest` event if non-null and the `WithoutRequest` event otherwise.
- Reply queues are per follower/appender; generated reply records must carry follower identity, and receive events must not consume another follower's reply.
- For old append replies after snapshot progress, emit `OldAppendReplyAfterSnapshot` only when the reply predates the current stream epoch or carries a range below acknowledged `snapshotIndex`.
- Non-empty AppendEntries replies are ordered by `GrpcServerProtocolService.replyInOrder`, but heartbeat replies may be out of order.  Keep `isHeartbeat` on every request/reply event.
- Snapshot notification mode and chunked mode both map to the same snapshot progress actions; include `requestIndex` when available.
- Terminal snapshot replies require an active snapshot stream that has sent a request.  Chunk `SUCCESS` and `IN_PROGRESS` replies may be silent before the terminal `SnapshotInstalled`, `SnapshotAlreadyInstalled`, or `SnapshotUnavailableOrExpired` event.
- Staging data append begins only after the snapshot-attempt path has run, and append is blocked while the follower is in `SendingChunks` or `FollowerInstalling`.
- Staging fields are split across `FollowerInfoImpl` indexes, `attemptedSnapshot`, `caughtUp`, and response freshness.  Capture all four around restart and check-progress events.
