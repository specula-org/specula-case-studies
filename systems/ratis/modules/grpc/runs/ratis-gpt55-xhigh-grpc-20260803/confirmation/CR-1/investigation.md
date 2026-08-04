# CR-1 Investigation

## Code Audit

Primary site: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java`.

- `GrpcLogAppender.appendLog` creates an `AppendEntriesRequest` and stores it in
  `pendingRequests` before sending: `pendingRequests.put(request)` at line 448.
  For data appends it then optimistically advances follower `nextIndex` via
  `increaseNextIndex(pending)` at line 449.
- `sendRequest` starts the request timer and schedules
  `timeoutAppendRequest(request.getCallId(), request.isHeartbeat())` at lines
  489-493.
- `timeoutAppendRequest` removes only the matching call id from
  `pendingRequests` at line 499, records a timeout, and leaves the stream active.
  This makes a later real follower reply for the same call id reachable with
  `request == null`.
- `resetClient` stops the stream observer and clears the whole pending map at
  lines 210-218. It then computes an error retry `nextIndex` and applies
  `getFollower().computeNextIndex(getNextIndexForError(nextIndex))` at line 236,
  except for the guarded `request == null` error case at lines 224-230 and the
  heartbeat case at lines 232-235.
- `AppendLogResponseHandler.onNext` removes the request context by reply call id
  at line 540. It updates `lastRpcResponseTime` even when the request is absent,
  then calls `onNextImpl(request, reply)` at lines 553-554.
- In the `SUCCESS` branch, the handler calls
  `getFollower().updateMatchIndex(reply.getMatchIndex())`; only if that returns
  true does it call `getFollower().updateNextIndex(reply.getMatchIndex() + 1)`
  and `onFollowerSuccessAppendEntries` at lines 571-573.
- In the `INCONSISTENCY` branch, if request context is absent,
  `requestFirstIndex` is `RaftLog.INVALID_LOG_INDEX`; the code then calls
  `updateNextIndex(getNextIndexForInconsistency(requestFirstIndex,
  reply.getNextIndex()))` at lines 591-592.
- `updateNextIndex` clears pending requests and unconditionally sets
  `nextIndex` at lines 636-640. The calculation it receives is bounded by
  `LogAppenderBase.getNextIndexForInconsistency`: lines 177-190 choose
  `max(replyNextIndex, matchIndex + 1)` unless that would resend the same first
  entry.
- Follower progress state is monotone for proven progress:
  `FollowerInfoImpl.updateMatchIndex` uses `updateToMax` at lines 92-95, and
  `updateNextIndex` uses `updateToMax` at lines 135-137. `setNextIndex` is
  unconditional at lines 129-131, but the inconsistency calculation above floors
  it at `matchIndex + 1`.

Reachability:

- Public path: `RaftClient` write -> leader `GrpcLogAppender.appendLog` ->
  gRPC `appendEntries` stream -> follower
  `GrpcServerProtocolService.appendEntries` ->
  `RaftServerImpl.appendEntriesAsync` -> follower reply -> leader
  `AppendLogResponseHandler.onNext`.
- The pending-context-absent late success path is reachable by normal gRPC
  replication plus timing assistance: a follower can receive a valid
  AppendEntries request, the leader request timeout removes that call id from
  `pendingRequests`, and the follower can later complete the append and send a
  valid `SUCCESS` reply for the same call id on the same stream.

Safeguards recorded for Phase 2:

- Late `SUCCESS` replies cannot lower progress because `matchIndex` and
  `updateNextIndex` are max-only updates.
- Late `INCONSISTENCY` replies without request context can lower optimistic
  `nextIndex`, but `getNextIndexForInconsistency` floors the value at
  `matchIndex + 1`; that is not below proven follower progress. Clearing pending
  requests can force resends, but the resend path is the normal recovery path.
- The real consumer for harm would be the leader commit/update path:
  `LeaderStateImpl.updateCommit` at lines 1037-1049 and the client write/watch
  path that waits for replication. Phase 2 must check whether a client observes
  failure, lost commit, or non-convergence.

## Developer Knowledge Search

Repository state checked:

- `git fetch origin --prune` completed with no fetched changes affecting the
  relevant files. `HEAD` is `7eedc1deed07fc883bfe448b2d33438b7a0e994e`, matching
  `origin/master` for the affected files.
- `git log origin/master --grep='pendingRequests\|GrpcLogAppender\|late\|out-of-order\|nextIndex\|resetClient\|reconnect\|inconsistency'`
  and path history for `GrpcLogAppender.java` were reviewed.

Related but not same-mechanism history:

- RATIS-458 / commit `99540743e`: pending log request accounting for
  `GrpcLogAppender#shouldWait`; not a report of late replies with absent request
  context corrupting progress.
- RATIS-1074 / commit `50594a565`: `GrpcLogAppender` improperly decreased
  `nextIndex` to 1 and could trigger installSnapshot; not this timeout/cleared
  pending-context late-reply mechanism.
- RATIS-1883 / commit `b8ce6d1f6`: ensures `nextIndex` stays larger than
  `matchIndex`; relevant safeguard history, not a report of this exact late
  reply path.
- RATIS-1909 / PR #939 / commit `b7ffa1ba1`: resetClient error retry must obey
  `matchIndex + 1`; same area and a current safeguard, but it reports reset
  decreasing `nextIndex`, not late success/inconsistency processed without
  pending context.
- RATIS-2135 / PR #1132 / commit `a78e6e2df`: repeated inconsistency replies and
  follower unavailability after CANCELLED/RST_STREAM; the Jira log shows
  `request=AppendEntriesRequest...` for the inconsistency replies, so it is not
  the absent-request-context mechanism in CR-1.
- RATIS-2283 / PR #1250 / commit `21ce4e1fd`: appender thread restart left
  `catchup=false`; related to restart/catch-up state, not pending request
  context loss in late replies.
- RATIS-2605 / PR #1519 / commit `6aafce539`: heartbeat `SUCCESS` should not
  pollute `matchIndex`; relevant to success-reply progress safety, but not a
  duplicate of CR-1's late data-reply/no-pending-context scenario.

Issue/PR tracker search:

- Searched Apache Jira/GitHub through web search and direct issue/PR pages for
  `GrpcLogAppender pendingRequests late reply nextIndex resetClient`,
  `ReceiveSuccessWithoutRequest`, `ReceiveInconsistencyWithoutRequest`,
  `pendingRequests.clear GrpcLogAppender`, and related terms.
- No public issue/PR/CVE/advisory found that reports the exact mechanism:
  a data AppendEntries reply arriving after `pendingRequests` has lost the
  original call-id context and then corrupting follower progress.

## Known Status / Precedent

Known-status result for Phase 1: no same-site same-mechanism upstream report was
found. This code-review finding is not dropped by the code-review x known
pre-filter and proceeds to Phase 2.

Novelty evidence:

- Recent upstream `origin/master` through 2026-08-02 was checked.
- Related historical Ratis issues/PRs were reviewed and did not match the exact
  absent-pending-context late-reply mechanism.
