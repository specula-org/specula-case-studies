# CR-3 Investigation

## Source

Code Review. The finding has no concrete model-checking counterexample; it asks
whether snapshot installation can interleave with AppendEntries and ReadIndex
state in the implementation.

## Step 1: Code Audit

Relevant current code:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:188-244`
  handles leader-driven snapshot chunks under `synchronized (server)`. It
  rejects stale/out-of-order chunks with `chunk0CallId` and `nextChunkIndex`,
  appends chunks to a temporary snapshot location, and only pauses the state
  machine, finalizes/publishes the snapshot, and reloads state on the final
  chunk.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:276-394`
  handles snapshot notifications. It sets
  `inProgressInstallSnapshotIndex` before invoking the state machine, fails
  queued ReadIndex waiters, stores the async state-machine result in
  `installedSnapshotTermIndex`, and does the actual `state.reloadStateMachine`
  plus `inProgressInstallSnapshotIndex` reset synchronously on the later
  notification reply path.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1099-1152`
  checks `snapshotInstallationHandler.getInProgressInstallSnapshotIndex()` both
  before a follower asks the leader for ReadIndex and when a read is about to be
  enqueued waiting for applied index advancement.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1683-1702`
  documents snapshot installation as an AppendEntries inconsistency case and
  returns `INCONSISTENCY` instead of accepting entries when the in-progress
  snapshot marker is set.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:1756-1762`
  is the concrete AppendEntries guard: a snapshot installation in progress
  returns `state.getNextIndex()`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:426-430`
  reloads the state machine and then calls `getLog().onSnapshotInstalled`.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java:262-267`
  clears the IO queue and resets written/flush/evict indices to the installed
  snapshot index.

Reachable scenario: a leader can legitimately send either snapshot chunks or
snapshot-install notifications to a follower that has fallen behind while
client reads and AppendEntries are also in flight. The current implementation
has explicit guards on the notification path for both ReadIndex and
AppendEntries. On the chunk path, current code no longer publishes a partially
received snapshot; it appends chunks to temporary storage and publishes only on
the final chunk.

Safeguards observed:

- ReadIndex: new requests fail before leader ReadIndex RPC when install is in
  progress, pending waiters are failed when notification starts, and a second
  check prevents a read from enqueueing after the failure sweep.
- AppendEntries: notification-mode install sets an in-progress marker that makes
  `checkInconsistentAppendEntries` reject appends instead of accepting log state
  not covered by either old log or installed snapshot.
- Snapshot publish/reload: chunk-mode install writes to temporary snapshot
  storage until `done=true`; notification-mode reload is delayed until the main
  installSnapshot path reports `SNAPSHOT_INSTALLED`.

## Step 2: Developer Knowledge Search

Upstream issue/PR search and git history found same-site fixes:

- RATIS-2511 / PR #1444: "Follower should throw ReadException if it is
  installing snapshot" was merged on 2026-05-19. The PR says follower reads can
  stall while a snapshot is installing and changes pending/new follower
  linearizable reads to return `ReadException`. It modified
  `RaftServerImpl`, `ReadRequests`, `SnapshotInstallationHandler`, and added
  `ReadOnlyRequestTests.runTestFollowerLinearizableReadFailsWhenInstallingSnapshot`.
  URL: https://github.com/apache/ratis/pull/1444
- RATIS-2430 / PR #1372: "Write snapshot to temporary path until finish" was
  merged on 2026-06-12. The PR describes partial installation state when
  `checkAndInstallSnapshot` called the old direct install path and moved chunk
  writes to temporary storage until final publish. URL:
  https://github.com/apache/ratis/pull/1372
- RATIS-1481 / PR #573: "notifyStateMachineToInstallSnapshot stuck in
  IN_PROGRESS" was resolved as fixed. Its JIRA description covers the
  notification async action, snapshot/commit-index update, and
  `appendEntriesAsync` returning inconsistency before the follower has sent
  `SNAPSHOT_INSTALLED`, causing failed AppendEntries and lost install progress.
  URL: https://issues.apache.org/jira/browse/RATIS-1481
- RATIS-1402 / PR #504: "do not send extra rpc calls to follower when the
  follower is still installing a snapshot" was resolved as fixed and covers
  retrying installSnapshot notifications while follower install is in progress.
  URL: https://github.com/apache/ratis/pull/504
- RATIS-2148 / PR #1145: "Snapshot transfer may cause followers to trigger
  reloadStateMachine incorrectly" changed `SnapshotInstallationHandler` chunk
  ordering state.

Current git history contains the corresponding merged commits:

- `0355d33e0 RATIS-2511. Follower should throw ReadException if it is installing snapshot (#1444)`
- `d430b4d45 RATIS-2430. Write snapshot to temporary path until finish (#1372)`
- `7167fafe7 RATIS-1481. make state upgradate in notifyStateMachineToInstallSnapshot serialized (#573)`
- `b735bb520 RATIS-1402. do not send extra rpc calls to follower when the follower is still installing a snapshot (#504)`
- `54a991623 RATIS-2148. Snapshot transfer may cause followers to trigger reloadStateMachine incorrectly (#1145)`

## Step 3: Known Status / Precedent

This code-review finding duplicates already-reported and already-fixed upstream
defects at the same sites:

- ReadIndex during snapshot install: RATIS-2511 / PR #1444, fixed.
- Partial chunk install state before final publish: RATIS-2430 / PR #1372,
  fixed.
- Notification-mode AppendEntries interleaving with state-machine install
  completion: RATIS-1481 / PR #573, fixed.

Known status: `KNOWN (cite: https://github.com/apache/ratis/pull/1444,
https://github.com/apache/ratis/pull/1372,
https://issues.apache.org/jira/browse/RATIS-1481; fix-status: fixed)`.

## Verification Run

Script executed:
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugCR-3_known_fixed.sh`

Output file:
`/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/CR-3/test_bugCR-3_known_fixed.out`

Result: after adding `-XX:+PerfDisableSharedMem` to work around an OpenJDK
`SIGBUS` in this environment, the upstream regression test passed:

```text
HEAD: 7eedc1deed07fc883bfe448b2d33438b7a0e994e
Known upstream reports/fixes covering this mechanism:
d430b4d45 RATIS-2430. Write snapshot to temporary path until finish (#1372)
0355d33e0 RATIS-2511. Follower should throw ReadException if it is installing snapshot (#1444)
7167fafe7 RATIS-1481. make state upgradate in notifyStateMachineToInstallSnapshot serialized (#573)
b735bb520 RATIS-1402. do not send extra rpc calls to follower when the follower is still installing a snapshot (#504)
[INFO] Running org.apache.ratis.grpc.TestLinearizableReadWithGrpc
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

Status: DROPPED (code-review x known, cite:
https://github.com/apache/ratis/pull/1444,
https://github.com/apache/ratis/pull/1372,
https://issues.apache.org/jira/browse/RATIS-1481; fix-status: fixed).
