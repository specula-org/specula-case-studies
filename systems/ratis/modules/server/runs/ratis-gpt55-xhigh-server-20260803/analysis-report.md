# Code Analysis Report: Apache Ratis `ratis-server`

## Scope

- System: Apache Ratis `ratis-server`
- Repository: `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-server`
- HEAD: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`
- Worktree state observed: clean (`git status --short` returned no output)
- Reference algorithm: Raft consensus
- Category: **Category A (Distributed / Message-Passing)**
- Out of scope per task: gRPC stream internals, client retry policy, Netty, log service, shell, examples, and metrics

The target is a crash-fault replicated state machine implementation. The main correctness boundary is the composition of Raft RPCs, role/term persistence, segmented WAL durability, snapshot install, ReadIndex/lease behavior, and joint consensus reconfiguration. Category B lock-free/runtime methodology was not used as the primary frame.

## Methodology Execution

The installed `code-analysis` skill was followed:

1. Step 0 classification: Category A because the relevant risks are message-passing, disk I/O, crash/recovery, cluster membership, and protocol state-machine transitions.
2. Phase 1 reconnaissance: mapped core files, atomicity boundaries, background loops, and persistence points.
3. Phase 2 bug archaeology: mined git history, GitHub PRs, and ASF JIRA issues; grouped by mechanism rather than file.
4. Phase 3 deep analysis: read the target files and adjacent log/storage/config/snapshot code, checked compensating mechanisms, and classified findings by verification method.
5. Phase 4 synthesis: produced `modeling-brief.md` for Spec Generation and this detailed audit trail.

Reference files read from the skill: `deep-analysis.md`, `distributed-analysis.md`, `bug-archaeology.md`, `modeling-brief-format.md`, and the HashiCorp Raft example.

## Phase 1: Reconnaissance

### Files Read First

The target-specific files were read first:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java`
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java`
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/RaftLogBase.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ReadIndexHeartbeats.java`

Adjacent files read for verification:

- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java`
- `ratis-server-api/src/main/java/org/apache/ratis/server/leader/LogAppender.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderLease.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ConfigurationManager.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftConfigurationImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/impl/PeerConfiguration.java`
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLog.java`
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java`
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/BufferedWriteChannel.java`
- `ratis-server/src/main/java/org/apache/ratis/server/storage/RaftStorageImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/storage/RaftStorageMetadataFileImpl.java`
- `ratis-server/src/main/java/org/apache/ratis/server/storage/SnapshotManager.java`
- `ratis-common/src/main/java/org/apache/ratis/util/DataQueue.java`
- `ratis-server-api/src/main/java/org/apache/ratis/server/protocol/TermIndex.java`

The primary inspected file set totaled about 8,453 LOC.

### Architecture Map

`RaftServerImpl` is the main RPC surface and role-transition coordinator. It handles RequestVote, AppendEntries, InstallSnapshot, StartLeaderElection, client reads, and server lifecycle. It uses `synchronized (this)` or `synchronized (server)` for many role/term critical sections, but delegates log I/O and read completions to asynchronous futures and executors.

`ServerState` owns current term, leader id, voted-for, raft configuration, raft log, state-machine updater, and snapshot indexes. Its class comment states that common state is protected by the RaftServer lock. Term and vote are volatile/atomic in memory and persisted through `RaftStorageMetadataFileImpl`.

`LeaderElection` implements PreVote and election phases. Force election increments term during constructor setup and normal election uses `ServerState.initElection`, which increments term, votes for self, and persists metadata.

`LeaderStateImpl` owns leader-only background loops: appenders, event queue, commit advancement, pending client requests, watch requests, ReadIndex heartbeat listeners, leader lease, and staged reconfiguration. It stops appenders, fails pending reads, and disables lease during `stop`.

`LogAppenderDefault` is an independent per-follower loop for AppendEntries and InstallSnapshot. It updates follower response timestamps before handling reply result and term.

`RaftLogBase` is the abstract log with commit index, snapshot index, purge index, and metadata entries. It caps commit index at `getFlushIndex()` and recovers commit index from metadata entries on open.

`SegmentedRaftLog` keeps an in-memory cache and enqueues disk work to `SegmentedRaftLogWorker`. Cache operations can become visible before disk futures complete.

`SegmentedRaftLogWorker` serializes file I/O through a `DataBlockingQueue`, tracks `lastWrittenIndex`, `flushIndex`, and state-machine data flushing, and optionally uses async or unsafe flush modes.

`SnapshotInstallationHandler` has two modes: direct snapshot chunk installation and state-machine notification. It coordinates leader recognition, term update, state-machine pause/reload, log snapshot sync, in-progress install index, and read failure.

`ReadIndexHeartbeats` tracks heartbeat acknowledgements required for ReadIndex. It uses per-index listener maps and follower commit indexes to decide completion.

### Atomicity Boundaries

- RequestVote term/vote update and metadata persist are inside the RPC handler before the reply is returned.
- AppendEntries leader recognition, role transition, leader id update, inconsistency check, and in-memory config update are inside the server lock, but log append and commit update happen afterward via futures.
- Leader commit is serialized through `LeaderStateImpl` event processing and `RaftLogBase` write lock, but it depends on the log worker's `flushIndex`.
- Log append becomes cache-visible before the file worker future completes.
- Async flush can complete later on a separate executor.
- Snapshot notification and chunk install have separate in-progress, temp, published, and reload states.
- Reconfiguration uses leader-side staging before old/new config, then old/new joint consensus, then stable config append.
- ReadIndex can complete through heartbeat listeners, lease, or configuration that disables the heartbeat check.

## Phase 2: Bug Archaeology

### Coverage

Git history mining:

- Exact core-file keyword scan: 346 unique candidate SHAs.
- Expanded scan over nearby `impl`, `leader`, `raftlog`, `storage`, and `config` paths: 432 unique candidate SHAs.
- Deep-read significant bug-fix commits: 77 SHA/issue groups.

GitHub/JIRA archaeology:

- GitHub collected 305 unique keyword hits from `gh search issues --include-prs`. GitHub Issues are disabled for `apache/ratis`, so these were PR hits.
- Deeply read 73 GitHub PRs with comments.
- For referenced RATIS keys, read 70 ASF JIRA issues/descriptions/comments where available.
- Classification over the 73 deeply read PR artifacts: 44 confirmed bug/fix, 14 design/feature, 7 uncertain/open, 8 excluded as non-bug/test-only.
- Open bug-fix-looking PRs reviewed: 13. Safety-relevant or near-scope open items included #1543, #1540, and #1538. ReadIndex performance/design items included #1455 and #1448. Test/example/leak/data-stream/out-of-scope items included #1446, #1447, #1476, #1539, #1445, #1368, #1363, and #453.

### Required Historical Issues

`RATIS-1995` / PR #1261:

- Type: confirmed fixed bug.
- Mechanism: accidental reformat produced an empty-log peer that could still contribute an election vote, risking loss of committed entries.
- Current code evidence: `LeaderElection.waitForResults` computes `emptyCommit` and requires accepted votes to pass `nonEmptyLog` when candidate commits are non-empty (`LeaderElection.java:517-571`). `nonEmptyLog` treats missing default `(0,0)` as compatible old-version evidence, `(term > 0)` as non-empty, and `(0,-1)` as empty (`LeaderElection.java:606-619`). Vote replies now include `lastEntry`, using `TermIndex.INITIAL_VALUE` when null (`ServerProtoUtils.java:46-54`, `TermIndex.java:31-42`).
- Use in this report: mechanism evidence for recovery/vote/log durability, not an MC target to recreate the closed bug.

`RATIS-2234` / PR #1205:

- Type: confirmed fixed bug.
- Mechanism: lock race between heartbeat and append-log channels.
- Current code evidence: commit updates are guarded by `RaftLogBase` write locking and `getFlushIndex()` (`RaftLogBase.java:122-141`), while log append/truncate/metadata operations run through `runner.runSequentially` (`RaftLogBase.java:217-250`, `RaftLogBase.java:310-361`).
- Use in this report: mechanism evidence for independent leader loops and durable commit boundaries.

`RATIS-1305` / PR #420:

- Type: confirmed fixed bug.
- Mechanism: leader repeatedly attempted snapshot installation when logs had been purged and followers were already effectively caught up.
- Current code evidence: `LogAppenderDefault.run` marks snapshot attempts for `SUCCESS`, `SNAPSHOT_UNAVAILABLE`, `ALREADY_INSTALLED`, and `SNAPSHOT_EXPIRED` (`LogAppenderDefault.java:160-170`); `LogAppender.shouldInstallSnapshot` marks attempted when no snapshot exists so log catch-up can leave staging (`LogAppender.java:193-203`); staging catch-up requires `hasAttemptedToInstallSnapshot` (`LeaderStateImpl.java:828-840`).
- Use in this report: mechanism evidence for snapshot/purge/catch-up interactions.

### Additional Historical Mechanism Groups

Term/vote/election:

- PreVote and vote behavior: PR #161, #1024.
- Old leader after term change: PR #1148.
- Member-change election issues: PR #943, #954, #1140.
- Listener/vote and priority edge cases: PR #739, #378, #789.

Commit/durable log:

- Async flush safety: PR #699.
- File channel close vs async flush: PR #746.
- Missing metadata commit entry: PR #1130.
- Heartbeat success advancing match index: PR #1519.
- Append/catch-up race: PR #983.

Snapshot/catch-up:

- Snapshot install and purge families: PR #137, #207, #360, #489, #573, #868, #878, #933, #1053, #1065, #1091, #1142, #1145, #1159, #1420.

ReadIndex/lease:

- ReadIndex implementation: PR #735, #738.
- Leader lease implementation: PR #897, #898, #925, #928.
- ReadIndex bugs: PR #958, #973, #1052, #1340, #1444.
- Skipped leadership check risk and revert: PR #1334 and revert.

Reconfiguration:

- Listener and setConfiguration behavior: PR #560, #683.
- Add mode and membership expansion: PR #1594.
- Joint majority refactor and membership election: PR #902, #943, #954.
- Concurrent deletion/election and stale config/catch-up: PR #1140, #1246, #1250.
- Open configuration concern: PR #1543.

### Exclusions From Archaeology

Excluded as not useful for this formal-modeling target:

- Pure logging, trace, metric, or output changes.
- SpotBugs, Sonar, Checkstyle, typo, and formatting commits.
- Test-only stability improvements with no production mechanism.
- Netty/RPC-proxy queue corruption and other out-of-scope transport internals.
- Broad feature commits where no concrete correctness mechanism could be tied to core Raft state transitions.

## Phase 3: Deep Analysis Findings

### Finding MC-1: Async Flush Durable Boundary

Classification: Model-checkable and test-verifiable.

Question: With `raft.server.log.async-flush.enabled=true`, can a flush completion publish a later `lastWrittenIndex` than the index actually covered by the completed force, or publish after force/state-machine flush failure?

Evidence:

- `SegmentedRaftLogWorker` reads config flags and rejects `asyncFlush && unsafeFlush` (`SegmentedRaftLogWorker.java:225-232`).
- `flushIfNecessary` creates a state-machine flush future for `lastWrittenIndex`; sync mode waits, async mode passes the future to `asyncFlushOutStream` (`SegmentedRaftLogWorker.java:368-392`).
- `asyncFlushOutStream` calls `out.asyncFlush(flushExecutor).thenCombine(stateMachineFlush, ...)` and then `whenComplete((v, e) -> updateFlushedIndexIncreasingly(lastWrittenIndex))` (`SegmentedRaftLogWorker.java:402-409`). The callback does not test `e` and uses mutable `lastWrittenIndex`.
- `BufferedWriteChannel.asyncFlush` performs `flushBuffer`, schedules `fileChannel.force(false)`, and reports force failure through `CompletionException` (`BufferedWriteChannel.java:144-159`).
- `WriteLog.execute` writes the entry, mutates `lastWrittenIndex`, increments pending flush count, and calls `flushIfNecessary` (`SegmentedRaftLogWorker.java:549-561`).
- Commit is capped at `getFlushIndex()` (`RaftLogBase.java:122-135`), so any premature `flushIndex` publication can become a commit-safety boundary.

Compensating mechanisms:

- `asyncFlush` defaults to false (`RaftServerConfigKeys.java:549-555`).
- The default synchronous path calls `flushOutStream`, waits for state-machine data if needed, and then advances `flushIndex` (`SegmentedRaftLogWorker.java:386-391`).
- `unsafeFlush` is explicit and defaults to false (`RaftServerConfigKeys.java:538-547`).

Why still worth modeling:

The question is not the closed `RATIS-1644` bug. It is a current-code open mechanism question about the callback's captured index and exception handling when async flush is enabled.

### Finding MC-2: Recovery/Election Vote Evidence

Classification: Model-checkable.

Question: Under crash/recovery, accidental empty storage, or mixed-version/default vote replies, can voter-log evidence be insufficient to preserve leader completeness?

Evidence:

- Startup cannot apply log entries because committed status is unknown (`ServerState.java:129-142`).
- Empty unformatted storage can be formatted with default metadata (`RaftStorageImpl.java:95-123`).
- Term and vote are persisted atomically as a pair (`RaftStorageMetadataFileImpl.java:59-83`).
- RequestVote persists term/vote before replying (`RaftServerImpl.java:1519-1533`).
- RequestVote checks candidate membership and last-log evidence (`VoteContext.java:54-60`, `VoteContext.java:136-163`).
- Election discounts empty-log voters when candidate commits are non-empty, but accepts missing default `lastEntry` as compatibility evidence (`LeaderElection.java:517-571`, `LeaderElection.java:606-619`).

Compensating mechanisms:

- Term/vote metadata is atomic, so "term persisted but vote not persisted" is not a current finding.
- Vote reply includes `lastEntry` in current code (`ServerProtoUtils.java:46-54`).
- Empty-log vote discount directly addresses the known `RATIS-1995` pattern.

Why still worth modeling:

The model should explore the general recovery evidence boundary: persisted vote/term, durable log, snapshot coverage, metadata commit, and missing/default reply evidence. The target is mixed recovery states, not a revert of PR #1261.

### Finding MC-3: Snapshot Install vs Append/Read

Classification: Model-checkable and test-verifiable.

Question: Can a follower accept AppendEntries or serve/read-index state that is not covered by either the pre-snapshot log or the completed installed snapshot?

Evidence:

- Snapshot chunk path changes to follower, updates leader, appends chunks, and only final chunk pauses state machine, finalizes snapshot, and reloads (`SnapshotInstallationHandler.java:174-250`).
- Notification path sets `inProgressInstallSnapshotIndex`, fails pending reads, and later reloads when the state machine reports an installed snapshot (`SnapshotInstallationHandler.java:272-396`).
- AppendEntries explicitly rejects while `inProgressInstallSnapshotIndex` is set (`RaftServerImpl.java:1739-1745`).
- ReadIndex forwarding rejects while snapshot is in progress (`RaftServerImpl.java:1099-1107`).
- `ServerState.reloadStateMachine` calls `getLog().onSnapshotInstalled` and updates `latestInstalledSnapshot` (`ServerState.java:425-429`).
- `SegmentedRaftLog.onSnapshotInstalled` updates snapshot index, syncs the worker, closes/purges logs, and returns a purge future (`SegmentedRaftLog.java:507-530`).
- `SegmentedRaftLogWorker.syncWithSnapshot` clears the queue, resets `lastWrittenIndex`, `flushIndex`, and `pendingFlushNum` (`SegmentedRaftLogWorker.java:261-267`).
- `DataQueue.clear` simply clears the queue and byte count (`DataQueue.java:87-90`).

Compensating mechanisms:

- The in-progress index is used to block both AppendEntries and ReadIndex forwarding.
- Chunk install checks order through `nextChunkIndex` in `SnapshotInstallationHandler`.
- Worker execution catches old task I/O exceptions after snapshot and marks them done when the task end index is below `lastWrittenIndex` (`SegmentedRaftLogWorker.java:320-335`).

Residual risks:

- Queued but not dequeued futures may be removed by `queue.clear` without completion.
- Snapshot configuration may be applied in `installSnapshotImpl` whenever `reply != null` and the request contains a last configuration entry, even for non-terminal replies (`SnapshotInstallationHandler.java:149-160`).
- `SnapshotManager` still contains a TODO to verify same requestId/requestIndex ordering and loss across a whole snapshot request cycle (`SnapshotManager.java:118-119`).

### Finding MC-4: ReadIndex/Lease Across Step-Down

Classification: Model-checkable.

Question: With leader lease enabled or heartbeat checking disabled, can a leader use timestamps from an AppendEntries reply before result/term processing causes step-down, allowing a stale read?

Evidence:

- `getReadIndex` returns immediately if heartbeat check is disabled or `hasLease()` is true (`LeaderStateImpl.java:1202-1205`).
- Leader stop fails ReadIndex listeners and disables lease (`LeaderStateImpl.java:460-478`).
- `LogAppenderDefault.sendAppendEntriesWithRetries` updates `lastRespondedAppendEntriesSendTime` immediately after RPC reply, before `handleReply` processes result (`LogAppenderDefault.java:98-105`).
- `handleReply` processes `SUCCESS`, `NOT_LEADER`, and `INCONSISTENCY`, and only calls `onFollowerTerm` for `NOT_LEADER` (`LogAppenderDefault.java:192-225`).
- `LeaderLease.extend` uses follower last-responded timestamps and current/old majority (`LeaderLease.java:68-83`).
- `LeaderStateImpl.onFollowerTerm` queues step-down only when the higher-term follower is considered caught up (`LeaderStateImpl.java:506-512`).
- `ReadIndexHeartbeats` tracks listeners separately from appender send/receive loops and gates by follower commit (`ReadIndexHeartbeats.java:90-117`, `ReadIndexHeartbeats.java:139-160`).

Compensating mechanisms:

- Leader lease defaults to disabled.
- `LeaderStateImpl.isRunning` checks that this LeaderState is still the active role (`LeaderStateImpl.java:703-709`).
- Step-down and stop disable the lease and fail pending ReadIndex listeners.

Why still worth modeling:

The relevant interleaving is before cleanup completes: timestamp observed, lease checked, reply result/term processed, step-down queued, and ReadIndex completed. That is a small independent-loop extension.

### Finding MC-5: Reconfiguration/Catch-Up/Leader Recognition

Classification: Model-checkable and code-review-only.

Question: During staged reconfiguration, can in-memory config or role changes before durable append, or differing membership guards across RPCs, let an out-of-conf or not-yet-caught-up peer affect leadership or commit?

Evidence:

- `startSetConfiguration` adds pending config request and builds staging state for new peers/listeners (`LeaderStateImpl.java:518-540`).
- `checkProgress` requires match index near committed, match index beyond config log index, recent response, and snapshot-attempt flag (`LeaderStateImpl.java:828-840`).
- `applyOldNewConf` appends old/new config and sets it as current conf (`LeaderStateImpl.java:624-640`).
- Transitional majorities require both current and old configs (`RaftConfigurationImpl.java:264-282`).
- `replicateNewConf` updates senders before appending stable new config (`LeaderStateImpl.java:1064-1073`).
- Follower AppendEntries calls `state.updateConfiguration(entries)` before waiting for the log append future (`RaftServerImpl.java:1691-1696`).
- `ServerState.updateConfiguration` removes and adds in-memory configurations and may promote a listener to follower with metadata persistence (`ServerState.java:397-410`).
- RequestVote uses current-conf membership guard (`VoteContext.java:54-60`).
- AppendEntries and InstallSnapshot leader recognition check term and same-term leader conflict, but not current-conf membership (`ServerState.java:329-342`, `RaftServerImpl.java:1655-1668`, `SnapshotInstallationHandler.java:182-190`, `SnapshotInstallationHandler.java:261-270`).

Compensating mechanisms:

- Joint consensus majority requires both old and new majorities.
- AppendEntries success is not returned until append futures complete.
- The leader shuts down after stable config commit if it is no longer in the current configuration (`LeaderStateImpl.java:1034-1053`).
- Removed candidates can be told to shut down through RequestVote logic when conditions match (`RaftServerImpl.java:1469-1483`).

Why still worth modeling:

The interaction composes with snapshots, leader changes, and crash recovery. It is not reducible to one closed historical bug.

## Test-Verifiable Findings

### TV-1: Queue Clear May Leave Append Futures Pending

`SegmentedRaftLogWorker.syncWithSnapshot` clears the worker queue (`SegmentedRaftLogWorker.java:261-267`). `DataQueue.clear` does not complete or fail queued tasks (`DataQueue.java:87-90`). An AppendEntries call that has left the server lock and is awaiting `state.getLog().append(entries)` futures (`RaftServerImpl.java:1693-1711`) could wait indefinitely if its task was queued but not dequeued before snapshot sync.

Suggested verification: inject a delayed worker, enqueue writes, call snapshot install/reload, and assert all returned append futures either complete or fail with a clear exception.

### TV-2: Snapshot Chunk Ordering and Request Identity

`SnapshotInstallationHandler` checks `nextChunkIndex` (`SnapshotInstallationHandler.java:206-228`), but `SnapshotManager.appendSnapshot` still has a TODO to check requestId/requestIndex ordering and lost requests for the whole request cycle (`SnapshotManager.java:118-119`).

Suggested verification: chunk install tests with duplicate chunk, skipped chunk, reordered chunk, and new requestId reuse.

### TV-3: Snapshot Configuration Before Terminal Success

`installSnapshotImpl` applies the request's `lastRaftConfigurationLogEntryProto` for any non-null reply (`SnapshotInstallationHandler.java:149-160`). Notification mode can return `IN_PROGRESS` (`SnapshotInstallationHandler.java:389-396`), and chunk mode returns `SUCCESS` for non-final chunks (`SnapshotInstallationHandler.java:229-250`). If those requests carry a configuration entry, in-memory and persisted config may update before final snapshot publish/reload.

Suggested verification: install-snapshot test that includes last configuration in non-final requests and checks intended config visibility and recovery.

### TV-4: In-Memory Config Update Before Durable Append

Follower AppendEntries updates configuration before durable append futures complete (`RaftServerImpl.java:1691-1696`). `ServerState.updateConfiguration` mutates `ConfigurationManager` and may persist metadata if listener becomes follower (`ServerState.java:397-410`). A failure/crash after config mutation but before append future completion should not leave behavior inconsistent.

Suggested verification: fault-injection test failing append of a config entry after `updateConfiguration`, then issue RequestVote/AppendEntries and restart.

### TV-5: Async Flush Error and Captured Index

The async flush callback does not check `e` and uses mutable `lastWrittenIndex` (`SegmentedRaftLogWorker.java:402-409`). This can be unit-tested by controlling the async force future and writing additional entries before completion.

Suggested verification: fake or instrumented `BufferedWriteChannel.asyncFlush`, failing and delayed futures, assert `flushIndex` and write futures.

## Code-Review-Only Findings

### CR-1: AppendEntries/InstallSnapshot Membership Guard

RequestVote checks whether the candidate is in current conf (`VoteContext.java:54-60`). AppendEntries and InstallSnapshot leader recognition use `ServerState.recognizeLeader`, which checks lower term and same-term conflicting leader but not current-conf membership (`ServerState.java:329-342`). AppendEntries then changes to follower and sets leader (`RaftServerImpl.java:1655-1668`); InstallSnapshot has the same pattern (`SnapshotInstallationHandler.java:182-190`, `SnapshotInstallationHandler.java:261-270`).

Suggested action: review whether non-conf higher-term leaders should be recognized in AppendEntries/InstallSnapshot, and whether bootstrap/listener cases need explicit exceptions.

### CR-2: Reply Term Captured Before Term Update

AppendEntries captures `currentTerm` before `changeToFollowerAndPersistMetadata` (`RaftServerImpl.java:1646-1664`) and uses that captured term in `INCONSISTENCY` and `SUCCESS` replies (`RaftServerImpl.java:1683-1688`, `RaftServerImpl.java:1725-1727`). InstallSnapshot has the same pattern (`SnapshotInstallationHandler.java:176-190`, `SnapshotInstallationHandler.java:248-250`, `SnapshotInstallationHandler.java:384-396`).

Compensation: metadata persistence occurs before reply future completion, and leader-side term handling primarily uses `NOT_LEADER` replies.

Suggested action: decide whether reply term should reflect post-update state for protocol observability and future-proofing.

### CR-3: Higher-Term Follower Step-Down Guard

`LeaderStateImpl.onFollowerTerm` steps down only when the follower is caught up and reports a higher term (`LeaderStateImpl.java:506-512`). This may be intentional for bootstrapping peers, but the guard is based on catch-up status rather than voting membership or configuration phase.

Suggested action: review whether a higher term from a current voting member that is not caught up should force step-down.

### CR-4: Snapshot Configuration Equality and `.conf` I/O

Snapshot config application compares current raft conf with the snapshot config before updating (`SnapshotInstallationHandler.java:149-160`). `RaftConfigurationImpl.equals` delegates to `PeerConfiguration.equals` (`RaftConfigurationImpl.java:354-363`), and `PeerConfiguration.equals` compares only `peers`, not listeners (`PeerConfiguration.java:185-194`). Persisted `.conf` writes and reads log errors but do not propagate failure (`RaftStorageImpl.java:144-164`).

Suggested action: review listener-only snapshot changes and failure behavior for persisted configuration recovery.

### CR-5: Pause/Resume Incomplete Operation Boundary

`RaftServerImpl.pause` and `resume` contain TODOs asking whether pause should be limited to followers and whether additional operations should be paused/resumed (`RaftServerImpl.java:1779-1801`).

Suggested action: review as a maintenance/snapshot lifecycle guard. This is not a primary MC target unless a concrete state transition is identified.

## Negative Findings and Compensating Mechanisms

- Term and vote are not persisted as separate durable writes. `RaftStorageMetadataFileImpl.atomicWrite` writes both values through `AtomicFileOutputStream` (`RaftStorageMetadataFileImpl.java:75-83`).
- RequestVote does not reply granted before term/vote metadata persist. The handler calls `state.persistMetadata()` before constructing the reply (`RaftServerImpl.java:1519-1533`).
- Leader commit does not use `CommitInfoCache`; `CommitInfoCache` is observational/update metadata and not the leader commit decision path. Commit uses follower match indexes and local `flushIndex` (`LeaderStateImpl.java:946-949`, `LeaderStateImpl.java:1088-1090`).
- Leader commit follows the Raft current-term rule (`RaftLogBase.java:131-135`).
- AppendEntries leader commit sent to followers is capped by `effectiveCommitIndex` in request construction (`LeaderStateImpl.java:650-657`).
- Leader stop disables lease and fails ReadIndex listeners (`LeaderStateImpl.java:460-478`).
- Snapshot install uses `inProgressInstallSnapshotIndex` to reject AppendEntries and ReadIndex forwarding while active (`RaftServerImpl.java:1739-1745`, `RaftServerImpl.java:1099-1107`).
- Joint consensus majority logic requires both old and new configurations (`RaftConfigurationImpl.java:264-282`).
- Unsafe flush is explicitly configured as unsafe and defaults to false; it should not be treated as a default correctness bug (`RaftServerConfigKeys.java:538-547`).

## Suggested Spec Focus

The next Spec Generation phase should start with a compact Raft model extended by:

1. Persistent vs volatile server state.
2. WAL cache/write/flush boundaries.
3. Snapshot install in-progress and publish/reload states.
4. ReadIndex heartbeat/lease state separate from AppendEntries reply handling.
5. Staged joint configuration with peer catch-up and distinct RequestVote vs AppendEntries membership guards.

The first MC target should be Scenario 1 or Scenario 5. Scenario 1 is smallest and directly checks crash/durability. Scenario 5 has the highest cross-product value but a larger state space. Scenario 3 should follow because snapshot install composes with both.

## External References Read

- `RATIS-1995`: https://issues.apache.org/jira/browse/RATIS-1995
- PR #1261: https://github.com/apache/ratis/pull/1261
- `RATIS-2234`: https://issues.apache.org/jira/browse/RATIS-2234
- PR #1205: https://github.com/apache/ratis/pull/1205
- `RATIS-1305`: https://issues.apache.org/jira/browse/RATIS-1305
- PR #420: https://github.com/apache/ratis/pull/420
- Additional PRs used as grouped mechanism evidence: #699, #718, #735, #738, #897, #898, #925, #928, #958, #973, #1052, #1130, #1140, #1246, #1250, #1334, #1340, #1420, #1444, #1519, #1540, #1543.
