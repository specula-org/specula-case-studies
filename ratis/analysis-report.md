# Analysis Report: apache/ratis

## 1. Reconnaissance Summary

### 1.1 Project Structure

Apache Ratis is a Java implementation of the Raft consensus protocol, organized as a multi-module Maven project:

| Module | Purpose |
|--------|---------|
| `ratis-server` | Core Raft implementation (~68 Java files) |
| `ratis-server-api` | Server API interfaces |
| `ratis-common` | Shared types (RaftPeerId, RaftGroup, etc.) |
| `ratis-proto` | Protobuf message definitions |
| `ratis-grpc` | gRPC transport |
| `ratis-netty` | Netty transport |
| `ratis-client` | Client library |
| `ratis-test` | Test suite |

### 1.2 Core Files

| File | Lines | Component |
|------|-------|-----------|
| `impl/RaftServerImpl.java` | 1957 | Core protocol handler — all RPC handlers, role transitions |
| `impl/LeaderStateImpl.java` | 1331 | Leader replication coordination, commit index, lease, config changes |
| `impl/LeaderElection.java` | 625 | Two-phase election (pre-vote + election) |
| `impl/ServerState.java` | 524 | Shared Raft state (term, votedFor, leaderId), persistence |
| `raftlog/RaftLogBase.java` | 471 | Abstract log — commit index update, validation |
| `raftlog/segmented/SegmentedRaftLog.java` | 621 | Disk-persisted segmented log |
| `raftlog/segmented/SegmentedRaftLogWorker.java` | 753 | Async I/O task queue |
| `leader/LogAppenderBase.java` | 290 | Base log appender — request construction |
| `leader/LogAppenderDefault.java` | ~210 | RPC-based log appender — reply handling |
| `impl/VoteContext.java` | 164 | Vote decision logic |
| `impl/FollowerState.java` | 184 | Election timeout management |
| `impl/FollowerInfoImpl.java` | ~250 | Per-follower nextIndex/matchIndex tracking |
| `impl/ConfigurationManager.java` | 118 | Membership state management |
| `impl/RaftConfigurationImpl.java` | ~300 | Joint consensus configuration |
| `impl/LeaderLease.java` | 104 | Leader lease mechanism |
| `impl/ReadIndexHeartbeats.java` | 191 | ReadIndex protocol |
| `impl/ReadRequests.java` | 125 | Read request queue |
| `impl/TransferLeadership.java` | 347 | Leadership transfer |
| `impl/SnapshotInstallationHandler.java` | ~250 | Snapshot chunk assembly |
| `impl/StateMachineUpdater.java` | 376 | Apply committed entries |
| `storage/SnapshotManager.java` | 208 | Snapshot storage |

### 1.3 Concurrency Model

| Thread | Role | Key State |
|--------|------|-----------|
| RPC threads (gRPC/Netty) | Handle incoming RPCs: requestVote, appendEntries, installSnapshot | Access `RaftServerImpl` under `synchronized(this)` |
| FollowerState daemon | Monitor election timeout, trigger `changeToCandidate()` | `lastRpcTime`, `outstandingOp` counter |
| LeaderElection executor | Send vote requests in parallel, collect responses | Election-local state |
| LogAppenderDaemon (per follower) | Send AppendEntries/InstallSnapshot to one follower | `FollowerInfoImpl` (nextIndex, matchIndex) |
| EventProcessor (leader) | Process state update events (STEP_DOWN, UPDATE_COMMIT, CHECK_STAGING) | `EventQueue`, serialized execution |
| SegmentedRaftLogWorker | Async disk I/O: write, truncate, purge, flush | Task queue, flushIndex |
| StateMachineUpdater | Apply committed entries to state machine | appliedIndex |

**Synchronization boundaries**:
- `synchronized(this)` on `RaftServerImpl` — guards role transitions, term updates, RPC handling
- `ReentrantReadWriteLock` on `RaftLogBase` — guards log reads/writes
- `Runner` (single-thread assertion) — enforces sequential log operations
- `AtomicLong/AtomicReference` — lock-free reads of term, leaderId, commitIndex
- `CopyOnWriteArrayList` — thread-safe sender list iteration

### 1.4 Persistence Model

- **(term, votedFor)**: Persisted atomically via `AtomicFileOutputStream` (write-to-tmp + fsync + rename) in `RaftStorageMetadataFileImpl`
- **Log entries**: Appended to segment files via `SegmentedRaftLogOutputStream`, flushed via `FileChannel.force()`
- **Commit index**: NOT directly persisted — recovered from metadata entries in log (acknowledged TODO at SegmentedRaftLog.java:258)
- **Configuration**: Persisted both as log entries and as a separate file via `writeRaftConfiguration()`
- **Snapshot**: Written to temp directory, then atomically renamed on completion

---

## 2. Bug Archaeology

### 2.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits in repository | 1,936 |
| Unique RATIS JIRA IDs | 1,595 |
| Commits matching bug-related keywords | ~586 |
| Bug-fix commits touching core server files | ~302 |
| Confirmed significant bug-fix commits analyzed | ~100 |
| GitHub PRs examined | ~200 |
| PRs read with full comments | 50+ |
| Distinct confirmed bugs documented | 86 |

### 2.2 File Hotspot Analysis

| Rank | File | Bug-fix commit count | % of total |
|------|------|---------------------|-----------|
| 1 | `impl/RaftServerImpl.java` | 132 | 44% |
| 2 | `impl/ServerState.java` | 49 | 16% |
| 3 | `impl/LeaderStateImpl.java` | 40 | 13% |
| 4 | `impl/LeaderElection.java` | 31 | 10% |
| 5 | `impl/StateMachineUpdater.java` | 23 | 8% |
| 6 | `raftlog/segmented/LogSegment.java` | 18 | 6% |
| 7 | `impl/RaftServerProxy.java` | 16 | 5% |
| 8 | `raftlog/segmented/SegmentedRaftLogWorker.java` | 15 | 5% |
| 9 | `impl/SnapshotInstallationHandler.java` | 15 | 5% |

### 2.3 Bug Distribution by Component

| Component | Count | Critical | High | Medium |
|-----------|-------|----------|------|--------|
| Leader state / Replication | 16 | 3 | 11 | 2 |
| Election / Voting | 7 | 3 | 4 | 0 |
| Log storage / integrity | 10 | 2 | 5 | 3 |
| Snapshot | 8 | 0 | 5 | 3 |
| Deadlocks | 6 | 6 | 0 | 0 |
| Race conditions | 9 | 1 | 8 | 0 |
| Commit index | 5 | 3 | 2 | 0 |
| State machine | 5 | 1 | 4 | 0 |
| Memory leaks | 5 | 0 | 2 | 3 |
| NPE / State transitions | 7 | 0 | 5 | 2 |
| Read index | 4 | 0 | 4 | 0 |
| Configuration change | 5 | 0 | 4 | 1 |

### 2.4 Detailed Bug Inventory

#### Deadlocks (6 — all Critical)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-263 | `4d00b24d` | Deadlock from synchronized getFollowerNextIndices | Lock ordering conflict with election |
| RATIS-404 | `6f3419ad` | Deadlock between appendEntries and RaftLogWorker | `thenApply` ran callback on log worker thread |
| RATIS-1691 | `62edc69e` | Deadlock in server shutdown | Executor shutdown outside lifecycle block |
| RATIS-2162 | `d8482f1f` | Deadlock closing leaderState while logAppender sends snapshot | ConfigurationManager volatile fields + join() inside lock |
| RATIS-2345 | `e2c867da` | Leader stepDown deadlock | `.join()` blocked indefinitely on changeToFollower future |
| RATIS-2116 | `6390a28b` | appendEntries blocked indefinitely | `queue.isEmpty()` not thread-safe in flush decision |

#### Commit Index Bugs (5 — 3 Critical)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-748 | `425ed52f` | Follower might not update commit index | Term check applied before clamping to flushIndex |
| RATIS-1256 | `195c5720` | Leader updateCommit used wrong index | Iterated entries using stale data after commit update |
| RATIS-1161 | `bcc392ca` | Follower commit index unnecessarily required term check | Raft §5.4.2 term check should only apply to leader |
| RATIS-502 | `c779f7a5` | Commit index < snapshot index ignored on restart | `updateIncreasingly` rejected valid metadata |
| RATIS-2109 | `e66b5afc` | updateCommitIndex returned true when not increased | Missing comparison check |

#### Election Bugs (7 — 3 Critical)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-1268 | `82fe7075` | Leader cannot vote for candidate | Stale null FollowerState reference after changeToFollower |
| RATIS-1047 | `ea949f17` | Cannot elect leader when higher priority server crashes | Election REJECTED despite majority votes |
| RATIS-981 | `85a6fda4` | Stale leader not stepping down in split-brain | No majority heartbeat check (production) |
| RATIS-980 | `32e3eed4` | Leader election happens too fast | updateLastRpcTime called before vote grant |
| RATIS-1912 | `c35f769f` | Infinite election during membership change | Adding majority of new peers |
| RATIS-1796 | `05c0db04` | TransferLeadership stopped by heartbeat from old leader | Term not incremented early enough |
| RATIS-2274 | `c1301b08` | New peer retains outdated config, causing election failure | CAUGHTUP check didn't verify config entry replicated |

#### Log Replication Bugs (8 — all High)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-2434 | `b0697091` | Data race: SegmentedRaftLog.get() vs LogSegment.append() | Record added to list before cache entry |
| RATIS-2278 | `39acebf8` | Index validation race in NavigableIndices | Duplicate concurrent appends |
| RATIS-2314 | `b73c44ca` | SegmentedRaftLogWorker appends entry by itself | `thenCompose` ran on wrong thread |
| RATIS-2234 | `337df17c` | Lock race between heartbeat and append log | `writeLock()` blocked indefinitely |
| RATIS-2137 | `099d23f2` | LogAppenderDefault INCONSISTENCY handling | Missing requestFirstIndex tracking |
| RATIS-1883 | PR#914 | nextIndex < matchIndex in GrpcLogAppender | Pipelined responses; non-atomic next/match update |
| RATIS-1909 | `b7ffa1ba` | Decreasing next index on GrpcLogAppender reset | nextIndex could drop below matchIndex |
| RATIS-558 | `de557a71` | GrpcLogAppender doesn't reset on inconsistency | pendingRequests not cleared |

#### Snapshot Bugs (8)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-987 | `6add5871` | Infinite install snapshot loop | Exception didn't clear in-progress flag |
| RATIS-1577 | `29ebff2c` | Install snapshot failure | Wrong comparison (0 vs INVALID_LOG_INDEX) |
| RATIS-2147 | `5a470a2b` | MD5 mismatch | Shared MessageDigest via ThreadLocal |
| RATIS-2148 | `54a99162` | Incorrect reloadStateMachine | No chunk index validation |
| RATIS-1305 | `371fbfe3` | Leader stuck in infinite install snapshot cycle | No check if follower already caught up |
| RATIS-1369 | `00f0c858` | Wrong snapshotIndex (0 vs -1) | Missing INVALID_LOG_INDEX constant |
| RATIS-1481 | `7167fafe` | notifyInstallSnapshot state not serialized | Used server's snapshot index instead of log's |
| RATIS-2236 | `dd8486aa` | Manual triggerSnapshot never finishes | Updater wait loop didn't check trigger flag |

#### Read Index Bugs (4 — all High)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-2044 | `e1acb4bd` | ReadIndex loss from data race | failAll() raced with add() |
| RATIS-1927 | `39cbca5e` | Data race in ReadRequests | ConcurrentSkipListMap non-atomic |
| RATIS-1773 | `9f3134af` | readIndexHeartbeat used wrong index | callId instead of followerCommit |
| RATIS-2350 | `81c714dd` | readAfterWrite bugs | Wrong index selection |

#### State Machine / Transaction Bugs (5)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-2001 | `1ec1bd98` | TransactionContext wrongly reused | Index-only key; should be TermIndex |
| RATIS-2019 | `2b30cb83` | Abnormal exit of StateMachineUpdater | Wrong comparison in isApplied() |
| RATIS-2011 | `e7c6453a` | Truncated entry retains TransactionContext | Missing cleanup on truncation |
| RATIS-209 | `9494b75c` | SM updater may miss writeLog after leader change | Cache entry added before worker submit |
| RATIS-1216 | `a562d9e0` | preAppend exception always forces leader step-down | No `leaderShouldStepDown` flag |

#### Configuration Change Bugs (5)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-1912 | `c35f769f` | Infinite election during membership change | changeMajority violation |
| RATIS-2274 | `c1301b08` | New peer retains outdated config | matchIndex not checked against config entry |
| RATIS-1960 | `9bd82aa2` | Follower incorrectly marked as caught up | initializing flag logic inverted |
| RATIS-2283 | `21ce4e1f` | GrpcLogAppender restart leaves catchup=false | Staging state stale after restart |
| RATIS-2146 | `211278e5` | Concurrent deletion and election during member changes | Missing synchronization |

#### Leadership Transition Bugs (5)

| JIRA | Commit | Summary | Root Cause |
|------|--------|---------|------------|
| RATIS-2154 | `5578be7f` | Old leader sends AppendEntries after term changed | Term updated before role change |
| RATIS-1751 | `1c00461b` | Race between LeaderStateImpl and ServerState | Unsynchronized voterLists during config changes |
| RATIS-2321 | `6d471e64` | NPE after continuous leader changes | Null lastNoLeaderTime reference |
| RATIS-1861 | `45772bb7` | NPE in readAsync when leader is changing | LeaderState accessed between creation and start |
| RATIS-982 | `b2d367fa` | Illegal RUNNING→RUNNING transition | AppendEntries during startup |

---

## 3. Deep Analysis Findings

### 3.1 RPC Handler Precondition Check Matrix

| Check | requestVote | appendEntries | installSnapshot | startLeaderElection |
|-------|-------------|---------------|-----------------|---------------------|
| LifeCycle state | RUNNING | STARTING_OR_RUNNING | STARTING_OR_RUNNING | RUNNING then STARTING_OR_RUNNING |
| Group match | Yes | Yes | Yes | Yes |
| Term validation | VoteContext.checkTerm | state.recognizeLeader | state.recognizeLeader | state.recognizeLeader |
| Role check | Implicit (VoteContext) | No | No | isFollower() |
| Membership check | Candidate in conf | **NO** | **NO** | **NO** |
| Log consistency | Log up-to-date | prevLogIndex/Term | N/A | Log comparison |
| Persist metadata | Yes (L1478) | Yes (changeToFollowerAndPersistMetadata) | Yes | Deferred to initElection |

**Key finding**: No membership check for AppendEntries/InstallSnapshot senders. Compensated by single-leader-per-term invariant.

### 3.2 Persistence Atomicity Analysis

| Operation | Atomic? | Risk | Mitigation |
|-----------|---------|------|------------|
| persistMetadata (term + votedFor) | Yes (write-tmp + rename) | None | Single atomic disk write |
| Log append (cache + disk) | No (cache sync, disk async) | Entry visible in cache before durable | flushIndex gates commitIndex |
| Snapshot install (write + reload + purge) | No (multi-step) | Crash between steps | Recovery rebuilds from snapshot file on disk |
| Log truncation (delete files + truncate file) | No (multi-step) | Stale entries after crash | Re-truncated on next AppendEntries from leader |
| Segment roll (finalize + start) | No (two tasks) | No open segment after crash | Recovery handles missing open segment |

### 3.3 Reference Deviation Analysis (vs Raft Paper Figure 2)

| Raft Rule | Implementation | Status |
|-----------|---------------|--------|
| RequestVote: grant if log up-to-date | VoteContext.decideVote compares (term, index) | Correct + priority extension |
| RequestVote: persist vote before reply | persistMetadata() called before reply construction | Correct |
| RequestVote: one vote per term | votedFor check in VoteContext.checkTerm | Correct |
| AppendEntries: check prevLogIndex/prevLogTerm | checkInconsistentAppendEntries via containsTermIndex | Correct (stricter: checks exact TermIndex pair) |
| AppendEntries: truncate conflicting entries | cache.computeTruncateIndices detects term mismatch | Correct |
| AppendEntries: update commitIndex | min(leaderCommit, lastNewEntry) | Correct |
| Leader commit: only entries from current term | RaftLogBase.updateCommitIndex checks entry.term == currentTerm | Correct |
| New leader: append no-op entry | LeaderStateImpl appends startup config entry | Correct (uses config entry instead of no-op) |

**Extensions beyond Raft paper**:
1. **Pre-vote** (Ongaro dissertation §9.6): Two-phase election; pre-vote does not increment term, checks leader validity
2. **Priority-based election**: When logs equal, voter rejects candidates with lower priority
3. **Joint consensus** (Ongaro dissertation §4.3): Full C_old,new two-phase protocol with staging
4. **Leader lease**: Time-based lease (0.9 × minElectionTimeout) for read optimization
5. **ReadIndex protocol** (Ongaro dissertation §6.4): Heartbeat round for linearizable reads
6. **Leader transfer**: Explicit StartLeaderElection RPC with lease disable
7. **Flush index gate**: commitIndex bounded by flushIndex (not just log length)

### 3.4 Developer Signals (TODO/FIXME)

| Location | Signal | Severity |
|----------|--------|----------|
| RaftServerImpl.java:1017-1019 | "cancelTransaction() for failed requests" — partial state leak | High |
| SnapshotInstallationHandler.java:217 | "should only update State with installed snapshot once the request is done" | Medium |
| SegmentedRaftLog.java:258 | "should let raft peer persist its committed index periodically" | Medium |
| SegmentedRaftLog.java:335 | "if the cache is hitting the maximum size and we cannot evict any" | Low |
| ServerState.java:474 | "verify that we need to install the snapshot" | Low |

### 3.5 Key Code Path Analysis

#### Vote Decision Flow (VoteContext.java)

```
checkTerm():
  currentTerm > candidateTerm → FAILED
  currentTerm == candidateTerm → CHECK_LEADER (check votedFor + leader validity)
  currentTerm < candidateTerm → SKIP_CHECK_LEADER (higher term always wins)

checkLeader():
  I am leader with valid leadership → reject
  I am follower with valid leader (lastRpc < minRpcTimeout) → reject
  Otherwise → proceed to decideVote

decideVote():
  I am LISTENER → reject
  compareLog(myLastEntry, candidateLastEntry):
    candidate behind → reject ("candidate log not up-to-date")
    candidate ahead → grant
    equal → check priority: grant if voter.priority <= candidate.priority
```

#### Commit Index Advancement (LeaderStateImpl + RaftLogBase)

```
LeaderStateImpl.updateCommit():
  getMajorityMin(matchIndex[], flushIndex, threshold):
    For current config: sort matchIndex[], take median (floor(n/2))
    For old config (if transitional): sort separately, take median
    combine(): Math.min(currentMajority, oldMajority)

  RaftLogBase.updateCommitIndex(majorityIndex, currentTerm, isLeader):
    newCommitIndex = min(majorityIndex, flushIndex)  ← durability gate
    if !isLeader:
      commitIndex.updateIncreasingly(newCommitIndex)  ← follower trusts leader
    else:
      entry = getTermIndex(newCommitIndex)
      if entry.term == currentTerm:
        commitIndex.updateIncreasingly(newCommitIndex)  ← Raft §5.4.2
```

#### Leader Lease Extension (LeaderLease.java)

```
extend(followers, conf, serverId):
  activePeers = followers.filter(f → f.lastRespondedTime.elapsed < leaseTimeoutMs)
  if !conf.hasMajority(activePeers, serverId):
    return  ← no majority, don't extend

  timestamp = earliest(
    getMaxTimestampWithMajorityAck(currentConfig followers),
    getMaxTimestampWithMajorityAck(oldConfig followers)  ← joint consensus
  )
  lease.set(timestamp)

isValid():
  return lease.get().elapsedTimeMs() < leaseTimeoutMs
```

---

## 4. Cross-Reference: Bug Families

### Family 1: Commit Index Safety

**Mechanism**: Incorrect computation, ordering, or bounds checking of commitIndex.

| Bug | Component | Root Cause | Model-checkable? |
|-----|-----------|------------|-------------------|
| RATIS-748 | RaftLogBase | Term check before flushIndex clamp | Yes |
| RATIS-1256 | LeaderStateImpl | Stale iteration after commit update | Yes |
| RATIS-1161 | RaftLogBase | Follower wrongly required term check | Yes |
| RATIS-502 | RaftLogBase | updateIncreasingly rejected valid restart index | Yes (crash recovery) |
| RATIS-2109 | RaftLogBase | Return value incorrect | No (API semantics) |
| RATIS-2134 | SegmentedRaftLog | Metadata entry timing | No (I/O detail) |

**New findings from deep analysis**:
- `unsafeFlush` mode (SegmentedRaftLogWorker.java:380-383) advances flushIndex before disk sync, potentially allowing commit of non-durable data. **Severity: HIGH if enabled in production.**
- commitIndex is not directly persisted — recovered from metadata entries in log. Long-standing TODO. Safe per Raft but means re-application on restart.

### Family 2: Election and Leadership Transition

**Mechanism**: Stale state references during role transitions, incorrect priority/pre-vote interactions, missing guards.

| Bug | Component | Root Cause | Model-checkable? |
|-----|-----------|------------|-------------------|
| RATIS-1268 | RaftServerImpl | Stale FollowerState after changeToFollower | Yes (vote dropped) |
| RATIS-981 | LeaderStateImpl | No majority heartbeat check | Yes (stale leader) |
| RATIS-980 | FollowerState | Timer reset before vote grant | Yes (election timing) |
| RATIS-1047 | LeaderElection | Priority rejection despite majority | Yes (priority + partition) |
| RATIS-1912 | LeaderElection | changeMajority during config change | Yes (config + election) |
| RATIS-1796 | TransferLeadership | Term not incremented early enough | Yes (transfer + heartbeat) |
| RATIS-2154 | RaftServerImpl | Term updated before role change | Yes (stale leader send) |
| RATIS-2274 | LeaderStateImpl | CAUGHTUP without config entry | Yes (config + election) |

**New findings from deep analysis**:
- `onFollowerTerm()` at LeaderStateImpl.java:477-483 only triggers step-down for caught-up followers. A bootstrapping follower with a higher term is ignored. Could theoretically create a window where the leader doesn't learn about a new term.
- Pre-vote correctly has zero side effects on the receiver — no term update, no votedFor change, no role change.
- The `emptyCommit` filter in LeaderElection.java:518,569-571 prevents election of a leader whose voters have empty logs when the candidate has committed entries. This is a Ratis-specific safety mechanism.

### Family 3: Log Replication Index Management

**Mechanism**: Incorrect nextIndex/matchIndex tracking under pipelining, INCONSISTENCY handling, and snapshot installation.

| Bug | Component | Root Cause | Model-checkable? |
|-----|-----------|------------|-------------------|
| RATIS-1883 | GrpcLogAppender | nextIndex < matchIndex with pipelining | Yes |
| RATIS-1909 | GrpcLogAppender | nextIndex decreased on client reset | Yes |
| RATIS-2137 | LogAppenderDefault | Missing requestFirstIndex for INCONSISTENCY | Yes |
| RATIS-558 | GrpcLogAppender | Pending state not cleared on inconsistency | Yes |
| RATIS-1767 | FollowerInfoImpl | matchIndex initialized to 0 instead of -1 | Yes |
| RATIS-1835 | LogAppenderDefault | nextIndex decreased on heartbeat INCONSISTENCY | Yes |

**New findings from deep analysis**:
- `FollowerInfoImpl.setSnapshotIndex()` at lines 146-150 updates snapshotIndex, matchIndex, nextIndex sequentially (not atomic). Safe due to single-writer per follower.
- `RaftLogIndex.updateIncreasingly()` at lines 66-76 does set-then-check (not CAS) — latent atomicity issue if lock discipline is relaxed.
- `getNextIndexForInconsistency()` at LogAppenderBase.java:190-204 correctly bounds nextIndex >= matchIndex+1.

### Family 4: Configuration Change Safety

**Mechanism**: Joint consensus correctness, premature catch-up detection, overlapping config changes.

| Bug | Component | Root Cause | Model-checkable? |
|-----|-----------|------------|-------------------|
| RATIS-1912 | LeaderElection | changeMajority violation | Yes |
| RATIS-2274 | LeaderStateImpl | matchIndex < config entry index | Yes |
| RATIS-1960 | LeaderStateImpl | initializing flag inverted | Yes |
| RATIS-2283 | GrpcLogAppender | catchup flag stale after restart | Partial |
| RATIS-2146 | RaftServerImpl | Concurrent deletion + election | No (lifecycle) |

**New findings from deep analysis**:
- Triple guard against overlapping config changes at RaftServerImpl.java:1362-1366: `isStable && !inStagingState && isConfCommitted`. Correct.
- `hasMajority` correctly requires AND of old+new majorities during transitional state (RaftConfigurationImpl.java:281).
- `majorityRejectVotes` correctly uses OR for early election abort (RaftConfigurationImpl.java:290-293).
- Config recovery from log replay is correct — `removeConfigurations` handles truncation, `initialConf` is fallback.
- ConfigurationManager.java:117 TODO: "remove Configuration entries after they are committed" — unbounded memory growth, not a safety issue.

### Family 5: Linearizable Read Safety

**Mechanism**: Stale reads from lease timing gaps, race conditions in heartbeat tracking, incorrect index filtering.

| Bug | Component | Root Cause | Model-checkable? |
|-----|-----------|------------|-------------------|
| RATIS-2044 | AppendEntriesListeners | failAll() raced with add() | Partial |
| RATIS-1927 | ReadRequests | Non-atomic ConcurrentSkipListMap ops | No (Java concurrency) |
| RATIS-1773 | ReadIndexHeartbeats | callId instead of followerCommit | Yes |
| RATIS-2350 | ReadRequests | Wrong index selection | Yes |

**New findings from deep analysis**:
- **Configuration trap**: `leaderHeartbeatCheckEnabled=false` silently bypasses ALL read confirmation (line 1173). Every read returns immediately without heartbeat or lease check. This is the default for non-linearizable reads but dangerous if users expect linearizability.
- Leader lease initializes to current time at construction (LeaderLease.java:40), but `isReady()` gate prevents serving reads before startup entry is committed. FollowerInfo initial timestamps are artificially old, preventing false lease extension.
- No leadership re-check after heartbeat round completes — safe per ReadIndex protocol since readIndex was confirmed by majority.
- `followerCommit` filtering at ReadIndexHeartbeats.java:146 may incorrectly reject valid heartbeat acks (liveness concern, not safety).

### Family 6: Snapshot-Log Consistency

**Mechanism**: Gaps between snapshot index and log, incorrect state mutation during multi-step installation, validation errors.

| Bug | Component | Root Cause | Model-checkable? |
|-----|-----------|------------|-------------------|
| RATIS-1577 | SnapshotInstallationHandler | getNextIndex vs getLastCommittedIndex | Yes |
| RATIS-1369 | ServerState | 0 vs INVALID_LOG_INDEX | Yes |
| RATIS-1481 | SnapshotInstallationHandler | Server's vs log's snapshot index | Yes |
| RATIS-987 | SnapshotInstallationHandler | Exception didn't clear in-progress | Partial |
| RATIS-2148 | SnapshotInstallationHandler | No chunk index validation | No (transport) |
| RATIS-1305 | LogAppenderBase | No check if follower caught up | Yes |

**New findings from deep analysis**:
- `syncWithSnapshot` (SegmentedRaftLogWorker.java:261-267) drops pending write tasks without clearing cache entries beyond snapshot index. Could create entries readable from cache but never persisted.
- Non-atomic truncation on disk (SegmentedRaftLogWorker.java:672-715): deletes files before truncating remainder. Crash leaves stale entries, but re-truncated on next AppendEntries.
- Snapshot file write is the linearization point for recovery — log cleanup follows, and recovery rebuilds correctly from snapshot on disk.

---

## 5. False Positives Excluded

| Finding | Why Excluded |
|---------|-------------|
| No membership check on AppendEntries sender | Compensated by single-leader-per-term invariant; `recognizeLeader` checks term |
| In-memory non-atomicity of (term, votedFor) update | Protected by `synchronized(this)` block; not observable externally |
| `appliedIndex` advances before async `applyTransaction` completes | Reset from snapshot on recovery; only cosmetic during normal operation |
| RATIS-1403 (should not change state on rejected vote) | Discussed in PR#500; confirmed correct per Raft paper — must step down on higher term even when rejecting |
| LeaderLease starts valid at construction time | Gated by `isReady()` (startup entry must be committed); follower timestamps initialized artificially old |
| Configuration updated in memory before log append | Safe: config rebuilt from log on recovery |

---

## 6. Key Observations

1. **Concurrency is the dominant root cause**: 15+ of the top bugs are race conditions or deadlocks, reflecting Java's multi-threaded Raft implementation vs Go's single-goroutine approach (hashicorp/raft).

2. **RaftServerImpl.java is the #1 hotspot**: 44% of all bug-fix commits touch this file. Its 1957 lines handle all RPC dispatching, role transitions, and client requests.

3. **The `thenApply` vs `thenApplyAsync` antipattern** caused at least 3 critical bugs (RATIS-404, RATIS-2314, and variants). CompletableFuture callbacks running on the wrong thread is a systemic issue.

4. **Snapshot installation has 8 separate bugs** — the highest per-component count. This aligns with known industry experience: snapshot transfer is one of the hardest Raft operations.

5. **Commit index logic had 5 bugs** despite being a fundamental Raft invariant. The leader-vs-follower asymmetry (§5.4.2) and the flushIndex interaction are non-obvious correctness requirements.

6. **Priority-based election and pre-vote** add significant state space not present in the standard Raft spec. The priority veto mechanism (immediate abort on higher-priority rejection with timeout fallback) creates nuanced liveness properties.

7. **The joint consensus implementation is thorough** — dual-majority enforcement, staging/bootstrapping, triple guard against overlap. But 5 bugs in catch-up detection show the staging mechanism is error-prone.

8. **Leader lease correctly uses 0.9 × minElectionTimeout** ratio, ensuring expiry before follower election timeout. Clock skew remains the fundamental assumption.
