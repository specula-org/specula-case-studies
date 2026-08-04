# CR-4 Investigation

## Finding

- Source: Code Review
- Finding: CR-4, "Cancellation, backpressure, and stream resource boundaries may duplicate or retain work"
- Worktree HEAD: 7eedc1deed07fc883bfe448b2d33438b7a0e994e
- Note: the worktree is dirty with Specula trace instrumentation in the cited files. The audit distinguishes trace-only local edits from upstream Ratis control flow.

## Step 1: Code Audit

### Cited locations

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:207-237`:
  `resetClient` resets gRPC connect backoff, stops the current append stream observer, clears `pendingRequests`, and computes a new follower `nextIndex`. If the error has no matching request, it keeps the follower's current `nextIndex`; if the failing request is a heartbeat, it also avoids changing `nextIndex`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:388-409`:
  append streaming waits while `CallStreamObserver.isReady()` is false before calling `onNext`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:436-467`:
  `appendLog` creates an `AppendEntriesRequest`, stores it in `RequestMap`, eagerly advances follower `nextIndex`, creates `StreamObservers` if needed, and later calls `sendRequest`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:481-495`:
  `sendRequest` starts the request timer, calls `StreamObservers.onNext`, records send time, and schedules a timeout cleanup by call id.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:539-604`:
  append replies remove by call id from `pendingRequests`; if no request is found, the handler still processes `SUCCESS` by monotonic `updateMatchIndex` / `updateNextIndex`, or `INCONSISTENCY` by `updateNextIndex(getNextIndexForInconsistency(INVALID_LOG_INDEX, replyNextIndex))`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:643-829`:
  snapshot streaming keeps a per-stream FIFO `pending` queue, removes one pending index per reply, calls `close()` on stream error or completion, and wakes the log appender.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:842-874`:
  `installSnapshot` streams snapshot chunks in a loop by calling `snapshotRequestObserver.onNext(request)` and only then adding the request to the response handler's pending queue. It does not itself check `CallStreamObserver.isReady()`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/util/StreamObserverWithTimeout.java:41-54,81-120`:
  `newInstance` creates a `ResourceSemaphore` only when `outstandingLimit > 0`. `onNext` acquires the semaphore when present, forwards to the underlying observer, increments `requestCount`, and schedules a timeout that calls `onError` when response count has not caught up.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolService.java:72-193`:
  server-side request streams retain `previousOnNext` and `requestFuture` across ordered requests. `onCompleted` completes the response after `requestFuture`; `onError` marks the stream closed and completes the response observer for non-CANCELLED status.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:93-150`:
  `matchIndex`, `commitIndex`, and normal `nextIndex` updates are monotonic where appropriate; `setNextIndex` and snapshot install can reset `nextIndex` intentionally.

### Call chain and reachability

- AppendEntries: `GrpcLogAppender.run` -> `appendLog` -> `sendRequest` -> `StreamObservers.onNext` -> `GrpcServerProtocolClient.appendEntries` -> `GrpcServerProtocolService.appendEntries` -> `server.appendEntriesAsync`. This path is reachable during normal leader-to-follower replication.
- Append stream reset: follower-side stream completion/error reaches `AppendLogResponseHandler.onCompleted` or `onError`, then `resetClient`; normal failures, disconnects, and leadership shutdown can reach it.
- Snapshot streaming: `GrpcLogAppender.run` -> `installSnapshot()` -> `getClient().installSnapshot(...)` -> `StreamObserverWithTimeout.onNext` -> `GrpcServerProtocolService.installSnapshot` -> `server.installSnapshot`. This path is reachable when a follower is behind the leader's log start index or snapshot notification is needed.
- Server-side cancellation: gRPC transport calls `ServerRequestStreamObserver.onError`; append and install-snapshot streams use this generic observer.

### Trigger scenario

One natural trigger for the snapshot side is:

1. A follower lags far enough that the leader installs a snapshot.
2. The operator sets `raft.grpc.server.install_snapshot.request.element-limit` to `0`, or otherwise disables the semaphore window.
3. The follower/network is slow, so the underlying gRPC outbound stream is not ready.
4. The leader's `installSnapshot` loop continues calling `snapshotRequestObserver.onNext(request)` for each chunk without an explicit `isReady()` gate in `GrpcLogAppender.installSnapshot`.

The direct consumer is the gRPC/Netty outbound stream and leader process memory/resource budget. The appendEntries path already has a readiness wait, but the snapshot path relies on `StreamObserverWithTimeout`; that helper does not create a semaphore when the element limit is `0`.

Related natural triggers for the cancellation/resource-retention side are:

1. An append stream is completed or errors while replies are still outstanding.
2. `GrpcLogAppender.resetClient` clears pending requests and stops the current observer.
3. The server-side `ServerRequestStreamObserver` may retain `previousOnNext` / `requestFuture` after close/error unless explicitly cleaned.

Safeguards observed:

- Append data streams wait for `isReady()` in `StreamObservers.onNext`.
- Append reset clears `pendingRequests` and bounds `nextIndex` by `matchIndex + 1` through `getNextIndexForError`.
- `FollowerInfoImpl.updateMatchIndex` and `updateNextIndex` are monotonic for successful append replies.
- Snapshot streaming has a semaphore and timeout when `outstandingLimit > 0`; this safeguard is disabled when the limit is `0`.

## Step 2: Developer-Knowledge Search

Commands run:

- `git log --oneline --all -- ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcServerProtocolService.java ratis-grpc/src/main/java/org/apache/ratis/grpc/util/StreamObserverWithTimeout.java`
- `git blame` on `GrpcLogAppender.resetClient`, `StreamObservers.onNext`, `StreamObserverWithTimeout.acquire/onNext`, and `GrpcServerProtocolService.onError/onCompleted`.
- GitHub issue/PR API searches over `repo:apache/ratis` for `GrpcLogAppender cancellation`, `pendingRequests nextIndex resetClient`, `StreamObserverWithTimeout installSnapshot timeout outstanding request`, `appendEntries stream backpressure`, and the historical RATIS references.

Relevant local history found:

- `RATIS-1812` / PR `#850`: enforced an outstanding request limit in `StreamObserverWithTimeout`.
- `RATIS-1868` / PR `#900`: handled Netty back pressure when streaming Ratis log; this is the append log path.
- `RATIS-1883` / PR `#914`: nextIndex should stay larger than matchIndex in `GrpcLogAppender`.
- `RATIS-1909` / PR `#939`: fixed decreasing nextIndex on `GrpcLogAppender.resetClient`.
- `RATIS-2183` / PR `#1173`: detected stale snapshot requests.
- `RATIS-2283` / PR `#1250`: fixed catch-up state left false after `GrpcLogAppender` thread restart.

These historical references are relevant background, but by themselves are not the same filed defect as CR-4.

Upstream PRs/issues reporting the CR-4 mechanisms:

- `https://github.com/apache/ratis/pull/1540` (`RATIS-2632`, open, created 2026-08-02): reports that `GrpcLogAppender.installSnapshot()` streams chunks without checking `CallStreamObserver.isReady()`. It specifically notes the appendEntries path checks readiness while the snapshot path does not, and that setting the install-snapshot element limit to `0` disables the semaphore, allowing unbounded outbound buffering for slow followers.
- `https://github.com/apache/ratis/pull/1363` (`RATIS-2421`, open): reports that after `onCompleted()` in `GrpcLogAppender`, server response may never arrive, leaving the RPC stream open and resources unreleased; the proposed change adds client-side cancellation after a grace period.
- `https://github.com/apache/ratis/pull/1368` (`RATIS-2426`, open): reports/fixes memory retention in `GrpcServerProtocolService.ServerRequestStreamObserver`; the changed files clear `previousOnNext` and `requestFuture` on handleError/onCompleted/onError.

Recently closed/merged PRs were also covered by the API and git searches. Closed hits such as PR `#1450` (`RATIS-2506`), `#1425` (`RATIS-2499`), `#1369` (`RATIS-2427`), `#1250` (`RATIS-2283`), `#939` (`RATIS-1909`), and `#914` (`RATIS-1883`) are adjacent but not the same combined snapshot-backpressure / stream-resource-retention report. The exact matching reports above are open and therefore unfixed in the searched upstream state.

## Step 3: Known-Status / Precedent

This is code-review-sourced and upstream already has open PRs reporting the same mechanisms at the same sites:

- Snapshot backpressure at `GrpcLogAppender.installSnapshot` / `StreamObserverWithTimeout`: `https://github.com/apache/ratis/pull/1540`
- Append stream cancellation/resource cleanup at `GrpcLogAppender.StreamObservers`: `https://github.com/apache/ratis/pull/1363`
- Server-side stream retention at `GrpcServerProtocolService.ServerRequestStreamObserver`: `https://github.com/apache/ratis/pull/1368`

Known-status result: `KNOWN (cite: https://github.com/apache/ratis/pull/1540; fix-status: unfixed)`.

Per the skill's single allowed Phase-1 pre-filter, Code Review x known is dropped before Phase 2. No live reproduction is required to establish novelty because this is a duplicate of existing upstream reports.

Status: DROPPED (code-review x known, cite: https://github.com/apache/ratis/pull/1540)
