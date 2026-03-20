# Analysis Report: real-logic/aeron

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git bug-fix commits analyzed | 55 (detailed), 113 total touching core files |
| GitHub issues deeply read (full comments) | 34 |
| GitHub issues confirmed bugs | 25 |
| GitHub issues user error / disputed | 4 |
| GitHub issues design limitations | 5 |
| Core source files analyzed (full read) | 8 |
| Total LOC analyzed | ~10,000 |

---

## Phase 1: Reconnaissance

### 1.1 Architecture Overview

Aeron Cluster is a high-performance Raft consensus implementation in Java built on top of the Aeron messaging library and Aeron Archive. It uses an Agent-based concurrency model (Agrona framework) with three primary agents:

1. **ConsensusModuleAgent** — Core consensus engine (single-threaded event loop)
2. **ClusteredServiceAgent** — Service-side log replay and invocation (separate thread)
3. **ClusterBackupAgent** — Backup replication (separate thread)

Communication between agents uses Aeron IPC (shared memory) and Aeron UDP for inter-node consensus.

### 1.2 Core Source Files

| File | LOC | Purpose |
|------|-----|---------|
| ConsensusModuleAgent.java | 3,592 | Core consensus engine: state machine, RPC handlers, commit logic |
| Election.java | 1,643 | 17-state election state machine |
| ClusterMember.java | 1,330 | Member state tracking, quorum calculation, vote comparison |
| RecordingLog.java | 1,790 | Persistent storage for term/snapshot metadata |
| ConsensusPublisher.java | 675 | Consensus message encoding and sending |
| ConsensusAdapter.java | 389 | Consensus message receiving and dispatch |
| LogPublisher.java | 344 | Log entry publishing to followers |
| LogAdapter.java | 298 | Log entry receiving and replay |

### 1.3 Message Types (SBE Schema v16)

**Consensus Protocol:**
- `CanvassPosition` (id=50) — Follower announces log position during election canvass
- `RequestVote` (id=51) — Candidate requests vote
- `Vote` (id=52) — Follower responds with vote (boolean)
- `NewLeadershipTerm` (id=53) — Leader announces new term with log state + truncation point
- `AppendPosition` (id=54) — Follower reports highest appended position
- `CommitPosition` (id=55) — Leader announces quorum-committed position
- `CatchupPosition` (id=56) — Follower requests log catchup
- `StopCatchup` (id=57) — Leader stops catchup

### 1.4 Concurrency Model

Single-threaded event loop for all consensus logic. No locks. The `ConsensusModuleAgent.doWork()` method:
1. Polls ingress adapter (client messages)
2. Polls consensus adapter (peer messages)
3. If election active: `election.doWork()`; else: `consensusWork()`
4. `slowTickWork()` for periodic tasks (heartbeat checks, quorum checks)

The `onUnavailableCounter` callback runs within the agent's thread during `idle()` / `slowTickWork()` invocations (via `aeronClientInvoker.invoke()`).

### 1.5 Election Protocol: Three-Phase Design

Unlike Raft's single RequestVote phase, Aeron uses:

1. **Canvass** — Discover peer log positions WITHOUT incrementing term. Nodes exchange `CanvassPosition` messages. A node assesses whether it is a viable candidate (has most up-to-date log among a quorum).
2. **Nominate** — Random delay (0 to electionTimeout/2) to break symmetry. Only then does the term increment.
3. **Ballot** — Send `RequestVote`, collect votes. Two thresholds: unanimous (immediate win) or quorum (after full election timeout).

This is more conservative than Raft — it avoids unnecessary term inflation and provides an implicit pre-vote mechanism (partitioned minority nodes can never pass the canvass guard).

### 1.6 Dual Term Design

- `candidateTermId` — Monotonically increasing, persisted to `NodeStateFile` (fsync). Acts as the vote guard (equivalent to Raft's `currentTerm` for voting). A node votes at most once per candidateTermId.
- `leadershipTermId` — The established leader's term. Only advances when a leader is confirmed. Does NOT advance during failed elections.

Key difference from Raft: `votedFor` is NOT persisted. Only the term is persisted. After crash recovery, the node knows it participated in term T but not who it voted for. This is safe because candidateTermId prevents double-voting.

---

## Phase 2: Bug Archaeology

### 2.1 Git History Mining

Total bug-fix commits touching core consensus files: **113** (keywords: fix, bug, race, deadlock, crash, revert), **240** including defensive keywords.

**55 commits analyzed in detail**, categorized below:

#### Election Safety (15 commits, 5 Critical)

| Commit | Summary | Severity |
|--------|---------|----------|
| `ae89386d1d` | Follower replays log past commit position | Critical |
| `a9d7215d74` | Quorum commit position goes backwards | Critical |
| `73e1e27d15` | Leader uncommitted state not rolled back on surprise election | Critical |
| `cb34d19ca5` | Candidate ballot cut short in 5-node cluster | Critical |
| `cda1e79c0e` | Vote based on truncated position, not append position | Critical |
| `57f489516b` | Election transitions proceed despite active leader | High |
| `258555b19c` | Leader re-initializes election on stale vote request | High |
| `5a3189ac92` | Wrong election state transition names | High |
| `ab719ccf91` | Election ends in wrong cluster role | High |
| `f686f55f98` | LeadershipTermId out of step after multiple failed elections | High |
| `e2fba3f1b1` | Single-node cluster leader re-election broken | High |
| `a9ddfb24b1` | candidateTermId not persisted across crashes | High |
| `61a6e4f095` | FOLLOWER_REPLAY missing from role assignment | Medium |
| `ec28ca3da5` | -1 termIds appear in recording log | Medium |
| `2cc18be2bd` | Wrong timestamp unit in publishNewLeadershipTerm | Medium |

#### Commit Position / Replication (9 commits, 4 Critical)

| Commit | Summary | Severity |
|--------|---------|----------|
| `5becec8b50` | notifiedCommitPosition allowed to go backwards | Critical |
| `b6625b473f` | Commit position accepted from any node | Critical |
| `8f7369d410` | Follower processes messages past commit position | Critical |
| `e6a3e709c0` | Follower replays log when logPosition >= quorumPosition | Critical |
| `ebaf5f8ad0` | Services race ahead of consensus module after replication | High |
| `65ab75dfd7` | Commit position moves during leader log replication | High |
| `608eb012a4` | Commit position stuck due to padding frame (#1619) | High |
| `9ca0951aa3` | Commit position broadcast after local update (ordering) | Medium |
| `aa06d107bb` | Commit position checked in wrong election state | Medium |

#### Race Conditions (6 commits, 0 Critical)

| Commit | Summary | Severity |
|--------|---------|----------|
| `af9ed9ba39` | Race retrieving snapshots for dynamic join | High |
| `287ca17326` | Service session messages filtered by leadershipTermId | High |
| `6ae08e0c2f` | Pending service messages race between services | High |
| `e089ea9c32` | leadershipTermId updated before services ready | High |
| `2efc62a74d` | Races with log moving during catchup | High |
| `8ec888ac47` | Cluster role race between service and consensus module | Medium |

#### Quorum Computation (3 commits, 1 Critical)

| Commit | Summary | Severity |
|--------|---------|----------|
| `b999d5d91d` | Crashed members counted in quorum position | Critical |
| `d37dfa873b` | hasQuorumAtPosition counted inactive members | High |
| `3daabe9f01` | Single-node cluster times itself out (regression) | Medium |

#### Log Truncation / Persistence (5 commits, 1 Critical)

| Commit | Summary | Severity |
|--------|---------|----------|
| `398122ca4d` | Returning leader's log needs truncation but protocol lacked support | Critical |
| `efc8edac2a` | Truncation during election doesn't reset to canvass | High |
| `e78fe85f59` | Recovery plan stale after truncation | High |
| `2a2f02f3fb` | Log recording not stopped before creating recovery plan | High |
| `2239f98eaf` | logPosition reset on truncation (applied then reverted) | Medium |

#### Snapshot / State Management (8 commits, 0 Critical)

| Commit | Summary | Severity |
|--------|---------|----------|
| `8d502e02ee` | Log adapter not drained before snapshot | High |
| `13b60f26e6` | Snapshotting broken with 0 services | High |
| `80a93bb54d` | Duplicate service messages during failover | High |
| `6bc6b7d7e6` | Session IDs not synchronized across cluster nodes | High |
| `32d15b81b6` | Indexing bug adding snapshots to RecoveryPlan | High |
| `f198812af5` | Timed-out uncommitted sessions reinstated after election | Medium |
| `2eea06d8ee` | Off-by-one truncating sessions before election | Medium |
| `789c6c8d22` | RecordingLog.appendTerm stored wrong logPosition | Medium |

#### Catchup / Recovery (3 commits)

| Commit | Summary | Severity |
|--------|---------|----------|
| `bd985c5834` | State tracking broken during catchup with async snapshot | High |
| `ba9e9c1df7` | NPE during follower catchup when leader transitions | Medium |
| `faa2b355c7` | Catchup accepts commit position from wrong term | Medium |

#### Other (6 commits)

| Commit | Summary | Severity |
|--------|---------|----------|
| `3593d8b347` | Follower position updated inconsistently | High |
| `a5d5072d5f` | Infinite loop awaiting service ACKs if services crash | High |
| `f274581f03` | Silent message loss on cluster ingress | Medium |
| `a8f2a580ae` | IndexOutOfBoundsException when entry straddles page size | Medium |
| `f5f6630475` | Leadership term wrong after recovery across multiple terms | High |
| `a1fd4a2f8a` | Log publication has inconsistent initial-term-id | High |

### 2.2 Bug Hotspot Analysis

| Component | Bug Count | Critical | High |
|-----------|-----------|----------|------|
| Election state machine | 15 | 5 | 7 |
| Commit position | 9 | 4 | 3 |
| Snapshot / state | 8 | 0 | 5 |
| Race conditions | 6 | 0 | 5 |
| Log truncation | 5 | 1 | 3 |
| Quorum calculation | 3 | 1 | 1 |
| Catchup / recovery | 3 | 0 | 1 |
| Other | 6 | 0 | 3 |
| **Total** | **55** | **11** | **28** |

### 2.3 GitHub Issues Analysis

#### Confirmed Consensus Bugs (with full comment threads read)

| Issue | Title | Component | Severity | Fixed? |
|-------|-------|-----------|----------|--------|
| PR #1898 | Follower consumes log past commit position (5 sub-bugs) | Election/CMA | Critical | Yes |
| #1739 / PR #1774 | Consensus Module snapshots differ across nodes | Snapshot | High | Yes |
| #1619 | Election cannot close due to Padding frame | Election/Log | High | Yes |
| #604 | Node fails to start with recording id=-1 | Snapshot/Replay | High | Yes (v1.14.0) |
| #1478 | Replay continues past commitPosition on shutdown | Archive/CMA | High | Yes |
| #1218 | Cluster broken with pre-touch enabled (async pub race) | ClientConductor | High | Yes |
| PR #1917 | Leader uncommitted state not rolled back | CMA | High | Yes |
| PR #1918 | nextCommittedSessionId not tracking actual commits | CMA | High | Open |
| PR #1919 | 0-service snapshot before data committed | CMA | High | Yes |
| PR #1932 | Single-node re-election broken | Election | Medium | Yes |
| #1671 | appVersion not encoded in NewLeadershipTerm | ConsensusPublisher | Medium | Yes |
| #693 | ConsensusModule segfault on Aeron timeout | Agrona/CMA | Medium | Yes |
| #1652 | NPE in ClusterBackupAgent.reset | Backup | Medium | Yes |
| #1467 | Failed snapshot retrieval in backup (session ID conflict) | Backup | Medium | Yes |
| #1574 | AsyncConnect leaks subscription | Client | Medium | Yes |
| #1944 | C client aeron_append_block ignores term_offset | C client | Critical | Yes |
| PR #1357 | Pending service message state divergence | PendingServiceMsg | High | Yes |
| PR #1865 | Log adapter not drained before snapshot (extensions) | CMA | High | Yes |

#### User Error / Disputed

| Issue | Classification | Reason |
|-------|---------------|--------|
| #1903 | User error | Cluster.offer() called only on leader; must be deterministic across all roles |
| #1879 | User error | Same as #1903 |
| #1601 | False alarm | Flow control configuration (fc=min vs fc=max) |
| #1211 | User error | Application-level data corruption, not Aeron |

#### Design Limitations

| Issue | Description |
|-------|-------------|
| #1533 | 2 of 3 nodes losing state exceeds Raft fault model; not recoverable |
| #1657 | Election retry loop with no backoff on ArchiveException |
| #1923 | Slow service follower becomes leader — potential log gap (uncertain) |
| #1662 | Archive segment deletion causes timeout under load |
| #1853 | No Jepsen testing exists for Aeron Cluster |

---

## Phase 3: Deep Analysis

### 3.1 ConsensusModuleAgent.java Analysis

#### RPC Handler Term Validation Summary

| Handler | Term Check | Sender Check | State Check |
|---------|-----------|--------------|-------------|
| `onRequestVote` (916) | candidateTermId > leadershipTermId triggers election | N/A | election != null delegates |
| `onVote` (936) | None outside election | N/A | election != null only |
| `onCanvassPosition` (856) | logLeadershipTermId <= this.leadershipTermId | followerMemberId lookup | role == LEADER |
| `onAppendPosition` (1032) | leadershipTermId <= this.leadershipTermId | followerMemberId lookup | role == LEADER |
| `onCommitPosition` (1062) | leadershipTermId >= resets heartbeat timeout; == for follower update | leaderMember.id() | role == FOLLOWER |
| `onNewLeadershipTerm` (953) | leadershipTermId >= resets heartbeat timeout; == for follower update | leaderId == leaderMember.id() | role == FOLLOWER |
| `onCatchupPosition` (1101) | leadershipTermId <= this.leadershipTermId | followerMemberId lookup | role == LEADER |
| `onStopCatchup` (1124) | leadershipTermId == | followerMemberId == memberId | N/A |
| `onTerminationPosition` (1137) | leadershipTermId == | **MISSING sender check** | role == FOLLOWER |

**Finding: onTerminationPosition missing sender validation** (ConsensusModuleAgent.java:1137-1147)
- `onTerminationPosition` checks `leadershipTermId == this.leadershipTermId` and `role == FOLLOWER` but does NOT verify that the sender is the actual leader (`leaderMember.id()`). Any cluster member with the correct term can set termination position.
- Severity: Medium (non-Byzantine threat model; cluster members are trusted)

**Finding: Heartbeat timeout reset for future terms** (ConsensusModuleAgent.java:1067-1070)
- `onCommitPosition` updates `timeOfLastLeaderUpdateNs` for ANY `leadershipTermId >= this.leadershipTermId` BEFORE the election/state checks. A commit position message with a future term resets the heartbeat timeout, potentially suppressing an election.
- Compensating mechanism: `enterElection` is triggered on the next line (1084-1098) for `leadershipTermId > this.leadershipTermId`.
- Severity: Low-Medium (timeout reset is transient; election still triggers)

**Finding: Election.onCommitPosition skips term validation** (Election.java:571-573)
- Comment: "we do not check `leadershipTermId == this.leadershipTermId` here, because prior to fixes the leader was sending wrong `leadershipTermId` value in the `CommitPosition` message"
- This is a backward-compatibility workaround. Only checks `leaderMember.id()` identity.
- Severity: Low-Medium (documented, intentional, but weakens safety check)

#### Commit Position Analysis

The commit position advancement pipeline:
1. Leader: `quorumPositionBoundedByLeaderLog()` → sorts active-member positions → returns quorum-th position bounded by leader's appendPosition
2. Leader: `commitPosition.proposeMaxRelease(quorumPosition)` → monotonic (never decreases)
3. Leader: `publishCommitPosition(quorumPosition)` → broadcasts to followers (can send regressed values)
4. Follower: `onCommitPosition` → `notifiedCommitPosition = max(notifiedCommitPosition, logPosition)` → monotonic
5. Follower: `logAdapter.poll(min(notifiedCommitPosition, limit))` → bounded replay

The pipeline has multiple monotonicity guards, but the leader CAN broadcast a quorum position lower than the current commit position (line 2837). Followers guard against this with `max()`. This was the subject of 9+ bug fixes.

#### Non-Atomic Operations

`prepareForNewLeadership()` (lines 1315-1388) — 14-step cleanup sequence with no rollback. If any step fails with an exception, the node is left in a partially-cleaned-up state. The `handleError` in Election catches exceptions and resets to INIT, which calls `prepareForNewLeadership` again. This retry-on-failure pattern works but is fragile.

`restoreUncommittedEntries()` (lines 2929-2966) — Pops the `uncommittedPreviousState` queue to restore the state before the first uncommitted control action. Correctly handles multiple uncommitted actions by restoring to the state before the FIRST uncommitted one.

#### Developer Signals

No TODO, FIXME, HACK, XXX, or BUG comments found in ConsensusModuleAgent.java. Two commented-out debug `System.out.println` statements (lines 1288-1289, 1307) suggest manual debugging during development.

### 3.2 Election.java Analysis

#### Complete State Transition Map

17 states with the following key transition paths:

```
INIT → CANVASS (or → LEADER_LOG_REPLICATION for single-node)
CANVASS → NOMINATE (unanimous or quorum candidate after timeout)
NOMINATE → CANDIDATE_BALLOT (after random delay)
CANDIDATE_BALLOT → LEADER_LOG_REPLICATION (unanimous or quorum after timeout)
                 → CANVASS (timeout without quorum)
FOLLOWER_BALLOT → CANVASS (timeout)

LEADER_LOG_REPLICATION → LEADER_REPLAY (quorum at appendPosition)
LEADER_REPLAY → LEADER_INIT (replay complete)
LEADER_INIT → LEADER_READY (joined log)
LEADER_READY → CLOSED (quorum at logPosition)

FOLLOWER_LOG_REPLICATION → CANVASS (replication complete + commit received)
FOLLOWER_REPLAY → FOLLOWER_CATCHUP_INIT / FOLLOWER_LOG_INIT (replay complete)
                → CANVASS (logPosition >= notifiedCommitPosition — rejected)
FOLLOWER_CATCHUP_INIT → FOLLOWER_CATCHUP_AWAIT → FOLLOWER_CATCHUP → FOLLOWER_LOG_INIT
FOLLOWER_LOG_INIT → FOLLOWER_LOG_AWAIT → FOLLOWER_READY
FOLLOWER_READY → CLOSED

Cross-cutting: handleError → INIT (from any state)
Cross-cutting: onNewLeadershipTerm → FOLLOWER_REPLAY / FOLLOWER_LOG_REPLICATION (from ballot/canvass)
Cross-cutting: onRequestVote → FOLLOWER_BALLOT (from canvass/nominate/ballot)
```

#### Vote Safety Analysis

**Double-voting prevention**: Line 357 (`candidateTermId <= this.candidateTermId`). Once a node votes YES for a candidate at term T, it updates its `candidateTermId` to T. Any subsequent RequestVote at term T or lower is rejected. `candidateTermId` is persisted via `NodeStateFile.proposeMaxCandidateTermId` (fsync'd), surviving crashes.

**Log comparison**: `compareLog()` (ClusterMember.java:1173-1197) correctly implements Raft's "at-least-as-up-to-date" check: first compare term, then log position.

**A node CAN vote YES for multiple candidates across different terms within a single election cycle**: If in FOLLOWER_BALLOT at term T, and a RequestVote arrives at term T+1 with adequate log, the node votes YES for the new candidate. This is safe because they are different terms.

**isQuorumLeader** (ClusterMember.java:1015-1036): Requires `votes >= quorumThreshold` AND no FALSE votes. Stricter than Raft's simple majority. A single explicit NO vote vetoes. `null` votes (no response) are not counted either way.

**isUnanimousLeader** checked every cycle; **isQuorumLeader** only at election timeout. Candidates win early only with unanimity, otherwise must wait for full election timeout. This is a stability optimization that differs from Raft.

#### Key Deviations from Raft

1. **Three-phase election** (Canvass → Nominate → Ballot) vs single-phase RequestVote
2. **No explicit step-down on higher-term canvass**: Leader throws ClusterEvent; others ignore higher-term canvass
3. **Dual term** (candidateTermId vs leadershipTermId) vs single currentTerm
4. **No votedFor persistence**: Only candidateTermId persisted; safe but delays elections post-crash
5. **FALSE vote vetoes quorum**: Single NO blocks isQuorumLeader
6. **NewLeadershipTerm for unknown terms silently dropped**: Can delay convergence
7. **Canvass prevents minority-partition term inflation**: Implicit pre-vote

### 3.3 Supporting Files Analysis

#### ClusterMember.java

- **quorumThreshold** (line 853): `(memberCount >> 1) + 1` — standard majority formula
- **quorumPosition** (line 867-895): Insertion-sort into `rankedPositions[]`, only active members counted. Returns smallest of top-N positions.
- **willVoteFor** (line 1292-1298): `logPosition != NULL_POSITION && compareLog(this, candidate) <= 0` — checks peer reported log is not more up-to-date than candidate's

#### LogPublisher.java

- **SEND_ATTEMPTS = 3** (line 47): All publish methods retry 3 times. Persistent back-pressure silently drops messages.
- **logPosition prediction** (lines 253-266): Predicts end position before `tryClaim`. Correct because `tryClaim` advances tail by exact aligned length; padding causes failure and retry.

#### ConsensusPublisher.java

- **Silent drops**: `canvassPosition`, `newLeadershipTerm`, `commitPosition` silently return when publication is null (fire-and-forget). `requestVote`, `appendPosition` return boolean, giving callers retry opportunity.
- **Thread.yield()**: Only in `terminationPosition` and `terminationAck` — treated as higher priority.

#### ConsensusAdapter.java

- **No sender authentication**: Messages dispatched purely by template ID. Sender validation deferred to ConsensusModuleAgent handlers.

#### LogAdapter.java

- **ClusterActionRequest returns BREAK** (line 277): One action per poll cycle — ensures consensus module processes cluster actions before replaying further.
- **disconnect truncates logPosition** (lines 70-74): `logPosition = min(logPosition, maxLogPosition)` — critical for truncation safety.

#### RecordingLog.java

- **Non-atomic persistence** (lines 1583-1623): No journaling, no checksumming. Partial writes on crash are undetectable.
- **fileSyncLevel=0** (lines 604-617): No fsync — zero crash durability.
- **ensureCoherent** (lines 1362-1427): Fills term gaps with placeholders. Hidden invariant: term IDs must be sequential.
- **No field validation on reload** (lines 1625-1674): Corrupted files loaded silently.
- **invalidateEntry** (lines 1096-1113): 4-byte write (safest operation — single sector write).

---

## Phase 4: Bug Family Synthesis

See modeling-brief.md for the 6 Bug Families with full evidence chains.

### Key Cross-Cutting Observations

1. **Commit position is the most bug-prone mechanism**: 9+ critical/high bugs across the git history. Every conceivable failure mode has occurred: regression, acceptance from wrong sender, advancement past quorum, processing past boundary.

2. **The 17-state election machine is the primary complexity driver**: Each state has guards and transitions that interact with cross-cutting message handlers. Historical bugs show that state transitions frequently leave the node in an inconsistent role.

3. **Aeron's three-phase election is safer than Raft in one critical way**: The canvass phase prevents minority-partition term inflation (implicit pre-vote). Partitioned nodes remain in CANVASS and never increment candidateTermId.

4. **Snapshot consistency is a systematic issue, not a one-off bug**: The leader-append-vs-follower-replay divergence affects multiple state fields (nextSessionId, nextCommittedSessionId, uncommittedState, pendingServiceMessages). This is a fundamental architectural tension.

5. **No Jepsen testing exists** (Issue #1853). The project relies on its own test suite. This suggests that distributed edge cases may be underexplored.

6. **The revert pattern appears multiple times**: `2239f98eaf` (logPosition reset) was reverted by `928d32fbcf`; `5c6fc70298` reverted leader log adapter changes. This suggests certain areas resist clean fixes and may have deeper structural issues.
