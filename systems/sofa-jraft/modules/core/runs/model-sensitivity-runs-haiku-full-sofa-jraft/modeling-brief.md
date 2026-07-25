# SOFAJraft Modeling Brief

## 1. System Overview

**System**: SOFAJraft — a production Java implementation of Raft consensus algorithm supporting MULTI-RAFT-GROUP.

**Category**: **Category A (Distributed / Message-Passing)**. This is a replicated state machine implementing the Raft consensus protocol. The main risks are protocol logic violations (split-brain, duplicate application), crash-recovery safety, and message-handling inconsistencies across nodes.

**Scale**: ~9,000 lines of core logic (NodeImpl: 3623, Replicator: 1909, FSMCallerImpl: 789, BallotBox: 294, ReplicatorGroupImpl: 315, etc.)

**Reference Algorithm**: [Raft Consensus](https://raft.github.io/) (Ongaro & Ousterhout)

**Key Architectural Deviations**:
- **Asynchronous persistence**: Separate threads handle log/meta storage; no atomic disk operations
- **Pipeline replication**: Sends multiple AppendEntries in parallel instead of one-at-a-time
- **Disruptor-based FSM application**: Ring buffer for task queueing; allows batching but introduces queueing races
- **Independent replicator threads**: Each follower has its own Replicator thread, enabling concurrent state updates with global consistency risks
- **Multi-tiered locking**: ReadWriteLocks in Node, StampedLocks in BallotBox; potential for deadlock or stale reads

**Concurrency Model**: Multi-threaded with separate event loops for:
- Node (state machine, RPC handlers) — ReadWriteLock-protected
- Replicator (log replication) — Per-follower threads
- FSMCaller (state machine application) — Disruptor-based event loop
- BallotBox (vote tracking) — StampedLock with concurrent grant() calls

---

## 2. Bug Families

### Family 1: Non-Atomic Persistence Windows

**Mechanism**: Multi-step durable operations with crash-induced inconsistency windows between memory writes and persistent storage.

**Evidence**:
- **Historical**: Issue #1260 "add null check and graceful degradation in AppendEntries" (GitHub PR #1260, merged 2026-04-XX) suggests missing defensive checks, likely stemming from partial persistence failures
- **Code analysis**:
  - NodeImpl:1178-1218 (electSelf): currTerm and votedId incremented in memory (lines 1178-1179) but persisted to metaStorage after unlock/relock cycle at line 1218
  - NodeImpl:1859-1860 (handleRequestVoteRequest): votedId updated in memory at line 1859, then metaStorage.setVotedFor() at line 1860 — non-atomic
  - Replicator:1534, 1544 (onAppendEntriesReturned): BallotBox.commitAt() uses nextIndex before nextIndex is incremented; crash between lines 1534-1544 causes log inconsistency
  - FSMCallerImpl:578-583 (setLastApplied): lastAppliedIndex.set() and logManager.setAppliedId() not atomic; divergence between FSM and LogManager views

**Affected code paths**: 
- electSelf() leader election
- handleRequestVoteRequest() vote granting
- onAppendEntriesReturned() replication success
- setLastApplied() FSM progress tracking

**Suggested modeling approach**:
- **Variables**: Add `persistentTerm`, `persistentVotedFor`, `persistentLastApplied` to track durable state separately from in-memory state
- **Actions**: Split persistence operations into multi-step sequences; model crashes between steps
- **Granularity**: Each persist operation is a separate action; allows TLC to explore interleaving

**Priority**: **CRITICAL** — All three are protocol safety violations: crash could allow same follower to vote twice in different terms, or FSM could apply wrong entries to state machine.

---

### Family 2: Code Path Inconsistency in Message Handlers

**Mechanism**: Multiple RPC handlers (AppendEntries, RequestVote, InstallSnapshot) that should enforce the same protocol rules but differ in important validation checks.

**Evidence**:
- **Code analysis**:
  - NodeImpl:1830-1833 vs 1980-1992: RequestVoteRequest handler does NOT validate leader identity after stepDown, while AppendEntriesRequest explicitly checks `!serverId.equals(this.leaderId)` and increments term for conflict. RequestVote skips this, allowing stale leaders to cause term inconsistencies.
  - NodeImpl:1996 vs 2713: handleAppendEntriesRequest only rejects if `entriesCount > 0 && isInstallingSnapshot()`, but preVote rejects unconditionally during snapshot. handleInstallSnapshot has no reciprocal check, creating asymmetry.
  - BallotBox:115-122 (concurrent vote counting): Multiple replicators call commitAt() concurrently; Ballot.grant() decrements quorum without cross-ballot validation of overlapping indices.

**Affected code paths**:
- RequestVote handlers vs AppendEntries handlers
- Snapshot installation vs heartbeat replication
- Vote counting with overlapping log ranges

**Suggested modeling approach**:
- **Variables**: Model `leaderId` as explicit per-handler state
- **Actions**: Split message handlers into variants: one for request-vote, one for append-entries, one for install-snapshot; each enforces complete validation
- **Granularity**: One action per handler type; allows spec to assert consistent preconditions

**Priority**: **HIGH** — Can lead to split-brain (two leaders in same term) or stale configuration application.

---

### Family 3: Unsafe Unlock-Relock Patterns (ABA Races)

**Mechanism**: Code releases locks to perform I/O or expensive operations, then reacquires locks assuming state hasn't changed. The ABA check (verifying term/state matches) is insufficient because intermediate state changes aren't guarded.

**Evidence**:
- **Code analysis**:
  - NodeImpl:1840-1850 (handleRequestVoteRequest): Unlocks at line 1841 to fetch lastLogId, relocks at line 1846. ABA check at line 1848 only verifies `term` and `state`, not that lastLogId is still valid. Another RequestVote(term=5) could arrive and update state; by the time we relock, the fetched lastLogId is stale, but we don't re-fetch it.
  - Replicator:622-708, 711-760 (installSnapshot, onInstallSnapshotReturned): Reader is checked for null at line 636, but between check and use (line 639), another thread's resetInflights() at line 1392 could set it to null. Use-after-release of snapshot reader.

**Affected code paths**:
- handleRequestVoteRequest vote validation
- Snapshot reader lifecycle

**Suggested modeling approach**:
- **Variables**: Track lock ownership; model "unlock window" as explicit state
- **Actions**: Split into lock/check/unlock/relock sequence; allow other actions to fire in between
- **Granularity**: Unlock window is its own action; allows TLC to explore concurrency

**Priority**: **HIGH** — Can cause double-voting (multiple votes in same term) or use-after-free of resources.

---

### Family 4: Volatile Field Non-Atomic Compound Operations

**Mechanism**: Volatile fields are accessed in sequences (read-modify-write) that are atomic individually but not as a compound operation. Between read and write, concurrent threads can observe intermediate states.

**Evidence**:
- **Code analysis**:
  - Replicator:92, 1544-1545: `nextIndex` is volatile. Operations like `nextIndex += entriesSize` are non-atomic: load, add, store. Between load and store, another thread's snapshot installation at line 740 (`nextIndex = lastIncludedIndex + 1`) can execute.
  - Replicator:687 (incrementing installSnapshotCounter on volatile field): Marked as NonAtomicOperationOnVolatileField; multiple concurrent increments can be lost
  - FSMCallerImpl: applyingIndex (AtomicLong at line 123) and lastAppliedIndex (AtomicLong at line 580) are written separately; not atomic as a pair

**Affected code paths**:
- Replication state tracking (nextIndex)
- Snapshot installation progress (installSnapshotCounter)
- FSM progress tracking (applyingIndex + lastAppliedIndex)

**Suggested modeling approach**:
- **Variables**: Model atomic fields as single-step writes, not compound operations
- **Actions**: If compound operation needed, either use a lock or split into atomic sub-actions
- **Granularity**: Each atomic operation is one action step

**Priority**: **MEDIUM** — Can cause replicators to skip or duplicate entries, but usually self-correcting on retry. Longer convergence time.

---

### Family 5: Snapshot-Replication State Machine Races

**Mechanism**: InstallSnapshot and AppendEntries handlers execute concurrently and both modify replicator state (nextIndex). Snapshot advances nextIndex to post-snapshot value, but in-flight AppendEntries responses can overwrite or interleave with this update.

**Evidence**:
- **Code analysis**:
  - Replicator:740, 759, 1542-1544: InstallSnapshot sets `nextIndex = lastIncludedIndex + 1` and state to Replicate. Meanwhile, onAppendEntriesReturned also transitions state to Replicate and modifies nextIndex. No version guard prevents AppendEntries from undoing snapshot's progress.
  - Replicator:1498-1504 (log mismatch recovery): nextIndex is decremented or set based on follower feedback without checking if snapshot installation is in progress. If snapshot sets nextIndex=100 at line 740 and mismatch handler decrements it at line 1504, final value is wrong.
  - BallotBox:154-156 (clearPendingTasks): Queue is cleared while commitAt() might be iterating over it, causing use-of-cleared-queue.

**Affected code paths**:
- onInstallSnapshotReturned state transitions
- onAppendEntriesReturned concurrent execution
- Snapshot installation with in-flight replication

**Suggested modeling approach**:
- **Variables**: Add explicit `installSnapshotInProgress` flag; version counter for nextIndex updates
- **Actions**: Model InstallSnapshot and AppendEntries as separate state machines; prevent state corruption during interleaving
- **Granularity**: Snapshot state machine is separate from replication state machine; allows modeling their interaction

**Priority**: **HIGH** — Can cause entries to be skipped (never applied) or duplicated (applied twice), violating consistency.

---

### Family 6: Leadership and Membership Transition Races

**Mechanism**: Leadership changes (stepDown/becomeLeader) and membership changes (applyConfiguration) happen asynchronously relative to message handling. Multiple code paths check leadership/membership but don't hold the check invariant across lock boundaries.

**Evidence**:
- **Code analysis**:
  - NodeImpl:1245-1258 (checkStepDown): If term increases or state changes, stepDown is called (clearing leaderId at line 1318), then resetLeaderId is called to assign new leader. Between stepDown and resetLeaderId, leaderId is null; concurrent handlers see inconsistent state.
  - NodeImpl:2719-2726 (preVote): Checks `conf.contains(this.serverId)` at line 2723, then unlocks and performs RPC. Meanwhile, applyConfiguration could remove this node from conf. Upon return, node thinks it can vote but isn't in membership.
  - NodeImpl:2587-2610 (handleRequestVoteResponse): Checks state==CANDIDATE at line 2587, but doesn't re-check before becomeLeader at line 2610. Concurrent stepDown could change state; becomeLeader could be called from wrong state.

**Affected code paths**:
- checkStepDown during RPC handling
- preVote during election startup
- Vote response processing
- Configuration application

**Suggested modeling approach**:
- **Variables**: Model `currentLeader`, `currentMembership` as mutable state; make transitions explicit
- **Actions**: All role transitions (stepDown, becomeLeader, applyConfiguration) are actions that atomically update related state
- **Granularity**: Leadership and membership are separate concerns; model their interaction

**Priority**: **HIGH** — Can violate election safety (multiple leaders) or membership safety (non-member voting).

---

### Family 7: Configuration Application and Double-Application Races

**Mechanism**: Configuration entries are applied in two places: FSM callback and configuration closure. Interleaving or crash between the two can cause configuration to be applied multiple times or skipped.

**Evidence**:
- **Code analysis**:
  - FSMCallerImpl:544-549: Configuration is applied via `fsm.onConfigurationCommitted()` inside the loop, then closures run at line 555. If node transitions to follower before closure runs, the config could be applied again by new leader's snapshot.
  - NodeImpl:applyConfiguration: Updates both oldConf and newConf during joint consensus. If snapshot is taken mid-transition, configuration state could diverge.

**Affected code paths**:
- doCommitted() configuration application
- Closure-based config callbacks
- Snapshot installation during config change

**Suggested modeling approach**:
- **Variables**: Track `configurationApplied` flag per log index
- **Actions**: Configuration application is atomic; closure is separate action
- **Granularity**: Configuration application and closure are independent steps

**Priority**: **MEDIUM** — Manifests as non-idempotent configuration changes, but usually caught by upper layers.

---

### Family 8: Vote Counting and Quorum Races

**Mechanism**: Multiple replicators concurrently call BallotBox.grant() to record votes. The quorum calculation and vote counting are not atomic across multiple ballot entries, especially during membership changes.

**Evidence**:
- **Code analysis**:
  - BallotBox:115-122: commitAt iterates through ballots and calls grant() on each. Concurrent calls from different replicators can interleave; vote for index 4 might be counted twice if overlapping ranges are processed.
  - BallotBox:127-137 (joint consensus): Old and new quorum calculations use simple majority `size() / 2 + 1`. If removing nodes (e.g., 4→3), joint consensus requires both old (3) and new (2) quorums. Code at line 145 checks `this.quorum <= 0 && this.oldQuorum <= 0`, but if oldPeers is empty, oldQuorum isn't updated correctly.
  - Ballot:68-80 (getLastCommittedIndex): StampedLock optimistic read can return stale value while commitAt() is updating, causing followers to apply old entries.

**Affected code paths**:
- grant() vote recording
- commitAt() vote counting
- Joint consensus transitions
- getLastCommittedIndex reads

**Suggested modeling approach**:
- **Variables**: Model ballot state per (term, index) pair; explicit vote set per replicator
- **Actions**: grant() is atomic and updates global commit index only after quorum is reached
- **Granularity**: Vote recording and commit index update are separate; allows TLC to explore timing

**Priority**: **HIGH** — Can violate quorum invariant: entries could be committed without majority quorum if vote counting races.

---

### Family 9: FSM Application and Log Consistency Races

**Mechanism**: FSM reads log entries asynchronously from LogManager while LogManager concurrently truncates or compacts the log (for snapshots). The read-then-use of log indices is not atomic with truncation, causing FSM to try to apply entries that no longer exist.

**Evidence**:
- **Code analysis**:
  - FSMCallerImpl:520-576 (doCommitted): Pops closures for indices 1-100 at line 534, then IteratorImpl tries to read entries starting at line 542. If log is truncated to index 50 between pop and read, IteratorImpl.getEntry() at line 542 returns null or throws; closure at line 555 still runs.
  - IteratorImpl:112 (getEntry): Calls logManager.getEntry() without synchronization. Concurrent truncation can remove entries while IteratorImpl is iterating.
  - FSMCallerImpl:578-583: lastAppliedIndex and logManager.setAppliedId() are updated separately; LogManager doesn't know FSM has applied up to index 100 until setAppliedId() runs. Snapshot could be taken with stale lastApplied.

**Affected code paths**:
- doCommitted() entry application
- IteratorImpl log iteration
- setLastApplied() progress tracking
- Snapshot creation

**Suggested modeling approach**:
- **Variables**: Model log entries as mutable; distinguish "applied to FSM" from "logged"
- **Actions**: Log truncation and FSM application are separate actions; model their interleaving
- **Granularity**: Log reading and application are separate steps; crash between them

**Priority**: **CRITICAL** — Can cause FSM to apply wrong entries or skip entries, violating durability and consistency.

---

### Family 10: Retry and Recovery Logic Vulnerabilities

**Mechanism**: Error recovery paths (retries, blocking, state resets) are not protected against cascading failures or rapid repeated errors. Retry loops can spin unboundedly if network is degraded, exhausting resources.

**Evidence**:
- **Code analysis**:
  - Replicator:1285-1291: If multiple retries fail, pendingResponses queue grows unboundedly. Eventually hits maxReplicatorInflightMsgs and triggers resetInflights(), causing state thrashing.
  - Replicator:1028-1053, 1005-1022 (block/continueSending): If blockTimer expires while another error is being processed, prematurely exits blocking state and retries immediately, causing retry storm.
  - FSMCallerImpl:220-237 (shutdown): Enqueues SHUTDOWN task, but if tasks are enqueued AFTER shutdown() call but BEFORE shutdownLatch assignment (line 245 check), they will be added to ring buffer after SHUTDOWN and never processed. Closure leaks.

**Affected code paths**:
- onAppendEntriesReturned error handling
- block() and continueSending() state management
- shutdown() and task queueing
- resetInflights() and queue management

**Suggested modeling approach**:
- **Variables**: Track retry count; distinguish recoverable from unrecoverable errors
- **Actions**: Retry is bounded; after N failures, escalate to step-down
- **Granularity**: Retry attempt is one action; allows TLC to limit retry explosion

**Priority**: **MEDIUM** — Manifests as performance degradation and resource exhaustion rather than safety violation, but can cause denial of service in production.

---

### Family 11: Deadlock and Circular Lock Dependencies

**Mechanism**: FSMCallerImpl, Node, BallotBox, and Replicator use multiple locks (ReadWriteLock, StampedLock). Circular lock dependencies or lock order violations can cause deadlock.

**Evidence**:
- **Code analysis**:
  - FSMCallerImpl:763-764 (setError): Calls this.node.onError(e). If Node is holding locks and tries to call BallotBox or FSMCaller, circular dependency occurs.
  - FSMCallerImpl:598: fsm.onApply(iter) is called with iterator holding logManager reference. If onApply blocks and calls back into Node, and Node tries to access FSMCaller, potential deadlock.
  - NodeImpl uses ReadWriteLock (line 169), ReplicatorGroup uses locks in ReplicatorGroupImpl:83. If ReplicatorGroup.resetInflights() calls back to Node while Node is holding writeLock, deadlock.

**Affected code paths**:
- FSMCallerImpl.setError() → NodeImpl.onError() → BallotBox.onError()
- FSMCallerImpl.doApply() with callbacks
- Node lifecycle methods and Replicator state updates

**Suggested modeling approach**:
- **Variables**: Model lock ownership explicitly
- **Actions**: Never model callback that acquires locks
- **Granularity**: Lock-free or single-lock per action

**Priority**: **MEDIUM** — Rare in practice (requires specific timing) but can cause complete system hang.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|-----|-----|-----|
| **Persistent vs In-Memory State Divergence** | Family 1: crash windows create inconsistency between memory and disk | Add persistent term, votedFor, lastApplied variables; model as separate from in-memory state. Crash action clears memory, restore action reads disk. |
| **Leader Conflict Detection** | Family 2: asymmetric message handlers can miss conflicting leaders | Model explicit leaderId tracking; all handlers must check and enforce (no skipping leader validation) |
| **ABA-Protected Lock/Unlock Sequences** | Family 3: term check insufficient for relock safety | Model unlock as explicit action; allow other actions to run; relock must re-validate all state assumptions, not just term |
| **Snapshot Installation as Separate State Machine** | Family 5: snapshot and replication races; nextIndex state corruption | Model InstallSnapshot with separate nextIndex tracking; AppendEntries cannot write to nextIndex during snapshot |
| **Quorum Calculation with Joint Consensus** | Family 8: vote counting races in membership transitions | Model old and new quorum sizes separately; commit only when both satisfied; prevent vote double-counting with per-voter tracking |
| **Log Truncation During FSM Application** | Family 9: log entries disappear mid-application | Model LogStorage as separate; FSM read is not atomic with truncation; allow crash between read and apply |
| **Retry Bounds and Error Escalation** | Family 10: retry storms exhaust resources | Model retry count; after threshold, escalate to stepDown; prevent unbounded retry loops |
| **Membership Change Atomicity** | Family 6: configuration changes race with leadership transitions | applyConfiguration is atomic; leadership cannot change during config transition without explicit handling |

### 3.2 Do Not Model (with rationale)

| What | Why |
|-----|-----|
| **Metrics and Monitoring** | No safety property; instrumentation only |
| **Network Simulation (Partition, Delay, Reorder)** | Orthogonal to protocol logic; handled separately with message ordering/loss fault model |
| **Heap/Garbage Collection Behavior** | Memory management; not a protocol concern |
| **Thread Scheduling Details** | Abstracted by TLA+ action interleaving; don't model lock wait queues |
| **Performance Optimizations (e.g., pipelining efficiency)** | Correctness only; pipelining is modeled for state safety, not throughput |
| **Copy-Paste Errors in Metrics Labels** | Code quality issue, not protocol safety |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| **PersistentVotedFor** | `persistentVotedFor[term]` | Track voted-for separately from in-memory; model crash window | Family 1 |
| **LeaderConflictDetection** | `lastLeaderFromAppendEntries` | Track which leader sent last append; validate against RequestVote source | Family 2 |
| **SnapshotState** | `snapshotInProgress`, `snapshotNextIndex` | Distinguish snapshot-advanced nextIndex from replication nextIndex | Family 5 |
| **VoteSet** | `votesGranted[peer]`, `voteTerm` | Track which peers granted votes in current term; prevent double-voting | Family 8 |
| **LogTruncationWindow** | `lastTruncatedIndex`, `truncationInProgress` | Model log truncation as explicit action; allow crash during FSM apply | Family 9 |
| **RetryCounter** | `appendEntriesRetries[peer]` | Bound retries; escalate after threshold | Family 10 |
| **LockedRegions** | `locksHeld[node]` | Track lock acquisition to detect deadlock | Family 11 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **ElectionSafety** | Safety | At most one leader per term | Family 2, 3, 6, 8 |
| **LeaderCompleteness** | Safety | If entry committed at leader, it appears in future leaders' logs | Family 1, 5, 9 |
| **LogMatching** | Safety | If two logs have entry at same index and term, all preceding entries identical | Family 5, 9 |
| **CommittedEntriesApplied** | Safety | All committed entries eventually applied to state machines | Family 9, 10 |
| **NoDoubleVote** | Safety | Follower grants at most one vote per term | Family 1, 3, 8 |
| **QuorumInvariant** | Safety | Entry committed only if majority of peers have it | Family 8 |
| **PersistenceConsistency** | Safety | In-memory state matches persistent storage after recovery | Family 1 |
| **SnapshotConsistency** | Safety | Snapshot lastIncludedIndex is subset of log; no entries skipped | Family 5, 9 |
| **ConfigurationSafety** | Safety | Configuration changes are applied at most once per index | Family 6, 7 |
| **LastAppliedMonotonicity** | Safety | lastAppliedIndex is monotonically increasing | Family 9 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable Findings

| ID | Description | Expected Invariant Violation | Bug Family | Priority |
|----|-------------|----------------------------|------------|----------|
| MC-1 | Can a follower grant vote twice in same term due to non-atomic votedId persistence? | NoDoubleVote violated | Family 1 | CRITICAL |
| MC-2 | Can electSelf proceed with stale currTerm after crash-recovery, causing term divergence? | ElectionSafety violated (two leaders) | Family 1 | CRITICAL |
| MC-3 | Can AppendEntries handler skip term/leadership validation as RequestVote does, allowing conflicting leaders? | ElectionSafety violated | Family 2 | HIGH |
| MC-4 | During unlock-relock in RequestVote, can two votes be granted to different candidates in same term? | NoDoubleVote violated | Family 3 | HIGH |
| MC-5 | If InstallSnapshot sets nextIndex while AppendEntries is in flight, can entries be skipped? | LogMatching violated | Family 5 | CRITICAL |
| MC-6 | Can FSM apply entries that were truncated by log compaction, causing divergent state machines? | CommittedEntriesApplied violated | Family 9 | CRITICAL |
| MC-7 | If leader crashes during config change and follower installs snapshot, can config be applied twice? | ConfigurationSafety violated | Family 6, 7 | HIGH |
| MC-8 | Can quorum calculation miss a vote during joint consensus membership change? | QuorumInvariant violated | Family 8 | HIGH |
| MC-9 | Can onCaughtUp proceed with wrong condition (AND vs OR) causing unsafe config application? | ConfigurationSafety violated | Family 2 | MEDIUM |
| MC-10 | If checkStepDown clears leaderId then resetLeaderId fails, can split-brain result? | ElectionSafety violated | Family 6 | MEDIUM |

### 6.2 Test-Verifiable Findings

| ID | Description | Suggested Test Approach | Bug Family |
|----|-------------|----------------------|------------|
| TV-1 | Retry storm under degraded network | Simulate network timeouts; measure retry queue size; assert bounded | Family 10 |
| TV-2 | Task loss during shutdown | Enqueue tasks during shutdown() call; verify all closures invoked | Family 10 |
| TV-3 | Reader use-after-release in snapshot | Concurrent snapshot + resetInflights; assert reader not accessed after release | Family 3 |

### 6.3 Code-Review-Only Findings

| ID | Description | Suggested Action | Bug Family |
|----|-------------|-----------------|------------|
| CR-1 | Volatile field compound operations (nextIndex += entriesSize) | Use AtomicLong or guard with lock | Family 4 |
| CR-2 | StampedLock optimistic reads returning stale committed index | Switch to pessimistic read in hot path, or accept eventual consistency | Family 8 |
| CR-3 | Deadlock risk between FSMCallerImpl.setError() and Node.onError() | Audit lock ordering; consider callback-free API design | Family 11 |
| CR-4 | Missing null check for leaderId in checkStepDown | Add defensive check before resetLeaderId call | Family 6 |

---

## 7. Reference Pointers

**Full Analysis Report**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/sofa-jraft/analysis-report.md`

**Key Source Files**:
- NodeImpl.java (lines 1-3623): State machine, RPC handlers, elections
  - Critical: lines 1178-1218 (electSelf), 1802-1873 (handleRequestVoteRequest), 1944-2060 (handleAppendEntriesRequest), 2584-2616 (handleRequestVoteResponse)
- Replicator.java (lines 1-1909): Log replication, snapshot transfer
  - Critical: lines 1531-1544 (onAppendEntriesReturned), 622-708 (installSnapshot), 1495-1509 (mismatch recovery)
- FSMCallerImpl.java (lines 1-789): State machine application
  - Critical: lines 520-576 (doCommitted), 220-237 (shutdown), 578-583 (setLastApplied)
- BallotBox.java (lines 1-294): Vote tracking
  - Critical: lines 115-122 (commitAt), 127-137 (joint consensus), 68-80 (getLastCommittedIndex)

**GitHub Issues/PRs**:
- #1260 (merged 2026-04-XX): "add null check and graceful degradation in AppendEntries" — indicates missing defensive checks in message handling
- #1262 (merged 2026-04-XX): "fix: flaky ElectSelfPersistOrderTest" — suggests election timing issues
- [Additional issues from sofastack/sofa-jraft issues list — requires gh cli review]

**Reference Spec**:
- [Raft Consensus Paper](https://raft.github.io/)
- [Raft Thesis](https://github.com/ongardie/dissertation)
- [Specification](https://github.com/ongardie/raft-tla) (Diego Ongaro's TLA+ spec for Raft)

---

## Summary

This brief identifies **11 Bug Families** spanning **27+ distinct findings** across NodeImpl, Replicator, FSMCallerImpl, and BallotBox. The families center on:

1. **Non-atomic persistence** (crash windows)
2. **Handler inconsistencies** (missing checks)
3. **Lock safety** (ABA races, deadlock)
4. **State machine interleaving** (snapshot vs replication)
5. **Quorum safety** (vote counting races)
6. **Log consistency** (truncation during FSM apply)
7. **Error recovery** (retry storms, task loss)

**Category A (Distributed)** modeling with explicit message delivery, crash/recovery, and term-driven role transitions should capture these bugs. **TLC model checking** is appropriate for all 10 MC findings; each has a clear safety invariant violation path.

**Modeling strategy**: Start with standard Raft spec extended with PersistentState divergence, SnapshotState separation, and explicit retry bounds. Incrementally add extensions (VoteSet, LockedRegions, etc.) as needed to trigger each bug family.
