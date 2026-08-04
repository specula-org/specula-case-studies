# MC-1 Investigation

## Code Audit

Source checkout: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-1/worktree`

HEAD: `7eedc1deed07fc883bfe448b2d33438b7a0e994e` (`origin/master` after `git fetch origin`).

The worktree is dirty from the existing Specula gRPC trace harness. The core upstream logic at the affected site is unchanged: `GrpcLogAppender` still handles `INCONSISTENCY` by computing an inconsistency next index and then unconditionally setting follower `nextIndex`.

### Affected Code

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:561-604`: `AppendLogResponseHandler.onNextImpl` processes append replies. In `INCONSISTENCY`, it computes `requestFirstIndex` and calls `updateNextIndex(getNextIndexForInconsistency(...))`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:636-640`: `updateNextIndex` clears pending append requests and calls `getFollower().setNextIndex(replyNextIndex)`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:757-766`: `InstallSnapshotResponseHandler.onNext` for `ALREADY_INSTALLED` sets `snapshotIndex`, marks snapshot attempted, updates follower commit, and calls `increaseNextIndex(followerSnapshotIndex, reply.getResult())`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:776-786`: `SNAPSHOT_INSTALLED` does the same snapshot progress update and then checks catch-up.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:129-137`: `setNextIndex` is unconditional for non-negative values, while `updateNextIndex` is monotonic max.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:147-150`: `setSnapshotIndex` also sets `matchIndex = snapshotIndex` and `nextIndex = snapshotIndex + 1`.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:177-190`: `getNextIndexForInconsistency` protects `nextIndex >= matchIndex + 1` except for the request-first-index special case (`i != requestFirstIndex`). A stale reply whose request first entry equals `snapshotIndex + 1` can return a lower value.
- `ratis-server-api/src/main/java/org/apache/ratis/server/leader/LogAppender.java:171-219`: `shouldInstallSnapshot` sends a snapshot when follower `nextIndex` is behind leader log start, or when previous log is unavailable at the leader start boundary.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:213-251`: `newAppendEntriesRequest` is a real consumer of the shared follower progress. It returns `null` when `previous == null`, `followerNext > 1`, and `followerNext != snapshotIndex + 1`.

### Call Chain and Reachability

Normal gRPC append flow:

1. A leader `GrpcLogAppender` sends an `AppendEntriesRequest` through the gRPC stream (`GrpcLogAppender.appendLog`, `sendRequest`).
2. A follower receives the stream request in `GrpcServerProtocolService.appendEntries(...).onNext`.
3. `RaftServerImpl.appendEntriesAsync` validates the append. If snapshot installation is in progress, the append overlaps snapshot state, or the previous term/index is missing, `checkInconsistentAppendEntries` returns a positive value and the follower returns `AppendResult.INCONSISTENCY` (`RaftServerImpl.java:1675-1693`, `1745-1778`).
4. The leader response handler receives replies asynchronously in `GrpcLogAppender.AppendLogResponseHandler.onNext`.

Normal snapshot progress flow:

1. The same leader appender decides snapshot installation is needed (`GrpcLogAppender.installSnapshot`, `LogAppender.shouldInstallSnapshot`).
2. The follower replies `ALREADY_INSTALLED` or `SNAPSHOT_INSTALLED`.
3. The leader records snapshot progress with `setSnapshotIndex(followerSnapshotIndex)` and `updateNextIndex(followerSnapshotIndex + 1)`.

The race condition is reachable at the protocol level because append replies and snapshot replies are separate asynchronous RPC streams. A follower can compute an `INCONSISTENCY` reply before the leader records snapshot progress, while the leader processes the snapshot reply first and then later processes the stale append reply.

### Trigger Scenario

Concrete sequence:

1. Leader has compacted/purged logs up to a snapshot boundary.
2. Leader sends an append request to a follower for entries beginning at the boundary (`requestFirstIndex = snapshotIndex + 1`).
3. The follower decides that append is inconsistent and prepares an `INCONSISTENCY` reply with a lower `reply.nextIndex`.
4. Before that append reply is handled by the leader, the leader receives an install-snapshot reply from the follower (`ALREADY_INSTALLED` or `SNAPSHOT_INSTALLED`) and records `snapshotIndex = S`, `matchIndex = S`, `nextIndex = S + 1`.
5. The stale append reply is then handled. Because `requestFirstIndex == matchIndex + 1`, `getNextIndexForInconsistency` does not clamp to `matchIndex + 1`; it can return `reply.nextIndex < S + 1`.
6. `GrpcLogAppender.updateNextIndex` calls `FollowerInfoImpl.setNextIndex`, lowering `nextIndex` below the recorded snapshot boundary.

Safeguards observed:

- `FollowerInfoImpl.updateMatchIndex` and `updateNextIndex` are monotonic, but the stale `INCONSISTENCY` path uses unconditional `setNextIndex`.
- `getNextIndexForInconsistency` normally clamps to `matchIndex + 1`, but deliberately skips that clamp when `matchIndex + 1 == requestFirstIndex`.
- `newAppendEntriesRequest` avoids building an append whose previous entry is unavailable and `followerNext != snapshotIndex + 1`, returning `null` instead.
- `shouldInstallSnapshot` can choose snapshot installation again when `followerNext < leaderStartIndex`; this may mask permanent harm by retrying snapshot work, but it does not prevent the stale reply from losing the already-recorded `nextIndex` progress.

## Developer Knowledge Search

Issue/PR search covered GitHub open and closed issues/PRs with these terms:

- `repo:apache/ratis GrpcLogAppender INCONSISTENCY snapshot nextIndex`
- `repo:apache/ratis stale AppendEntries reply snapshot nextIndex`
- `repo:apache/ratis SnapshotAlreadyInstalled nextIndex`
- `repo:apache/ratis RATIS-1883 GrpcLogAppender`
- `repo:apache/ratis RATIS-1909 GrpcLogAppender`
- `repo:apache/ratis RATIS-558 GrpcLogAppender`
- `repo:apache/ratis RATIS-2283 GrpcLogAppender`

Relevant adjacent history found:

- GitHub PR #914 / commit `b8ce6d1f6`: RATIS-1883, "Next Index should be always larger than Match Index in GrpcLogAppender". This changed success handling near `GrpcLogAppender`, not the stale `INCONSISTENCY` after snapshot progress mechanism.
- GitHub PR #926 / commit `d461a01a5`: RATIS-1895, "IllegalStateException: Failed to updateIncreasingly for nextIndex". This replaced a strict increasing update in the success path with monotonic max update.
- GitHub PR #939 / commit `b7ffa1ba1`: RATIS-1909, "Fix Decreasing Next Index When GrpcLogAppender Reset Client". This added `getNextIndexForError`/`computeNextIndex` for reset-client error handling, not the append `INCONSISTENCY` reply handler.
- GitHub PR #1250: RATIS-2283, "GrpcLogAppender Thread Restart Leaves catchup=false, Blocking Reconfiguration Progress". This is staging/catch-up restart logic, not stale append reply overwriting snapshot progress.
- GitHub PR #573: RATIS-1481, "make state update in notifyStateMachineToInstallSnapshot serialized". This is follower-side snapshot state update ordering.
- GitHub PR #504: RATIS-1402, "do not send extra rpc calls to follower when the follower is still installing a snapshot". This is excessive RPCs during follower-side snapshot installation.

No issue/PR found that reports the exact mechanism: a stale `INCONSISTENCY` append reply processed after `ALREADY_INSTALLED`/`SNAPSHOT_INSTALLED` lowers leader-side follower `nextIndex` below the recorded snapshot boundary.

Blame/developer comments:

- `LogAppenderBase.getNextIndexForInconsistency` comments state that nextIndex should ideally be greater than matchIndex, but skip this in special cases to avoid resending the same first entry.
- `LogAppender.shouldInstallSnapshot` documents snapshot resend conditions when leader lacks follower's next log.
- No local comment or test asserts that a stale append reply may lower nextIndex below `snapshotIndex + 1` after snapshot progress is recorded.

## Known Status

Novelty determination: `NEW`.

Reason: current upstream issue/PR search and git history search found adjacent known problems in the same subsystem but no prior report or merged/closed PR for this exact stale-append-reply-after-snapshot-progress mechanism at `GrpcLogAppender`'s `INCONSISTENCY` branch.

## Repair-loop Continuation

Current continuation source HEAD: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`.

The repair-round counterexample analysis still maps to the current implementation:

- `GrpcLogAppender.AppendLogResponseHandler.onNextImpl` still handles `INCONSISTENCY` by calling
  `updateNextIndex(getNextIndexForInconsistency(requestFirstIndex, reply.getNextIndex()))`
  at `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:586-592`.
- `GrpcLogAppender.updateNextIndex` still clears pending requests and calls
  `getFollower().setNextIndex(replyNextIndex)` at `GrpcLogAppender.java:636-640`.
- `FollowerInfoImpl.setSnapshotIndex` still records snapshot progress by setting
  `snapshotIndex`, `matchIndex`, and `nextIndex = snapshotIndex + 1` at
  `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:147-150`.
- The downstream mask remains present: `LogAppenderBase.newAppendEntriesRequest` returns `null`
  when the previous entry is unavailable and `nextIndex != snapshotIndex + 1`, and
  `LogAppender.shouldInstallSnapshot` retries snapshot work when the follower's next index falls
  before the leader log start.

The prior shell repro target referenced a JUnit class that is not present in the current worktree.
For this continuation I replaced the stale target with
`ratis-server/src/test/java/org/apache/ratis/server/leader/TestSpeculaMC1SnapshotStaleInconsistency.java`
and kept the required executable wrapper at
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro/test_bugMC-1_snapshot_stale_inconsistency.sh`.
The wrapper now fails unless the MC-1 `LEVEL2`, `BUG_STATE`, `MASK_TRIGGER`, and `MASK_RESOLUTION`
markers all appear in the command output.

Novelty refresh: GitHub search API queries on `apache/ratis` for
`GrpcLogAppender INCONSISTENCY snapshot nextIndex`, `"stale AppendEntries reply" snapshot nextIndex`,
and `"ALREADY_INSTALLED" nextIndex GrpcLogAppender`, plus `git log --all --grep` across fetched
history, found adjacent PRs #926, #573, #504, #1227, and #643 but no issue or merged/closed PR
reporting this exact stale `INCONSISTENCY` reply after snapshot progress mechanism.
