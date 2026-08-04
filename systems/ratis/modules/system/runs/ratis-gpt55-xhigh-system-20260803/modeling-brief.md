# Code Analysis Modeling Brief: ratis-system

## 1. System Overview

Apache Ratis is a Java implementation of the Raft consensus algorithm. This analysis focused on the end-to-end Raft path across `ratis-server`, `ratis-grpc`, persistent log/snapshot storage, commit, read-index, and membership change. The six primary files requested by the target instructions total 5,526 lines, with additional storage, configuration, read, and appender helpers inspected. Category: **Category A (Distributed / Message-Passing)**, because safety depends on RPC ordering, crashes/restarts, durable metadata, log replication, snapshot transfer, and cluster reconfiguration. It is not BFT.

Ratis deviates from a minimal Raft spec through asynchronous log append/flush, gRPC streaming appenders, chunked snapshot installation, `ReadIndex` with optional heartbeat/lease modes, listeners, joint and staged configuration changes, and implementation-level role lifecycle state. The relevant concurrency model is multi-threaded and future-based: RPC handlers, leader event processing, log appender threads, log worker flushing, snapshot installation, state-machine updater, and read queues all communicate through locks, futures, atomics, and persistent storage.

## 2. Scenarios

### Scenario 1: In-flight append composition across leader change

**Mechanism**: The follower's append composition cache coalesces in-flight append ranges by index shape, but the Raft overwrite rule requires term/content comparison when a new leader sends overlapping entries.

**Evidence**:
- Historical: #1248 (`39acebf88bc2a015c0f86f48d9334cb86a820893`) fixed duplicate in-flight append handling, showing this path is safety-sensitive.
- Code analysis: compose is default-enabled at `RaftServerConfigKeys.java:475`; follower append uses `appendLogTermIndices.append` at `RaftServerImpl.java:1695`; `NavigableIndices.append` reuses an existing future at `ServerImplUtils.java:148`; `alreadyExists` checks only start-index overlap at `ServerImplUtils.java:153`; the real log truncate/append path is in `SegmentedRaftLog.java:470`; success replies let leaders advance match/next at `LogAppenderDefault.java:197` and `GrpcLogAppender.java:512`.

**Affected code paths**: `RaftServerImpl.appendEntriesAsync`, `ServerImplUtils.NavigableIndices.append`, `SegmentedRaftLog.appendImpl`, `LogAppenderDefault.AppendEntriesResponseHandler`, `GrpcLogAppender.AppendEntriesResponseHandler`.

**Suggested modeling approach**:
- Variables: `inFlightAppend[server]`, `log[server]`, `leaderEpoch`, `appendFutureDone`, `replyStatus`, `matchIndex`.
- Actions: split follower AppendEntries into `RegisterInFlight`, `CompletePhysicalAppend`, and `ReplyAppend`; allow leader change between them.
- Granularity: do not model AppendEntries as atomic; split cache registration, disk append/truncation, and reply.

**Priority**: High. **Rationale**: This is a new forward-looking mechanism question with direct LogMatching and LeaderCompleteness exposure, not merely a closed historical regression.

### Scenario 2: Term, role, and metadata persistence are non-atomic

**Mechanism**: Ratis changes volatile role/term/leader state and persistent metadata through separate steps, and some asynchronous step-down events are de-duplicated by type rather than by term.

**Evidence**:
- Historical: #1148 (`5578be7fb07e52cfa90e2979fd251ae78badfc62`) fixed old-leader behavior after term update; #863 (`4089b0e6e86ad600b81cc19378ee242e8db84ff0`) fixed election state not resetting on all follower transitions; #799, #895, and #1300 show role lifecycle ordering bugs.
- Code analysis: `ServerState.updateCurrentTerm` mutates volatile term/vote/leader at `ServerState.java:211`; `RaftServerImpl.changeToFollowerAndPersistMetadata` persists only after role change at `RaftServerImpl.java:638`; AppendEntries catches persistence error and returns a failed future at `RaftServerImpl.java:1664`; later same-term AppendEntries may no longer set `metadataUpdated`; restart reads metadata at `ServerState.java:139`. `StateUpdateEvent.equals` compares only event type at `LeaderStateImpl.java:129`, and `EventQueue.submit` drops duplicate types at `LeaderStateImpl.java:156`, while `submitStepDownEvent(term, reason)` captures a concrete term at `LeaderStateImpl.java:738`.

**Affected code paths**: `RaftServerImpl.changeToFollower`, `RaftServerImpl.changeToFollowerAndPersistMetadata`, `RaftServerImpl.appendEntriesAsync`, `RaftServerImpl.requestVoteAsync`, `LeaderStateImpl.submitStepDownEvent`, `ServerState.updateCurrentTerm`, `ServerState.persistMetadata`.

**Suggested modeling approach**:
- Variables: `volatileTerm`, `persistedTerm`, `votedFor`, `leaderId`, `role`, `leaderStateAlive`, `queuedStepDownTerm`, `persistFailure`.
- Actions: split `ObserveHigherTerm`, `ChangeRole`, `PersistMetadata`, `AcceptAppend`, `CrashRestart`, and `ProcessStepDownEvent`.
- Granularity: model one-shot persistence failure and event coalescing as separate nondeterministic actions.

**Priority**: High. **Rationale**: Raft assumes term/vote persistence before future protocol acceptance. The current code has verified non-atomic boundaries and a concrete event coalescing hazard.

### Scenario 3: Snapshot, purge, restart, and configuration frontier

**Mechanism**: Snapshot installation and notification bridge several frontiers (`snapshotIndex`, `firstAvailableLogIndex`, `commitIndex`, `nextIndex`, configuration at snapshot), and historical bugs cluster around stale, missing, or out-of-order frontier updates.

**Evidence**:
- Historical: #1420, #1053, #89, #745, and #360 fixed purge/snapshot boundary bugs; #1145, #1159, and #1173 fixed chunk order, duplicate, and stale-stream bugs; #1091 fixed old snapshot and config truncation after leader switch; #253 fixed missing configuration propagation in snapshots.
- Code analysis: appender switches to snapshot/notification when previous log is unavailable at `LogAppenderBase.java:225` and `GrpcLogAppender.java:241`; snapshot notification guards invalid snapshot index at `SnapshotInstallationHandler.java:272`; snapshot chunk order/callId gates are at `SnapshotInstallationHandler.java:193` and `SnapshotInstallationHandler.java:209`; install applies configuration and truncates state at `SnapshotInstallationHandler.java:149`; `ServerState.reloadStateMachine` updates snapshot/log state at `ServerState.java:425`; restart/open applies metadata and configuration from log at `RaftLogBase.java:263`.

**Affected code paths**: `LogAppenderBase.newAppendEntriesRequest`, `GrpcLogAppender.installSnapshot`, `SnapshotInstallationHandler.checkAndInstallSnapshot`, `SnapshotInstallationHandler.installSnapshotImpl`, `ServerState.reloadStateMachine`, `ConfigurationManager.removeConfigurations`, `RaftLogBase.open`.

**Suggested modeling approach**:
- Variables: `logStart`, `logEnd`, `snapshotIndex`, `installedSnapshotIndex`, `firstAvailableLogIndex`, `installingSnapshot`, `chunk0CallId`, `nextChunkIndex`, `configAtIndex`, `nextIndex`.
- Actions: split `NotifyInstallSnapshot`, `SendSnapshotChunk`, `FinalizeSnapshot`, `ReloadStateMachine`, `PurgeLog`, `LeaderChange`, and `Restart`.
- Granularity: model snapshots as indexed summaries with optional config payload, not full state-machine data.

**Priority**: High. **Rationale**: High bug density, direct safety/liveness relevance, and good TLA+ fit via small integer frontiers.

### Scenario 4: Joint membership, staged catch-up, and listener role transition

**Mechanism**: Configuration changes span admin CAS checks, staged catch-up, old/new quorum commit, listener/follower role changes, and snapshot-carried configuration.

**Evidence**:
- Historical: #1246 fixed declaring a new peer caught up before it had the config log; #954/#943 fixed majority replacement liveness; #1140 fixed deletion/election interleavings; #1331 fixed listener promotion by `NewConf`; #683 fixed staging new listeners; #560 fixed empty-conf election; #253/#460 fixed snapshot/config catch-up.
- Code analysis: `setConfigurationAsync` validates current configuration and majority replacement at `RaftServerImpl.java:1398` and `RaftServerImpl.java:1443`; staging checks match index, config log index, and install-snapshot attempt at `LeaderStateImpl.java:828`; old/new quorum majority is computed at `LeaderStateImpl.java:956`; configuration transitions and leader self-removal are handled at `LeaderStateImpl.java:1034`; listener catch-up may remain initializing because success marks only `containsInConf(id)` without listener role at `LeaderStateImpl.java:884`, while no-role `containsInConf` checks voting peers at `RaftConfigurationImpl.java:152` and `PeerConfiguration.java:122`.

**Affected code paths**: `RaftServerImpl.setConfigurationAsync`, `LeaderStateImpl.startSetConfiguration`, `LeaderStateImpl.checkProgress`, `LeaderStateImpl.checkStaging`, `LeaderStateImpl.updateCommit`, `ServerState.updateConfiguration`, `SnapshotInstallationHandler.installSnapshotImpl`, `LeaderElection.submitRequest`.

**Suggested modeling approach**:
- Variables: `conf`, `oldConf`, `roleByPeer`, `stagingPeers`, `caughtUp`, `configLogIndex`, `matchIndex`, `listenerInitializing`, `electionEligible`.
- Actions: split `StartConfigChange`, `CatchUpNewMember`, `AppendJointConfig`, `CommitJointConfig`, `ReplicateNewConfig`, `PromoteListener`, `Election`.
- Granularity: represent peer roles and old/new quorum membership explicitly; keep log payload abstract except configuration entries.

**Priority**: High. **Rationale**: Reconfiguration is the densest historical bug cluster and can invalidate core Raft quorum assumptions.

### Scenario 5: Client-visible commit, read-index, and delayed AppendEntries replies

**Mechanism**: Client-visible reads depend on commit/applied/replied indexes and heartbeat proof of leadership, but those signals are produced by separate append replies, read queues, flushes, and state-machine updater threads.

**Evidence**:
- Historical: #706 fixed delayed AppendEntries replies satisfying ReadIndex heartbeat majority; #1311 fixed read-after-write and read queue races; #973 and #912 fixed leader readiness gating; #1334 documents stale-read risk if heartbeat check is disabled; #1340 fixed follower ReadIndex propagation; #1362 fixed monotonic follower reads through replied-index flushing; #369 fixed reading log headers before commit/purge.
- Code analysis: read path chains write-index and leader read-index at `RaftServerImpl.java:1119`; waits for applied/read queue at `RaftServerImpl.java:1147` and `ReadRequests.java:58`; `ReadIndexHeartbeats` records minimum callId at `ReadIndexHeartbeats.java:49` and validates replies at `ReadIndexHeartbeats.java:76`; commit advancement clamps to flush and current-term rules at `RaftLogBase.java:122`; leader updateCommit snapshots headers before advancing commit at `LeaderStateImpl.java:1015`; replied-index is flushed by `ReplyFlusher.java:97`.

**Affected code paths**: `RaftServerImpl.submitClientRequestAsync`, `LeaderStateImpl.getReadIndex`, `ReadIndexHeartbeats`, `ReadRequests`, `StateMachineUpdater`, `ReplyFlusher`, `RaftLogBase.updateCommitIndex`.

**Suggested modeling approach**:
- Variables: `commitIndex`, `flushIndex`, `appliedIndex`, `repliedIndex`, `pendingReadIndex`, `heartbeatCallId`, `leaderHeartbeatCheck`, `leaseValid`.
- Actions: split `AppendReply`, `UpdateCommit`, `ApplyEntry`, `FlushReply`, `RegisterReadIndex`, `HeartbeatAck`, and `CompleteRead`.
- Granularity: include delayed/stale AppendEntries replies by callId; model unsafe read modes as parameters, not defaults.

**Priority**: High. **Rationale**: Directly targets user-visible linearizability and the target instructions' commit/read behavior questions.

### Scenario 6: gRPC appender progress under reconnect, timeout, and stream reset

**Mechanism**: Leader-side follower progress is maintained by `nextIndex`, `matchIndex`, pending requests, and stream epochs; reconnect and timeout paths must not regress below committed or matched state.

**Evidence**:
- Historical: #207 fixed reconnect with null request dropping `nextIndex` to 1; #875 fixed heartbeat failure regressing `nextIndex`; #939 fixed `nextIndex <= matchIndex`; #832, #883, #680, #872, #929, #848, #850, and #752 are mostly transport liveness/backpressure/performance.
- Code analysis: `GrpcLogAppender.resetClient` keeps next index on null request at `GrpcLogAppender.java:221`, skips next-index decrease on heartbeat error at `GrpcLogAppender.java:228`, and lower-bounds data-error next index through `LogAppenderBase.getNextIndexForError` at `LogAppenderBase.java:193`; pending timeout removal is at `GrpcLogAppender.java:448`; success updates follower match/next at `GrpcLogAppender.java:512`.

**Affected code paths**: `GrpcLogAppender.run`, `GrpcLogAppender.appendLog`, `GrpcLogAppender.resetClient`, `GrpcLogAppender.AppendEntriesResponseHandler`, `LogAppenderBase.getNextIndexForError`.

**Suggested modeling approach**:
- Variables: `nextIndex`, `matchIndex`, `pendingRequest`, `requestCallId`, `streamEpoch`, `lastReplyStatus`.
- Actions: `SendAppend`, `TimeoutPending`, `ResetClient`, `ReceiveOldReply`, `ReceiveSuccess`, `ReceiveInconsistency`.
- Granularity: model progress indexes abstractly; omit gRPC buffer/semaphore details.

**Priority**: Medium. **Rationale**: Important to end-to-end catch-up and read heartbeat behavior, but many historical bugs are already fixed and pure flow-control is less TLA-suitable.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **In-flight AppendEntries composition**: needed for Scenario 1 because the implementation can register, delay, coalesce, and reply independently of physical log mutation.
- **Volatile vs persisted term/vote metadata**: needed for Scenario 2 because crash/restart can expose states hidden by in-memory ordering.
- **Role lifecycle and step-down event queue**: needed for Scenario 2 because leader/appender behavior is not a single atomic Raft state transition.
- **Snapshot frontiers and chunk/session metadata**: needed for Scenario 3 because bugs cluster around off-by-one, stale stream, and leader-switch boundaries.
- **Joint configuration plus listener roles**: needed for Scenario 4 because `FOLLOWER` and `LISTENER` peers have different quorum, catch-up, and initialization semantics.
- **Read-index proof and visible indexes**: needed for Scenario 5 because commit, applied, replied, and heartbeat callId are distinct implementation states.
- **Abstract appender progress**: needed for Scenario 6 to verify `nextIndex >= matchIndex + 1` and no false catch-up after reconnect.

### 3.2 Do Not Model (with rationale)

- **Exact reproduction of closed historical PRs**: use them as evidence only; modeling should ask current forward-looking mechanism questions.
- **gRPC flow-control resource pressure** such as #1540 snapshot `isReady()` backpressure: better verified by integration/load tests because the issue is buffering and resource consumption, not protocol state.
- **Admin/client copy-paste API bugs** such as #1543: code-review or unit-test target, not consensus modeling.
- **Metrics, shell commands, group-info response shape, log-service application, examples, and alternate transports**: out of the target scope or do not affect the Raft state machine.
- **Unsafe flush as a default safety bug**: `unsafe-flush` defaults false at `RaftServerConfigKeys.java:539`; model default durability, and treat unsafe mode as an explicit configuration caveat.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|-----------|-----------|---------|----------|
| AppendComposeCache | `inFlightAppend`, `appendFutureDone`, `replyStatus` | Capture async coalescing before physical log mutation | Scenario 1 |
| PersistentMetadata | `volatileTerm`, `persistedTerm`, `votedFor`, `persistFailure` | Check crash/restart and term/vote persistence assumptions | Scenario 2 |
| RoleLifecycle | `role`, `leaderStateAlive`, `queuedStepDownTerm` | Represent non-atomic leader/follower transition and event de-duplication | Scenario 2 |
| SnapshotFrontier | `snapshotIndex`, `logStart`, `firstAvailableLogIndex`, `nextChunkIndex` | Capture install/notification/purge/restart boundaries | Scenario 3 |
| ConfigRoles | `conf`, `oldConf`, `roleByPeer`, `stagingPeers`, `caughtUp` | Model joint membership and listener/follower differences | Scenario 4 |
| ReadVisibility | `commitIndex`, `flushIndex`, `appliedIndex`, `repliedIndex`, `heartbeatCallId` | Check linearizable read and read-after-write behavior | Scenario 5 |
| AppenderProgress | `nextIndex`, `matchIndex`, `pendingRequest`, `streamEpoch` | Check reconnect/timeout progress monotonicity | Scenario 6 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader is elected per term. | Scenarios 2, 4 |
| LogMatching | Safety | If two logs contain the same index/term, prefixes match. | Scenarios 1, 3 |
| LeaderCompleteness | Safety | A committed entry is present in later leaders' logs. | Scenarios 1, 3, 4 |
| StateMachineSafety | Safety | Applied entries at the same index are identical across servers. | Scenarios 3, 5 |
| AppendSuccessReflectsLog | Safety | A successful AppendEntries reply implies the follower log contains the acknowledged entries or an installed snapshot covers them. | Scenario 1 |
| PersistedTermBeforeAccept | Safety | A server does not accept same-term leader traffic after a higher term unless that term is durable or the server cannot later restart into the old term. | Scenario 2 |
| StepDownTermNotLost | Safety | If a leader observes a caught-up follower with higher term, pending step-down processing cannot persist only an older term. | Scenario 2 |
| SnapshotLogContinuity | Safety | After snapshot install, purge, or restart, `snapshotIndex + 1`, `logStart`, and configuration state have no gap or stale overlap. | Scenario 3 |
| ConfigEntryBeforeCaughtUp | Safety | A newly voting peer is not counted as caught up until it stores the latest configuration log entry or equivalent snapshot. | Scenario 4 |
| ListenerInitializationCompletes | Liveness | A configured listener that has caught up eventually stops receiving initializing AppendEntries. | Scenario 4 |
| LinearizableReadIndex | Safety | A read completes only after the chosen read index is committed, applied/replied as required, and protected by current-leader proof when enabled. | Scenario 5 |
| ProgressBounds | Safety | `nextIndex` never regresses below `matchIndex + 1`, and old stream replies cannot increase match for unsent entries. | Scenario 6 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|----|-------------|------------------------------|----------|
| MC-RATIS-1 | If a higher-term leader sends conflicting entries while an old same-start-index append is in flight, can the follower return success without appending/truncating to the new entries? | `AppendSuccessReflectsLog`, `LogMatching`, `LeaderCompleteness` | Scenario 1 |
| MC-RATIS-2 | If AppendEntries observes a higher term, metadata persistence fails once, and later same-term AppendEntries succeeds before restart, can restart expose an older persisted term with accepted new-term log state? | `PersistedTermBeforeAccept`, `ElectionSafety` | Scenario 2 |
| MC-RATIS-3 | If multiple step-down events with different terms are queued while one `STEP_DOWN` event is pending, can the higher term be lost before old leader behavior stops? | `StepDownTermNotLost`, `ElectionSafety` | Scenario 2 |
| MC-RATIS-4 | If a server becomes leader while carrying an uncommitted transitional configuration, can startup configuration entry handling stabilize the new configuration without the required joint-majority commit? | `ConfigEntryBeforeCaughtUp`, `LeaderCompleteness` | Scenario 4 |
| MC-RATIS-5 | If snapshot notification/reload, log purge, leader change, and restart interleave, can a follower keep a stale config or a log/snapshot gap even though the leader treats it as caught up? | `SnapshotLogContinuity`, `ConfigEntryBeforeCaughtUp` | Scenarios 3, 4 |
| MC-RATIS-6 | If reconnect, timeout, and delayed replies interleave with commit and snapshot catch-up, can `nextIndex` or `matchIndex` move to a state not justified by the follower log? | `ProgressBounds`, `AppendSuccessReflectsLog` | Scenario 6 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| TV-RATIS-1 | Newly added listener may remain bootstrapping/initializing after staging success because `catchUp()` is applied only to voting peers. | Add an integration test that adds a listener, waits for staging success, captures AppendEntries `initializing=false`, and verifies the listener reaches `RUNNING`. |
| TV-RATIS-2 | Snapshot streaming lacks `isReady()` backpressure in current open PR #1540. | Use a slow gRPC follower or fake `CallStreamObserver` to assert snapshot chunks wait for readiness rather than unbounded `onNext`. |
| TV-RATIS-3 | Default flush path appears durable, but `unsafe-flush` can intentionally expose acknowledged data before `FileChannel.force`. | Add crash/restart tests that compare default, async, and unsafe flush modes around reply/commit boundaries. |
| TV-RATIS-4 | Admin API array overload in #1543 sets listeners from servers and can assert before RPC construction. | Add a focused unit test for `AdminApi.setConfiguration(RaftPeer[], RaftPeer[])`. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| CR-RATIS-1 | `leaderHeartbeatCheck=false` is documented to risk stale reads under split brain. | Keep as explicit unsafe configuration documentation; do not report as default bug. |
| CR-RATIS-2 | Retry cache expiry shorter than client retry duration can permit duplicate logical requests. | Audit defaults and documentation; model only if exactly-once client semantics are in scope. |
| CR-RATIS-3 | Several historical role lifecycle bugs are liveness or NPE ordering issues already fixed upstream. | Use as scenario evidence, not as new model targets. |

## 7. Reference Pointers

- Full analysis report: `/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/analysis-report.md`
- Repository analyzed: `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-system`, HEAD `7eedc1deed07fc883bfe448b2d33438b7a0e994e`
- Primary source files: `RaftServerImpl.java`, `LeaderStateImpl.java`, `LogAppenderBase.java`, `GrpcLogAppender.java`, `ServerState.java`, `SnapshotInstallationHandler.java`
- High-value historical PRs: #1248, #1148, #1420, #1053, #1145, #1159, #1173, #1091, #706, #1311, #1246, #954, #1331, #1362
- Reference algorithm: Raft consensus algorithm, especially leader election, log matching, leader completeness, joint consensus, snapshot installation, and linearizable reads.
