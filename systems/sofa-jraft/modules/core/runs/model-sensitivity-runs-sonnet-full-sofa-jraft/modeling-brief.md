# Modeling Brief: sofastack/sofa-jraft

## 1. System Overview

- **System**: sofa-jraft — Java production Raft consensus library used in Ant Group / Alibaba infrastructure
- **Language**: Java, ~6000 LOC core logic (NodeImpl: 3623, Replicator: 1909, LogManagerImpl: 1254, FSMCallerImpl: 789, SnapshotExecutorImpl: 780, ReadOnlyServiceImpl: 474)
- **Protocol**: Raft (with PreVote extension, Leadership Transfer, ReadIndex, ReadLease, learner nodes)
- **System Category**: **Category A (Distributed / Message-Passing)** — network RPC, disk I/O, cluster membership, protocol state machines. Crash-fault-tolerant only (not BFT).
- **Key architectural choices that deviate from reference algorithm**:
  - `ReadOnlyService` is a **separate component** with its own Disruptor queue, decoupled from the main FSM apply loop
  - `FSMCallerImpl` uses a **Disruptor ring buffer** (single writer) to serialize FSM applies, snapshot saves, and snapshot loads — with a bypass in `onSnapshotSaveSync`
  - `LogManagerImpl` uses an **async Disruptor** for disk writes: `lastLogIndex` advances in-memory immediately, disk write happens asynchronously. Commitments wait for the `StableClosure` callback
  - `BallotBox` uses a **StampedLock** with optimistic reads for the committed index
  - **Single-peer fast-path** in `readLeader()`: quorum == 1 returns immediately without the no-committed-entry-at-current-term guard
  - `Replicator` runs on multiple threads (RPC callbacks, timers, LogManager waiter callbacks) serialized via a per-replicator `ThreadId` lock
- **Concurrency model**: NodeImpl state protected by `ReentrantReadWriteLock`; Replicators have per-peer `ThreadId` lock; FSM applies serialized on single Disruptor consumer thread

---

## 2. Bug Families

### Family 1: Non-Atomic Vote Persistence (HIGH)

**Mechanism**: The vote-granting and election sequences involve multiple sequential disk writes that can leave durable state inconsistent across a crash, enabling double-voting in the same term.

**Evidence**:
- Historical (fixed, reference): commit `16a6b5f` — `electSelf()` sent RequestVote RPCs before `setTermAndVotedFor()` was called; crash between send and persist = no record of own vote on restart
- Historical (fixed, reference): commit `9f6f5dc` / issue #1244 — `handleRequestVoteRequest` set in-memory `votedId` and responded `granted=true` without checking `setVotedFor()` return value; silent disk failure = vote not persisted
- Code analysis: `NodeImpl.java:1856–1860` — **two-write window still present in higher-term vote grant path**: when `request.getTerm() > currTerm`, `stepDown(term, ...)` first writes `setTermAndVotedFor(term, emptyPeer)` (clearing votedFor), then line 1860 calls `setVotedFor(candidateId)` as a separate second write. Crash between these two writes leaves term persisted with empty votedFor → node can vote again after restart in the same term

**Affected code paths**:
- `NodeImpl.electSelf()` (fixed) — RPCs before persist
- `NodeImpl.handleRequestVoteRequest()` lines 1856–1860 — two-write window for higher-term grant path
- `LocalRaftMetaStorage.setTermAndVotedFor()` / `setVotedFor()` — the two separate disk writes

**Suggested modeling approach**:
- Variables: `persistedTerm [Server]`, `persistedVotedFor [Server]` — separate from in-memory currTerm/votedFor
- Actions: Split `HandleRequestVote` grant-with-higher-term into: step 1 `PersistTermEmpty` (writes term+emptyVote), step 2 `PersistVotedFor` (writes actual candidateId), step 3 sends response. Model `Crash` recovering from persisted state
- Also provide `HandleRequestVoteAtomic` for trace validation (normal non-crash path)

**Priority**: High
**Rationale**: Two historical safety bugs confirmed + unfixed variant (two-write window). Crash recovery is a classic TLA+ strength. Violation of vote-once-per-term is ElectionSafety.

---

### Family 2: Missing/Inconsistent Higher-Term Check on RPC Response Paths (HIGH)

**Mechanism**: Not all RPC response handlers check `response.term` to detect a higher-term peer and trigger stepdown. An EBUSY early-return and the InstallSnapshot handler are the two gaps.

**Evidence**:
- Code analysis: `Replicator.java:711–761` — `onInstallSnapshotReturned` checks `status.isOk()` and `response.getSuccess()` but **never checks `response.getTerm()`**. Compare: `onAppendEntriesReturned` failure path checks `response.getTerm() > r.options.getTerm()` at line 1469; `onHeartbeatReturned` checks at line 1219; `onTimeoutNowReturned` checks. The snapshot response is the sole missing case
- Code analysis: `Replicator.java:1454–1466` — when `response.getSuccess() == false` AND `response.getErrorCode() == EBUSY`, the handler returns immediately after `r.block()` without ever reaching the `response.getTerm() > r.options.getTerm()` check at line 1469. A follower can respond with EBUSY + a higher term and the leader will not step down

**Affected code paths**:
- `Replicator.onInstallSnapshotReturned()` (lines 711–761) — no term check on any response path
- `Replicator.onAppendEntriesReturned()` failure path (lines 1454–1482) — EBUSY early return bypasses term check

**Suggested modeling approach**:
- Variables: no new variables needed beyond standard `currentTerm[Server]`
- Actions: In `HandleInstallSnapshotResponse`, add term check: if `response.term > leaderTerm`, call `stepDown`. Model as two action variants: `HandleInstallSnapshotResponseWithHigherTerm` (steps down) and `HandleInstallSnapshotResponseNormal`
- For EBUSY: split `HandleAppendEntriesResponseBusy` into `HandleAppendEntriesResponseBusyWithHigherTerm` and `HandleAppendEntriesResponseBusyNormal`

**Priority**: High
**Rationale**: A stale leader can continue sending snapshots and potentially committing entries after a quorum has already elected a new leader. This is an ElectionSafety / LeaderCompleteness threat. The InstallSnapshot gap is independently discovered (not a variant of any fixed bug).

---

### Family 3: Snapshot Install / Applied-Index Notification Ordering (HIGH)

**Mechanism**: The snapshot installation path updates `lastAppliedIndex` directly (bypassing `setLastApplied()`) and therefore never fires `notifyLastAppliedIndexUpdated()`. ReadOnlyService's `onApplied()` callback is never triggered after a snapshot install, leaving pending ReadIndex closures stuck indefinitely until the periodic scanner fires.

**Evidence**:
- Code analysis: `FSMCallerImpl.java:728–731` — `doSnapshotLoad` sets `lastCommittedIndex`, `lastAppliedIndex`, `lastAppliedTerm` directly, then calls `done.run()`. Compare with `setLastApplied()` (line 578–583) used in the commit path, which calls `logManager.setAppliedId()` and `notifyLastAppliedIndexUpdated()`; both are missing from the snapshot path
- Code analysis: `FSMCallerImpl.java:578–584` — `setLastApplied` updates `lastAppliedIndex` (AtomicLong, line 580) and `lastAppliedTerm` (plain long, line 581) non-atomically. `onSnapshotSaveSync(done)` (line 491) bypasses the Disruptor queue and calls the snapshot-save handler directly from the caller's thread — concurrent with FSM Disruptor thread setting `lastAppliedTerm` — creating a torn read of the (index, term) pair for snapshot metadata
- Historical: Issue #1092 — commit index temporarily < snapshot index (acknowledged transient inconsistency)

**Affected code paths**:
- `FSMCallerImpl.doSnapshotLoad()` (lines 685–731) — missing `notifyLastAppliedIndexUpdated()` and `logManager.setAppliedId()`
- `FSMCallerImpl.onSnapshotSaveSync()` (line 491) — bypasses Disruptor, races with `setLastApplied`
- `ReadOnlyServiceImpl.onApplied()` (lines 384–424) — never receives snapshot-apply notifications; pending closures for snapshot-index reads sit in `pendingNotifyStatus`

**Suggested modeling approach**:
- Variables: `lastApplied [Server]`, `pendingReadIndex [Server -> set of indices]`, `snapshotInstalled [Server -> Boolean]`
- Actions: Split `InstallSnapshot` completion into: `FSMApplySnapshot` (updates lastApplied), `NotifyReadOnlyService` (fires onApplied callbacks), `LogTruncatePrefix` (updates log). Model the gap where `lastApplied` is visible but `pendingReadIndex` is not yet notified

**Priority**: High
**Rationale**: ReadIndex requests at indices ≤ snapshot index can sit in `pendingNotifyStatus` for up to `maxElectionDelayMs` without being resolved. If the node subsequently steps down, they may be resolved incorrectly by the follower (linearizability violation). Two distinct code analysis findings; the snapshot path divergence from the commit path is systematic.

---

### Family 4: ReadIndex Safety Gaps (HIGH)

**Mechanism**: Multiple paths under which stale reads can be served: (a) single-node clusters bypass a critical linearizability guard, (b) leader step-down does not clear pending ReadIndex closures that may subsequently fire on the former leader as a follower.

**Evidence**:
- Code analysis: `NodeImpl.java:1599–1607` — `readLeader()` fast-path for `quorum == 1` returns `success=true` with `lastCommittedIndex` without checking `logManager.getTerm(lastCommittedIndex) != currTerm`. The guard at lines 1610–1617 (present for multi-peer clusters) rejects reads when the leader hasn't committed a no-op at its term, preventing stale reads on newly elected leaders. The single-peer fast-path bypasses this check entirely
- Code analysis: `NodeImpl.java:1301–1360` — `stepDown()` calls `replicatorGroup.stopAll()` and `ballotBox.clearPendingTasks()` but does NOT call `readOnlyService.setError()` or clear `pendingNotifyStatus`. The only path that clears ReadOnlyService is `onError()` (line 2565). Pending ReadIndex closures from the leader term remain in `ReadOnlyServiceImpl.pendingNotifyStatus`; as a follower, the periodic scanner (`onApplied()` callback) can fire them with `success=true` if `lastAppliedIndex` advances past the readIndex — returning a successful stale read from a follower
- Historical: Issue #25 — ReadLease handling not rigorous (leader's `lastLeaderTimestamp` not updated on stepdown timer — fixed in v1.2.4)
- Historical: Issue #15 — PreVote missing leader lease check on responder side (fixed)

**Affected code paths**:
- `NodeImpl.readLeader()` (lines 1599–1607) — quorum==1 fast-path skips no-op-at-current-term guard
- `NodeImpl.stepDown()` (lines 1301–1360) — no readOnlyService cleanup
- `ReadOnlyServiceImpl.onApplied()` (lines 384–424) — fires pending closures from prior leader term after step-down

**Suggested modeling approach**:
- Variables: `pendingReadIndex [Server -> set of (index, term)]`, `lastApplied [Server]`, `readIndexSuccess [Server -> set of indices]`
- Actions: Add `ServeReadIndex` action that checks both `lastApplied >= readIndex` AND `logTerm(committedIndex) == currentTerm`. Model `StepDown` as clearing `pendingReadIndex`. For single-peer: model explicit no-op guard.
- Invariant: `ReadIndexSafety` — if `readIndexSuccess[s]` contains index `i`, then `logTerm(i) == termWhenReadIssued`

**Priority**: High
**Rationale**: The single-peer bypass is a linearizability violation for a common production deployment topology (single-node cluster). The step-down/pending-read gap is an independently-discoverable mechanism that can produce stale reads visible to clients.

---

### Family 5: Code Path Inconsistencies in Protocol Handlers (MEDIUM)

**Mechanism**: Multiple handler functions that should enforce the same protocol rule differ in what side effects they apply, leading to state divergence that is only observable under specific event orderings.

**Evidence**:
- Code analysis: `NodeImpl.java:3355–3422` — `handleInstallSnapshot` does not call `updateLastLeaderTimestamp(Utils.monotonicMs())`, while `handleAppendEntriesRequest` does at line 1994. A follower receiving only `InstallSnapshot` RPCs (catching up via snapshot) never updates `lastLeaderTimestamp`; `isCurrentLeaderValid()` returns false, triggering a spurious election during a legitimate long-running snapshot install. The guard `isInstallingSnapshot()` at `preVote()` blocks pre-vote but not the `resetLeaderId` call in `handleElectionTimeout()`
- Code analysis: `NodeImpl.java:2221` — `onCaughtUp()` ABA guard: `if (term != this.currTerm && this.state != State.STATE_LEADER)` uses `&&` instead of `||`. When `term != currTerm` but `state == STATE_LEADER` (node re-elected at higher term), the guard does NOT return early — a stale `confCtx.onCaughtUp(version, peer, true)` call proceeds with a version from the previous term, potentially advancing the configuration change state machine incorrectly
- Historical: Issue #15 — `handlePreVoteRequest` missing `isCurrentLeaderValid()` check (fixed)
- Historical: Issue #25 — lease timestamp not refreshed in stepdown timer (fixed)

**Affected code paths**:
- `NodeImpl.handleInstallSnapshot()` (lines 3355–3422) — missing `updateLastLeaderTimestamp`
- `NodeImpl.onCaughtUp()` (line 2221) — wrong logical operator in ABA guard
- `NodeImpl.handlePreVoteRequest()` vs `handleRequestVoteRequest()` — asymmetric term handling documented in deep analysis

**Suggested modeling approach**:
- Variables: `lastLeaderContact [Server]` — tracks when leader was last heard from, updated by AppendEntries and InstallSnapshot
- Actions: Ensure both `HandleAppendEntries` and `HandleInstallSnapshot` update `lastLeaderContact`. Model `ElectionTimeout` as checking `lastLeaderContact`.

**Priority**: Medium
**Rationale**: The missing `updateLastLeaderTimestamp` causes spurious elections during snapshot catch-up — primarily a liveness issue, not safety. The `onCaughtUp` wrong-operator bug is a correctness risk for configuration changes under leadership changes. Both are suitable for TLA+ state-space exploration.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Non-atomic vote persistence (two-write) | Family 1: historical safety bugs + unfixed variant in higher-term grant path | Split `HandleRequestVote` with higher-term into: `PersistTermEmptyVote` → `PersistActualVote` → `SendResponse`; add `Crash` recovering from persisted state |
| Crash and recovery | Family 1: validates persistence correctness; crash between two disk writes is the exploitable window | `Crash` action resets volatile state; restart reads from `persistedTerm`/`persistedVotedFor` |
| InstallSnapshot response term check | Family 2: unique gap — snapshot responses skip term validation present in all other response handlers | Add `HandleInstallSnapshotResponseHigherTerm` that steps down; check against `currentTerm` not `options.term` |
| AppendEntries EBUSY response | Family 2: EBUSY early-return bypasses term check | Split `HandleAppendEntriesResponseBusy` into higher-term and normal variants |
| ReadIndex pending closure lifecycle | Family 3+4: snapshot install doesn't notify; stepDown doesn't clear | Track `pendingReadIndex` per server; `StepDown` action clears it; `SnapshotInstall` fires `NotifyReadIndex` |
| Single-peer readLeader guard | Family 4: fast-path skips no-op-at-current-term check | In `ServeReadIndex`, require `logTerm(committedIndex) == currentTerm` unconditionally (no quorum special case) |
| lastLeaderContact updated by both AppendEntries and InstallSnapshot | Family 5: missing update causes spurious elections | Add `lastLeaderContact` variable; update in both handlers |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Disruptor ring buffer mechanics | Implementation detail (Java-specific); the Disruptor stall/deadlock bugs (#136, #138, #1105) require JVM thread semantics, not protocol logic |
| PreVote protocol | Adds state space. The PreVote-specific bugs (#15) are fixed. Modeling RequestVote alone is sufficient for ElectionSafety |
| Pipeline replication (`reqSeq`/`requiredNextSeq`) | Sequence number overflow (Finding Replicator-14) requires integer arithmetic modeling; low probability; not a protocol safety issue |
| Snapshot file copy / ProtoBufFile fsync | Fixed bug (#480); requires POSIX filesystem semantics beyond Raft protocol logic |
| Learner nodes | Not in standard Raft; adds state space without targeting any high-priority bug family |
| `nextIndex` / `matchIndex` replication arithmetic | Optimization detail; the TOCTOU in log availability check (Finding Replicator-6) is a low-probability race, not a protocol violation |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-atomic vote persist | `persistedTerm [Server]`, `persistedVotedFor [Server]` | Model crash between the two disk writes in vote grant | Family 1 |
| Crash/recovery | (uses persisted vars above) | Crash resets volatile state; restart reads from durable storage | Family 1 |
| Snapshot response term | (no new vars; reuse `currentTerm`) | Missing term check in InstallSnapshot response path | Family 2 |
| EBUSY term bypass | (no new vars) | EBUSY early-return bypasses higher-term detection | Family 2 |
| ReadIndex pending lifecycle | `pendingReadIndex [Server -> SUBSET Nat]` | Track outstanding read requests; verify they are cleared on step-down and notified on snapshot install | Family 3, 4 |
| lastLeaderContact | `lastLeaderContact [Server -> Int]` | Per-follower timestamp of last accepted AppendEntries or InstallSnapshot; drives election timer | Family 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | If two logs have an entry with the same index and term, they are identical up to that index | Standard |
| LeaderCompleteness | Safety | A committed entry appears in every future leader's log | Standard |
| VoteOncePerTerm | Safety | Each server grants at most one vote per term; survives crash + restart | Family 1 |
| PersistBeforeSend | Safety | A server's voted-for is durably stored before it responds granted=true | Family 1 |
| StepDownOnHigherTerm | Safety | If a leader receives any response (AppendEntries, Heartbeat, InstallSnapshot) with `term > currentTerm`, it steps down before committing further entries | Family 2 |
| ReadIndexSafety | Safety | A successful ReadIndex at committed index I was served by a node that had committed a no-op at its term at or before I | Family 3, 4 |
| NoPendingReadAfterStepDown | Safety | After stepDown, no pending ReadIndex closures remain that could be resolved with success | Family 4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Two-write window in higher-term vote grant: crash after `setTermAndVotedFor(term, emptyPeer)` but before `setVotedFor(candidateId)` allows the node to vote again after restart in the same term | VoteOncePerTerm, ElectionSafety | Family 1 |
| MC-2 | Can a leader continue committing entries after a follower has seen a higher term and responded to an `InstallSnapshot` RPC — since the leader never checks `response.term` in `onInstallSnapshotReturned`? | StepDownOnHigherTerm, LeaderCompleteness | Family 2 |
| MC-3 | Does the EBUSY early-return in `onAppendEntriesReturned` allow a leader to remain active when a quorum has already elected a new leader at a higher term (by responding with EBUSY + elevated term to the old leader)? | StepDownOnHigherTerm, ElectionSafety | Family 2 |
| MC-4 | In a single-node cluster, can a freshly elected leader (before committing a no-op at its term) serve a ReadIndex and return committed entries from a previous leader's term as "current"? | ReadIndexSafety | Family 4 |
| MC-5 | After leader step-down, can a pending ReadIndex request (with readIndex ≤ snapshot's lastIncludedIndex) be resolved by the former leader as a follower's `onApplied()` callback, returning a stale-read success to the client? | NoPendingReadAfterStepDown, ReadIndexSafety | Family 3, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `FSMCallerImpl.doSnapshotLoad` does not call `notifyLastAppliedIndexUpdated()` — pending ReadIndex closures at snapshot index wait for periodic scanner | Integration test: install snapshot with pending ReadIndex at snapshot index; verify closures are resolved before `maxElectionDelayMs` |
| TV-2 | `onSnapshotSaveSync` bypasses Disruptor serialization — concurrent `setLastApplied` creates torn read of `(lastAppliedIndex, lastAppliedTerm)` for snapshot metadata | Multi-thread test: concurrent snapshot save + log apply; verify snapshot meta term matches index |
| TV-3 | `LogManagerImpl.unsafeTruncateSuffix` crash window between in-memory truncation and async Disruptor disk write — on restart, log on disk may be longer than node believed at crash | Mock Disruptor to block; verify that after simulated crash, node on restart re-reads correct log boundaries from storage |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `NodeImpl.onCaughtUp()` ABA guard line 2221: `term != this.currTerm && state != STATE_LEADER` should be `||` — stale `confCtx.onCaughtUp()` can proceed when leader re-elected at higher term | Submit PR; change `&&` to `\|\|`; add unit test covering term-changed-but-still-leader scenario |
| CR-2 | `NodeImpl.handleInstallSnapshot()` missing `updateLastLeaderTimestamp()` call — follower catching up via snapshot can trigger spurious election | Add `updateLastLeaderTimestamp(Utils.monotonicMs())` call analogous to line 1994 in `handleAppendEntriesRequest` |
| CR-3 | `FSMCallerImpl.onConfigurationCommitted` asymmetry: called only for joint-stage changes in normal apply path but for non-joint changes in snapshot load path — FSM implementations relying on this for all membership changes will miss single-step adds/removes during normal operation | Document the contract explicitly; consider calling `onConfigurationCommitted` for all configuration entries |
| CR-4 | `Replicator.onHeartbeatReturned` failure path does not call `resetInflights()` — stale pipeline inflights remain when peer becomes reachable | Review inflights cleanup logic; ensure version-check guards all stale responses after reconnect |
| CR-5 | `ReadOnlyServiceImpl`: shutdown sentinel ring-buffer slot not cleared after handling (stale `shutdownLatch` on reused Disruptor slot can cause subsequent normal read events to be treated as shutdown) | Add `event.shutdownLatch = null` in the sentinel-event handler path |

---

## 7. Reference Pointers

- **Key source files**:
  - `jraft-core/src/main/java/com/alipay/sofa/jraft/core/NodeImpl.java` (3623 lines — main state machine)
  - `jraft-core/src/main/java/com/alipay/sofa/jraft/core/Replicator.java` (1909 lines — per-peer replication)
  - `jraft-core/src/main/java/com/alipay/sofa/jraft/storage/impl/LogManagerImpl.java` (1254 lines — log management)
  - `jraft-core/src/main/java/com/alipay/sofa/jraft/core/FSMCallerImpl.java` (789 lines — FSM + snapshot lifecycle)
  - `jraft-core/src/main/java/com/alipay/sofa/jraft/storage/snapshot/SnapshotExecutorImpl.java` (780 lines)
  - `jraft-core/src/main/java/com/alipay/sofa/jraft/core/ReadOnlyServiceImpl.java` (474 lines)
- **Bug fix commits** (fixed bugs, reference for mechanism evidence):
  - `16a6b5f` — electSelf RPCs before persist (vote safety)
  - `9f6f5dc` — setVotedFor return value unchecked (vote safety)
  - `747910e` — uncaught exception stalled apply pipeline
  - `8cdde76` — BallotBox lastCommittedIndex not initialized from snapshot
  - `2cef7ec` — RocksDB truncateSuffix double-evaluation bug
- **GitHub issues** (reference):
  - #1244, #1241 (vote persistence ordering — fixed)
  - #25 (ReadLease not rigorous — fixed)
  - #15 (PreVote missing lease check — fixed)
  - #136, #138, #1105 (Disruptor deadlock — partial mitigations)
  - #480 (snapshot metadata persistence — fixed)
  - #1092 (commit index < snapshot index transiently)
- **Reference algorithm**: Raft paper (Ongaro & Ousterhout, 2014); Diego Ongaro's TLA+ spec `raft.tla`
- **Analysis coverage**: 54 total commits analyzed; 22 bug-fix commits; 18 bug-label issues read; 15 issues read in full; git keywords: fix, bug, race, deadlock, correct, safety, crash, inconsistent
