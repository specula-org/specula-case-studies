# Modeling Brief: ratis-grpc Replication Pipeline

## System Overview

- System: Apache Ratis `ratis-grpc`, commit `7eedc1deed07fc883bfe448b2d33438b7a0e994e`.
- Category: Category A, distributed message-passing system with local concurrency inside leader and follower processes.
- Reference algorithm: Raft leader-to-follower log replication, plus snapshot installation for log-compaction gaps.
- Target scope: `ratis-grpc` AppendEntries and InstallSnapshot streams, and shared follower-progress state in `ratis-server`.
- Out of scope: elections, leases, Netty internals, log service, shell, examples, metrics, and read-index except where a replication reply can affect the model boundary.
- Core implementation shape: each leader has a per-follower `GrpcLogAppender`; it sends AppendEntries over a gRPC bidirectional stream, optionally sends heartbeats on a separate stream, and stores progress in `FollowerInfoImpl`.
- The leader appender optimistically advances `nextIndex` when it creates a data AppendEntries request, tracks requests by gRPC call id, and later repairs or confirms progress from replies.
- Snapshot installation can run through chunked snapshot RPCs or a notification mode, while ordinary AppendEntries may still be in flight.
- The important modeling risk is not the Raft algorithm alone; it is the interaction between stream reset, pending-request bookkeeping, late replies, snapshot progress, and non-atomic follower-progress fields.

## Scenario 1: Stream Reconnect, Late Replies, and Pending Request Reset

Priority: High.

Historical references: RATIS-457, RATIS-558, RATIS-1883, RATIS-1909, RATIS-2605. These are scenario references only; do not assume the current head still has the historical bug.

### Why This Matters

The gRPC appender advances `nextIndex` before the follower replies, then later reconciles success, inconsistency, timeout, or stream failure. A stream reset clears pending requests and may leave old sends or old replies still observable by the local handler. RATIS-457 also shows that late timed-out replies can be intentionally useful because they may carry a valid `matchIndex`.

This means the spec should model request context as optional at reply time. A reply may arrive when the original request is still pending, after it timed out, or after a stream reset cleared the pending map.

### Evidence Pointers

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:206` resets the client, stops observers, clears `pendingRequests`, and computes a replacement `nextIndex`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:392` creates AppendEntries, records pending state, and optimistically increases `nextIndex`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:448` removes a pending request on timeout but does not reset the stream or immediately roll back `nextIndex`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:487` removes the pending request by reply call id; if no request is found, the reply is still processed.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:509` handles success, inconsistency, not-leader, and error replies.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:572` sets `nextIndex` and clears current pending requests.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:898` tracks heartbeat and data requests in separate maps.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolService.java:241` serves AppendEntries; non-empty AppendEntries replies are ordered, heartbeat replies are not.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:177` computes a repair index for inconsistency replies.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:92` makes `matchIndex` monotonic, while `setNextIndex` and `computeNextIndex` can assign lower values.

### Model State

Model per leader-follower pair:

- `leaderLog`: sequence of log terms and indexes sufficient to check prefix consistency.
- `followerLog`: abstract follower prefix, plus optional snapshot boundary.
- `matchIndex[f]`: highest log or snapshot index proven replicated on follower `f`.
- `nextIndex[f]`: leader's next candidate index for follower `f`.
- `streamEpoch[f]`: current logical gRPC stream generation.
- `pending[f][callId]`: optional request record with `epoch`, `kind`, `prevIndex`, `firstIndex`, `lastIndex`, `isHeartbeat`, and `state`.
- `replyQueue`: network-delivered replies that may be duplicated, delayed, reordered across heartbeat/data streams, or delivered after timeout/reset.
- `requestContextPresent`: derived predicate for whether a reply still maps to a pending request.

### Actions

- `SendAppendData`: create a data AppendEntries request, store it in `pending`, optimistically advance `nextIndex` to `lastIndex + 1`.
- `SendHeartbeat`: create a heartbeat request; optionally use separate heartbeat stream.
- `TimeoutAppend`: remove the pending request while preserving the already-advanced `nextIndex`.
- `StreamErrorReset`: stop the current stream, clear all pending requests, and compute a repaired `nextIndex` from the triggering request if known.
- `StreamCompleteReset`: stop the stream and clear pending requests without a triggering request.
- `ReceiveSuccessWithRequest`: process success for a still-pending data request and update `matchIndex` and `nextIndex`.
- `ReceiveSuccessWithoutRequest`: process a late success reply with no request context; allow it only to increase proven progress if the reply carries a valid match proof.
- `ReceiveInconsistencyWithRequest`: repair `nextIndex` using the reply's suggested next index and request first index.
- `ReceiveInconsistencyWithoutRequest`: process an inconsistency reply without request context; this should not reduce progress below the proven prefix.
- `Reconnect`: start a new stream epoch; old network events may still be delivered unless explicitly excluded.

### Expected Invariants

- `NextBeyondMatch`: for every active follower, `nextIndex[f] >= matchIndex[f] + 1`, except explicit invalid initial states if the model represents them.
- `MatchOnlyFromProof`: `matchIndex[f]` increases only from a successful data AppendEntries reply or a snapshot acknowledgement that proves the index.
- `StaleReplyNoProgressRegression`: late, duplicate, or out-of-order replies cannot lower `matchIndex[f]` or leave `nextIndex[f]` below the proven prefix.
- `NoCommitFromHeartbeatTail`: a heartbeat reply's `nextIndex` field alone cannot prove follower log suffix replication.
- `PendingResetDoesNotLoseSafety`: clearing pending requests may force resend or lower throughput, but cannot make the leader commit entries that lack quorum proof.

## Scenario 2: AppendEntries and Snapshot Installation Transition

Priority: High.

Historical references: RATIS-1305, RATIS-1390, RATIS-1402, RATIS-2045, RATIS-2145, RATIS-2183, RATIS-2487.

### Why This Matters

When the leader cannot find the follower's previous log entry, it switches from AppendEntries to snapshot installation. During this transition, old AppendEntries can still be in flight and the follower may reject appends while installing a snapshot. On the leader side, a snapshot acknowledgement updates `snapshotIndex`, `matchIndex`, and `nextIndex`; in the implementation these are separate fields rather than one atomic progress record.

The model should check that snapshot success cannot be lost by a stale AppendEntries reply and that appends after snapshot acknowledgement start at the right boundary.

### Evidence Pointers

- `ratis-server-api/src/main/java/org/apache/ratis/server/leader/LogAppender.java:193` decides when a snapshot must be installed.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:260` runs snapshot installation before normal append work when needed.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:579` handles install-snapshot replies.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:764` sends snapshot requests and waits for responses.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1739` rejects or redirects AppendEntries when snapshot installation is in progress or entries overlap snapshot/commit boundaries.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:174` validates chunked snapshot request ordering.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:253` handles snapshot-notification mode with asynchronous state-machine installation.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:146` stores snapshot progress and also updates match and next indexes.

### Model State

Extend Scenario 1 with:

- `snapshotIndex[f]`: highest snapshot index the leader believes follower `f` has installed.
- `snapshotState[f]`: `None`, `SendingChunks`, `FollowerInstalling`, `Installed`, `Unavailable`, or `Expired`.
- `snapshotCallId[f]` and `snapshotRequestIndex[f]`: abstract chunk/notification identity.
- `attemptedSnapshot[f]`: whether the leader has attempted snapshot installation for bootstrapping progress.
- `installedSnapshotIndexOnFollower[f]`: follower-side installed boundary.
- `appendDuringSnapshot[f]`: abstract event for appends that arrive while snapshot installation is in progress.

### Actions

- `TriggerSnapshot`: leader observes that AppendEntries cannot be sent because the previous log is unavailable.
- `SendSnapshotChunk`: leader sends the next snapshot chunk or notification request.
- `FollowerSnapshotInProgress`: follower rejects or redirects AppendEntries while installing a snapshot.
- `SnapshotInstalled`: follower acknowledges installed snapshot; leader updates `snapshotIndex`, `matchIndex`, and `nextIndex`.
- `SnapshotAlreadyInstalled`: follower reports the snapshot boundary is already present.
- `SnapshotUnavailableOrExpired`: follower reports the requested snapshot cannot be installed.
- `OldAppendReplyAfterSnapshot`: an AppendEntries reply from the pre-snapshot epoch arrives after snapshot progress is recorded.
- `AppendAfterSnapshot`: leader resumes normal AppendEntries at or above `snapshotIndex + 1`.

### Expected Invariants

- `SnapshotAppendBoundary`: once snapshot index `S` is acknowledged for follower `f`, current append progress for `f` is not moved below `S + 1`.
- `SnapshotProgressMonotonic`: leader-side `snapshotIndex[f]` and `matchIndex[f]` never regress.
- `AppendDuringSnapshotDoesNotCommitUnprovenEntries`: a successful or inconsistent append reply racing with snapshot installation cannot create a false quorum proof.
- `SnapshotRetryPreservesCatchup`: snapshot unavailable, expired, or in-progress replies may require retry, but cannot permanently hide that a retry is required.

## Scenario 3: Bootstrap, Catch-Up, and Configuration Staging

Priority: Medium-High.

Historical references: RATIS-1390, RATIS-2233, RATIS-2283.

### Why This Matters

Ratis treats new or restarted peers differently while they are bootstrapping. The staging path depends not only on `matchIndex`, but also on `caughtUp`, recent response time, and whether snapshot installation was attempted. RATIS-2283 is a useful historical reference because a restarted gRPC appender could leave catch-up state inconsistent with real log progress.

This is partly a liveness scenario: a peer that catches up and continues to communicate should not remain stuck in staging forever.

### Evidence Pointers

- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:518` starts new configuration staging.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:667` creates follower senders for new peers with `caughtUp=false`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:711` restarts a sender.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:828` checks catch-up progress for staging peers.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:856` treats `!caughtUp` as bootstrapping.
- `ratis-server-api/src/main/java/org/apache/ratis/server/leader/LogAppender.java:193` can force a first snapshot attempt for bootstrapping followers.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:153` stores snapshot-attempt and caught-up state separately from indexes.

### Model State

Extend Scenarios 1 and 2 with:

- `peerMode[f]`: `Existing`, `StagingNewPeer`, or `Removed`.
- `caughtUp[f]`: whether the leader considers follower `f` caught up.
- `attemptedSnapshot[f]`: whether snapshot installation has been attempted.
- `recentResponse[f]`: abstraction of the freshness check used by staging.
- `configurationState`: old/new/staging configuration phase.

### Actions

- `AddStagingPeer`: add a new peer with low `nextIndex` and `caughtUp=false`.
- `RestartAppender`: replace an appender while preserving or recomputing relevant follower progress.
- `AppendSuccessForStagingPeer`: advance `matchIndex` for a staging peer.
- `SnapshotAttemptForStagingPeer`: mark snapshot attempt and possibly update snapshot progress.
- `CheckProgress`: evaluate the staging progress predicate.
- `ApplyStagingConfiguration`: complete staging when catch-up requirements hold.

### Expected Invariants and Liveness Conditions

- `NoPrematureStagingCommit`: a bootstrapping peer is not treated as fully caught up before the catch-up predicate holds.
- `NoPermanentStaging`: under fair delivery, fresh responses, and sufficient replicated log or snapshot progress, a staging peer eventually becomes caught up.
- `RestartPreservesUsefulProgress`: appender restart does not erase progress needed to complete catch-up.

## Scenario 4: Cancellation, Backpressure, and Resource Boundaries

Priority: Low for TLA+ safety modeling; test-verifiable and code-review-priority for implementation hardening.

Current open references: RATIS-2421 / PR #1363, RATIS-2426 / PR #1368, RATIS-2632 / PR #1540.

### Why This Matters

The AppendEntries stream checks `isReady()` before sends, while snapshot streaming is mediated by `StreamObserverWithTimeout`. Current open PRs report cancellation and snapshot-backpressure issues. These are mostly resource and lifecycle concerns rather than compact Raft safety-state concerns, but they can amplify duplicate work, retry loops, or pending-state churn.

### Evidence Pointers

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:343` wraps append and heartbeat streams and waits on `isReady()`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:764` sends snapshot chunks through `StreamObserverWithTimeout`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/util/StreamObserverWithTimeout.java:40` bounds requests by response count when a positive element limit is configured.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolService.java:170` completes server streams after the last request future completes; `onError` closes the observer.

### Modeling Recommendation

Do not model byte queues, Netty flow-control internals, executor leaks, or direct memory. If a future liveness model needs this surface, use a small abstraction:

- `streamReady`: whether the transport accepts a send.
- `snapshotOutstandingChunks`: bounded count of snapshot chunks not yet acknowledged.
- `cancelled`: whether the server-side stream has been cancelled.
- `resourceExhausted`: optional terminal environment event for test-only exploration.

## Proposed Spec Extensions

| Extension | Purpose | Suggested Variables |
| --- | --- | --- |
| `GrpcPendingStream` | Represents AppendEntries stream epochs, pending maps, timeout, reset, and late reply delivery. | `streamEpoch`, `pending`, `replyQueue`, `callId`, `isHeartbeat` |
| `ReplyStrength` | Separates what a reply proves from what the leader can infer. | `replyType`, `replyMatchIndex`, `replyNextIndex`, `requestContextPresent` |
| `FollowerProgressRecord` | Models split leader-side progress state. | `matchIndex`, `nextIndex`, `snapshotIndex`, `caughtUp`, `attemptedSnapshot` |
| `SnapshotInstallState` | Captures chunked and notification snapshot transitions. | `snapshotState`, `snapshotCallId`, `snapshotRequestIndex`, `installedSnapshotIndex` |
| `BootstrapCatchup` | Captures staging and reconfiguration liveness gates. | `peerMode`, `recentResponse`, `configurationState` |
| `StreamBackpressureAbstract` | Optional low-priority abstraction for open cancellation/backpressure reports. | `streamReady`, `outstandingChunks`, `cancelled` |

## Proposed Invariants

Standard Raft invariants:

- `ElectionSafety`: at most one leader per term. Keep only as context unless elections are explicitly added.
- `LogMatching`: if two logs contain an entry with the same index and term, their prefixes match up to that index.
- `LeaderCompleteness`: committed entries remain present in later leaders. Keep as a boundary invariant if the model includes term changes.

Implementation-specific invariants:

- `NextBeyondMatch`: `nextIndex[f] >= matchIndex[f] + 1` for each follower after every modeled atomic appender step.
- `MatchOnlyFromProof`: leader `matchIndex[f]` increases only from successful data AppendEntries or snapshot installation proof.
- `StaleReplyNoProgressRegression`: stale, duplicate, timeout-delayed, or out-of-order replies cannot reduce proven progress.
- `SnapshotAppendBoundary`: after snapshot index `S` is acknowledged, append progress for that follower does not move below `S + 1`.
- `NoCommitFromHeartbeatTail`: heartbeat success cannot by itself prove follower log entries beyond the prior proven match.
- `NoPermanentStaging`: under fair delivery and fresh responses, a staging peer with sufficient replicated progress eventually exits bootstrapping.

## Findings Pending Verification

### Model-Checkable Findings

`MC-RG-1`: Stream reset and stale inconsistency reply.

- Question: If `resetClient` clears pending requests while an old AppendEntries send or reply remains in flight, can a stale `INCONSISTENCY` reply reduce `nextIndex` below the proven `matchIndex + 1`, or cause a resend loop that never converges?
- Expected check: `NextBeyondMatch` and `StaleReplyNoProgressRegression`.
- Source basis: `GrpcLogAppender.resetClient`, `AppendLogResponseHandler.onNextImpl`, `updateNextIndex`, and `LogAppenderBase.getNextIndexForInconsistency`.

`MC-RG-2`: Timeout removal followed by late success or inconsistency.

- Question: If a request times out and is removed from `pendingRequests`, can its later reply be processed without enough request context to preserve both RATIS-457-style useful progress and RATIS-1883/RATIS-1909-style next-index safety?
- Expected check: `MatchOnlyFromProof`, `NextBeyondMatch`, and `StaleReplyNoProgressRegression`.
- Source basis: timeout removes the request, but reply processing continues even when the request lookup returns null.

`MC-RG-3`: Snapshot completion racing with old append replies.

- Question: If snapshot installation is acknowledged while pre-snapshot AppendEntries replies arrive later, can leader-side `snapshotIndex`, `matchIndex`, or `nextIndex` regress or start append work below the snapshot boundary?
- Expected check: `SnapshotAppendBoundary` and `SnapshotProgressMonotonic`.
- Source basis: snapshot response handling updates follower progress; stale append replies can still enter the appender reply handler.

`MC-RG-4`: Bootstrap restart and staging liveness.

- Question: If a gRPC appender restarts while a new peer is bootstrapping, can `caughtUp`, `attemptedSnapshot`, `recentResponse`, and indexes become inconsistent enough to keep staging open permanently despite successful communication?
- Expected check: `NoPermanentStaging` under fair delivery.
- Source basis: RATIS-2283, `LeaderStateImpl.checkProgress`, `LeaderStateImpl.isFollowerBootstrapping`, and `FollowerInfoImpl` catch-up fields.

`MC-RG-5`: Inconsistency helper boundary at the current match frontier.

- Question: When `requestFirstIndex == matchIndex + 1` and the follower's inconsistency reply suggests a lower `nextIndex`, does `getNextIndexForInconsistency` always preserve or quickly restore `nextIndex >= matchIndex + 1`?
- Expected check: `NextBeyondMatch`.
- Source basis: `LogAppenderBase.getNextIndexForInconsistency` and `GrpcLogAppender.onNextImpl`.

### Test-Verifiable Findings

`TV-RG-1`: First-call error and missing request context.

- Test idea: induce a stream error on the first AppendEntries call and assert that pending clear, retry, and next-index repair preserve the proven prefix.
- Risk shape: error trailers may not map cleanly to a pending request, so the reset path may run without request context.

`TV-RG-2`: Reset/send race.

- Test idea: let a send capture an old stream observer, then concurrently force `resetClient`. Verify a send after `stop()` is either prevented or repaired without corrupting pending state.

`TV-RG-3`: Snapshot backpressure with slow receiver.

- Test idea: exercise snapshot installation with a slow receiver and an element limit configuration that permits many outstanding chunks. Open PR #1540 reports an `isReady()` gap here.

`TV-RG-4`: Server stream cancellation cleanup.

- Test idea: cancel append and snapshot streams while server-side futures are still outstanding. Assert observer cleanup and no retained per-stream state. Open PRs #1363 and #1368 are current references.

### Code-Review-Only Findings

`CR-RG-1`: `StreamObservers.stop()` sets a local flag but does not itself complete or cancel the underlying gRPC observers. Review whether this is sufficient for all reset paths.

`CR-RG-2`: `FollowerInfoImpl.setSnapshotIndex` writes snapshot, match, and next indexes as separate unconditional updates. Review all callers to ensure only monotonic snapshot acknowledgements reach this method.

`CR-RG-3`: `ReadIndexHeartbeats` uses AppendEntries reply call ids as heartbeat evidence. This is outside the current scope, but if read-index is modeled later, reply generation should be considered.

## Do Not Model

- Netty internals, gRPC transport retry policy, direct memory, allocator behavior, metrics, logging, tracing, examples, shell, and log service.
- BFT behavior. This target is not Byzantine fault tolerant and does not require Category B modeling.
- Full election and lease behavior, except the minimum term/leader gate needed for AppendEntries and snapshot acceptance.
- Closed historical issues as assumed present bugs. Use RATIS issue history to shape scenarios and invariants only.

## Reference Pointers

- Detailed audit trail: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/analysis-report.md`
- Source repository: `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc`
- Raft paper: https://raft.github.io/raft.pdf
- RATIS-457: https://issues.apache.org/jira/browse/RATIS-457
- RATIS-558: https://issues.apache.org/jira/browse/RATIS-558
- RATIS-1883: https://issues.apache.org/jira/browse/RATIS-1883 and https://github.com/apache/ratis/pull/914
- RATIS-1909: https://issues.apache.org/jira/browse/RATIS-1909 and https://github.com/apache/ratis/pull/939
- RATIS-2283: https://issues.apache.org/jira/browse/RATIS-2283 and https://github.com/apache/ratis/pull/1250
- RATIS-2605: https://issues.apache.org/jira/browse/RATIS-2605 and https://github.com/apache/ratis/pull/1519
- RATIS-2632: https://issues.apache.org/jira/browse/RATIS-2632 and https://github.com/apache/ratis/pull/1540
- RATIS-2421: https://issues.apache.org/jira/browse/RATIS-2421 and https://github.com/apache/ratis/pull/1363
- RATIS-2426: https://issues.apache.org/jira/browse/RATIS-2426 and https://github.com/apache/ratis/pull/1368
