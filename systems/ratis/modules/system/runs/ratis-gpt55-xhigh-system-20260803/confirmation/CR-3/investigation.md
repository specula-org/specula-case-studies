# CR-3 Investigation

## Finding

Source: Code Review.

Claim: snapshot catch-up, log purge, restart, and configuration-frontier
interleavings can leave stale or discontinuous follower state.

Primary location: `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:225`.

## Step 1: Code Audit

Relevant code and call chain:

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:245-269` runs the leader appender loop. It calls `installSnapshot()` before sending append entries; if snapshot installation or notification starts, it calls `appendLog(true)` so only heartbeat-style traffic is sent in that iteration.
- `ratis-server-api/src/main/java/org/apache/ratis/server/leader/LogAppender.java:144-163` obtains the previous `TermIndex` from the log or the latest state-machine snapshot. It returns `null` when the previous entry is unavailable.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:225-234` records follower snapshot/next indexes and returns `null` instead of composing append entries when `previous == null`, `followerNext > 0`, and `followerNext != snapshotIndex + 1`.
- `ratis-server-api/src/main/java/org/apache/ratis/server/leader/LogAppender.java:193-219` then classifies the same `followerNext == leaderStartIndex && previous unavailable` frontier as `shouldInstallSnapshot(true)`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:149-160` applies a snapshot-carried raft configuration by truncating later configurations, updating the in-memory configuration, writing the configuration, and notifying the state machine.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:174-252` handles snapshot chunks under `synchronized(server)`, rejects stale same-term chunks via `chunk0CallId`, enforces chunk order through `nextChunkIndex`, writes chunks to temporary storage first, finalizes only on `done`, and calls `state.reloadStateMachine(lastIncluded)`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java:255-389` handles snapshot notifications. It recognizes and persists the leader/term, keeps `inProgressInstallSnapshotIndex`, rejects already-installed snapshots only when `snapshotIndex != -1` and `snapshotIndex + 1 >= firstAvailableLogIndex`, fails pending reads while waiting for the frontier, and returns `SNAPSHOT_INSTALLED` only after moving the asynchronously delivered `installedSnapshotTermIndex` through `state.reloadStateMachine`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:438-442` reloads the state machine, calls `getLog().onSnapshotInstalled(snapshotIndex)`, and records `latestInstalledSnapshot`.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/RaftLogBase.java:263-279` reloads persisted log state on open, updates commit index from metadata entries, opens log state, and advances purge index to `startIndex - 1`.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLog.java:507-529` records the installed snapshot index, synchronizes file-log worker state with the snapshot, closes an open segment already covered by the snapshot, and purges through the snapshot index.

Reachability:

- Normal clients can reach the snapshot frontier by appending enough entries to trigger a snapshot, adding or restarting a lagging follower, and letting the leader catch it up.
- The notification path is reachable when `raft.server.log.appender.install.snapshot.enabled` is disabled and the application state machine supplies snapshots after `notifyInstallSnapshotFromLeader`.
- The configuration frontier is reachable by adding a new peer and committing `setConfiguration` while that peer catches up by snapshot or snapshot notification.
- Restart and purge are reachable through normal server shutdown/restart and snapshot-driven raft-log purge. Some existing tests also delete log files while the server is stopped to model a post-snapshot leader whose old log files are no longer available.

Safeguards recorded for Phase 2:

- Leader appender skips append composition when the previous entry is unavailable and routes to snapshot/notification on the next loop.
- Follower snapshot installation serializes term/leader recognition, chunk ordering, stale chunk detection, and state reload under the server monitor.
- Read requests waiting past the snapshot frontier are failed while snapshot installation is in progress.
- The leader updates follower `snapshotIndex`, `commitIndex`, and `nextIndex` on `ALREADY_INSTALLED` or `SNAPSHOT_INSTALLED` replies.
- Restart/open recomputes commit/purge frontiers from persisted metadata and log start.

Concrete trigger scenario for reproduction:

1. Start a gRPC mini-cluster.
2. Append enough client entries to create a snapshot.
3. Exercise a follower that must catch up across the leader's snapshot/log frontier, both by chunked installSnapshot and by installSnapshot notification.
4. Exercise log purge or removed log files plus restart.
5. Add a peer and commit a new raft configuration across that frontier.
6. Restart a participant and assert leader content, follower log content, latest installed snapshot index, and committed configuration converge instead of leaving stale or discontinuous state.

## Step 2: Developer Knowledge Search

Issue/PR search commands executed against the upstream tracker:

- GitHub API search: `repo:apache/ratis SnapshotInstallationHandler firstAvailableLogIndex`
- GitHub API search: `repo:apache/ratis installSnapshot notification configuration snapshot purge restart`
- GitHub API search: `repo:apache/ratis SNAPSHOT_INSTALLED nextIndex configuration`
- GitHub API search: `repo:apache/ratis snapshot stale configuration state in:title,body`
- GitHub API search: `repo:apache/ratis purge restart configuration snapshot in:title,body`
- Recent closed PR inspection through GitHub API for `apache/ratis`.

Relevant upstream history:

- PR #573 / RATIS-1481, "make state upgradate in notifyStateMachineToInstallSnapshot serialized", reported an older snapshot-notification state-upgrade race. Its body says the state upgrade should be synchronized in the main thread and describes the risk that a leader could see an inconsistency reply with the new index before the follower acknowledges `SNAPSHOT_INSTALLED`. This matches the developer comment now present at `SnapshotInstallationHandler.java:313-323`.
- PR #643 / RATIS-1577, "Install snapshot failure", reported an older `inProgressInstallSnapshotRequest` eligibility failure for notification at first available index 0.
- PR #1053 / RATIS-2045, "SnapshotInstallationHandler doesn't notify follower when snapshotIndex is -1 and firstAvailableLogIndex is 0", fixed the no-snapshot bootstrap notification condition.
- PR #1257 / RATIS-2291, "Fix failing TestInstallSnapshotNotificationWithGrpc#testAddNewFollowersNoSnapshot", refined expected behavior around notification and no-snapshot bootstrap.
- PR #1420 / RATIS-2487, "Trigger installSnapshot if leader cannot get previous entry", states that when the leader cannot get the previous log, `newAppendEntriesRequest` returns `null` and `shouldInstallSnapshot` / `shouldNotifyToInstallSnapshot` should trigger snapshot on the next appender run. It added `LogAppenderTests` coverage for the purged-previous frontier.
- PR #1372 / RATIS-2430, "Write snapshot to temporary path until finish", added temporary snapshot publication before finalize.
- PR #1289 / RATIS-2333, "Fix TestInstallSnapshotNotificationWithGrpc failure", adjusted notification tests and `SnapshotInstallationHandler`.

Comments/docs/tests:

- `SnapshotInstallationHandler.java:313-323` documents the exact stale-nextIndex concern and says follower-side `nextIndex` must be kept upgraded synchronously with the main thread so the leader cannot learn the follower's latest index before `SNAPSHOT_INSTALLED`.
- `LogAppenderTests.java:267-318` creates a purged leader log and then places follower `nextIndex` at the leader start index with the previous entry unavailable. It asserts `newAppendEntriesRequest` returns `null`, follower `nextIndex` remains unchanged, and `shouldInstallSnapshot()` is non-null.
- `InstallSnapshotNotificationTests.java:170-264` starts a one-node cluster with snapshot notification, creates a snapshot, removes old leader log segments while stopped, restarts, adds a new peer, commits configuration, asserts follower installed snapshot index equals the leader snapshot, checks follower log content, restarts the leader, and asserts leader content.

## Step 3: Known Status / Precedent

This is code-review sourced. The upstream search found several fixed historical bugs at adjacent snapshot-frontier sites. I did not find a current upstream issue/PR/CVE/advisory reporting the same current-code defect claimed by CR-3: a stale configuration or log/snapshot gap that survives snapshot installation, purge, or restart in the present code.

Novelty evidence for final entry: `NEW` for the current-code CR-3 mechanism, with related-but-not-identical fixed precedents #573, #643, #1053, #1257, #1372, #1420, and #1289 recorded above.
