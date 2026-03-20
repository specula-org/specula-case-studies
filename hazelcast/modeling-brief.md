# Modeling Brief: hazelcast/hazelcast — CP Subsystem (Raft)

## 1. System Overview

- **System**: Hazelcast CP Subsystem — Java Raft consensus library powering distributed locks, atomics, semaphores
- **Language**: Java, ~7800 LOC core Raft logic (pre-enterprise move at commit `f2fa6ae842`)
- **Protocol**: Raft (Ongaro 2014), with PreVote (§9.6), Leadership Transfer (§4.2.3), single-server membership changes (§4.1)
- **Key architectural choices**:
  - All Raft state mutations serialized through a **single-threaded executor** (`RaftIntegration.execute()`)
  - Heartbeat is **piggybacked on AppendEntries** (not an independent thread) — unlike hashicorp/raft
  - Leader can **commit before flushing to own disk** (Raft dissertation §10.2.1) via `flushedLogIndex` tracking
  - `persistTerm(term, votedFor)` is a **single atomic call** — no split-persist risk
  - Membership changes are **pre-applied** (take effect on append, before commit) with rollback on truncation
  - Linearizable reads use heartbeat-round approach (§6.4) with query round tracking
  - InstallSnapshot sends **entire snapshot in one message** (no chunking)
- **Concurrency model**: Single-threaded executor per Raft group; `status` and `leader` fields are `volatile` for cross-thread visibility

## 2. Bug Families

### Family 1: Vote Safety Violations on Leader Demotion (CRITICAL)

**Mechanism**: When a leader demotes to follower, state transitions clear or corrupt vote-related invariants, violating Raft's Election Safety property.

**Evidence**:
- Historical: PR #16643 — `votedFor` cleared when leader demoted to follower in **same term** (`setTerm()` unconditionally cleared `votedFor`). Could allow two leaders per term. Fixed: only clear `votedFor` when `newTerm > term` (RaftState.java:436-441).
- Historical: PR #15591 (Jepsen) — Leader did not self-demote when majority silent. Partitioned leader continued accepting writes that never committed. Fixed: added `majorityAppendRequestAckTimestamp` tracking and demotion in `HeartbeatTask`.
- Code analysis: `AppendSuccessResponseHandlerTask.java:64` — term check is `assert` only (not runtime `if`). In production (asserts disabled), a higher-term success response would bypass demotion, unlike `AppendFailureResponseHandlerTask.java:63` which has a runtime check.

**Affected code paths**:
- `RaftState.toFollower()` / `setTerm()` (RaftState.java:406-442)
- `HeartbeatTask` leader self-demotion (RaftNodeImpl.java:1366-1388)
- `AppendSuccessResponseHandlerTask.handleResponse()` (lines 59-133)
- `AppendFailureResponseHandlerTask.handleResponse()` (lines 58-110)

**Suggested modeling approach**:
- Variables: model `votedFor` as persistent state, `leaseContact` map for majority ack tracking
- Actions: Split `HandleAppendResponse` into success/failure variants. Model `LeaderCheckLease` as periodic action. Model `DemoteToFollower` with same-term vs. higher-term distinction.
- Key invariant: `VotePreservation` — votedFor must never be cleared in the same term

**Priority**: High
**Rationale**: 2 critical historical bugs (one found by Jepsen). The assert-only term check is a live defense-in-depth gap. Election safety is the most fundamental Raft invariant.

---

### Family 2: Membership Change Safety Gaps (HIGH)

**Mechanism**: Single-server membership changes with pre-application (take effect before commit) create windows where reverts, ordering, or quorum calculations can go wrong.

**Evidence**:
- Historical: commit `61c376d329` — Multiple membership changes committed before slow follower could apply them. Follower tried batch-applying all at once, violating one-at-a-time constraint.
- Historical: commits `5c6d2e18bd` / `f45e41c606` — Incorrect membership revert logic: node stepped down when its member-add entry was truncated, but it didn't know if a replacement existed further in the log. Fix was reverted within 2 days.
- Historical: PR #22793 / issue #21438 — Mutable snapshot corrupted membership state across Raft nodes sharing the same snapshot object.
- Code analysis: `RaftState.updateGroupMembers()` (line 497) relies on `assert committedGroupMembers == lastGroupMembers` — this reference equality assert is the sole guard against concurrent membership changes.
- Code analysis: `RaftNodeImpl.canReplicateNewEntry()` (lines 538-546) — leader must have committed an entry in current term before membership change (Raft §4.2.1), but only checked when status is already `UPDATING_GROUP_MEMBER_LIST`.

**Affected code paths**:
- `MembershipChangeTask` (task/MembershipChangeTask.java:56-171)
- `RaftState.updateGroupMembers()` / `commitGroupMembers()` / `resetGroupMembers()` (RaftState.java:496-543)
- `AppendRequestHandlerTask.preApplyRaftGroupCmd()` / `revertPreAppliedRaftGroupCmd()` (lines 221-262)
- `RaftNodeImpl.applyLogEntry()` (lines 813-860)

**Suggested modeling approach**:
- Variables: `committedGroupMembers`, `lastGroupMembers` (per server), `nodeStatus` (ACTIVE / UPDATING / TERMINATING)
- Actions: `ProposeMembershipChange` (pre-applies), `CommitMembershipChange`, `RevertMembershipChange` (on log truncation), `Crash` (to test recovery of partial membership state)
- Granularity: pre-application and revert must be separate actions from commit

**Priority**: High
**Rationale**: 3+ historical bugs, most error-prone area in the codebase. Pre-application with rollback is complex and unique to this implementation. Membership + election interleaving is a classic TLA+ strength.

---

### Family 3: Leader Self-Liveness / Stale Leader (HIGH)

**Mechanism**: Leader fails to detect its own partitioning or abnormality, continues operating while a new leader is elected elsewhere.

**Evidence**:
- Historical: PR #15591 (Jepsen) — Leader did not self-demote when majority stopped responding. Added `majorityAppendRequestAckTimestamp` checking.
- Historical: PR #16038 — False failure detection during IP address changes caused spurious leader elections.
- Code analysis: `HeartbeatTask` (RaftNodeImpl.java:1374-1379) — Leader self-demotion based on `majorityAppendRequestAckTimestamp`. The `isHeartbeatTimedOut()` check at line 1347-1350 uses `maxMissedLeaderHeartbeatCount * heartbeatPeriodInMillis` as threshold.
- Code analysis: `LEADER_LOCAL` reads have no freshness guarantee (QueryTask.java:96 TODO) — partitioned leader serves arbitrarily stale reads until timeout demotion.
- Code analysis: `ANY_LOCAL` reads have no recency check (QueryTask.java:107 TODO) — partitioned follower serves stale reads without bound.

**Affected code paths**:
- `HeartbeatTask` (RaftNodeImpl.java:1366-1388)
- `LeaderFailureDetectionTask` (RaftNodeImpl.java:1394-1438)
- `QueryTask` — `LEADER_LOCAL` and `ANY_LOCAL` paths (QueryTask.java:88-109)
- `FollowerState.appendRequestAckTimestamp` tracking

**Suggested modeling approach**:
- Variables: `leaseTimestamp [Server -> Timestamp]`, `partitioned [Server -> BOOLEAN]`
- Actions: `NetworkPartition`, `NetworkHeal`, `LeaderCheckLease` (demotion check), `LeaderLocalRead`, `AnyLocalRead`
- Key: model the window between actual partition and demotion detection

**Priority**: High
**Rationale**: Jepsen-discovered bug. Leader liveness is fundamental to linearizability. The stale read TODOs are confirmed unfixed gaps.

---

### Family 4: PreVote Protocol State Management (MEDIUM)

**Mechanism**: PreVote extension adds `preCandidateState` that can leak or interact incorrectly with election and stickiness logic.

**Evidence**:
- Historical: commit `c3b558e425` — Pre-vote state leaked when two nodes ran pre-vote concurrently and one won a real election. Leaked state prevented the other node from ever starting elections again.
- Historical: commit `1f4bb0ed9c` — Leader stickiness check used randomized election timeout instead of heartbeat-based timeout, allowing pre-votes to succeed even when leader was alive.
- Historical: commit `61c376d329` — `PreVoteTask` did not store/check the term it was initiated for, could proceed with stale term info.
- Code analysis: `PreVoteResponseHandlerTask.java:53` — Does NOT demote on higher-term response (intentional for pre-vote, but different from `VoteResponseHandlerTask.java:63`).
- Code analysis: `LeaderElectionTimeoutTask.java:40` — Election timeout retry uses `disruptive=false`, losing the original disruptive flag from leadership transfer.

**Affected code paths**:
- `PreVoteTask` / `PreVoteTimeoutTask` (task/ directory)
- `PreVoteRequestHandlerTask` / `PreVoteResponseHandlerTask` (handler/ directory)
- `LeaderFailureDetectionTask` (RaftNodeImpl.java:1394-1438)
- `RaftState.initPreCandidateState()` / `removePreCandidateState()` (RaftState.java:466-481)

**Suggested modeling approach**:
- Variables: `preCandidateState [Server -> CandidateState | null]`
- Actions: `StartPreVote`, `HandlePreVoteRequest` (read-only), `HandlePreVoteResponse`, `PreVoteTimeout`
- Key: model concurrent pre-vote and real election interaction

**Priority**: Medium
**Rationale**: 3 historical bugs in pre-vote. TLA+ can systematically explore concurrent pre-vote/election interleavings.

---

### Family 5: Linearizable Read Correctness (MEDIUM)

**Mechanism**: Linearizable reads use heartbeat-round confirmation that can interact incorrectly with leader changes, membership changes, and commit advancement.

**Evidence**:
- Code analysis: `QueryTask.java:130` records `state.commitIndex()` at query submission. The query is satisfied when the round gets majority acks AND `commitIndex >= queryCommitIndex` (QueryState.java:135-140). But between submission and ack collection, a new leader could be elected with a different commit index.
- Code analysis: `QueryState.tryAck()` at line 105 checks `queryRound == round`. If a new query round starts before acks for the old round arrive, old acks are ignored. This prevents cross-round confusion but means pending queries from the old round are never satisfied (they rely on the NEW round's acks).
- Code analysis: On leader demotion, `completePendingQueries()` (RaftNodeImpl.java:1207-1211) fails all queries with `LeaderDemotedException`. This is correct.
- Code analysis: `LEADER_LOCAL` has no freshness guarantee (TODO at QueryTask.java:96).

**Affected code paths**:
- `QueryTask` (task/QueryTask.java:41-166)
- `QueryState` (state/QueryState.java:40-181)
- `RaftNodeImpl.tryRunQueries()` (line 592-622)
- `RaftNodeImpl.canQueryLinearizable()` (line 568-590)

**Suggested modeling approach**:
- Variables: `queryRound`, `queryCommitIndex`, `queryAcks`
- Actions: `SubmitLinearizableRead`, `HeartbeatAck` (for query round), `RunQuery` (after majority ack)
- Key: model query + leader change + membership change interaction

**Priority**: Medium
**Rationale**: The heartbeat-round mechanism is correct in isolation, but interactions with leader changes and membership changes are complex. The LEADER_LOCAL staleness is a confirmed gap.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Same-term leader demotion (vote preservation) | Family 1: Critical historical bug, assert-only residual gap | Model `toFollower` with same-term and higher-term variants; check `VotePreservation` invariant |
| Leader lease / majority ack tracking | Family 1, 3: Jepsen-found bug, stale leader window | `leaseContact` variable + `CheckLease` action that models demotion timeout |
| Pre-applied membership changes with revert | Family 2: 3+ historical bugs, most complex area | `committedConfig` and `latestConfig` variables; pre-apply on append, revert on truncation |
| Single-change-at-a-time enforcement | Family 2: Historical batch-apply bug on slow followers | Status variable prevents concurrent changes; model slow-follower catch-up |
| Leader must commit in current term before membership change | Family 2: Guard at RaftNodeImpl.java:538-546 | Model as precondition on `ProposeMembershipChange` |
| Linearizable read (heartbeat-round) | Family 5: Complex interaction surface | `queryRound`, `queryAcks` variables; model query + partition + leader change |
| Crash and recovery | Family 2: Membership recovery from log replay | `Crash` action resets volatile state; model log replay restoring membership |
| PreVote protocol | Family 4: 3 historical bugs in pre-vote interaction | Model as separate phase before election |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Disk flush optimization (flushedLogIndex) | Correctly implements §10.2.1. No historical bugs. Adds complexity without targeting known issues. |
| Flow control / exponential backoff | Performance mechanism, not safety. Historical bugs (#24958) are liveness issues. |
| Leadership transfer (TriggerLeaderElection) | No safety bugs found. Only a liveness concern (disruptive flag lost on timeout retry). |
| Snapshot chunking | Hazelcast sends full snapshot in one message — no chunking protocol to model. |
| Session management / FencedLock / Semaphore | Application-level state machine, not Raft protocol. Historical bugs are CME/idempotency, not consensus. |
| Thread-safety / lifecycle races | Bugs #9c3b0d5070, #a680f71a22, #532474629f are Java threading issues, not protocol logic. |
| LEADER_LOCAL / ANY_LOCAL reads | Not linearizable by design. Acknowledged TODOs, not bugs. |
| Log capacity management | Bug #bf38a8c5e5 (follower overflow) is an implementation detail, not protocol. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Same-term demotion | (split `ToFollower` action) | Distinguish same-term vs higher-term demotion; verify vote preservation | Family 1 |
| Leader lease | `leaseContact`, `partitioned` | Track majority ack timeout for stale leader detection | Family 1, 3 |
| Dual membership config | `committedConfig`, `latestConfig`, `nodeStatus` | Capture pre-application, revert, and commit of membership changes | Family 2 |
| Pre-vote state | `preCandidateState` | Model pre-vote / election interaction | Family 4 |
| Linearizable read round | `queryRound`, `queryCommitIndex`, `queryAcks` | Model read confirmation during leader changes | Family 5 |
| Assert-as-guard injection | `assertsDisabled` | Model behavior when assert checks are absent (production mode) | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard, Family 1 |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard |
| VotePreservation | Safety | `votedFor` is never cleared within the same term | Family 1 |
| NoPhantomLeaseContact | Safety | Leader lease contacts only count followers whose term ≤ leader's term | Family 1, 3 |
| SingleMembershipChange | Safety | At most one uncommitted membership change at a time | Family 2 |
| MembershipRevertConsistency | Safety | After log truncation, `lastGroupMembers` equals `committedGroupMembers` | Family 2 |
| ReadLinearizability | Safety | Linearizable read returns value from committed state at or after read invocation | Family 5 |
| PreVoteNoTermInflation | Safety | PreVote never increments a node's persisted term | Family 4 |
| LeaderDemotionLiveness | Liveness | A partitioned leader eventually demotes to follower | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Assert-only term check in AppendSuccessResponseHandlerTask: if asserts disabled and stale response arrives with higher term, leader doesn't demote | ElectionSafety (possible), VotePreservation | 1 |
| MC-2 | Pre-applied membership + leader crash before commit: can new leader have conflicting membership view? | MembershipRevertConsistency | 2 |
| MC-3 | Slow follower receiving batch of committed membership changes: does one-at-a-time enforcement hold? | SingleMembershipChange | 2 |
| MC-4 | Linearizable read started before membership change, satisfied by acks from newly added member | ReadLinearizability | 5 |
| MC-5 | Concurrent pre-vote and real election: can preCandidateState leak block future elections? | LeaderDemotionLiveness | 4 |
| MC-6 | Leader stickiness interaction with PreVote: can pre-vote succeed when leader is alive? | ElectionSafety | 4 |
| MC-7 | Leader self-demotion timing: window between partition and demotion allows stale leader operations | NoPhantomLeaseContact | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | LeaderElectionTimeoutTask loses disruptive flag on retry (line 40: `disruptive=false`) | Test leadership transfer with network delay causing election timeout |
| TV-2 | FollowerState backoff power overflow (`nextBackoffPower++` without bound, line 114) | Unit test with 32+ failed rounds, verify no integer overflow |
| TV-3 | Flow control compatibility shim still present (TODO RU_COMPAT_5_3 at FollowerState.java:144) | Verify with 5.3 node that backoff resets correctly |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `commitEntries` order depends on status (RaftNodeImpl.java:1296-1311): queries run before apply when NOT ACTIVE | Review whether query-before-apply ordering matters for consistency |
| CR-2 | `groupDestroyed()` bypasses `setStatus()` guard (RaftNodeImpl.java:485-493) | Review whether STEPPED_DOWN -> TERMINATED transition is intentional |
| CR-3 | `replicateMembershipChange()` without commit index skips CAS safety check | Review external callers of the no-commitIndex overload |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/hazelcast/analysis-report.md`
- **Key source files** (restored from commit `f2fa6ae842`, pre-enterprise move):
  - `artifact/.../raft/impl/RaftNodeImpl.java` (1498 lines — core state machine)
  - `artifact/.../raft/impl/handler/AppendRequestHandlerTask.java` (268 lines — follower AppendEntries)
  - `artifact/.../raft/impl/handler/AppendSuccessResponseHandlerTask.java` (141 lines — leader commit path)
  - `artifact/.../raft/impl/state/RaftState.java` (607 lines — persistent state, transitions)
  - `artifact/.../raft/impl/task/MembershipChangeTask.java` (171 lines — config changes)
  - `artifact/.../raft/impl/task/QueryTask.java` (166 lines — linearizable reads)
- **GitHub PRs**: #16643 (vote preservation), #15591 (Jepsen leader demotion), #14705 (membership revert), #22793 (snapshot immutability), #16038 (false failure detection), #25055 (flow control)
- **Open issue**: #24897 (CP subsystem instability on member restart — unrecoverable majority loss)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Raft dissertation Sections 4.1, 6.4, 9.6, 10.2.1
