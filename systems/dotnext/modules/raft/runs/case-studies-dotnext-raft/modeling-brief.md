# Modeling Brief: dotnet/dotNext Raft

## 1. System Overview

- **System**: dotnet/dotNext — C# Raft consensus library for .NET
- **Language**: C#, ~6K LOC core Raft logic (excluding WAL/transport)
- **Protocol**: Raft (with PreVote, Leader Lease, custom sideband membership changes)
- **Key architectural choices**:
  - Heartbeat and replication are **combined** into a single loop (no separate heartbeat goroutine)
  - **No matchIndex array** — leader uses all-or-nothing quorum counting per heartbeat round
  - Configuration changes are **NOT log entries** — replicated as sideband on AppendEntries RPCs
  - State transitions dispatched via `ThreadPool.UnsafeQueueUserWorkItem` (asynchronous, serialized by `transitionLock`)
  - Term + votedFor persisted atomically in a single `WriteAsync` with `WriteThrough` (`WriteAheadLog.NodeState.cs`)
- **Concurrency model**: Async/await throughout; `AsyncExclusiveLock` for state transitions; single async loop for heartbeats; parallel replication tasks per follower

## 2. Bug Families

### Family 1: Election Restriction Deviation (HIGH)

**Mechanism**: The log up-to-dateness check deviates from the Raft paper, using a conjunctive comparison instead of the paper's disjunctive one. This can prevent valid candidates from being elected.

**Evidence**:
- Code analysis: `PersistentStateExtensions.cs:29-32` — `IsUpToDateAsync` checks `index >= localIndex && term >= localLastTerm` instead of the paper's `(term > localTerm) || (term == localTerm && index >= localIndex)`. A candidate with a higher last-term but shorter log is incorrectly rejected.
- Historical: Issue #168 — election race condition at startup (FollowerState->CandidateState transition window)
- Historical: Issue #149 — infinite loop in leadership when starting multiple members fast
- Historical: Issue #89 — unexpected election timeouts when rejecting vote requests
- Historical: Commit `287762551` — pre-vote optimization reverted due to stalled elections

**Affected code paths**:
- `PersistentStateExtensions.IsUpToDateAsync()` (line 29) — used by both Vote and PreVote handlers
- `RaftCluster.VoteAsync()` (line 834)
- `RaftCluster.PreVoteAsync()` (line 719)

**Suggested modeling approach**:
- Variables: standard Raft `log`, `currentTerm`, `votedFor`
- Actions: `RequestVote` with the **code's** conjunctive check; also model the **paper's** disjunctive check as an alternative for comparison
- Invariant: `ElectionSafety` (at most one leader per term) should still hold (the code is stricter, not weaker), but `ElectionLiveness` (a leader is eventually elected) may fail
- Granularity: single action per RPC

**Priority**: High
**Rationale**: Active deviation from Raft paper in a safety-critical check. While the conjunctive check is stricter (preserving safety), it can cause liveness failures in specific partition/recovery scenarios. The area has 4+ historical bugs. Model checking can determine whether the stricter check ever prevents progress.

---

### Family 2: Sideband Configuration Change Protocol (HIGH)

**Mechanism**: Configuration changes are NOT stored as log entries. They are replicated as sideband metadata piggybacked on AppendEntries RPCs. The leader applies the proposed config to active after any heartbeat quorum, not after log commit. This is a fundamental departure from the Raft paper.

**Evidence**:
- Code analysis: `RaftCluster.cs:594` — `AppendEntriesAsync` accepts `IClusterConfiguration config, bool applyConfig` as separate parameters
- Code analysis: `LeaderState.cs:189-191` — config applied on heartbeat quorum, not log commit
- Code analysis: `RaftCluster.cs:644-667` — follower processes config via fingerprint matching, not log entry
- Historical: Issue #105 — loading persisted cluster configuration from disk doesn't work
- Historical: Issue #108 — persistent config thread safety
- Historical: Issue #153 — cluster fails to elect after nodes leave and rejoin (random ID generation)
- Historical: Issue #277 — membership modification permanently blocked after unreachable-member failure
- Historical: Commit `966635fe7` — `ClusterConfigurationStorage` methods not synchronized

**Affected code paths**:
- `LeaderState.ForkHeartbeats()` (lines 42-75) — config selection per heartbeat round
- `LeaderState.Replication.Initialize()` (lines 59-87) — replicator config setup
- `RaftCluster.AppendEntriesAsync()` (lines 644-667) — follower config processing
- `ClusterConfigurationStorage.*` — Propose/Apply two-phase protocol
- `PersistentClusterConfigurationStorage.ApplyProposedAsync()` (lines 165-176) — non-atomic file operations
- `RaftCluster.Membership.AddMemberAsync()` / `RemoveMemberAsync()`

**Suggested modeling approach**:
- Variables: `activeConfig[Server -> SUBSET Server]`, `proposedConfig[Server -> Option(SUBSET Server)]`, `configFingerprint[Server -> Nat]`
- Actions: `ProposeConfig` (leader proposes new member set), `ReplicateConfig` (sideband on AppendEntries), `ApplyConfig` (on heartbeat quorum), `CrashWithPendingConfig` (crash between propose and apply)
- Key modeling decision: config changes are NOT log entries — they are separate state that can diverge from the log
- Granularity: separate actions for propose vs apply; sideband on AppendEntries

**Priority**: High
**Rationale**: 5+ historical bugs in this area. The sideband protocol is unique to dotNext and cannot be validated against the standard Raft TLA+ spec. Config applied on quorum (not commit) creates a window where config can diverge from committed log state. Non-atomic persistent config operations add crash-recovery risk.

---

### Family 3: State Transition Atomicity and Ordering (MEDIUM)

**Mechanism**: State transitions (Follower/Candidate/Leader) are dispatched asynchronously via ThreadPool. Multiple operations must complete in sequence (dispose old state, create new state, start async tasks), creating race windows between the transition trigger and the actual state change.

**Evidence**:
- Historical: Issue #221 (CRITICAL) — leader loses leadership, node stuck permanently (deadlock in transition)
- Historical: Issue #168 — election timeout fires, but refresh arrived concurrently (race between timeout and vote)
- Historical: Commit `cd51b6a91` — race between stop vs. dispose of old state
- Historical: Commit `10f580acf` — synchronous state transition calls from within async continuations caused re-entrancy
- Historical: Commit `a5b4f4b38` — LeaderChanged event fires before LeadershipToken is valid
- Code analysis: `RaftCluster.cs:1157-1164` — `UpdateStateAsync` → `AppendNoOpEntry` → `Leader = newLeader` → `StartLeading` is a multi-step sequence

**Affected code paths**:
- `RaftCluster.MoveToCandidateState()` (line 1061) — PreVote before lock, then lock, then transition
- `RaftCluster.MoveToLeaderState()` (line 1139) — multi-step with no-op append
- `RaftCluster.MoveToFollowerState()` (line 1020)
- `RaftState.StateTransitionWorkItem.Execute()` (line 77) — WeakGCHandle guard
- `FollowerState.Track()` — timeout vs refresh race

**Suggested modeling approach**:
- Variables: `state[Server -> {Follower, Candidate, Leader, Transitioning}]`, `transitionLockHolder[Server -> Option(Action)]`
- Actions: split state transitions into `BeginTransition` (acquire lock) and `CompleteTransition` (update state, start tasks). Model `StaleTransitionDrop` (WeakGCHandle expired).
- Key: model the asynchronous dispatch — the triggering event (timeout, higher term) and the actual state change are separate actions
- Granularity: 2-step transitions

**Priority**: Medium
**Rationale**: 5+ historical bugs, including a CRITICAL production deadlock (#221). The async dispatch pattern is well-defended (WeakGCHandle, IsValid checks, transitionLock), but the number of historical bugs suggests edge cases may remain. Model checking can explore interleavings.

---

### Family 4: Leader Lease Correctness (MEDIUM)

**Mechanism**: Leader lease renewal timing, quorum counting for lease, and interaction with term changes. Multiple historical bugs in lease implementation.

**Evidence**:
- Historical: Commits `44268e20e`, `f0072cc4e` — lease renewal race condition, ObjectDisposedException (complete rewrite needed)
- Historical: Commit `7b27337f6` — lease timing wrong (measured from commit, not heartbeat start)
- Historical: Commit `cc638a7b9` — lease counted stale-term responses
- Code analysis: `LeaderState.Lease.cs` — lease = `maxLease - elapsed` where elapsed is heartbeat round time
- Code analysis: `LeaderState.cs:168` — `RenewLease` called when quorum reached, before commit completes
- Code analysis: `RaftCluster.cs:804` — leader stickiness check (`lastUpdated.Elapsed`) done before lock, not re-checked inside

**Affected code paths**:
- `LeaderState.Lease.TryRenew()` (line 13-32)
- `LeaderState.RenewLease()` (line 41-55) — CAS for new lease on expiry
- `LeaderState.DoHeartbeats()` (line 168) — lease renewed on quorum, before commit

**Suggested modeling approach**:
- Variables: `leaseValid[Server -> BOOLEAN]`, `leaseExpiry[Server -> Nat]` (abstract time)
- Actions: `RenewLease` (on quorum response), `LeaseExpire` (timer), `ReadWithLease` (client read under lease)
- Invariant: `LeaseImpliesLeadership` — if lease is valid, no other leader exists with a higher term
- Key: lease is renewed BEFORE commit completes — model this ordering

**Priority**: Medium
**Rationale**: 3 historical bugs in lease implementation, all involving timing or concurrency. The current implementation has been rewritten multiple times. Model checking can verify the timing relationship between lease renewal and commit.

---

### Family 5: WAL Commit Index and Persistence Ordering (MEDIUM)

**Mechanism**: The WAL's commit index, applied index, and checkpoint have complex ordering requirements. In-memory state is updated before persistence completes. Crash recovery can regress the commit index.

**Evidence**:
- Historical: Issue #24 (CRITICAL) — commit index exceeded last log index, corrupted WAL state
- Historical: Issue #244/#242 (CRITICAL) — WAL crash from unsafe cancellation of I/O operations
- Historical: Commit `ebd3b96c0` — incorrect write position in WAL partition
- Historical: Commit `549e2fbd3` — applied index not updated on snapshot installation
- Historical: Commit `c7ee41bbc` — merged log entries not cleaned up correctly (off-by-one in flusher)
- Historical: Commit `4cf8439ba` — compaction deadlock (foreground vs background)
- Code analysis: `WriteAheadLog.Flusher.cs` — checkpoint written AFTER page flush, but commit index updated in memory first
- Code analysis: `WriteAheadLog.cs:113` — recovery sets `LastEntryIndex = LastCommittedEntryIndex = max(checkpoint, snapshotIndex)`

**Affected code paths**:
- `WriteAheadLog.Flusher` — flush ordering (pages, then checkpoint)
- `WriteAheadLog.Cleaner` — cleanup after snapshot
- `WriteAheadLog.Applier` — apply committed entries
- `WriteAheadLog` constructor — crash recovery

**Suggested modeling approach**:
- Variables: `memoryCommitIndex`, `persistedCheckpoint`, `appliedIndex`, `snapshotIndex`
- Actions: `AppendToMemory`, `FlushPages`, `WriteCheckpoint`, `Crash`, `Recover`
- Invariant: `CommitMonotonicity` — commit index never regresses after recovery; `NoGapAfterSnapshot` — no gap between snapshot and first log entry
- Granularity: split flush into page flush + checkpoint write

**Priority**: Medium
**Rationale**: 6+ historical bugs in WAL persistence, including 2 CRITICAL production crashes. The flush ordering is complex and has been a recurring source of bugs. Model checking with crash actions can verify the recovery invariants.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Conjunctive vs disjunctive election restriction | Family 1: active deviation from Raft paper | Parameterize the `IsUpToDate` check; run with both and compare |
| Sideband config replication | Family 2: unique protocol, 5+ historical bugs | Separate config state from log; config applied on quorum not commit |
| Non-atomic config persistence | Family 2: crash between propose and apply | Split config apply into steps with `Crash` action between |
| Asynchronous state transitions | Family 3: 5+ bugs including CRITICAL deadlock | Split transitions into trigger + execute; model dispatch queue |
| Leader lease timing | Family 4: 3 rewrites of lease code | Lease renewed before commit; model clock drift and expiry |
| Combined heartbeat/replication | Architecture: no separate heartbeat path | Single action for heartbeat+replicate (unlike hashicorp/raft) |
| AppendEntries without sender membership check | Family 2, F-18/F-19 | Allow non-member to send AppendEntries |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| WAL page management | Too low-level; page allocation/compaction is implementation detail |
| TCP/HTTP transport framing | Transport-level bugs (fragmented headers, Content-Length) are not protocol logic |
| Memory management (ArrayPool, LOH) | Performance issue, not correctness |
| Failure detector (PhiAccrual) | Implementation-level bug (IndexOutOfRange), not protocol logic |
| Metrics/logging | No impact on correctness |
| MemberAdded event wiring bug (F-27) | Copy-paste error at `RaftCluster.Membership.cs:99`; code-review fix, not model-checkable |
| PreVote protocol | Well-tested, no unique bugs; adds state space without targeting known issues |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Conjunctive election check | (parameterized action) | Test both paper and code election restriction | Family 1 |
| Sideband config | `activeConfig`, `proposedConfig`, `configFingerprint` | Model out-of-band config replication | Family 2 |
| Config crash window | `configPersistPhase` | Model non-atomic config persistence | Family 2 |
| Async transition | `transitionPending`, `transitionLockHolder` | Model dispatch delay between trigger and execution | Family 3 |
| Leader lease | `leaseValid`, `leaseExpiry` | Model lease timing relative to commit | Family 4 |
| Commit ordering | `memoryCommitIndex`, `persistedCheckpoint` | Model in-memory vs persisted commit state | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard, Family 1 |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard, Family 1 |
| ElectionLiveness | Liveness | A leader is eventually elected (under fairness) | Family 1 |
| ConfigSafety | Safety | At most one proposed config at a time; applied config reflects majority | Family 2 |
| ConfigCommitConsistency | Safety | Config applied only when a quorum has the same proposed config | Family 2 |
| NoStaleLeaderWithLease | Safety | If lease valid, no other server has higher term AND is leader | Family 4 |
| CommitMonotonicity | Safety | commitIndex never regresses after crash recovery | Family 5 |
| TransitionSafety | Safety | At most one pending transition per server; stale transitions are dropped | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Conjunctive election check prevents valid candidate (shorter log, higher term) | ElectionLiveness | 1 |
| MC-2 | Config applied on quorum, not commit — can config diverge from log? | ConfigCommitConsistency | 2 |
| MC-3 | Non-member sends AppendEntries, accepted as leader | ElectionSafety | 2 |
| MC-4 | Lease renewed before commit completes — stale read possible? | NoStaleLeaderWithLease | 4 |
| MC-5 | Config crash between propose-file and apply-file — recovery state? | ConfigSafety | 2 |
| MC-6 | Async transition dispatch — timeout fires, transition queued, heartbeat arrives — duplicate leader? | ElectionSafety | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | MemberAdded event `remove` accessor wired to wrong handler (`RaftCluster.Membership.cs:99`) | Unit test: subscribe to MemberAdded, unsubscribe, verify handler is removed |
| TV-2 | Leader stickiness check before lock not re-checked inside lock (`RaftCluster.cs:804`) | Integration test: concurrent heartbeat + vote timing |
| TV-3 | Follower timeout reset even when vote not granted (`RaftCluster.cs:825-828`) | Unit test: mock vote rejection, verify timeout was still reset |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `MoveToStandbyState()` in catch blocks of `async void` can throw unrecoverably | Add try-catch around `MoveToStandbyState` calls |
| CR-2 | AppendEntries/InstallSnapshot don't check sender membership (`RaftCluster.cs:594,537`) | Add `members.ContainsKey(sender)` guard |
| CR-3 | Implicit rejection via default enum value in AppendEntries (`RaftCluster.cs:605`) | Add explicit `result.Value = HeartbeatResult.Rejected` return |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/dotnext-raft/analysis-report.md`
- **Key source files** (all under `src/cluster/DotNext.Net.Cluster/Net/Cluster/Consensus/Raft/`):
  - `RaftCluster.cs` — main state machine, RPC handlers (~400 LOC)
  - `LeaderState.cs` + partials — leader orchestration, replication, lease (~500 LOC)
  - `CandidateState.cs` — election logic (~185 LOC)
  - `FollowerState.cs` — timeout tracking (~80 LOC)
  - `PersistentStateExtensions.cs:29-32` — **IsUpToDateAsync bug**
  - `RaftCluster.Membership.cs` — membership changes (~380 LOC)
  - `Membership/ClusterConfigurationStorage.cs` — config storage base
  - `StateMachine/WriteAheadLog*.cs` — WAL (~2K LOC across 13 partial files)
- **GitHub issues**: #221, #168, #185 (elections); #105, #108, #153, #277 (config); #24, #244 (WAL); #184 (memory)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
