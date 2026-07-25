# Modeling Brief: sofastack/sofa-jraft

## 1. System Overview

- **System**: sofa-jraft — Java Raft consensus library used by Ant Group's SOFA stack (Nacos, Seata, RheaKV)
- **Language**: Java, ~8400 LOC core logic (NodeImpl 3623, Replicator 1909, FSMCallerImpl 789, BallotBox 294, LogManagerImpl 1254, SnapshotExecutorImpl 780)
- **Protocol**: Raft with PreVote, Leadership Transfer, Joint Consensus, ReadIndex, Leader Lease
- **Key architectural choices**:
  - Uses **LMAX Disruptor** ring buffers for batching log appends and FSM application
  - **ReadWriteLock** on NodeImpl for all state changes; per-peer **ThreadId (ReentrantLock)** for Replicators
  - Heartbeat sent via the **same Replicator** (not independent goroutine) but on an **independent timer**
  - Vote persistence uses **two separate disk writes**: `stepDown()` writes `(term, empty)`, then `setVotedFor()` writes votedFor separately (NodeImpl.java:1857-1860)
  - Meta storage (term+votedFor) uses **ProtoBuf + write-to-temp + atomic-rename** pattern
- **Concurrency model**: Main state changes under NodeImpl writeLock; Replicators have per-peer ThreadId locks; FSM applies on dedicated Disruptor thread; Log persistence on separate Disruptor thread

## 2. Bug Families

### Family 1: Vote Persistence Safety Violations (CRITICAL)

**Mechanism**: Multiple paths where the Raft "vote at most once per term" invariant can be violated due to non-atomic persistence, unchecked error returns, and ordering issues.

**Evidence**:
- Historical: #96 — `setTermAndVotedFor()` return value ignored by all callers; node continues after failed persistence (maintainer confirmed)
- Historical: #1241 (open) — `setVotedFor()` return value not checked; in-memory votedId set before disk write (PR #1242 provides reproduction test)
- Code analysis: NodeImpl.java:1857-1860 — `stepDown()` persists `(term, empty)` then separate `setVotedFor(candidate)` call. Crash between these = term persisted but votedFor lost, allowing double-vote on restart
- Code analysis: NodeImpl.java:1218 — `electSelf()` sends RequestVote RPCs (line 1215) **before** persisting `(term, votedFor)` (line 1218). Crash between = term increment lost
- Code analysis: NodeImpl.java:1332 — `stepDown()` ignores `setTermAndVotedFor()` return value
- Code analysis: LocalRaftMetaStorage.java:184-189 — in-memory state updated **before** `save()`, no rollback on failure

**Affected code paths**:
- `handleRequestVoteRequest()` (NodeImpl.java:1804-1872)
- `electSelf()` (NodeImpl.java:1163-1226)
- `stepDown()` (NodeImpl.java:1297-1360)
- `LocalRaftMetaStorage.setTermAndVotedFor()` / `setVotedFor()` (LocalRaftMetaStorage.java:158-189)

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor` (on-disk state) separate from `currentTerm`, `votedFor` (in-memory)
- Actions: Split `HandleRequestVoteRequest` into: (1) `StepDown` persists `(term, empty)`, (2) `PersistVotedFor` persists votedFor. Model `Crash` recovering from persisted state only.
- Also split `ElectSelf` into: (1) increment term + send RPCs, (2) persist. Model crash between.
- For trace validation, provide atomic `HandleRequestVoteRequestAtomic` that does both in one step (normal non-crash path)

**Priority**: High
**Rationale**: Directly violates Raft Election Safety. Open issue #1241 with reproduction test. Historical #96 confirmed by maintainer. Multiple independent persistence gaps compound the risk.

---

### Family 2: Missing/Inconsistent Term Checks in Response Handlers (HIGH)

**Mechanism**: Not all RPC response handlers check `response.term > leader.term` and trigger step-down. A stale leader can continue operating after being superseded.

**Evidence**:
- Code analysis: Replicator.java:711-761 — `onInstallSnapshotReturned()` has **NO term check at all**. If a follower responds with a higher term, the leader does NOT step down and continues replicating.
- Code analysis: Replicator.java:1519-1526 — `onAppendEntriesReturned()` success path checks `response.getTerm() != r.options.getTerm()` but only resets to Probe state. Does NOT call `increaseTermTo()` to step down. Compare with failure path at line 1469-1482 which correctly steps down.
- Reference: `onHeartbeatReturned()` (Replicator.java:1219-1232) correctly checks and steps down
- Reference: `onTimeoutNowReturned()` (Replicator.java:1812-1818) correctly checks and steps down

**Affected code paths**:
- `onInstallSnapshotReturned()` (Replicator.java:711-761) — **missing**
- `onAppendEntriesReturned()` success branch (Replicator.java:1519-1526) — **incomplete**
- `onHeartbeatReturned()` (Replicator.java:1219-1232) — correct
- `onTimeoutNowReturned()` (Replicator.java:1812-1818) — correct

**Suggested modeling approach**:
- Actions: Model each response handler as a separate action. For `HandleInstallSnapshotResponse`, omit the term check (matching the code). For `HandleAppendEntriesResponseSuccess`, include the no-step-down behavior.
- Invariant: Check if a superseded leader can continue serving writes.

**Priority**: High
**Rationale**: Classic "path inconsistency" bug. 4 response handlers, 2 have correct term checks, 1 is completely missing, 1 is incomplete. Directly model-checkable.

---

### Family 3: Disruptor Backpressure Deadlocks (MEDIUM)

**Mechanism**: Circular lock dependency between NodeImpl.writeLock and Disruptor ring buffers when all queues are full simultaneously.

**Evidence**:
- Historical: #138 — LogManager/Node Disruptor deadlock under load (confirmed, 2019)
- Historical: #1105 — Deadlock when all three Disruptors full: writeLock -> diskQueue -> taskQueue -> writeLock (confirmed, reproduced, 2024)
- Historical: #1195 — FSMCallerImpl `iterImpl.done()` exception causes task apply twice + deadlock variant (open)
- Code analysis: `executeApplyingTasks()` holds writeLock, calls `logManager.appendEntries()` which blocks on full diskQueue; diskQueue consumer blocks on full FSM taskQueue; FSM consumer needs writeLock for `onConfigurationChangeDone()`

**Affected code paths**:
- `NodeImpl.executeApplyingTasks()` (NodeImpl.java:1395-1457)
- `LogManagerImpl.StableClosureEventHandler` (LogManagerImpl.java:521-599)
- `FSMCallerImpl.ApplyTaskHandler` (FSMCallerImpl.java:143-159)
- `NodeImpl.onConfigurationChangeDone()` (NodeImpl.java — config change callback)

**Suggested modeling approach**:
- This is primarily a liveness/availability bug, not a safety bug
- Variables: `disruptorFull [Component -> BOOLEAN]`
- Actions: Model Disruptor publish as blocking when full; model the circular dependency
- Invariant: Liveness check — eventually a committed entry is applied

**Priority**: Medium
**Rationale**: Confirmed by maintainers, reproduced multiple times. But it's an availability issue (deadlock = node halts), not a safety issue (no data corruption). Other nodes will elect a new leader.

---

### Family 4: Configuration Change Interactions (MEDIUM)

**Mechanism**: Interactions between joint consensus, election quorum, and commit quorum during configuration changes have subtle edge cases.

**Evidence**:
- Historical: commit `b6338f5` / #482 — Joint consensus was skipped for single-peer changes (`nchanges > 1` instead of `> 0`). FIXED.
- Historical: commit `4bd2a82` / #510 — Nodes not in config could still trigger PreVote processing. FIXED.
- Code analysis: BallotBox.java:127-132 — Developer comment: "not well proved right now" about committing all preceding uncommitted entries when a later config-change entry is committed.
- Code analysis: ConfigurationManager.java — No explicit committed vs uncommitted config distinction; `getLastConfiguration()` returns possibly-uncommitted config.
- Code analysis: NodeImpl.java:509-515 — Switch fall-through from `STAGE_CATCHING_UP` to `STAGE_JOINT` when `nchanges == 0` (fragile code).

**Affected code paths**:
- `ConfigurationCtx.nextStage()` (NodeImpl.java:506-533)
- `BallotBox.commitAt()` (BallotBox.java:99-143)
- `Ballot.init()` / `Ballot.isGranted()` (Ballot.java:69-91, 144-146)
- `ConfigurationManager.getLastConfiguration()` (ConfigurationManager.java:80-86)

**Suggested modeling approach**:
- Variables: `config [Server -> Configuration]`, `configState [Server -> {None, Joint, Stable}]`
- Actions: `ProposeConfigChange`, `CommitJointConfig`, `CommitStableConfig`, `StepDownRemovedLeader`
- Key: Ballot quorum uses latest (possibly uncommitted) config per Raft design
- Invariant: At most one uncommitted config change at a time; ElectionSafety holds during transitions

**Priority**: Medium
**Rationale**: Historical fixes show this area is error-prone. The "not well proved" comment from developers is a strong signal. TLA+ is ideal for exploring config change + election interleavings.

---

### Family 5: Crash Recovery State Inconsistencies (MEDIUM)

**Mechanism**: After a crash, the node may restart with incomplete or inconsistent persistent state, violating invariants.

**Evidence**:
- Historical: #480 — Snapshot metadata lost after crash due to missing `flush()` before `fsync()` and missing directory `fsync()` after rename (FIXED by PR #481)
- Historical: #1092 — `BallotBox.lastCommittedIndex` initialized to snapshot index (not true committed index) after restart. Developer acknowledges but downplays: "doesn't seem to have substantial impact"
- Code analysis: LocalRaftMetaStorage.java:98-99 — If meta file is corrupted/missing, silently returns `true` with `term=0`. Node restarts with term=0, potentially violating term monotonicity.
- Code analysis: NodeImpl.java:1127-1148 — BallotBox init uses `snapshotIndex` not true committed index for multi-node clusters
- Historical: commit `7f11eac` / #99 — Added halt-on-meta-persist-failure (defensive fix)

**Affected code paths**:
- `LocalRaftMetaStorage.load()` (LocalRaftMetaStorage.java:89-104)
- `NodeImpl.initBallotBox()` (NodeImpl.java:1127-1148)
- `SnapshotExecutorImpl.onSnapshotSaveDone()` (SnapshotExecutorImpl.java:400-461)

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor`, `persistedLog`, `snapshotIndex`
- Actions: `Crash` resets volatile state, recovers from persisted state. `Restart` reinitializes from persisted + snapshot state.
- Invariant: After recovery, node's term >= all terms it previously operated with; committed entries not lost

**Priority**: Medium
**Rationale**: Multiple historical bugs show crash recovery is a real problem area. TLA+ with crash/recovery actions is well-suited. The silent term=0 recovery is concerning but requires specific filesystem failure conditions.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Non-atomic vote persistence | Family 1: Critical safety violation, open issue #1241, reproduction test exists | Split vote handling into two persistence steps + Crash action |
| Persistence ordering in electSelf | Family 1: RPCs sent before persist, crash window for term loss | Model RPC send before persist, with crash between |
| Missing term check in InstallSnapshot response | Family 2: Stale leader continues after being superseded | Omit term check in HandleInstallSnapshotResponse action |
| Incomplete term check in AppendEntries success | Family 2: Stale leader doesn't step down on success path | Model success-path without step-down |
| Joint consensus quorum | Family 4: "Not well proved" developer comment, historical fixes | Model dual-quorum Ballot with config change transitions |
| Crash and recovery | Family 1+5: Validates persistence correctness | Crash action resets volatile state; Restart recovers from persisted |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Disruptor deadlocks | Family 3: Availability issue, not safety. Requires modeling Java threading primitives not suited for TLA+. |
| PreVote | Not related to high-priority bug families. Adds state space without targeting known issues. |
| Snapshot transfer | Important but not in top families. Would significantly expand spec scope. |
| ReadIndex / LeaseRead | Historical bugs (#26, #34, #121) are FIXED. Not in active bug families. |
| Pipeline replication ordering | Implementation optimization detail. Requires modeling Java PriorityQueue semantics. |
| FSM double-apply (#1195) | Requires modeling exception propagation in Java Disruptor, not protocol logic. |
| Lock contention (#1232, #1198) | Performance/availability concerns, not safety violations. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-atomic vote persist | `persistedTerm`, `persistedVotedFor` | Separate in-memory from on-disk vote state | Family 1 |
| Persistence ordering | `persisted [Server -> BOOLEAN]` | Track whether current term+vote has been durably written | Family 1 |
| Response term check variants | (split in actions, no new vars) | Model missing/incomplete term checks per response type | Family 2 |
| Dual configuration | `config`, `oldConfig`, `configState` | Capture joint consensus transitions | Family 4 |
| Crash/Recovery | `crashed [Server -> BOOLEAN]` | Model crash between persistence steps | Family 1, 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard + Family 1, 2 |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard + Family 4, 5 |
| VoteOncePerTerm | Safety | Each server votes for at most one candidate per term (across crashes) | Family 1 |
| TermMonotonicity | Safety | A server's persisted term never decreases (even across crashes) | Family 1, 5 |
| StaleLeaderDetection | Safety | A leader with a superseded term eventually steps down | Family 2 |
| ConfigSafety | Safety | At most one uncommitted config change at a time | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Non-atomic vote persist: crash between stepDown(term,empty) and setVotedFor(candidate) | VoteOncePerTerm, ElectionSafety | 1 |
| MC-2 | electSelf sends RPCs before persisting (term,votedFor) | VoteOncePerTerm, ElectionSafety | 1 |
| MC-3 | onInstallSnapshotReturned missing term check: stale leader continues | StaleLeaderDetection | 2 |
| MC-4 | onAppendEntriesReturned success path doesn't step down on term mismatch | StaleLeaderDetection | 2 |
| MC-5 | Joint consensus "commit all preceding" optimization | LeaderCompleteness | 4 |
| MC-6 | Corrupted meta file → silent restart with term=0 | TermMonotonicity, VoteOncePerTerm | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Heartbeat timer not cancelled before rescheduling (Replicator.java:1215,1245) | Inject slow heartbeat responses, check for redundant heartbeats |
| TV-2 | startHeartbeatTimer called after lock released by sendProbeRequest (Replicator.java:1243-1245) | Concurrent test with lock contention |
| TV-3 | FSM uncaught exception leaves lastAppliedIndex stale (FSMCallerImpl.java:597-608) | Mock FSM that throws, verify recovery |
| TV-4 | Log truncation lock release window (LogManagerImpl.java:1038-1041) | Concurrent read during truncation |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Missing ABA check in handlePreVoteRequest after relock (NodeImpl.java:1746-1754) | Add term check like handleRequestVoteRequest has |
| CR-2 | Switch fall-through in ConfigurationCtx.nextStage (NodeImpl.java:509-515) | Add explicit break or comment |
| CR-3 | onCaughtUp ABA check uses && instead of \|\| (NodeImpl.java:2221) | Review logic, consider changing to \|\| |
| CR-4 | Incorrect StampedLock optimistic read pattern in BallotBox.describe (BallotBox.java:272-276) | Move validate() after reads |
| CR-5 | Error message says "heartbeat_response" in AppendEntries handler (Replicator.java:1481) | Fix copy-paste error in log message |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/sofa-jraft/analysis-report.md`
- **Key source files**:
  - `artifact/sofa-jraft/jraft-core/src/main/java/com/alipay/sofa/jraft/core/NodeImpl.java` (3623 lines — state machine, vote handling, config changes)
  - `artifact/sofa-jraft/jraft-core/src/main/java/com/alipay/sofa/jraft/core/Replicator.java` (1909 lines — replication, heartbeat, response handling)
  - `artifact/sofa-jraft/jraft-core/src/main/java/com/alipay/sofa/jraft/core/BallotBox.java` (294 lines — quorum tracking)
  - `artifact/sofa-jraft/jraft-core/src/main/java/com/alipay/sofa/jraft/core/FSMCallerImpl.java` (789 lines — state machine application)
  - `artifact/sofa-jraft/jraft-core/src/main/java/com/alipay/sofa/jraft/storage/impl/LocalRaftMetaStorage.java` (195 lines — term/vote persistence)
  - `artifact/sofa-jraft/jraft-core/src/main/java/com/alipay/sofa/jraft/storage/impl/LogManagerImpl.java` (1254 lines — log operations)
- **GitHub issues**: #96, #1241 (Family 1); #781 (Family 2); #138, #1105, #1195 (Family 3); #482, #510 (Family 4); #480, #1092 (Family 5)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014)
