# Analysis Report: sofastack/sofa-jraft

## 1. Codebase Reconnaissance

### 1.1 Module Structure

sofa-jraft is a Maven multi-module project:
- **jraft-core** — Core Raft implementation (~83,842 LOC, 279 Java files)
- **jraft-test** — Test utilities
- **jraft-example** — Example applications
- **jraft-rheakv** — Distributed KV store built on Raft
- **jraft-extension** — gRPC transport, BDB log storage

### 1.2 Core Files

| Component | File | LOC |
|-----------|------|-----|
| State machine / main node | `core/NodeImpl.java` | 3623 |
| Log replication / heartbeat | `core/Replicator.java` | 1909 |
| FSM application | `core/FSMCallerImpl.java` | 789 |
| Quorum tracking | `core/BallotBox.java` | 294 |
| Log management | `storage/impl/LogManagerImpl.java` | 1254 |
| Snapshot management | `storage/snapshot/SnapshotExecutorImpl.java` | 780 |
| Meta persistence | `storage/impl/LocalRaftMetaStorage.java` | 195 |
| Configuration | `conf/ConfigurationManager.java` | 110 |
| Ballot/quorum | `entity/Ballot.java` | 147 |

All files under: `jraft-core/src/main/java/com/alipay/sofa/jraft/`

### 1.3 Concurrency Model

1. **NodeImpl WriteLock**: `LongHeldDetectingReadWriteLock` (NodeImpl.java:169-174) protects all state changes
2. **Disruptors**: Two ring buffers — NodeImpl apply Disruptor (LogEntryAndClosure, MULTI producer, BlockingWait) and FSMCaller Disruptor (ApplyTask)
3. **Per-peer ThreadId locks**: Each Replicator has a `ThreadId` wrapping `ReentrantLock` for serialized state changes
4. **StampedLock**: BallotBox uses optimistic reads for high-throughput commit tracking
5. **Per-peer MpscSingleThreadExecutor**: AppendEntries processing serialized per peer
6. **Lock-Unlock-Relock pattern**: Used in `electSelf()`, `handleRequestVoteRequest()`, `handlePreVoteRequest()` to avoid holding locks during I/O (logManager.getLastLogId)

### 1.4 Atomicity Boundaries

- **Under NodeImpl writeLock**: State transitions, term changes, votedFor changes, election start
- **Under Replicator ThreadId lock**: nextIndex updates, state transitions, RPC response handling
- **Under BallotBox StampedLock write**: commitIndex advancement, ballot tracking
- **Under LogManager write lock**: Log append (in-memory), configuration tracking, lastLogIndex update
- **Async across Disruptors**: Log append (in-memory) → Log persist (disk Disruptor) → FSM apply (FSM Disruptor)

---

## 2. Bug Archaeology

### 2.1 Bug Hotspot Analysis

Files most frequently changed in fix commits:

| Count | File |
|-------|------|
| 41 | NodeImpl.java |
| 30 | Replicator.java |
| 16 | FSMCallerImpl.java |
| 14 | ReadOnlyServiceImpl.java |
| 9 | ReplicatorGroupImpl.java |
| 7 | BallotBox.java |

### 2.2 Critical Bug-Fix Commits

#### Vote / Election

| Commit | Summary | Severity |
|--------|---------|----------|
| `aab1c61` (#26) | Stale reads from wall-clock lastLeaderTimestamp; PreVote not rejected during valid lease | High |
| `29b8009` (#34) | lastLeaderTimestamp not volatile; lease check miscalculated | High |
| `570219d` (#357) | findTheNextCandidate ignored election priority; NotElected nodes could be selected | Medium |
| `4bd2a82` (#510) | Nodes not in config could trigger PreVote processing | Medium |
| `b6338f5` (#482) | Joint consensus skipped for single-peer changes (nchanges > 1 instead of > 0) | Critical |

#### Replication

| Commit | Summary | Severity |
|--------|---------|----------|
| `5d055ef` (#19) | Replicator permanently blocked when requireTrue threw before try block | High |
| `aec90ee` (#847) | waitId reset unexpectedly in onBlockTimeoutInNewThread | Medium |
| `0d8c96f` (#462) | Replicator state not set to Replicate on successful probe; duplicate block timers | Medium |
| `a1fa8c3` (#606) | Newer InstallSnapshot rejected while previous in progress | Medium |

#### Persistence / Crash Safety

| Commit | Summary | Severity |
|--------|---------|----------|
| `7f11eac` (#99) | Node continued after raft metadata save failure | Critical |
| `fa23d59` (#80) | Snapshot EOF detection and timeout issues for large snapshots | Medium |

#### ReadIndex / BallotBox

| Commit | Summary | Severity |
|--------|---------|----------|
| `83e3389` (#121) | ReadIndexResponseClosure concurrent access on event list | High |
| `8cdde76` (#1109) | BallotBox lastCommittedIndex initialized to 0 instead of snapshot index | High |
| `f8d84b6` (#361) | setErrorAndRollback broke ReadIndex promise by setting wrong lastAppliedIndex | High |
| `9787367` (#969) | Heartbeat blocked when FSM Disruptor full; follower thinks leader dead | High |

#### Deadlocks

| Commit/Issue | Summary | Severity |
|--------------|---------|----------|
| #138 | LogManager/Node Disruptor deadlock under backpressure | High |
| #1105 | Three-way Disruptor deadlock: writeLock → diskQueue → taskQueue → writeLock | High |
| `b0c5ee3` (#649) | Segment log storage producer/consumer deadlock | Medium |

### 2.3 Key GitHub Issues Investigated

| Issue | Status | Title | Confirmed | Safety Impact |
|-------|--------|-------|-----------|---------------|
| #1241 | Open | Non-atomic vote persistence in handleRequestVoteRequest | Not yet discussed | CRITICAL |
| #1242 | Open PR | Test demonstrating double-vote after setVotedFor IO failure | Test code proves bug | CRITICAL |
| #96 | Closed | Not handling RaftMetaStorage error returns | Confirmed by maintainer | HIGH |
| #882 | Closed | braft overwrites committed log — does jraft have it too? | Disputed for jraft (safe) | N/A |
| #1105 | Closed | Deadlock on configuration application when Disruptors full | Confirmed, reproduced | MEDIUM |
| #1195 | Open | FSMCallerImpl.done() causes task apply twice | Not fully confirmed | HIGH |
| #1092 | Closed | Commit index < snapshot index after restart | Confirmed, downplayed | MEDIUM |
| #480 | Closed | Snapshot metadata lost after crash (missing flush/fsync) | Confirmed, FIXED | HIGH |
| #781 | Closed | Heartbeat race condition: pendingErrors.add vs ThreadId.unlock | Confirmed | MODERATE |
| #583/#599 | Closed | Voting ping-pong from RPC connect timeout to dead nodes | Confirmed, FIXED | LOW (liveness) |
| #954 | Open | Two leaders observed (likely app-layer observation) | Uncertain | LOW |
| #981 | Open | AppendEntries term_unmatched stuck | Not fully confirmed | LOW-MEDIUM |
| #1232 | Open | ThreadId lock contention stalls leader during follower catch-up | Partially confirmed | LOW (availability) |
| #1198 | Open | Heartbeat blocked by node writeLock | Proposed optimization | LOW |
| #138 | Closed | LogManager/Node deadlock under backpressure | Confirmed | HIGH (availability) |

### 2.4 Excluded False Positives

| Issue | Why Excluded |
|-------|-------------|
| #882 | Maintainer demonstrated jraft is NOT vulnerable; jraft's stepDown ordering is correct |
| #954 | Likely Nacos application-layer stale leader cache, not Raft-level dual leadership |
| #583/#599 | Liveness issues with RPC connect timeout; no safety violation; FIXED |
| #683 | gRPC DNS caching issue in Kubernetes; transport-specific, not protocol logic |

---

## 3. Deep Analysis Findings

### 3.1 NodeImpl.java

#### Finding N-1: Non-atomic vote persistence (CRITICAL)
**Location**: NodeImpl.java:1857-1860
```java
stepDown(request.getTerm(), false, ...);  // persists (term, empty) via setTermAndVotedFor
this.votedId = candidateId.copy();         // in-memory update
this.metaStorage.setVotedFor(candidateId); // separate disk write
```
`stepDown()` calls `setTermAndVotedFor(term, emptyPeer)` (NodeImpl.java:1332), which persists `(term, empty)`. Then `setVotedFor(candidate)` is a second separate disk write. A crash between these two writes leaves `(term, empty)` on disk, allowing the node to vote for a different candidate in the same term after restart.

**Compensating mechanisms checked**: None found. The `onError()` handler in LocalRaftMetaStorage only fires on write failure, not between successful writes.

#### Finding N-2: electSelf() persistence ordering (HIGH)
**Location**: NodeImpl.java:1178-1218
The term is incremented in memory at line 1178, RPCs are sent at lines 1197-1215, and persistence happens at line 1218. If the node crashes between the RPC send and persistence, remote nodes may have granted votes for this term, but the candidate restarts with the old term.

**Compensating mechanisms checked**: The ABA check at line 1193 catches concurrent term changes but does NOT address the crash window between RPC send and persist.

#### Finding N-3: Missing ABA check in handlePreVoteRequest (MEDIUM)
**Location**: NodeImpl.java:1746-1754
After the lock-unlock-relock for `logManager.getLastLogId()`, the PreVote handler does NOT check if `currTerm` changed during the gap. All three other methods using this pattern (`electSelf`, `preVote`, `handleRequestVoteRequest`) DO perform ABA checks. This is the only one missing.

**Impact**: A stale PreVote grant could cause an unnecessary election, disrupting a stable leader. PreVote is non-persistent so no safety violation, but availability impact.

#### Finding N-4: setTermAndVotedFor() return value ignored (HIGH)
**Location**: NodeImpl.java:1332 (stepDown), NodeImpl.java:1218 (electSelf), NodeImpl.java:1860 (handleRequestVoteRequest)
All three callers ignore the return value. The `LocalRaftMetaStorage.save()` failure triggers `node.onError()` asynchronously, but there is a window between the failed write and the error callback where the node operates with in-memory state that won't survive a restart.

#### Finding N-5: Dual-leader detection term bump (MEDIUM)
**Location**: NodeImpl.java:1981-1992
When a follower detects two leaders in the same term, it bumps the term by 1. This is a defensive extension not in the standard Raft paper. Could cause unnecessary term inflation in pathological network scenarios.

#### Finding N-6: onCaughtUp ABA check logic (MEDIUM)
**Location**: NodeImpl.java:2221
```java
if (term != this.currTerm && this.state != State.STATE_LEADER) { return; }
```
Uses `&&` (bail if BOTH term changed AND not leader). Should arguably be `||` (bail if EITHER changed). In practice, equivalent due to Raft invariants, but the intent is ambiguous.

### 3.2 Replicator.java

#### Finding R-1: Missing term check in onInstallSnapshotReturned (HIGH)
**Location**: Replicator.java:711-761
The method checks `status.isOk()` (line 723) and `response.getSuccess()` (line 733) but NEVER checks `response.getTerm()`. Compare:
- `onHeartbeatReturned` (line 1219): checks `response.getTerm() > r.options.getTerm()` → steps down ✓
- `onAppendEntriesReturned` failure (line 1469): checks `response.getTerm() > r.options.getTerm()` → steps down ✓
- `onInstallSnapshotReturned`: **NO TERM CHECK** ✗
- `onTimeoutNowReturned` (line 1812): checks `response.getTerm() > r.options.getTerm()` → steps down ✓

If a follower responds to InstallSnapshot with a higher term, the stale leader does NOT step down and continues replicating with `nextIndex` updated (line 740).

#### Finding R-2: Incomplete step-down in AppendEntries success path (MEDIUM)
**Location**: Replicator.java:1519-1526
When AppendEntries succeeds but `response.getTerm() != r.options.getTerm()`, the code only resets to Probe and unlocks — does NOT call `increaseTermTo()`. The failure path (line 1469-1482) correctly calls `increaseTermTo()`.

**Compensating mechanisms checked**: If `response.getTerm() < leader.term`, ignoring is arguably correct (stale response). But if `response.getTerm() > leader.term` and `success=true`, the leader should step down. The Raft paper says followers should never return success with a higher term, but defensive coding should handle this.

#### Finding R-3: startHeartbeatTimer after lock release (MEDIUM)
**Location**: Replicator.java:1243-1245
After `sendProbeRequest()` returns (which releases the ThreadId lock inside), `startHeartbeatTimer(startTimeMs)` is called without the lock. This means `this.heartbeatTimer` is modified without synchronization — a data race.

#### Finding R-4: Heartbeat timer not cancelled before rescheduling (LOW)
**Location**: Replicator.java:1215, 1245, 1254
`startHeartbeatTimer()` is called without cancelling the previous timer. Multiple timer firings are possible, but the ThreadId lock prevents concurrent execution. Only wastes resources.

### 3.3 BallotBox.java

#### Finding B-1: "Not well proved" commit-all-preceding optimization
**Location**: BallotBox.java:127-132
```java
// When removing a peer off the raft group which contains even number of
// peers, the quorum would decrease by 1, so we need to handle this case
// here. It's not well proved right now so we just commit this entry.
```
When a config-change entry is committed, ALL preceding uncommitted entries are also committed. The developer explicitly acknowledges this is "not well proved."

#### Finding B-2: Incorrect StampedLock pattern in describe()
**Location**: BallotBox.java:272-276
`validate(stamp)` is called BEFORE reading the values, not after. This means a concurrent write could occur between validation and read, yielding inconsistent values. Only affects diagnostics/logging output.

### 3.4 FSMCallerImpl.java

#### Finding F-1: Uncaught exception in onApply aborts batch
**Location**: FSMCallerImpl.java:597-608
If the user's `fsm.onApply()` throws an uncaught exception, `lastAppliedIndex` is NOT advanced. Subsequent COMMITTED events re-attempt from the same index, potentially causing repeated failures.

#### Finding F-2: Double-apply prevention confirmed
**Location**: FSMCallerImpl.java:526
Guard `if (lastAppliedIndex >= committedIndex) { return; }` prevents processing the same entries twice. Single-threaded Disruptor consumer ensures no concurrent execution.

### 3.5 LogManagerImpl.java

#### Finding L-1: Entries visible before persistent
**Location**: LogManagerImpl.java:362, 372-376
Entries added to `logsInMemory` (line 362) are immediately readable before disk write completes. This is by design — the leader can replicate before local persistence. The leader's own `commitAt` only fires after the disk callback.

#### Finding L-2: Lock release during truncateSuffix
**Location**: LogManagerImpl.java:1038-1041
Lock is released to publish to disk queue, then re-acquired. During this window, concurrent log reads could see stale data. Mitigated by in-memory `lastLogIndex` already being updated.

### 3.6 LocalRaftMetaStorage.java

#### Finding M-1: In-memory update before persist, no rollback
**Location**: LocalRaftMetaStorage.java:184-189
```java
this.votedFor = peerId;  // in-memory first
this.term = term;        // in-memory first
return save();           // disk write may fail
```
If `save()` fails, in-memory state has diverged from persisted state. The `onError()` callback eventually transitions the node to ERROR state, but there's a window of inconsistency.

#### Finding M-2: Silent recovery with term=0 on corrupted meta file
**Location**: LocalRaftMetaStorage.java:98-99
If the meta file doesn't exist or is corrupted (`FileNotFoundException`), `load()` returns `true` with `term=0, votedFor=empty`. The node restarts with term=0, which could violate term monotonicity if the node previously operated at a higher term.

#### Finding M-3: Atomic persistence of term+votedFor (POSITIVE)
**Location**: LocalRaftMetaStorage.java:112-118
Both term and votedFor are bundled into a single `StablePBMeta` protobuf message and written in one `ProtoBufFile.save()` call. The `save()` uses write-to-temp + atomic-rename. This means a SUCCESSFUL `save()` atomically updates both values.

The problem (Finding N-1) is that `handleRequestVoteRequest` calls `setTermAndVotedFor(term, empty)` in `stepDown()` and then `setVotedFor(candidate)` separately — two atomic writes, but NOT atomic with respect to each other.

### 3.7 Configuration

#### Finding C-1: No committed vs uncommitted config distinction
**Location**: ConfigurationManager.java:38, 80-86
`getLastConfiguration()` returns the most recent config entry, which may be uncommitted. This is correct per Raft design (leader uses latest config), but means all components using `getLastConfiguration()` operate on potentially-uncommitted state.

#### Finding C-2: Joint consensus quorum correctly dual
**Location**: Ballot.java:144-146
`isGranted()` requires `this.quorum <= 0 && this.oldQuorum <= 0` — majority of BOTH old AND new configs. Correct.

---

## 4. Bug Family Summary

| Family | Name | Severity | Bug Count | TLA+ Suitability |
|--------|------|----------|-----------|-------------------|
| 1 | Vote Persistence Safety Violations | Critical | 6+ (3 historical, 3+ code analysis) | Excellent |
| 2 | Missing/Inconsistent Term Checks | High | 3 (1 missing, 1 incomplete, 1 historical) | Excellent |
| 3 | Disruptor Backpressure Deadlocks | Medium | 3+ historical | Poor (liveness, threading) |
| 4 | Configuration Change Interactions | Medium | 3+ historical, code concerns | Good |
| 5 | Crash Recovery State Inconsistencies | Medium | 4+ (2 historical, 2 code analysis) | Good |

---

## 5. Cross-Implementation Comparison Notes

Comparing with hashicorp/raft (from the example modeling brief):

| Concern | hashicorp/raft | sofa-jraft |
|---------|---------------|------------|
| Heartbeat independence | Separate goroutine, no term check on response | Same Replicator, independent timer, term check present on heartbeat but MISSING on InstallSnapshot |
| Vote persistence | Two separate disk writes (SetUint64 then Set) | Single protobuf write per call, BUT two separate calls in handleRequestVoteRequest |
| Leader lease | lastContact-based, uses latestConfig | Leader lease present, similar concerns but lease bugs already fixed (#26, #34) |
| Config committed vs latest | Two explicit variables (committed/latest) | Single list in ConfigurationManager, no explicit committed tracking |
| Disruptor/channel backpressure | Go channels with capacity limits | LMAX Disruptor with blocking when full, causing deadlocks |

Both implementations share the **non-atomic vote persistence** pattern — the most critical finding. The sofa-jraft variant is slightly different (two `save()` calls vs two `Set*()` calls) but the root cause is identical.

The **missing term check in onInstallSnapshotReturned** is unique to sofa-jraft and was not found in hashicorp/raft.
