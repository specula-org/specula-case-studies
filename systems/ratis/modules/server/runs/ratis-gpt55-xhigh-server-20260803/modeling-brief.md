# Modeling Brief: Apache Ratis `ratis-server`

## 1. System Overview

Apache Ratis `ratis-server` is a Java implementation of the Raft consensus algorithm. This analysis focused on the core server state-transition paths in `ratis-server`, with about 8.4k LOC read in the primary file set covering RPC handlers, leader state, election, log persistence, snapshot install, and ReadIndex.

Category: **Category A (Distributed / Message-Passing)**. The primary correctness risks are Raft RPC ordering, crash/recovery, durable log state, snapshots, membership changes, and independent leader/follower background loops. This is a crash-fault Raft system, not a BFT system and not primarily a lock-free runtime.

Important implementation choices beyond the reference Raft paper include PreVote, leader lease, ReadIndex heartbeats, staged peer catch-up before joint consensus, listener roles, segmented WAL workers with optional async flush, metadata log entries for recovered commit index, and two snapshot install modes: chunk transfer and state-machine notification.

## 2. Scenarios

### Scenario 1: Durable Commit Boundary vs Async Log Flush

**Mechanism**: Commit advancement depends on a local durable boundary, but the implementation splits cache append, worker write, file force, state-machine-data flush, metadata entry append, and crash recovery across separate steps.

**Evidence**:
- Historical: `RATIS-1644` / PR #699 made async flush wait before updating commit; `RATIS-2134` / PR #1130 fixed missing `metadataEntry(lastCommitIndex)`; `RATIS-2234` / PR #1205 fixed a lock race between heartbeat and append-log channels.
- Code analysis: leader commit uses follower `matchIndex` plus local `raftLog.getFlushIndex()` (`LeaderStateImpl.java:946-949`, `LeaderStateImpl.java:1088-1090`); `RaftLogBase.updateCommitIndex` caps commit at `getFlushIndex()` and applies the leader current-term rule (`RaftLogBase.java:122-135`); async flush completes by calling `updateFlushedIndexIncreasingly(lastWrittenIndex)` without capturing the index at flush start or checking the completion exception (`SegmentedRaftLogWorker.java:402-409`); metadata entries are marked as `lastMetadataEntry` immediately after append is enqueued (`RaftLogBase.java:217-235`).

**Affected code paths**: `LeaderStateImpl.updateCommit`, `LeaderStateImpl.logMetadata`, `RaftLogBase.updateCommitIndex`, `RaftLogBase.appendMetadata`, `RaftLogBase.open`, `SegmentedRaftLogWorker.flushIfNecessary`, `SegmentedRaftLogWorker.asyncFlushOutStream`, `SegmentedRaftLogWorker.WriteLog.execute`.

**Suggested modeling approach**:
- Variables: `volatileLog`, `diskLog`, `writeQueue`, `lastWrittenIndex`, `flushIndex`, `flushInFlightIndex`, `commitIndex`, `metadataCommitIndex`, `stateMachineDataFlushed`.
- Actions: split append into cache-visible append, worker write, flush start, flush completion, commit advancement, metadata append, crash, and recovery.
- Granularity: split flush start and flush completion; capture both successful and failed force completions. Keep unsafe flush as a separate optional action disabled by default.

**Priority**: High
**Rationale**: This is directly tied to Raft safety after crash and to several historical fixes. It is also a small, precise extension to the reference spec.

### Scenario 2: Recovered or Reformatted Voter in Election

**Mechanism**: A recovering peer may have term/vote metadata, log state, snapshot state, configuration state, and commit evidence that do not agree, yet vote replies participate in leader election.

**Evidence**:
- Historical: `RATIS-1995` / PR #1261 fixed a data-loss scenario where an accidentally reformatted voter helped elect a leader without committed entries. `RATIS-1677` / PR #718 stopped auto-format during recovery mode.
- Code analysis: startup loads persisted configuration, state machine, then term/vote metadata, but cannot apply log entries because committed status is unknown (`ServerState.java:129-142`); storage can format empty directories with default metadata (`RaftStorageImpl.java:95-123`); vote handling persists term/vote before constructing the reply (`RaftServerImpl.java:1496-1542`); votes reject candidates outside current conf (`VoteContext.java:54-60`) and compare last log entry (`VoteContext.java:136-163`); election now discounts empty-log voters when the candidate has non-empty commits (`LeaderElection.java:517-571`, `LeaderElection.java:606-619`), while missing `lastEntry` is treated as compatible old-version evidence.

**Affected code paths**: `ServerState.initialize`, `RaftStorageImpl.analyzeAndRecoverStorage`, `RaftServerImpl.requestVote`, `VoteContext.recognizeCandidate`, `VoteContext.decideVote`, `LeaderElection.waitForResults`, `ServerProtoUtils.toRequestVoteReplyProto`.

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVote`, `diskLog`, `snapshotIndex`, `metadataCommitIndex`, `reformatted`, `voteReplyLastEntryKind`, `currentConf`.
- Actions: format empty storage, recover from metadata, recover from snapshot and log, request vote, accept/discount vote reply, elect leader.
- Granularity: split recovery into metadata load, configuration load, log open, and snapshot discovery. Represent vote replies with explicit `lastEntry` states: valid, empty, and missing/default.

**Priority**: High
**Rationale**: The exact historical bug is fixed, but the mechanism remains central to crash safety and mixed-version/recovery behavior.

### Scenario 3: Snapshot Install vs AppendEntries and ReadIndex

**Mechanism**: Snapshot installation has chunk, notification, temporary-file, state-machine reload, log purge, read failure, append rejection, and configuration update sub-states that are not atomic.

**Evidence**:
- Historical: `RATIS-1305` / PR #420 fixed an infinite install-snapshot loop after log purge; related snapshot/catch-up fixes include PRs #489, #573, #868, #878, #933, #1053, #1091, #1159, and #1420. Open PR #1540 indicates install-snapshot chunk-loop pressure is still an active area.
- Code analysis: snapshot chunk handling recognizes the leader, changes to follower, appends chunks, and reloads the state machine only on the final chunk (`SnapshotInstallationHandler.java:174-250`); notification mode sets `inProgressInstallSnapshotIndex`, fails reads, and later reloads state machine (`SnapshotInstallationHandler.java:272-396`); AppendEntries rejects while a snapshot is in progress (`RaftServerImpl.java:1739-1745`); ReadIndex forwarding fails while snapshot install is in progress (`RaftServerImpl.java:1099-1107`); snapshot reload calls `RaftLog.onSnapshotInstalled` (`ServerState.java:425-429`), which clears the log worker queue and resets durable indices (`SegmentedRaftLogWorker.java:261-267`).

**Affected code paths**: `SnapshotInstallationHandler.installSnapshotImpl`, `SnapshotInstallationHandler.checkAndInstallSnapshot`, `SnapshotInstallationHandler.notifyStateMachineToInstallSnapshot`, `RaftServerImpl.checkInconsistentAppendEntries`, `RaftServerImpl.sendReadIndexAsync`, `ServerState.reloadStateMachine`, `SegmentedRaftLog.onSnapshotInstalled`, `SegmentedRaftLogWorker.syncWithSnapshot`.

**Suggested modeling approach**:
- Variables: `snapshotInProgressIndex`, `tempSnapshot`, `snapshotPublished`, `installedSnapshot`, `logStartIndex`, `nextIndex`, `pendingReadIndexes`, `appendReplyPending`, `workerQueue`.
- Actions: snapshot notification, chunk append, final chunk publish, state-machine reload, append during snapshot, read during snapshot, queue clear, crash/recover.
- Granularity: split notification from installation completion. Split chunk append from final publish/reload. Model append/read rejection while `snapshotInProgressIndex` is set.

**Priority**: High
**Rationale**: Snapshot install has high historical bug density and naturally composes with recovery, log truncation, and ReadIndex safety.

### Scenario 4: ReadIndex and Leader Lease Across Leadership Change

**Mechanism**: Linearizable reads are served by independent heartbeat/appender loops and optional leader lease state; reply timestamps, reply result processing, term changes, and listener completion are not one atomic Raft action.

**Evidence**:
- Historical: ReadIndex and lease work includes PRs #735, #738, #897, #898, #925, #928, with bug fixes around ReadIndex races and leadership checks in PRs #958, #973, #1052, #1340, and #1444. PR #1334 explicitly documented stale-read risk when skipping leadership check and was later reverted.
- Code analysis: `getReadIndex` may return immediately when heartbeat checking is disabled or lease is valid (`LeaderStateImpl.java:1181-1218`); leader stop fails pending ReadIndex listeners and disables the lease (`LeaderStateImpl.java:460-478`); appender receive path updates `lastRespondedAppendEntriesSendTime` before `handleReply` processes `SUCCESS`, `NOT_LEADER`, or `INCONSISTENCY` (`LogAppenderDefault.java:98-105`, `LogAppenderDefault.java:192-225`); `LeaderLease.extend` decides from response timestamps and current/old majority (`LeaderLease.java:68-83`); `ReadIndexHeartbeats` records heartbeat listeners and gates ack by follower commit (`ReadIndexHeartbeats.java:90-117`, `ReadIndexHeartbeats.java:139-160`).

**Affected code paths**: `LeaderStateImpl.getReadIndex`, `LeaderStateImpl.hasLease`, `LeaderStateImpl.stop`, `LeaderStateImpl.onAppendEntriesReply`, `ReadIndexHeartbeats.addAppendEntriesListener`, `ReadIndexHeartbeats.onAppendEntriesReply`, `LogAppenderDefault.sendAppendEntriesWithRetries`, `LogAppenderDefault.handleReply`, `LeaderLease.extend`.

**Suggested modeling approach**:
- Variables: `leaderStateGeneration`, `role`, `term`, `leaseEnabled`, `leaseUntil`, `lastRespondedAppendEntriesSendTime`, `readIndexListeners`, `ackedCommitIndex`, `replyResult`.
- Actions: send heartbeat, receive reply timestamp, process reply result/term, complete ReadIndex listener, check lease, step down, fail listeners.
- Granularity: split "receive AppendEntries reply" into timestamp observation and result/term processing. Keep leader lease disabled in the base model and enable it for a targeted configuration.

**Priority**: Medium
**Rationale**: The default lease is disabled and stop has strong cleanup, but this is a high-value linearizability scenario when lease or skipped heartbeat checks are enabled.

### Scenario 5: Reconfiguration, Catch-Up, and Leader Recognition

**Mechanism**: Membership changes pass through staging, old/new joint consensus, follower catch-up, listener promotion, sender updates, and persisted configuration; several RPC paths do not use identical membership guards.

**Evidence**:
- Historical: reconfiguration/catch-up fixes include `RATIS-1912`, `RATIS-2146` / PR #1140, `RATIS-2274` / PR #1246, and `RATIS-2283` / PR #1250. Open PR #1543 is also configuration-related.
- Code analysis: staging starts by adding new senders before old/new configuration is appended (`LeaderStateImpl.java:518-540`); a follower is considered caught up only after match index, conf index, recent response, and snapshot-attempt gates pass (`LeaderStateImpl.java:828-840`); old/new config is appended and immediately becomes in-memory current conf (`LeaderStateImpl.java:624-640`); joint majority requires both old and new configs (`RaftConfigurationImpl.java:264-282`); follower AppendEntries updates in-memory configuration before the log append futures complete (`RaftServerImpl.java:1691-1696`, `ServerState.java:397-410`); vote requests check current-conf membership (`VoteContext.java:54-60`) but leader recognition for AppendEntries/InstallSnapshot checks only term and same-term leader conflict (`ServerState.java:329-342`, `RaftServerImpl.java:1655-1668`, `SnapshotInstallationHandler.java:182-190`, `SnapshotInstallationHandler.java:261-270`).

**Affected code paths**: `LeaderStateImpl.startSetConfiguration`, `LeaderStateImpl.checkProgress`, `LeaderStateImpl.applyOldNewConf`, `LeaderStateImpl.replicateNewConf`, `RaftConfigurationImpl.hasMajority`, `RaftServerImpl.appendEntriesAsync`, `SnapshotInstallationHandler.checkAndInstallSnapshot`, `SnapshotInstallationHandler.notifyStateMachineToInstallSnapshot`, `ServerState.updateConfiguration`, `VoteContext.checkConf`.

**Suggested modeling approach**:
- Variables: `currentConf`, `oldConf`, `stagingPeers`, `caughtUp`, `attemptedSnapshot`, `confLogIndex`, `durableConfLogIndex`, `recognizedLeader`, `voterRole`.
- Actions: start staging, bootstrap follower, append old/new conf, commit old/new conf, append stable conf, follower receives conf entry, crash before append durable, removed peer sends AppendEntries/Snapshot.
- Granularity: split leader-side config append from in-memory `setRaftConf`; split follower config update from durable log append. Add distinct RequestVote and AppendEntries membership guards.

**Priority**: High
**Rationale**: Configuration changes are repeatedly bug-dense and interact with election, catch-up, snapshot, and recovery. This is a natural Category A cross-product scenario.

## 3. Modeling Recommendations

### 3.1 Model

- **Persistent vs in-memory state**: Model term/vote, WAL, snapshot index, configuration, commit metadata, and volatile role/conf separately. This supports Scenarios 1, 2, 3, and 5.
- **Segmented WAL durable boundary**: Model cache append, worker write, flush completion, and `flushIndex` separately. This supports Scenario 1.
- **Snapshot lifecycle**: Model notification, chunks, publish/reload, queue clearing, append rejection, and read rejection. This supports Scenario 3.
- **ReadIndex heartbeat and lease loops**: Model heartbeat-triggered ReadIndex ack separately from AppendEntries reply result processing and leader step-down. This supports Scenario 4.
- **Joint consensus plus staging**: Model staging catch-up before old/new config, then old/new and stable config entries, with RequestVote and AppendEntries membership guards represented separately. This supports Scenario 5.

### 3.2 Do Not Model

- **gRPC stream internals, Netty, client retry policy, log service, shell, examples, and metrics**: out of scope for this run and not needed to capture core Raft state transitions.
- **Unsafe flush as a default behavior**: `raft.server.log.unsafe-flush.enabled` is explicitly unsafe and defaults to false. Include only as an optional fault injection, not in the base correctness model.
- **Closed historical bugs as direct targets**: `RATIS-1995`, `RATIS-2234`, and `RATIS-1305` should be reference evidence, not MC targets that simply recreate pre-fix code.
- **Low-level file chunk I/O correctness**: chunk checksum/offset details are better tested directly unless they affect the abstract snapshot lifecycle.
- **Logging, metrics, trace, checkstyle, and pure test-flake commits**: these were excluded during archaeology.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|-----------|-----------|---------|----------|
| PersistentStateSplit | `persistedTerm`, `persistedVote`, `diskLog`, `snapshotIndex`, `metadataCommitIndex`, `volatileRole` | Capture crash/recovery and non-atomic durable state | 1, 2, 3, 5 |
| WalFlushBoundary | `volatileLog`, `writeQueue`, `lastWrittenIndex`, `flushIndex`, `flushInFlightIndex`, `stateMachineDataFlushed` | Check commit never outruns durable log state | 1 |
| SnapshotLifecycle | `snapshotInProgressIndex`, `tempSnapshot`, `snapshotPublished`, `installedSnapshot`, `workerQueue` | Capture snapshot/append/read interleavings | 3 |
| ReadIndexLeaseLoop | `leaderStateGeneration`, `leaseEnabled`, `leaseUntil`, `readIndexListeners`, `ackedCommitIndex`, `replyResult` | Check linearizable read completion across step-down | 4 |
| StagedJointConfig | `currentConf`, `oldConf`, `stagingPeers`, `caughtUp`, `attemptedSnapshot`, `durableConfLogIndex` | Capture peer catch-up, old/new majority, and RPC guard differences | 5 |
| VoteEvidence | `voteReplyLastEntryKind`, `reformatted`, `candidateLastEntry`, `candidateCommitKnown` | Capture empty or missing voter-log evidence during election | 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader can be elected in a term. | Standard Raft, Scenario 2, Scenario 5 |
| LeaderCompleteness | Safety | A leader elected for a later term contains every committed entry from earlier terms or an installed snapshot covering it. | Scenario 2, Scenario 5 |
| LogMatching | Safety | Logs sharing an index and term have the same prefix, including after truncate and snapshot install. | Scenario 1, Scenario 3 |
| CommittedImpliesDurableFlush | Safety | A server's committed index never exceeds the durable log or snapshot boundary it can recover after crash. | Scenario 1 |
| RecoveredCommitCovered | Safety | After recovery, `metadataCommitIndex` is covered by the recovered disk log or installed snapshot. | Scenario 1, Scenario 2, Scenario 3 |
| SnapshotInstallExclusion | Safety | While snapshot install is in progress, AppendEntries cannot succeed with entries that leave a gap or overlap before the install boundary. | Scenario 3 |
| ReadIndexRequiresCurrentLeader | Safety | A successful ReadIndex reply must come from a live LeaderState for the server's current term and current configuration. | Scenario 4 |
| NoOldLeaderLeaseRead | Safety | A leader lease cannot justify a read after a higher-term or not-leader reply has been observed but before step-down cleanup completes. | Scenario 4 |
| JointConfigMajorityOverlap | Safety | Transitional configuration commit requires majorities in both old and new voter sets. | Scenario 5 |
| DurableConfigMatchesRecoveredRole | Safety | After crash/recovery, a server's voter/listener role and current configuration must be derivable from durable log/snapshot/config state. | Scenario 5 |
| SnapshotEventuallyClearsOrFails | Liveness | A snapshot install notification eventually clears, succeeds, or fails under fair state-machine response. | Scenario 3 |
| ReadIndexEventuallyCompletesOrFails | Liveness | A pending ReadIndex future eventually completes or fails under fair heartbeat response or leadership loss. | Scenario 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|----|-------------|------------------------------|----------|
| MC-1 | With `asyncFlush` enabled, can a flush completion publish a later `lastWrittenIndex` than the index covered by the completed force or publish after a force/state-machine flush failure? | `CommittedImpliesDurableFlush`, `RecoveredCommitCovered` | Scenario 1 |
| MC-2 | Under crash/recovery or mixed-version vote replies, can empty or missing voter-log evidence help elect a leader missing a previously committed prefix? | `LeaderCompleteness`, `ElectionSafety` | Scenario 2 |
| MC-3 | Can snapshot notification/chunk install interleave with AppendEntries or ReadIndex so that a follower accepts a log/read state not covered by either the old log or installed snapshot? | `SnapshotInstallExclusion`, `LogMatching`, `ReadIndexRequiresCurrentLeader` | Scenario 3 |
| MC-4 | With leader lease or skipped heartbeat checking enabled, can AppendEntries reply timestamps refresh the lease before reply result/term processing forces step-down, allowing a stale ReadIndex result? | `NoOldLeaderLeaseRead`, `ReadIndexRequiresCurrentLeader` | Scenario 4 |
| MC-5 | During staged reconfiguration, can in-memory config/role changes before durable append or differing RPC membership guards allow a removed or not-yet-caught-up peer to affect leadership or commit? | `JointConfigMajorityOverlap`, `DurableConfigMatchesRecoveredRole`, `LeaderCompleteness` | Scenario 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| TV-1 | `SegmentedRaftLogWorker.syncWithSnapshot` clears the queue without completing queued append futures. | Unit test with queued `WriteLog` tasks, snapshot install, and assertion that waiting AppendEntries futures complete or fail. |
| TV-2 | Snapshot chunk order/request identity is guarded partly outside `SnapshotManager`, which still has a TODO for requestId/requestIndex ordering. | Snapshot chunk integration test with duplicate, skipped, and reordered chunks across requestIds. |
| TV-3 | Snapshot configuration may be applied when `installSnapshotImpl` receives a non-null non-terminal reply carrying `lastRaftConfigurationLogEntryProto`. | InstallSnapshot notification/chunk test asserting intended config visibility before and after terminal success. |
| TV-4 | Follower configuration entries update in-memory conf before log append futures complete. | Fault-injection test that fails log append after a config entry and checks subsequent RPC decisions and recovery. |
| TV-5 | Async flush callback should not advance `flushIndex` after failed force or beyond the captured force-start index. | Unit test with controlled `BufferedWriteChannel.asyncFlush` future and concurrent writes. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| CR-1 | AppendEntries and InstallSnapshot leader recognition do not mirror RequestVote's current-conf candidate guard. | Review whether higher-term/same-term unknown leaders outside current conf should be rejected or allowed only for bootstrap cases. |
| CR-2 | AppendEntries and InstallSnapshot replies may carry the old `currentTerm` captured before `changeToFollowerAndPersistMetadata` updates the local term. | Decide whether reply term should be recomputed after term persistence for protocol clarity. |
| CR-3 | `LeaderStateImpl.onFollowerTerm` only steps down for a higher-term follower if that follower is caught up. | Review whether the guard should depend on voting membership/staging role rather than catch-up status. |
| CR-4 | Snapshot config equality ignores listener-only differences through `PeerConfiguration.equals`, and `.conf` read/write errors are logged but not propagated. | Review recovery/config semantics for listener-only snapshot changes and persisted conf I/O failures. |
| CR-5 | Pause/resume comments in `RaftServerImpl` explicitly ask whether more operations must be paused/resumed. | Treat as a human audit item for snapshot/state-machine maintenance operations. |

## 7. Reference Pointers

- Detailed audit trail: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/analysis-report.md`
- Target repo: `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-server` at `7eedc1deed07fc883bfe448b2d33438b7a0e994e`
- Core source files: `RaftServerImpl.java`, `LeaderStateImpl.java`, `LeaderElection.java`, `VoteContext.java`, `ServerState.java`, `LogAppenderBase.java`, `LogAppenderDefault.java`, `RaftLogBase.java`, `SegmentedRaftLog.java`, `SegmentedRaftLogWorker.java`, `SnapshotInstallationHandler.java`, `ReadIndexHeartbeats.java`
- Required historical references: `RATIS-1995` / PR #1261, `RATIS-2234` / PR #1205, `RATIS-1305` / PR #420
- Additional reference PRs/issues used as mechanism evidence: PRs #699, #718, #735, #738, #897, #898, #925, #928, #958, #973, #1052, #1130, #1140, #1246, #1250, #1334, #1340, #1420, #1444, #1519, #1540, #1543
