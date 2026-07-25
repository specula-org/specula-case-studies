# Modeling Brief: apache/ratis

## 1. System Overview

- **System**: Apache Ratis — Java Raft consensus library used by Apache Ozone, Celeborn, and others
- **Language**: Java, ~8000 LOC core logic (ratis-server/src/main/java/org/apache/ratis/server/)
- **Protocol**: Raft (with Pre-Vote, Priority-based election, Joint Consensus config changes, Leader Lease, ReadIndex)
- **Key architectural choices**:
  - **Multi-threaded**: RPC handlers run on Netty/gRPC threads; per-follower `LogAppender` daemons; `EventProcessor` thread in LeaderStateImpl; `SegmentedRaftLogWorker` for async I/O; `StateMachineUpdater` for applying committed entries
  - **Async log I/O**: Log appends go to an in-memory cache immediately, then to a task queue for disk write. `flushIndex` gates commit advancement
  - **Joint consensus** for configuration changes (C_old,new two-phase), with a mandatory staging/bootstrapping phase for new peers
  - **Leader lease** (optional): 0.9 × minElectionTimeout, enables bypassing heartbeat round for reads
  - **Priority-based election**: when logs are equal, voters reject candidates with lower priority
  - **(term, votedFor) persisted atomically** via write-to-tmp + fsync + rename

## 2. Bug Families

### Family 1: Commit Index Safety (HIGH)

**Mechanism**: Incorrect commit index computation or update — wrong entry checked for term, wrong index used, or missing update.

**Evidence**:
- RATIS-748: Commit index term check applied to `majorityIndex` instead of `min(majorityIndex, flushIndex)` — follower may not update commit index
- RATIS-1256: Leader used wrong index to iterate entries after commit, could read purged entries
- RATIS-1161: Follower commit index update incorrectly required term check (Raft §5.4.2 only applies to leader)
- RATIS-502: Commit index less than snapshot index rejected on restart (`updateIncreasingly` vs `updateToMax`)
- RATIS-2109: `updateCommitIndex` returned true even when index didn't change
- RATIS-2134: Metadata entry with lastCommitIndex could be missed during log append
- Code: RaftLogBase.java:122-142 — leader commit rule correctly checks `entry.getTerm() == currentTerm`
- Code: RaftLogBase.java:125 — `min(majorityIndex, flushIndex)` correctly gates on durability

**Affected code paths**: `RaftLogBase.updateCommitIndex()`, `LeaderStateImpl.updateCommit()`, `LeaderStateImpl.getMajorityMin()`

**Suggested modeling approach**:
- Variables: `commitIndex[Server]`, `flushIndex[Server]` (separate from log length for leader)
- Actions: Leader `AdvanceCommitIndex` checks majority matchIndex, caps at flushIndex, requires entry at newCommitIndex has term == currentTerm. Follower `UpdateCommitIndex` uses min(leaderCommit, lastNewEntry) without term check.
- Key invariant: commitIndex never exceeds flushIndex; leader only commits entries from current term

**Priority**: High
**Rationale**: 6 historical bugs on a fundamental Raft invariant. The flushIndex/majorityIndex interaction and leader-vs-follower term check asymmetry are rich modeling targets.

---

### Family 2: Election and Leadership Transition (HIGH)

**Mechanism**: Incorrect state management during role transitions — stale references after role change, term/role ordering issues, priority-based election edge cases.

**Evidence**:
- RATIS-1268: After `changeToFollower()`, code used stale null `FollowerState` reference — vote silently dropped
- RATIS-981: Stale leader never stepped down in split-brain (no majority heartbeat check)
- RATIS-980: `updateLastRpcTime` called before `grantVote` — timer reset even on denied vote
- RATIS-1047: Higher-priority peer crash caused election to be incorrectly REJECTED despite majority
- RATIS-1912: Adding majority of new peers caused infinite election loops
- RATIS-1796: TransferLeadership blocked by old leader's heartbeats resetting election timer
- RATIS-2154: `updateCurrentTerm(newTerm)` called before `setRole(FOLLOWER)` — old leader sends AppendEntries with new term
- RATIS-2274: New peer marked CAUGHTUP before replicating config entry — retains outdated config
- Code: VoteContext.java:152-162 — priority tiebreaker when logs equal (Ratis extension)
- Code: LeaderElection.java:560-563 — immediate abort on higher-priority peer rejection, with timeout fallback at line 523
- Code: FollowerState.java:94-96 — leader validity check uses `minRpcTimeout`
- Code: LeaderStateImpl.java:477-483 — higher-term step-down only for caught-up followers (`isCaughtUp` guard)

**Affected code paths**: `RaftServerImpl.requestVote()`, `RaftServerImpl.changeToFollower()`, `LeaderElection.askForVotes()`, `VoteContext.decideVote()`, `FollowerState.runImpl()`, `LeaderStateImpl.onFollowerTerm()`

**Suggested modeling approach**:
- Variables: `role[Server]`, `currentTerm[Server]`, `votedFor[Server]`, `priority[Server]`, `leaderOf[Server]`
- Actions: `RequestVote` with pre-vote phase (no side effects on receiver) and election phase (term increment, persist, role change). `ChangeToFollower` updates role before term. `CheckLeadership` steps down leader if no majority contact within timeout.
- Priority extension: when logs equal, grant vote only if voter.priority <= candidate.priority
- Pre-vote: separate phase that does NOT increment term, checks leader validity

**Priority**: High
**Rationale**: 8 historical bugs including production split-brain. The priority extension and pre-vote interaction create a state space not covered by standard Raft specs.

---

### Family 3: Log Replication Index Management (HIGH)

**Mechanism**: Incorrect nextIndex/matchIndex tracking, especially during INCONSISTENCY handling, snapshot installation, and pipelined responses.

**Evidence**:
- RATIS-1883: nextIndex became less than matchIndex in GrpcLogAppender with pipelining
- RATIS-1909: nextIndex decreased below matchIndex on GrpcLogAppender client reset
- RATIS-2137: LogAppenderDefault didn't track request's firstIndex for INCONSISTENCY handling
- RATIS-558: GrpcLogAppender didn't reset pending state on inconsistency
- RATIS-1767: matchIndex initialized to 0 instead of INVALID_LOG_INDEX (-1)
- RATIS-1835: nextIndex decreased on heartbeat INCONSISTENCY (should be ignored)
- Code: FollowerInfoImpl.java:93 — matchIndex uses `updateToMax` (monotonic increase only)
- Code: FollowerInfoImpl.java:117-125 — nextIndex has multiple update methods (increase, decrease, set, compute)
- Code: LogAppenderBase.java:190-204 — `getNextIndexForInconsistency` bounds nextIndex >= matchIndex+1

**Affected code paths**: `LogAppenderDefault.handleReply()`, `LogAppenderBase.getNextIndexForInconsistency()`, `FollowerInfoImpl.increaseNextIndex/decreaseNextIndex/setNextIndex()`

**Suggested modeling approach**:
- Variables: `nextIndex[Leader][Follower]`, `matchIndex[Leader][Follower]`
- Actions: `HandleAppendEntriesReply` — on SUCCESS: matchIndex = nextIndex-1, nextIndex = reply.nextIndex (monotonic). On INCONSISTENCY: nextIndex = max(matchIndex+1, replyNextIndex). Heartbeat INCONSISTENCY ignored.
- Invariant: `nextIndex[f] > matchIndex[f]` always
- Model pipelined responses where multiple in-flight requests can return out of order

**Priority**: High
**Rationale**: 6 historical bugs in a critical Raft mechanism. The pipelining and multiple nextIndex update paths make this ideal for model checking.

---

### Family 4: Configuration Change Safety (HIGH)

**Mechanism**: Incorrect quorum calculation, premature catch-up marking, or config inconsistency during joint consensus transitions.

**Evidence**:
- RATIS-1912: Adding majority of new peers caused infinite elections (changeMajority check added)
- RATIS-2274: New peer's matchIndex not checked against config entry log index — retained outdated config
- RATIS-1960: Follower incorrectly marked as caught up; `initializing` flag logic inverted
- RATIS-2283: GrpcLogAppender restart left catchup=false, permanently blocking reconfiguration
- RATIS-2146: Concurrent group deletion and election during member changes
- Code: RaftConfigurationImpl.java:265-283 — `hasMajority` requires AND of old+new majorities during transition
- Code: RaftServerImpl.java:1362-1366 — triple guard: `isStable && !inStagingState && isConfCommitted`
- Code: LeaderStateImpl.java:592-601 — `applyOldNewConf` appends joint config
- Code: LeaderStateImpl.java:1031-1041 — `replicateNewConf` appends stable config after commit

**Affected code paths**: `RaftServerImpl.setConfigurationAsync()`, `LeaderStateImpl.startSetConfiguration()`, `LeaderStateImpl.checkStaging()`, `LeaderStateImpl.applyOldNewConf()`, `RaftConfigurationImpl.hasMajority()`

**Suggested modeling approach**:
- Variables: `config[Server]` with `{conf, oldConf}` (joint consensus), `stagingState` on leader
- Actions: `ProposeConfigChange` (enters staging), `AppendJointConfig` (C_old,new), `CommitJointConfig` (triggers C_new append), `CommitNewConfig` (stable). Guard: no overlapping changes.
- Quorum: during transition, require majority in BOTH old and new
- Leader step-down: if leader not in new stable config after commit

**Priority**: High
**Rationale**: 5 historical bugs. Joint consensus is complex and the staging/catch-up mechanism adds state not in standard Raft. Ideal for exploring config+election interleavings.

---

### Family 5: Linearizable Read Safety (MEDIUM)

**Mechanism**: Stale reads from incorrect read index protocol implementation, lease timing gaps, or race conditions in heartbeat acknowledgment tracking.

**Evidence**:
- RATIS-2044: ReadIndex loss — `failAll()` raced with `add()` in AppendEntriesListeners
- RATIS-1927: Data race in ReadRequests — ConcurrentSkipListMap operations non-atomic
- RATIS-1773: readIndexHeartbeat used `callId` instead of `followerCommit` for filtering
- RATIS-2350: readAfterWrite bugs — wrong index selection, stale lastAppliedIndex
- Code: LeaderStateImpl.java:1173 — `!leaderHeartbeatCheckEnabled || hasLease()` bypasses heartbeat round
- Code: LeaderLease.java:47-49 — lease timeout = 0.9 × minElectionTimeout (must expire before followers' election timeout)
- Code: LeaderStateImpl.java:1167 — readiness gate: startup log entry must be applied before serving reads
- Code: ReadIndexHeartbeats.java:146 — followerCommit filtering may incorrectly reject valid heartbeat acks (liveness issue)

**Affected code paths**: `LeaderStateImpl.getReadIndex()`, `ReadIndexHeartbeats.onAppendEntriesReply()`, `LeaderLease.extend()`, `ReadRequests.waitToAdvance()`

**Suggested modeling approach**:
- Variables: `leaseValid[Server]`, `readIndex`, `leaseTimeout`
- Actions: `ClientRead` with three paths: (a) lease valid → return immediately, (b) heartbeat round → wait for majority ack, (c) non-linearizable → no check. `ExtendLease` on majority heartbeat response. `ExpireLease` when timeout elapses.
- Key constraint: leaseTimeout < minElectionTimeout (clock synchrony assumption)
- Invariant: `ReadReturnsCommitted` — any read returns data at or after the readIndex, which was committed when leadership was confirmed

**Priority**: Medium
**Rationale**: 4 historical bugs. The lease mechanism adds clock-based reasoning that TLA+ can explore under various timing assumptions. However, the core bugs were implementation races rather than protocol logic errors.

---

### Family 6: Snapshot-Log Consistency (MEDIUM)

**Mechanism**: Gaps or inconsistencies between snapshot index and log indices, incorrect validation during snapshot installation, or state mutation before snapshot transfer completes.

**Evidence**:
- RATIS-1577: Used `getNextIndex()` instead of `getLastCommittedIndex()` to validate snapshot
- RATIS-1369: `getSnapshotIndex()` returned 0 instead of -1 when no snapshot exists
- RATIS-1481: `getNextIndex()` used server's snapshot index instead of log's own snapshot index
- RATIS-987: Infinite snapshot install loop — exception handler didn't clear in-progress flag
- RATIS-2148: No chunk index validation — out-of-order/duplicate chunks caused incorrect reloadStateMachine
- RATIS-1305: Leader stuck in infinite install snapshot cycle after log purge
- Code: SnapshotInstallationHandler.java:217 — TODO: "should only update State with installed snapshot once the request is done"
- Code: SegmentedRaftLog.java:506-529 — `onSnapshotInstalled` updates indices, syncs worker, purges log
- Code: SegmentedRaftLogWorker.java:261-267 — `syncWithSnapshot` drops pending writes without cache cleanup

**Affected code paths**: `SnapshotInstallationHandler.checkAndInstallSnapshot()`, `SegmentedRaftLog.onSnapshotInstalled()`, `ServerState.reloadStateMachine()`, `LogAppenderBase.shouldInstallSnapshot()`

**Suggested modeling approach**:
- Variables: `snapshotIndex[Server]`, `snapshotTerm[Server]`
- Actions: `InstallSnapshot` sets snapshotIndex/Term, truncates log prefix. `PurgeLog` removes entries ≤ snapshotIndex.
- Invariant: `snapshotIndex <= commitIndex`, no gap between snapshotIndex and first log entry
- Interaction: snapshot installation must set matchIndex and nextIndex on leader's follower tracking

**Priority**: Medium
**Rationale**: 7 historical bugs. Snapshot-log interaction is a known weak point in Raft implementations. However, many bugs were implementation-level (MD5, chunk ordering) rather than protocol-level.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Leader election with pre-vote | Family 2: 8 bugs, priority extension unique to Ratis | Two-phase election: pre-vote (no term increment, leader validity check) then election (term increment, persist) |
| Priority-based voting | Family 2: causes unique election dynamics not in standard Raft | Tiebreaker variable: when logs equal, reject if voter.priority > candidate.priority |
| Log replication with pipelining | Family 3: 6 bugs on nextIndex/matchIndex | Model multiple in-flight AppendEntries; track requestFirstIndex for INCONSISTENCY |
| Commit index with flushIndex gate | Family 1: 6 bugs; leader/follower asymmetry | Separate flushIndex from log length; leader-only term check |
| Joint consensus config changes | Family 4: 5 bugs; dual-majority requirement | Two config variables (conf, oldConf); quorum = majority(old) AND majority(new) |
| Leader lease for reads | Family 5: lease bypass path, clock assumption | leaseTimeout < electionTimeout; ExtendLease on majority ack |
| ReadIndex heartbeat round | Family 5: 4 bugs on read correctness | Heartbeat round confirms leadership before serving read |
| Snapshot installation (simplified) | Family 6: snapshot-log gap bugs | Atomic snapshot install action; update snapshotIndex, matchIndex, nextIndex |
| Leader step-down on lost majority | Family 2: RATIS-981 production split-brain | `CheckLeadership` action: if no majority contact, step down |
| Startup log entry (no-op on leader) | Raft §5.4.2: new leader must commit entry from own term | Leader appends config entry on becoming leader; reads gated behind it |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Deadlocks / lock ordering | Java threading concern, not protocol logic (Family 7: 7 bugs all from `synchronized` + `join()` patterns) |
| Async log I/O (SegmentedRaftLogWorker) | Implementation detail; model log append as atomic with separate flush |
| gRPC/Netty transport details | Network abstraction; model message send/receive with loss |
| Memory leaks | Resource management, not protocol safety |
| State machine application | Application-level; model as atomic apply-on-commit |
| TransactionContext lifecycle | Java object lifecycle, not protocol logic (RATIS-2001 was fixed by using TermIndex as key) |
| Disk corruption / checksum | Storage integrity, not consensus protocol |
| Metrics / JMX | Observability, no safety impact |
| Data streaming | Separate subsystem, orthogonal to consensus |
| Listener (non-voting) peers | Correctly excluded from quorum in all paths; adds state space without targeting bugs |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Pre-vote phase | `phase ∈ {PRE_VOTE, ELECTION}` | Model two-phase election without term increment in pre-vote | Family 2 |
| Priority voting | `priority[Server]` | Tiebreaker when logs equal; immediate abort on higher-priority rejection | Family 2 |
| Flush index | `flushIndex[Server]` | Gate commit advancement on durability; separate from log length | Family 1 |
| Joint consensus | `conf[Server], oldConf[Server]` | Dual-majority during config transition | Family 4 |
| Leader lease | `leaseValid[Server], leaseTimestamp[Server]` | Enable lease-based read bypass | Family 5 |
| Read index | `pendingReads[Server]` | Track reads waiting for heartbeat confirmation | Family 5 |
| Startup entry | `startupEntryCommitted[Server]` | Gate reads behind leader's first committed entry | Family 2, 5 |
| Pipelined replication | `inFlight[Server][Server]` | Multiple outstanding AppendEntries per follower | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard, Family 2 |
| LogMatching | Safety | Same term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in all future leaders' logs | Standard, Family 1 |
| CommitMonotonicity | Safety | commitIndex never decreases on any server | Family 1 |
| CommitFlushBound | Safety | commitIndex ≤ flushIndex on leader | Family 1 |
| LeaderTermCommit | Safety | Leader only commits entries from current term | Family 1 |
| NextIndexBound | Safety | nextIndex[f] > matchIndex[f] for all followers f | Family 3 |
| JointQuorum | Safety | During config transition, commits require majority in both old and new | Family 4 |
| OneConfigChange | Safety | At most one uncommitted config change at a time | Family 4 |
| LeaseImpliesLeader | Safety | If lease is valid, no other leader exists with higher term (under clock assumption) | Family 5 |
| ReadLinearizability | Safety | Read returns data at index ≥ readIndex, where readIndex was committed when leadership was confirmed | Family 5 |
| SnapshotLogConsistency | Safety | No gap between snapshotIndex and first log entry index | Family 6 |
| PreVoteNoSideEffect | Safety | Pre-vote phase does not change term, votedFor, or role on receiver | Family 2 |
| PriorityLiveness | Liveness | If highest-priority server is reachable and has up-to-date log, it eventually becomes leader | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Priority-based voting + partition: highest-priority node partitioned, lower-priority node has equal log — can lower-priority candidate win? | PriorityLiveness (check liveness) | 2 |
| MC-2 | Stale leader with valid lease serves read after new leader elected (clock skew) | LeaseImpliesLeader, ReadLinearizability | 5 |
| MC-3 | Leader steps down during config transition — uncommitted C_old,new truncated, new leader uses stale config | JointQuorum | 4 |
| MC-4 | INCONSISTENCY reply handling: can nextIndex decrease below matchIndex with pipelined responses? | NextIndexBound | 3 |
| MC-5 | Follower marked CAUGHTUP before config entry replicated — votes with outdated config in next election | ElectionSafety | 4 |
| MC-6 | Crash between term update and metadata persist — server restarts with old votedFor, votes twice in same term | ElectionSafety | 2 |
| MC-7 | Leader's commitIndex caps at flushIndex — verify no committed entry is un-flushed | CommitFlushBound | 1 |
| MC-8 | Pre-vote + leader validity: can a pre-vote round disrupt an existing leader? | ElectionSafety | 2 |
| MC-9 | Startup entry not yet committed — leader serves stale read | ReadLinearizability | 5 |
| MC-10 | `isCaughtUp` guard on `onFollowerTerm`: bootstrapping follower with higher term doesn't trigger step-down — can this create split-brain? | ElectionSafety | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Cache-before-persist ordering in LogSegment (RATIS-2434) | Concurrent append + read stress test with race detector |
| TV-2 | syncWithSnapshot drops pending writes without cache cleanup | Unit test: snapshot install during pending log writes |
| TV-3 | Partial state leak on write failure (RaftServerImpl.java:1017-1019 TODO) | Mock state machine preAppend to fail; verify no leaked TransactionContext |
| TV-4 | GrpcLogAppender restart leaves catchup=false (RATIS-2283) | Integration test: restart gRPC stream during staging |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Swapped log message arguments in startLeaderElection (RaftServerImpl.java:1797-1798) | Submit fix PR |
| CR-2 | `unsafeFlush` mode advances flushIndex before disk sync (SegmentedRaftLogWorker.java:380-383) | Document safety implications; verify no production use |
| CR-3 | `readLock` can be disabled, allowing read-write races on log cache (SegmentedRaftLog.java:224-227) | Document safety implications |
| CR-4 | `RaftLogIndex.updateIncreasingly` does set-then-check (RaftLogIndex.java:67-68) | Refactor to use CAS loop |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/ratis/analysis-report.md`
- **Key source files**:
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java` (1957 lines — core protocol handler)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java` (1331 lines — leader replication, commit, lease)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderElection.java` (625 lines — voting protocol)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java` (524 lines — shared state, persistence)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/VoteContext.java` (164 lines — vote decision logic)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/raftlog/RaftLogBase.java` (471 lines — commit index, log base)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderLease.java` (104 lines — lease mechanism)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/ReadIndexHeartbeats.java` (191 lines — read index protocol)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/ConfigurationManager.java` (118 lines — membership)
  - `artifact/ratis/ratis-server/src/main/java/org/apache/ratis/server/impl/RaftConfigurationImpl.java` (300+ lines — joint consensus)
- **JIRA issues**: RATIS-748, RATIS-1256, RATIS-1161, RATIS-981, RATIS-1268, RATIS-1912, RATIS-2154, RATIS-2274, RATIS-2044, RATIS-1927, RATIS-1773
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Ongaro dissertation (2014) §4.3 (Joint Consensus), §6.4 (ReadIndex)
