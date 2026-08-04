# Code Analysis Report: ratis-system

## Scope and Method

Target system: Apache Ratis (`apache/ratis`), Java, local repository `/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-system`.

Analyzed revision: `7eedc1deed07fc883bfe448b2d33438b7a0e994e`. The local checkout was clean before writing these output files.

System category: **Category A (Distributed / Message-Passing)**. Ratis is an end-to-end Raft implementation whose correctness depends on network RPCs, persistent term/vote/log state, crash/restart, snapshot transfer, reconfiguration, and client-visible reads. It is not a BFT protocol, so no BFT overlay was applied.

The analysis followed the installed `code-analysis` skill phases:

1. Reconnaissance of core modules, concurrency boundaries, and persistence.
2. Bug archaeology through local git history and GitHub PR discussions. GitHub issues are disabled for `apache/ratis`, so PR discussions and commits were used as the issue corpus.
3. Deep analysis of the target files and adjacent helpers, with separate parallel review of snapshot, election, append/gRPC, membership/read, `RaftServerImpl`, and `LeaderStateImpl` paths.
4. Scenario-based modeling brief synthesis.

## Phase 1: Reconnaissance

Primary files requested by the target instructions:

| File | Lines | Role |
|------|-------|------|
| `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java` | 2011 | Main server state machine, RPC handlers, client read/write/admin paths |
| `ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java` | 1376 | Leader lifecycle, appenders, commit, read-index, staging config |
| `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java` | 285 | Base leader-to-follower append/snapshot request construction |
| `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java` | 927 | gRPC stream append/snapshot transport and follower progress |
| `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java` | 512 | Persistent and volatile server metadata, configuration, snapshot/log state |
| `ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java` | 415 | Snapshot chunk/notification install path |

Additional files inspected included `ServerImplUtils.java`, `FollowerInfoImpl.java`, `ReadIndexHeartbeats.java`, `ReadRequests.java`, `VoteContext.java`, `FollowerState.java`, `RaftLogBase.java`, `SegmentedRaftLog.java`, `SegmentedRaftLogWorker.java`, `SnapshotManager.java`, `RaftStorageImpl.java`, `LeaderLease.java`, `LeaderElection.java`, `RaftConfigurationImpl.java`, `PeerConfiguration.java`, `ConfigurationManager.java`, `RaftServerConfigKeys.java`, `ServerImplUtils.java`, and `LogAppenderDefault.java`.

Key concurrency and atomicity boundaries:

- Client writes append through `RaftServerImpl.appendTransaction`, then leader appenders replicate to followers asynchronously.
- Follower `AppendEntries` first handles term/role/leader recognition under server synchronization, then performs log append through a future outside the main state lock.
- The append compose path is enabled by default and uses `ServerImplUtils.NavigableIndices` to coalesce in-flight follower appends.
- Log durability is separated from append acknowledgement by segmented log worker flushing. Default `unsafe-flush` is false; `forceSyncNum` defaults to 128.
- Leader commit calculation uses follower match indexes and the local flush index; `RaftLogBase.updateCommitIndex` clamps to `getFlushIndex`.
- Snapshot install has two forms: full chunk transfer and notification to install an already available snapshot.
- Membership changes stage catch-up before joint configuration, then commit old/new and finally new configuration.
- Linearizable reads use write-index cache, leader `ReadIndex`, heartbeat callId validation, and read queues waiting for applied/replied indexes.

## Phase 2: Bug Archaeology Coverage

GitHub issues: `gh issue list` reports issues are disabled for `apache/ratis`; no issue threads were available. PR discussions were used instead.

Deeply read PR/related threads: 89, including one supplemental thread (#943) because #954 explicitly pointed to it. Classified as confirmed bug, design defect, or open implementation risk: 83. Classified as uncertain, test-only, supplemental, or out-of-scope for this system: 6 plus supplemental #943.

The PRs were read with full body/comments/files/commits rather than title-only sampling. Local master often contains squash/fix commits rather than PR head objects; when available, local commits were matched by PR/JIRA title and verified with `git show --stat` and current source lines.

### Snapshot, Purge, and Install History

- #1420 (`98a4c483b78980948f87236995f13885b9cc5a4a`) fixed leader behavior when previous log is purged: appender must move to snapshot/notification instead of empty append spinning.
- #1053 (`7760eec695d79d4363f980e31f76c8842a140568`) fixed `snapshotIndex == -1` with `firstAvailableLogIndex == 0` being mistaken for already installed.
- #1145 (`54a991623ec34d8386cda18ec2c2951ccb08a70b`) fixed snapshot chunk failure allowing later chunks to trigger state-machine reload.
- #1159 (`536419c50365e1765fe303e3452a967aae4cd1dd`) fixed `ALREADY_INSTALLED` not advancing `nextChunkIndex`.
- #1173 (`7c3942d1d09bdfa6a062b06e4cef6cf01c4a2e1f`) fixed stale snapshot chunks from old streams using `chunk0CallId`.
- #1091 (`10c362b761dbac0930546424ee2bf77c11b524a5`) fixed old snapshot/config truncation behavior after leader switch.
- #253 (`c16a811cc3472767d923f52aa40bddca707ef49e`) fixed snapshot install not propagating configuration.
- #360 (`2ddf0dbb27f78727d5b93546445d2112e5612e15`) fixed leader trying to append purged entries to a recovering follower.

Modeling value: high. These bugs share small integer frontier state (`snapshotIndex`, `firstAvailableLogIndex`, `nextIndex`, `logStart`, `configLogIndex`) that is suitable for TLA+.

### Election, Term, Role Lifecycle History

- #1148 (`5578be7fb07e52cfa90e2979fd251ae78badfc62`) fixed old leader/appender behavior after current term changed.
- #863 (`4089b0e6e86ad600b81cc19378ee242e8db84ff0`) fixed `firstElectionSinceStartup` not being reset on all `changeToFollower` paths.
- #799 (`77a9949f98d6c80a8c1466887763d44fb64c9ccc`) fixed stale/non-running `LeaderStateImpl` allowing appender restart.
- #895 (`45772bb7ec79bced76e546375c3acecce0ca4563`) fixed role becoming `LEADER` before `leaderState` was installed.
- #1068 (`14f3a617680b20144edb7574523eb27e934c4b27`) fixed leader readiness notification ordering.
- #1143 (`1e10b7186fa7f4bea695cab01c82579af8fee66b`) fixed election running before server startup was complete.
- #1300 (`e2c867da55f8caf789db5e759ffebc2e79a4961d`) fixed stepDown waiting indefinitely.
- #252 (`9357fdb8a8344b0bbda3f38291380f18f6be00d0`) fixed voluntary step-down leader being re-elected too soon.
- #275 (`190b0f7107b4ff1d801535e798d988412616a773`) handled long JVM pauses invalidating leader authority.

Modeling value: high for term/persistence/lifecycle; lower for pure wait/deadlock cases.

### Append, gRPC Reconnect, and Follower Progress History

- #1248 (`39acebf88bc2a015c0f86f48d9334cb86a820893`) fixed async append `NavigableIndices` duplicate in-flight range handling.
- #89 (`3596a589707fa8f7947af50ada582b12ec15b650`) fixed append/restart loading around `snapshotIndex`.
- #745 (`89853ea72bf8357d1a6983b8b52419d0ec6ccf1e`) fixed purged-log/latest-snapshot mismatch.
- #289 (`bcc392ca4fedcb47202aaf775e31fa867c63b218`) fixed follower commit advancement incorrectly requiring current-term entries.
- #207 (`50594a565cdd7d98dbf0f8c19aaf8e169154c7a4`) fixed reconnect/error with null request dropping `nextIndex` to 1.
- #875 (`60587b63a4401cc6160907d33fb5cd89dbbdc724`) fixed heartbeat failure regressing `nextIndex`.
- #939 (`b7ffa1ba1e3e7cecd9ea687f72425c2ffd5b1c34`) fixed `resetClient` decreasing `nextIndex <= matchIndex`.
- #706 (`5dd3c1db093bb06e462afbd0df4b8b215bbd8bf3`) fixed delayed old AppendEntries replies satisfying read-index heartbeat quorum.
- #789 (`1c00461b93a2d259bf810713b00a9791a6bd292d`) fixed stale follower config lists in leader state.
- #795 (`82cb5ee66d93675cbd746887e4aa7278b6fee759`) fixed transitional old-conf majority threshold logic.

Modeling value: high for append composition, follower progress, delayed replies, and quorum calculations. Pure flow-control PRs (#680, #752, #848, #850, #872, #883, #929) are better suited to stress tests.

### Membership, Configuration, and Listener History

- #1246 (`c1301b082c3f9359dc510e6f5c26ff0d7a8a7e21`) fixed new peer catch-up before latest config log.
- #954 (`c35f769f513609d808ab1cc91c5323d9ff30f636`) with #943 fixed majority replacement causing empty-conf peers and infinite election.
- #1140 (`211278e5677799deb6a6e342a7b835783d78ff01`) fixed deletion/election interleavings.
- #682 (`6d2580f69fdefa87e23f633e0f3a2c8fbc6a1d68`) added CAS checks to configuration changes.
- #560 (`478749ced9832aa389fe1c2349305102fc49e41b`) fixed empty-conf follower election/priority behavior.
- #1331 (`d7370f897f43aa31d44beb3bf61933430bfb8355`) fixed listener promoted by `NewConf` not becoming follower.
- #673 (`43d0275ac9515924468c24e528d4226dc7b79190`) added listener role startup semantics.
- #683 (`b8f050eab1d8a1922f158a6142f86c10f395e79a`) fixed staging tracking `newPeers` but not `newListeners`.
- #460 (`80f6e4b3825860bf50f1253a4ee2cc5240bd194b`) fixed install-snapshot leader info when local conf is empty during setConf.

Modeling value: high. Membership changes directly affect quorum, election eligibility, snapshot install, and catch-up.

### Commit and Read Visibility History

- #1362 (`32e7925ee9aec86922d173f3922337618d918362`) fixed monotonic follower read semantics through replied-index flushing.
- #1311 (`81c714dde6632d82fb2f10cc5118de309d77c92a`) fixed read-after-write and read queue races.
- #973 (`e306b0290270170d17dfc27730f305b4b89276cf`) fixed new leader ReadIndex readiness.
- #912 (`1b54bfab05e4f1775ea82b58c8140c4b2b6beb8c`) fixed leader readiness placeholder index.
- #1334 (`bd06cf79315a065c611986ea0fe47c5b71ea3c9b`) added an unsafe option to skip leader heartbeat checks; docs warn about stale reads.
- #1340 (`f72863e7377981535dfdf8789f1d4595f1469e69`) fixed follower ReadIndex reply not promptly advancing commit/apply.
- #730/#735/#738 added/fixed leader and follower ReadIndex paths.
- #185 (`a79281ca2452028228582ddde143e5350df9203d`) fixed watch-for-commit blocking without later commit-info traffic.
- #369 (`195c572024fc5fd88d00c3c0985c01215d2719aa`) fixed leader updateCommit using entries after commit/purge window.

Modeling value: high for read linearizability and delayed replies.

## Phase 3: Deep Analysis Findings

### Finding A: In-flight AppendEntries compose can skip a conflicting overwrite

Classification: model-checkable, high priority.

Scenario:

1. Old leader sends AppendEntries to a follower.
2. The follower registers the append in `appendLogTermIndices`, but the physical log append future is still pending.
3. The follower observes a higher term and can vote for or follow a new leader.
4. The new leader sends AppendEntries with the same start index but different term/content.
5. `NavigableIndices.append` sees an existing in-flight range and returns the old future without comparing term/content.
6. When the old future completes, the new leader's AppendEntries handler can return success even if the follower log contains the old entries, not the new leader's entries.

Verified code:

- Compose is default-enabled through `RaftServerConfigKeys.Log.appendEntriesComposeEnabled`.
- `RaftServerImpl.appendEntriesAsync` uses `appendLogTermIndices.append(entries, this::appendLog)` at `RaftServerImpl.java:1695`.
- `checkInconsistentAppendEntries` treats an in-flight `previous` index as present via `appendLogTermIndices.contains(previous)` at `RaftServerImpl.java:1764`.
- `ServerImplUtils.NavigableIndices.append` returns an existing future when `alreadyExists` is true at `ServerImplUtils.java:148`.
- `alreadyExists` checks index ranges and restores entries, but does not compare entry term/content at `ServerImplUtils.java:153`.
- If the real append path runs, `SegmentedRaftLog.appendImpl` computes truncate/append at `SegmentedRaftLog.java:470`.
- Leader-side success updates `matchIndex` and `nextIndex` at `LogAppenderDefault.java:197` and `GrpcLogAppender.java:512`.

Why not already closed: #1248 fixed duplicate in-flight range behavior, but the current code path still raises a forward-looking question under leader change plus conflicting same-start append. This is not simply reproducing the old PR.

### Finding B: Higher-term AppendEntries persistence failure can leave volatile term ahead of stable term

Classification: model-checkable, high priority.

Scenario:

1. A follower receives higher-term AppendEntries.
2. `changeToFollower` updates in-memory `currentTerm`, clears vote, and clears leader.
3. `persistMetadata()` throws `IOException`.
4. The AppendEntries handler returns a failed future, but the server remains alive with volatile term already advanced.
5. Later same-term AppendEntries no longer reports `metadataUpdated`, so the metadata write is not retried.
6. The server can accept same-term leader traffic and append log entries, then crash and restart from the older persisted term.

Verified code:

- `ServerState.updateCurrentTerm` mutates volatile state at `ServerState.java:211`.
- `RaftServerImpl.changeToFollowerAndPersistMetadata` persists only when `metadataUpdated` is true at `RaftServerImpl.java:638`.
- AppendEntries catches `IOException` and returns `completeExceptionally` at `RaftServerImpl.java:1664`.
- Later successful append path continues through `RaftServerImpl.java:1693` and updates commit/reply at `RaftServerImpl.java:1720`.
- Restart loads metadata through `ServerState.initialize` at `ServerState.java:139`.
- RequestVote partially compensates by persisting again when `voteGranted`, but AppendEntries does not have an equivalent same-term retry trigger.

### Finding C: `STEP_DOWN` event coalescing may drop a higher observed term

Classification: model-checkable, medium/high priority.

Scenario:

1. A leader already has a queued `STEP_DOWN` event for its current term, for example forced step-down or local lifecycle reason.
2. Before the event processor handles it, an appender observes a caught-up follower with a higher term.
3. `submitStepDownEvent(followerTerm, HIGHER_TERM)` creates a new `STEP_DOWN` event with a higher captured term.
4. The queue drops it because `StateUpdateEvent.equals` compares only event type.
5. The older event runs and calls `changeToFollowerAndPersistMetadata` with the older term.

Verified code:

- `StateUpdateEvent.equals` compares only `type` at `LeaderStateImpl.java:129`.
- `EventQueue.submit` drops duplicate events using `queue.contains(event)` at `LeaderStateImpl.java:156`.
- `onFollowerTerm` submits the higher-term event only when the follower is caught up and term is greater at `LeaderStateImpl.java:507`.
- `submitStepDownEvent(long term, StepDownReason reason)` captures the term in the handler at `LeaderStateImpl.java:738`.
- `stepDown` persists the captured term through `changeToFollowerAndPersistMetadata` at `LeaderStateImpl.java:742`.

Compensation: later higher-term RPCs can still update the server. The modeling question is whether the already observed higher term must be durable before any further old-leader behavior or restart.

### Finding D: Newly added listener may remain initializing after staging success

Classification: test-verifiable/code-review, medium priority.

Scenario:

1. A configuration change adds a listener.
2. Staging creates log appenders for new peers and new listeners.
3. `checkStaging` declares all lagging appenders caught up.
4. It calls `catchUp()` only on lagging followers where `server.getRaftConf().containsInConf(f.getId())` is true.
5. No-role `containsInConf` checks voting peers, not listeners.
6. The leader may continue sending AppendEntries to the new listener with `initializing = true`, and the listener only starts from `STARTING` when it receives non-initializing AppendEntries.

Verified code:

- Staging includes new listeners at `LeaderStateImpl.java:523`, `LeaderStateImpl.java:530`, and `LeaderStateImpl.java:545`.
- Completion uses all non-caught-up appenders at `LeaderStateImpl.java:870`.
- Success calls `catchUp()` only for `containsInConf(id)` at `LeaderStateImpl.java:884`.
- `RaftConfigurationImpl.containsInConf` delegates no-role lookup to `PeerConfiguration.contains` at `RaftConfigurationImpl.java:152`.
- `PeerConfiguration.contains(id)` checks `RaftPeerRole.FOLLOWER` at `PeerConfiguration.java:122`.
- AppendEntries request `initializing` is `!isCaughtUp(follower)` at `LeaderStateImpl.java:650`.
- Follower/listener server transitions from `STARTING` to `RUNNING` only when `!proto.getInitializing()` at `RaftServerImpl.java:1669`.

Reason for classification: This is a concrete code-path inconsistency, but it is more directly verifiable by a targeted integration test than by model checking unless listener liveness is explicitly in scope.

### Finding E: Startup configuration entry while transitional config exists needs model validation

Classification: model-checkable, medium priority.

Scenario:

1. A server can observe a transitional configuration in memory/log.
2. It becomes leader before that transitional configuration is committed.
3. Leader startup appends a configuration entry built from `server.getRaftConf().getConf()` without oldConf.
4. The usual `prepare()` path only replicates the new configuration when the transitional configuration is already committed.

Verified code:

- `StartupLogEntry` appends `server.getRaftConf().getConf()` at `LeaderStateImpl.java:296`.
- `start()` constructs startup state before processor/senders run at `LeaderStateImpl.java:433`.
- `prepare()` replicates new config only when `!server.getRaftConf().isStable()` and `state.isConfCommitted()` at `LeaderStateImpl.java:774`.
- `appendConfiguration` updates in-memory configuration immediately at `LeaderStateImpl.java:635`.
- Commit calculation in transitional mode uses current and old confs at `LeaderStateImpl.java:956` and `LeaderStateImpl.java:980`.

Reason for classification: I did not mark this as a confirmed bug because the full election preconditions may prevent a leader from being elected with an unsafe uncommitted transitional config. The interaction is suitable for model checking.

## Excluded False Positives and Non-targets

- Listener RequestVote malformed RPC: normal elections are sent to voting peers; listeners do not self-elect. Treat as robustness, not a Raft safety finding.
- Linearizable read seeing unapplied state: excluded because read path waits through `ReadRequests.waitToAdvance`, and the state-machine updater completes the gate after apply.
- Higher-term AppendEntries reply term stale: the local reply term can be stale, but leader step-down on reply term is only in the `NOT_LEADER` branch; this is not enough evidence for a safety finding.
- Candidate forwarding read to old leader: election initialization clears leader state, and leader-side ReadIndex still checks readiness/quorum/lease.
- Default async append/flush exposing non-durable committed data: excluded as a default finding because commit is clamped to flush index and `unsafe-flush` defaults false. Unsafe flush should be treated as an explicit configuration caveat.
- #1446: test/user error on a stale non-master branch, excluded from product bug set.
- #18: log-service/docker cleanup, outside ratis-system scope.
- #1513: docs/design-only listener delegation, no confirmed implementation bug.
- Metrics, shell, examples, group-info display, and alternate transports were excluded unless they affected in-scope Raft interactions.

## Phase 4 Scenario Synthesis

The modeling brief groups findings by mechanism rather than by source file:

1. In-flight append composition across leader change.
2. Non-atomic term/role/persistent metadata transitions.
3. Snapshot/purge/restart/config frontier.
4. Joint membership, staged catch-up, and listener role transition.
5. Client-visible commit/read-index/delayed-reply behavior.
6. Abstract gRPC appender progress under reconnect and timeout.

The highest-value model-checkable candidates are MC-RATIS-1 through MC-RATIS-6 in `modeling-brief.md`. Closed historical bugs are used as evidence for bug-prone mechanisms, not as direct modeling targets.

## Key Source Anchors

- `RaftServerImpl.java:638`: follower transition and metadata persistence boundary.
- `RaftServerImpl.java:1695`: follower append uses compose cache.
- `RaftServerImpl.java:1764`: in-flight previous index is accepted as present.
- `ServerImplUtils.java:148`: duplicate in-flight append reuses existing future.
- `ServerState.java:211`: volatile current term update.
- `ServerState.java:139`: restart metadata initialization.
- `LeaderStateImpl.java:129`: event equality by type.
- `LeaderStateImpl.java:738`: step-down event captures term.
- `LeaderStateImpl.java:828`: staging catch-up criteria.
- `LeaderStateImpl.java:884`: catch-up applied only to no-role `containsInConf`.
- `SnapshotInstallationHandler.java:149`: snapshot install applies configuration and truncates.
- `SnapshotInstallationHandler.java:193`: stale snapshot stream guard.
- `SnapshotInstallationHandler.java:272`: invalid/already-installed snapshot boundary.
- `GrpcLogAppender.java:221`: resetClient null-request next-index handling.
- `GrpcLogAppender.java:512`: append success updates match/next.
- `ReadIndexHeartbeats.java:49`: min callId captured for read-index heartbeat.
- `ReadRequests.java:58`: read queue applied-index gate.
- `RaftLogBase.java:122`: commit index update and flush/current-term checks.

## Final Recommendations

For Spec Generation, start with a compact Raft model and add only the implementation extensions listed in `modeling-brief.md`:

- Append composition as a split register/complete/reply workflow.
- Volatile and persistent metadata with crash/restart.
- Leader role lifecycle and coalesced step-down events.
- Snapshot frontiers and chunk/session metadata.
- Joint configuration, listeners, and staged catch-up.
- Read-index, applied/replied indexes, and delayed AppendEntries replies.
- Abstract follower progress under reconnect.

Do not spend model-checking budget on exact reproduction of closed PRs, pure transport buffering, metrics, shell/admin UX, or log-service/example modules.
