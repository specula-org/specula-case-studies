# Code Analysis Report: ratis-grpc Replication Pipeline

## 1. Scope and Methodology

System analyzed:

- Name: `ratis-grpc`
- Upstream project: `apache/ratis`
- Source checkout: `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc`
- Analyzed commit: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`
- Source worktree status at analysis time: clean
- Output directory: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output`

The installed `code-analysis` skill was used as the methodology source. The required phases were followed:

1. Reconnaissance of the target system and algorithm boundary.
2. Bug archaeology through repository history, JIRA records, merged PRs, and current open PRs.
3. Deep code analysis of the target replication paths.
4. Scenario modeling brief generation with model-checkable, test-verifiable, and code-review-only findings.

Category handling:

- This target is Category A: distributed message-passing plus local concurrency.
- Category B / BFT handling is not applicable. Apache Ratis implements crash-fault Raft, not Byzantine consensus.
- The model should include lossy, duplicated, delayed, and reordered messages where the gRPC stream and request bookkeeping make those effects observable.
- The model should also include local interleavings between send, timeout, stream reset, reply handling, snapshot callbacks, and follower-progress field updates.

Target-specific scope:

- In scope: `GrpcLogAppender`, shared `LogAppender` / `LogAppenderBase` behavior, `LogAppenderDefault` as a comparison point, `FollowerInfoImpl`, AppendEntries RPC handling, snapshot RPC handling, and leader catch-up state that affects replication.
- Out of scope: Netty internals, log service, shell, examples, metrics, full elections, and leases except as term/leader gates needed for replication acceptance.
- Historical references RATIS-1883, RATIS-1909, RATIS-558, and RATIS-2283 were used as scenario references, not as assumed current bugs.

No tests were executed. This phase was a code-analysis and modeling-brief handoff.

## 2. Phase 1 Reconnaissance

Core Java size for `ratis-grpc/src/main/java` plus `ratis-server/src/main/java`:

- Java files: 99
- Lines counted with `find ... -name '*.java' -print0 | xargs -0 wc -l`: 25,014

Primary files read:

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java`
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolClient.java`
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolService.java`
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/util/StreamObserverWithTimeout.java`
- `ratis-server-api/src/main/java/org/apache/ratis/server/leader/LogAppender.java`
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java`
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java`
- `ratis-server/src/main/java/org/apache/ratis/server/leader/InstallSnapshotRequests.java`
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LeaderProtoUtils.java`
- `ratis-server-api/src/main/java/org/apache/ratis/server/raftlog/RaftLogIndex.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ReadIndexHeartbeats.java`

### Architecture Summary

The leader creates one `LogAppender` per follower. In the gRPC implementation, `GrpcLogAppender` uses a bidirectional AppendEntries stream and optionally a separate heartbeat stream. It keeps a map of pending data requests and heartbeat requests keyed by gRPC call id. For data appends, the leader optimistically advances the follower's `nextIndex` at request creation time before the follower reply is received.

The follower side is implemented by `GrpcServerProtocolService`, which routes AppendEntries and InstallSnapshot stream messages into `RaftServerImpl`. Non-empty AppendEntries replies are ordered by chaining request futures. Heartbeat replies are not ordered by that chain. Snapshot install replies are ordered.

Follower progress is stored in `FollowerInfoImpl`. It separates:

- `nextIndex`
- `matchIndex`
- `commitIndex`
- `snapshotIndex`
- `errorState`
- `caughtUp`
- `ackInstallSnapshotAttempt`

These fields have individual atomic or volatile behavior, but the group is not one atomic progress record. This matters for snapshot and catch-up transitions.

### Concurrency and Atomicity Boundaries

`GrpcLogAppender` has a write lock around request creation, pending-map changes, and some reset/update operations. The actual gRPC `onNext` send happens outside that lock. Reply handlers, timeout handlers, and reset handlers can therefore interleave with sends that already captured a stream observer.

`FollowerInfoImpl.updateMatchIndex` and `updateNextIndex` are monotonic max-style updates, but `setNextIndex` and `computeNextIndex` can lower `nextIndex`. `setSnapshotIndex` writes `snapshotIndex`, `matchIndex`, and `nextIndex` separately and unconditionally.

`RaftServerImpl.appendEntriesAsync` checks leader and term state under synchronization, then performs log appends asynchronously. Snapshot notification mode in `SnapshotInstallationHandler` uses an in-progress CAS and asynchronous state-machine callback.

These local interleavings are important Category A modeling details because a pure Raft message model would miss them.

## 3. Phase 2 Bug Archaeology

Repository mining:

- A broad git search over selected core replication files found 224 commit records across all refs/backports.
- These records referenced 155 unique `RATIS-*` issue ids.
- A focused archaeology pass over the five target files found 176 unique commits; 106 matched fault keywords; 75 issue/subject entries remained after deduplication.

Issue and PR review:

- GitHub Issues are disabled for `apache/ratis`; Apache JIRA was used for issue records.
- Main pass fetched 43 JIRA records into `/tmp/ratis-jira/*.json` and summarized them in `/tmp/ratis-jira-summary.tsv`.
- RATIS-457 was fetched separately because it is an older gRPC replication issue directly relevant to late replies.
- The focused archaeology pass reviewed 31 JIRA records, 25 merged PRs, and 3 open PRs.

Current open PRs relevant to this scope as of 2026-08-03:

- PR #1540 / RATIS-2632: install-snapshot backpressure report; open.
- PR #1363 / RATIS-2421: graceful cancellation after stream completion; open.
- PR #1368 / RATIS-2426: `ServerRequestStreamObserver` memory-leak report; open draft.
- PR #1445 / RATIS-2509 concerns zero-copy shutdown resource cleanup and is mostly out of this replication-safety scope.

### Historical Issue Table

| Issue | Status in archaeology | Relevance |
| --- | --- | --- |
| RATIS-457 | Fixed; commit `f80757d3df3ce15022118095cd5f623b1c89d559` | Timed-out gRPC append replies can still carry useful `matchIndex`; explains current late-reply processing. |
| RATIS-558 | Fixed; commit `de557a713d4834cc6343d474ac64e122d9c8267f` | Inconsistent AppendEntries replies must reset leader state enough to resend missing entries. |
| RATIS-1074 | Fixed | Historical example of improper next-index decrease causing unnecessary snapshot. |
| RATIS-1305 | Fixed | Historical snapshot loop when logs were purged. |
| RATIS-1390 | Fixed | Bootstrapping peer needs first snapshot attempt semantics. |
| RATIS-1402 | Fixed | Avoids extra RPC churn while follower is installing a snapshot. |
| RATIS-1835 | Fixed | Heartbeat to restarting follower must not incorrectly change nextIndex. |
| RATIS-1868 | Fixed | Backpressure and streaming-log replication scenario reference. |
| RATIS-1883 | Fixed; PR #914, commit `b8ce6d1f6ea37ed3ff9f6e888d2357fe48490567` | In-flight success and inconsistency replies could drive `nextIndex` below `matchIndex`. |
| RATIS-1895 | Fixed | `updateIncreasingly` could throw after race; relevant to monotonic progress updates. |
| RATIS-1909 | Fixed; PR #939, commit `b7ffa1ba1e3e7cecd9ea687f72425c2ffd5b1c34` | Stream error reset could decrease `nextIndex` to `matchIndex`. |
| RATIS-2137 | Fixed | Default appender inconsistency handling alignment. |
| RATIS-2183 | Fixed; PR #1173 | Snapshot notification path could prevent future AppendEntries. |
| RATIS-2233 | Fixed | Follow-on catch-up / bootstrapping reference. |
| RATIS-2283 | Fixed; PR #1250, commit `21ce4e1fd8b39cd139a6821bd4de9cbf7d90a5b0` | Restarted gRPC appender and caught-up state could block reconfiguration. |
| RATIS-2487 | Fixed | Snapshot installation timeout/hang scenario reference. |
| RATIS-2605 | Fixed; PR #1519, commit `6aafce539ca3c280db6e91fe8a6e02b345001952` | Heartbeat success in default appender must not over-advance progress. |
| RATIS-2632 | Open; PR #1540 | Snapshot stream backpressure report. |
| RATIS-2421 | Open; PR #1363 | Stream cancellation after completion report. |
| RATIS-2426 | Open draft; PR #1368 | Server request stream observer memory-leak report. |

### Archaeology Mechanism Groups

1. Next-index and match-index regressions.
   Historical issues RATIS-558, RATIS-1074, RATIS-1883, RATIS-1895, RATIS-1909, RATIS-2137, and RATIS-2605 all point to one modeling theme: reply handling must distinguish proven replication from retry cursor repair.

2. Late, duplicate, or context-free replies.
   RATIS-457 shows late replies should not be blindly ignored; they can carry useful `matchIndex`. That intent creates a tension with stale inconsistency replies after pending request context has been removed.

3. Snapshot transition and snapshot liveness.
   RATIS-1305, RATIS-1390, RATIS-1402, RATIS-2045, RATIS-2145, RATIS-2183, and RATIS-2487 point to snapshot/append boundary hazards and retry loops.

4. Bootstrap and reconfiguration catch-up.
   RATIS-2283 and adjacent catch-up fixes show that `caughtUp`, `attemptedSnapshot`, and appender restart state are part of the replication correctness boundary.

5. Resource/cancellation/backpressure.
   RATIS-2421, RATIS-2426, and RATIS-2632 are current open references. They should be treated as test-verifiable or code-review-only until reproduced locally.

## 4. Phase 3 Current Code Analysis

### 4.1 GrpcLogAppender Send, Reset, Timeout, and Reply Handling

`GrpcLogAppender` is the primary target. It implements a per-follower asynchronous stream appender.

Important current behavior:

- `resetClient` at `GrpcLogAppender.java:206` resets connection backoff, stops stream observers, clears the pending map, and computes a new `nextIndex` depending on the triggering request and event.
- If `resetClient` is called for an error without a known request, it keeps the follower's current `nextIndex`.
- If the triggering request is a heartbeat, `resetClient` does not lower `nextIndex`.
- For non-heartbeat request errors, `resetClient` computes a candidate next index through `getNextIndexForError`.
- `appendLog` at `GrpcLogAppender.java:392` creates the request under the write lock, records it in `pendingRequests`, and calls `increaseNextIndex` before the send.
- `sendRequest` at `GrpcLogAppender.java:431` starts the request timer, sends through the stream observer, updates last-send time, and schedules timeout handling.
- `timeoutAppendRequest` at `GrpcLogAppender.java:448` removes the pending request and processes a timeout event, but it does not reset the stream and does not immediately roll back the optimistic `nextIndex`.
- `AppendLogResponseHandler.onNext` at `GrpcLogAppender.java:487` removes the pending request by reply key; even if no request is found, it still calls `onNextImpl`.
- `onNextImpl` at `GrpcLogAppender.java:509` handles success, not-leader, inconsistency, and error cases.
- On success, the handler updates follower commit index, then updates `matchIndex`; if `matchIndex` increased, it sets `nextIndex` to `reply.matchIndex + 1` through `updateNextIndex`.
- On inconsistency, it computes a repair next index using either the request first index or `INVALID_LOG_INDEX` if the request context is missing.
- `updateNextIndex` at `GrpcLogAppender.java:572` clears all pending requests and sets follower `nextIndex`.

Key observation:

The implementation intentionally accepts some replies without request context. This is useful for RATIS-457-style late success replies, but it should be modeled because inconsistency replies without request context have weaker proof value.

### 4.2 RequestMap and Call Identity

`GrpcLogAppender.RequestMap` at `GrpcLogAppender.java:898` stores data requests and heartbeat requests separately:

- `put` stores by `callId` and request kind.
- `remove(reply)` uses `reply.getServerReply().getCallId()` and `reply.getIsHearbeat()`.
- `remove(callId, isHeartbeat)` is used on stream errors when gRPC status metadata exposes the call id.

The model should include both request kind and call id. Heartbeat and data replies may share numeric call-id ranges but are separated by `isHeartbeat`.

### 4.3 Backpressure and Stream Observer Lifecycle

`StreamObservers` at `GrpcLogAppender.java:343` wraps append and optional heartbeat streams. Its `onNext` waits while `!stream.isReady()` and `running` is true, then calls `stream.onNext(proto)`. `stop()` only sets `running=false`; completion is handled separately through `onCompleted()`.

This is an implementation lifecycle concern. It should not be over-modeled in TLA+ unless liveness/resource pressure is the selected scenario, but it is a useful test-verifiable area because sends can race with reset.

### 4.4 Leader-Side Next-Index Repair Helpers

`LogAppenderBase.getNextIndexForInconsistency` at `LogAppenderBase.java:177` attempts to avoid decreasing `nextIndex` below the proven match prefix. It uses:

- reply-suggested next index;
- `matchIndex + 1`;
- the request first index;
- a one-step decrement when the reply next equals the request first index.

Potential boundary to model:

If `requestFirstIndex == matchIndex + 1` and the reply suggests a lower next index, the helper can select a value lower than `matchIndex + 1`. This may still be repaired by the next append or snapshot step, but it should be checked because it is directly adjacent to RATIS-1883 and RATIS-1909.

`LogAppenderBase.getNextIndexForError` at `LogAppenderBase.java:193` similarly uses match-index and request context to prevent error reset from falling too far behind in normal cases.

### 4.5 Default Appender Comparison

`LogAppenderDefault` is not the gRPC target, but it is useful as a synchronous comparison point:

- `sendAppendEntriesWithRetries` at `LogAppenderDefault.java:74` sends one request and handles its reply before the next send.
- `handleReply` at `LogAppenderDefault.java:192` distinguishes heartbeat success from data success.
- Current default appender code uses `max(oldNextIndex, requestPreviousIndex + 1)` for heartbeat success and trusts data success only for real append replies.

RATIS-2605 was fixed in the default appender path. The gRPC path currently does not appear to use heartbeat success to advance `matchIndex` because follower heartbeat success returns an invalid match index. This is a useful exclusion from the current modeling target, while retaining `NoCommitFromHeartbeatTail` as an invariant.

### 4.6 FollowerInfoImpl Progress State

`FollowerInfoImpl` is the shared progress record used by leader appender logic and leader reconfiguration logic.

Important behavior:

- `updateMatchIndex` at `FollowerInfoImpl.java:92` is monotonic max.
- `updateCommitIndex` at `FollowerInfoImpl.java:102` is monotonic max.
- `increaseNextIndex` at `FollowerInfoImpl.java:117` is increasing-only.
- `setNextIndex` at `FollowerInfoImpl.java:128` unconditionally assigns a non-negative index.
- `updateNextIndex` at `FollowerInfoImpl.java:134` is max-style.
- `computeNextIndex` at `FollowerInfoImpl.java:140` unconditionally assigns the result of an operation.
- `setSnapshotIndex` at `FollowerInfoImpl.java:146` unconditionally sets snapshot index, then match index, then next index.
- `setAttemptedToInstallSnapshot` and `catchUp` are separate state changes.

Key observation:

`FollowerInfoImpl` should be abstracted as a progress record, but the implementation does not update all fields atomically as one record. The spec can either model the whole appender action atomically or explicitly model split progress fields for snapshot and catch-up interleavings.

For this target, explicitly modeling split fields is recommended for snapshot and bootstrap scenarios.

### 4.7 AppendEntries Server Handler

`GrpcServerProtocolService.appendEntries` at `GrpcServerProtocolService.java:241` wraps the server request stream:

- `process` calls `server.appendEntriesAsync(request)`.
- `replyInOrder` returns true for non-empty AppendEntries requests and false for heartbeats.

`RaftServerImpl.appendEntriesAsync` at `RaftServerImpl.java:1556` validates lifecycle, group, and entries before processing. The core append logic at `RaftServerImpl.java:1639`:

- recognizes the leader and term;
- changes to follower as needed;
- checks group/configuration;
- updates last RPC time;
- rejects inconsistent requests;
- performs log append asynchronously;
- returns success with `matchIndex` and `nextIndex`.

`checkInconsistentAppendEntries` at `RaftServerImpl.java:1739` handles:

- snapshot installation in progress;
- AppendEntries overlapping snapshot or committed boundaries;
- missing previous log entries.

This means the follower side already has important snapshot-boundary defenses. The model should capture those defenses rather than treating the follower as a passive log append function.

### 4.8 Snapshot RPC Handler

`GrpcServerProtocolService.installSnapshot` at `GrpcServerProtocolService.java:278` routes stream messages to `server.installSnapshot(request)` and preserves reply order.

`SnapshotInstallationHandler` has two broad paths:

- Chunked installation through `checkAndInstallSnapshot` at `SnapshotInstallationHandler.java:174`.
- Notification/state-machine installation through `notifyStateMachineToInstallSnapshot` at `SnapshotInstallationHandler.java:253`.

Important snapshot behavior:

- Chunk mode rejects stale snapshot requests by call id and request ordering.
- Notification mode uses `inProgressInstallSnapshotIndex.compareAndSet` to serialize installation per index.
- `SNAPSHOT_INSTALLED` updates installed state and reloads the state machine.
- `SNAPSHOT_UNAVAILABLE`, `SNAPSHOT_EXPIRED`, and `ALREADY_INSTALLED` are distinct states and should not be collapsed in the model.

Leader-side `InstallSnapshotResponseHandler` in `GrpcLogAppender` updates follower snapshot, match, and next progress on installed/already-installed responses. The transition back to AppendEntries is a primary model scenario.

### 4.9 LeaderState Catch-Up and Reconfiguration

`LeaderStateImpl` uses appender progress for normal commit and configuration staging:

- Existing followers are added with current log next index and `caughtUp=true`.
- New peers are added with `nextIndex=LEAST_VALID_LOG_INDEX` and `caughtUp=false`.
- New configuration staging checks `matchIndex`, response freshness, configuration log index, and snapshot-attempt state.
- `isFollowerBootstrapping` currently maps to `!caughtUp`.

Relevant code:

- `LeaderStateImpl.java:518` starts configuration staging.
- `LeaderStateImpl.java:667` adds new senders.
- `LeaderStateImpl.java:711` restarts a sender.
- `LeaderStateImpl.java:828` checks progress.
- `LeaderStateImpl.java:856` tests bootstrapping.
- `LeaderStateImpl.java:863` checks staging.

This is why `caughtUp` and `attemptedSnapshot` belong in the modeling brief even though they are not Raft log indexes.

### 4.10 ReadIndex and Lease Boundary

`ReadIndexHeartbeats` listens to AppendEntries replies and validates them by call id and follower commit. This is outside the requested scope except as a warning that stale reply generation may have read-index implications if the model is later expanded.

No read-index invariant is recommended for the first Spec Generation pass.

## 5. Scenario Findings

### Scenario A: Stream Reconnect, Pending Reset, and Late Replies

Classification: Model-checkable.

Question covered:

- What happens when a gRPC stream reconnects with AppendEntries requests in flight?
- Can stale, duplicated, or out-of-order replies corrupt `nextIndex` or `matchIndex`?
- Can cancellation, retry, or backpressure duplicate work or skip required replication?

Evidence:

- Send path records pending and optimistically advances `nextIndex`.
- Timeout removes pending but leaves optimistic `nextIndex`.
- Reset clears all pending state.
- Reply handling continues even when request context is absent.
- Inconsistency repair with missing request context uses `INVALID_LOG_INDEX`.

Assessment:

This is the highest-priority model-checking scenario. The current code contains defenses from earlier bugs, especially monotonic `matchIndex` and safer error reset. The remaining risk is boundary behavior when request context is missing or when the reply corresponds to a prior stream generation.

Recommended checks:

- `NextBeyondMatch`
- `MatchOnlyFromProof`
- `StaleReplyNoProgressRegression`
- `PendingResetDoesNotLoseSafety`

### Scenario B: AppendEntries-to-Snapshot Transition

Classification: Model-checkable.

Question covered:

- Does a stream reset clear pending and catch-up state consistently?
- Can the transition between AppendEntries and snapshot installation lose progress?

Evidence:

- Snapshot is triggered when previous log is unavailable or bootstrapping requires the first snapshot attempt.
- Snapshot install may run while append replies from an older epoch still exist.
- Follower rejects or redirects appends during snapshot installation.
- Leader snapshot success writes snapshot/match/next progress.

Assessment:

This scenario should be modeled because it crosses the request-level gRPC state and the follower progress record. The current code has follower-side defenses and snapshot request ordering, but the leader-side progress update is split across fields and can race conceptually with stale append replies.

Recommended checks:

- `SnapshotAppendBoundary`
- `SnapshotProgressMonotonic`
- `AppendDuringSnapshotDoesNotCommitUnprovenEntries`
- `SnapshotRetryPreservesCatchup`

### Scenario C: Bootstrap and Catch-Up State

Classification: Model-checkable liveness plus code review.

Question covered:

- Does a stream reset clear pending and catch-up state consistently?
- Can retry or reset skip required replication for a bootstrapping peer?

Evidence:

- New peers start with `caughtUp=false`.
- Catch-up requires recent response, match progress, configuration-index progress, and snapshot-attempt state.
- RATIS-2283 shows appender restart and catch-up state can block reconfiguration.

Assessment:

This should be included if Spec Generation is expected to model membership staging. If the first spec is strictly append/snapshot safety, it can be a second-phase extension.

Recommended checks:

- `NoPrematureStagingCommit`
- `NoPermanentStaging`
- `RestartPreservesUsefulProgress`

### Scenario D: Backpressure, Cancellation, and Server Stream Cleanup

Classification: Test-verifiable and code-review-only.

Question covered:

- Can cancellation, retry, or backpressure duplicate work or skip required replication?

Evidence:

- Append stream waits for `isReady()`.
- Snapshot stream uses `StreamObserverWithTimeout`.
- Open PR #1540 reports missing snapshot `isReady()` backpressure.
- Open PR #1363 reports graceful cancellation after completion.
- Open PR #1368 reports server request stream observer retention.

Assessment:

These are real implementation concerns, but they should not dominate the first TLA+ safety model. They are better handled by targeted Java tests and code review unless a later model explicitly studies bounded queues or cancellation liveness.

## 6. Findings Pending Verification

### 6.1 Model-Checkable

`MC-RG-1`: Stream reset and stale inconsistency reply.

- If `resetClient` clears pending while an old reply remains in flight, a later `INCONSISTENCY` reply without request context should not push `nextIndex` below `matchIndex + 1`.
- Model should include stream epochs, pending map clear, and stale reply delivery.

`MC-RG-2`: Timeout removal followed by late success or inconsistency.

- A late success after timeout should be allowed to increase progress when it carries valid proof.
- A late inconsistency after timeout should not erase proven progress or current pending work in a way that violates safety.

`MC-RG-3`: Snapshot completion racing with old append replies.

- After snapshot index `S` is acknowledged, stale append replies from before the snapshot should not move leader progress below `S + 1`.

`MC-RG-4`: Bootstrap restart and staging liveness.

- If a new peer catches up after appender restart, staging should eventually complete under fair delivery and fresh responses.

`MC-RG-5`: `getNextIndexForInconsistency` boundary case.

- The helper should be checked when `requestFirstIndex == matchIndex + 1` and the follower suggests a lower next index.

### 6.2 Test-Verifiable

`TV-RG-1`: First-call stream error without useful request context.

- Inject a stream error on the first AppendEntries call and verify pending clear, retry, and next-index repair.

`TV-RG-2`: Reset/send race.

- Force a send to capture an old stream observer, then trigger reset before `onNext` completes. Verify no untracked request corrupts progress.

`TV-RG-3`: Snapshot backpressure with slow receiver.

- Reproduce or reject the open RATIS-2632 / PR #1540 claim with a slow receiver and a configuration that permits unbounded or high outstanding snapshot chunks.

`TV-RG-4`: Server request stream cleanup on cancellation.

- Reproduce or reject RATIS-2421 / PR #1363 and RATIS-2426 / PR #1368 on the current head.

### 6.3 Code-Review-Only

`CR-RG-1`: `StreamObservers.stop()` lifecycle semantics.

- `stop()` only flips the local `running` flag. Review whether all reset and cancellation paths eventually complete or cancel the underlying gRPC observers.

`CR-RG-2`: Split unconditional snapshot progress update.

- `FollowerInfoImpl.setSnapshotIndex` sets snapshot, match, and next fields separately and unconditionally. Review whether older snapshot acknowledgements are impossible at all call sites.

`CR-RG-3`: ReadIndex reply-generation boundary.

- `ReadIndexHeartbeats` consumes AppendEntries replies by call id. If read-index is later included, stale replies after reset should be generation-scoped in the model.

## 7. Exclusions and Ruled-Out Current Concerns

Closed historical issues are not assumed current bugs:

- RATIS-1883 and RATIS-1909 have current-code defenses in `LogAppenderBase` and `GrpcLogAppender`.
- RATIS-558's historical stuck-in-inconsistency behavior is not assumed present; current inconsistency handling clears pending and repairs `nextIndex`.
- RATIS-2283's specific bootstrapping predicate was changed; current code uses `!caughtUp` for bootstrapping.

Heartbeat over-advance is not a current gRPC finding:

- RATIS-2605 fixed default appender heartbeat handling.
- In the current gRPC path, heartbeat success does not appear to advance `matchIndex` because heartbeat replies use an invalid match index.
- Still keep `NoCommitFromHeartbeatTail` as a regression invariant.

Append success cannot silently decrease proven progress in the normal path:

- `FollowerInfoImpl.updateMatchIndex` is max-style.
- gRPC success updates `nextIndex` through a max-style `updateNextIndex` after `matchIndex` increases.

Snapshot reply ordering has follower-side and handler-side defenses:

- Server snapshot stream replies are ordered.
- Chunked snapshot install checks call id and request index.
- Notification mode serializes in-progress install state by snapshot index.

Not modeled:

- Netty details, gRPC retry policy internals, allocator behavior, direct memory, metrics, logging, tracing.
- Log service, shell, examples, and unrelated modules.
- Full elections and leases.
- Read-index correctness, unless later selected as a separate scope.

## 8. Question Coverage

What happens when a gRPC stream reconnects with AppendEntries requests in flight?

- The current appender resets the client, stops stream observers, clears pending requests, and recomputes or preserves `nextIndex` depending on event and request context. Old replies may still reach the response handler and can be processed without pending request context. This is covered by `MC-RG-1` and `MC-RG-2`.

Can stale, duplicated, or out-of-order replies corrupt `nextIndex` or `matchIndex`?

- `matchIndex` is monotonic, and current success handling is safer than historical versions. The main remaining model question is whether stale inconsistency or context-free replies can leave `nextIndex` below the proven prefix or clear useful pending work. This is covered by `NextBeyondMatch` and `StaleReplyNoProgressRegression`.

Does a stream reset clear pending and catch-up state consistently?

- Stream reset clears pending requests but does not directly reset catch-up fields. Catch-up state lives in `FollowerInfoImpl` and `LeaderStateImpl`, so the important check is interaction with appender restart and bootstrapping predicates. This is covered by `MC-RG-4`.

Can the transition between AppendEntries and snapshot installation lose progress?

- Snapshot completion updates leader-side progress, while old append replies may still exist. Follower-side snapshot defenses are present, but the model should check stale append replies after snapshot acknowledgement. This is covered by `MC-RG-3`.

Can cancellation, retry, or backpressure duplicate work or skip required replication?

- The append path has `isReady()` waiting and pending-request throttling. Snapshot streaming and cancellation have current open PRs, so treat these as test-verifiable/code-review issues rather than first-pass TLA+ safety findings. This is covered by `TV-RG-3`, `TV-RG-4`, and `CR-RG-1`.

## 9. Handoff to Spec Generation

Recommended first model:

- Build a small Raft leader/follower replication model with one leader and one or two followers.
- Include leader log, follower log, `matchIndex`, `nextIndex`, pending AppendEntries map, stream epoch, and reply queue.
- Include data AppendEntries, heartbeat AppendEntries, timeout, reset, late replies, and inconsistency repair.
- Add snapshot boundary state only after the base append model reproduces useful interleavings.

Recommended second extension:

- Add snapshot install state, snapshot acknowledgements, append rejection during snapshot installation, and old append replies after snapshot success.

Recommended third extension:

- Add bootstrapping peers and configuration staging liveness.

Keep resource/backpressure/cancellation as Java test work unless a later model explicitly targets liveness under bounded transport queues.

## 10. Source and External References

Local source paths:

- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java`
- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolService.java`
- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java`
- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java`
- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java`
- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java`
- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java`
- `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc/ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java`

External references:

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
