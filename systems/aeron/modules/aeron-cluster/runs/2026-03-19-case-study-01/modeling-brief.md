# Modeling Brief: real-logic/aeron

## 1. System Overview

- **System**: Aeron Cluster — Java high-performance Raft consensus library by Real Logic
- **Language**: Java, ~10,000 LOC core consensus logic (ConsensusModuleAgent 3592, Election 1643, ClusterMember 1330, RecordingLog 1790, ConsensusPublisher 675, ConsensusAdapter 389, LogAdapter 298, LogPublisher 344)
- **Protocol**: Raft variant with three-phase election (Canvass → Nominate → Ballot), Aeron Archive-based log replication
- **Key architectural choices**:
  - **Single-threaded event loop** (Agent-based concurrency via Agrona); no locks, all coordination via message passing
  - **17-state election machine** (vs Raft's 3 roles): INIT, CANVASS, NOMINATE, CANDIDATE_BALLOT, FOLLOWER_BALLOT, LEADER_LOG_REPLICATION, LEADER_REPLAY, LEADER_INIT, LEADER_READY, FOLLOWER_LOG_REPLICATION, FOLLOWER_REPLAY, FOLLOWER_CATCHUP_INIT/AWAIT/CATCHUP, FOLLOWER_LOG_INIT/AWAIT, FOLLOWER_READY, CLOSED
  - **Dual term design**: `candidateTermId` (monotonic, persisted, vote guard) vs `leadershipTermId` (established leader term)
  - **No votedFor persistence** — only the term is persisted via `NodeStateFile`, not who received the vote
  - **Canvass as implicit pre-vote**: partitioned minority nodes cannot self-nominate (no term inflation)
  - **Single FALSE vote vetoes election**: `isQuorumLeader` rejects if ANY explicit NO vote exists (stricter than Raft)
  - **Log replication via Aeron Archive**: followers replicate from leader's archive recordings, not direct AppendEntries RPC
- **Concurrency model**: ConsensusModuleAgent runs on a single dedicated thread; ClusteredServiceAgent on a separate thread; communication via Aeron IPC channels and shared counters

## 2. Bug Families

### Family 1: Commit Position Safety Violations (CRITICAL)

**Mechanism**: The commit position (Raft's `commitIndex`) can regress, be accepted from wrong sources, or advance past the actual quorum-committed boundary, causing followers to process uncommitted entries.

**Evidence**:
- Historical: `ae89386d1d` — follower replays log past commit position during FOLLOWER_REPLAY (Critical)
- Historical: `a9d7215d74` — quorum commit position goes backwards when faster node restarts; leader's archive lag not bounded (Critical)
- Historical: `5becec8b50` — notifiedCommitPosition allowed to decrease (Critical)
- Historical: `b6625b473f` — commit position accepted from any node, not just leader (Critical)
- Historical: `8f7369d410` — follower processes messages past commit position boundary (Critical)
- Historical: PR #1898 — 5 sub-bugs in commit position handling (follower using leader appendPosition as commitPosition, wrong leadershipTermId in broadcast, commitPosition going to zero during leader replay, notifiedCommitPosition going backwards in electionComplete)
- Historical: Issue #1478 — replay continues past commitPosition when ConsensusModule closed before Archive
- Code analysis: ConsensusModuleAgent.java:2830-2837 — `publishCommitPosition` sends regressed quorum position to followers (guarded by follower-side `max()`)
- Code analysis: Election.java:571-573 — `onCommitPosition` during election intentionally skips `leadershipTermId` validation (backward-compat workaround)

**Affected code paths**:
- `quorumPositionBoundedByLeaderLog()` (ConsensusModuleAgent.java:2806-2815)
- `onCommitPosition()` (ConsensusModuleAgent.java:1062-1099)
- `followerCommitPosition` calculation in `consensusWork()` (ConsensusModuleAgent.java:2441)
- `Election.onCommitPosition()` (Election.java:571-593)

**Suggested modeling approach**:
- Variables: `commitPosition[Server]`, `notifiedCommitPosition[Server]`, `appendPosition[Server]`
- Actions: `LeaderAdvanceCommitPosition` (quorum calculation with active-member filtering), `FollowerReceiveCommitPosition` (with sender validation + monotonicity guard), `FollowerReplayLog` (bounded by min(notifiedCommitPosition, appendPosition))
- Key: model the `proposeMaxRelease` monotonicity guard and test what happens when it's absent

**Priority**: High
**Rationale**: 9+ critical/high bugs sharing the same mechanism. The most recurrent theme in Aeron's bug history. Multiple independent production incidents. Several sub-bugs found as recently as PR #1898.

---

### Family 2: Election State Machine Transition Bugs (HIGH)

**Mechanism**: The 17-state election machine with cross-cutting message handlers creates subtle transition bugs — wrong role assignment, premature state advancement, term ID miscalculation, and ballot timing issues.

**Evidence**:
- Historical: `cb34d19ca5` — candidate ballot cut short in 5-node cluster; quorum accepted too early, missing best candidate (Critical)
- Historical: `57f489516b` — election transitions proceed despite active leader existing (High)
- Historical: `258555b19c` — leader re-initializes election on stale vote request instead of asserting leadership (High)
- Historical: `ab719ccf91` — election ends in wrong cluster role (High)
- Historical: `f686f55f98` — leadershipTermId out of step after multiple failed elections (High)
- Historical: `61a6e4f095` — FOLLOWER_REPLAY state missing from role assignment (Medium)
- Historical: `5a3189ac92` — wrong election state transition names for leader replay (High)
- Historical: `e2fba3f1b1` — single-node re-election broken (High)
- Code analysis: Election.java:449-530 — `onNewLeadershipTerm` only accepts messages where `leadershipTermId == candidateTermId`; messages for unknown terms silently dropped, potentially delaying convergence
- Code analysis: Election.java:709-712 — `appointedLeaderId` prevents non-appointed nodes from ever self-nominating (liveness risk)

**Affected code paths**:
- `Election.doWork()` state dispatch (Election.java:274-308)
- `Election.onRequestVote()` (Election.java:340-387)
- `Election.onNewLeadershipTerm()` (Election.java:418-539)
- `Election.onCanvassPosition()` (Election.java:290-338)
- `ConsensusModuleAgent.enterElection()` (ConsensusModuleAgent.java:2968-3002)

**Suggested modeling approach**:
- Variables: `electionState[Server]`, `candidateTermId[Server]`, `leadershipTermId[Server]`, `vote[Server -> Server -> {TRUE, FALSE, NULL}]`, `role[Server]`
- Actions: Model the full canvass → nominate → ballot → leader-init → leader-ready pipeline. Model `onNewLeadershipTerm` acceptance/rejection. Model `handleError` reset to INIT.
- Granularity: Each election state transition is a separate TLA+ action. Message handlers are separate actions that can fire at any point.

**Priority**: High
**Rationale**: 10+ historical bugs. The 17-state machine is the most complex component and the primary source of critical election bugs. The dual candidateTermId/leadershipTermId design is unique and needs verification.

---

### Family 3: Log Truncation on Leadership Change (HIGH)

**Mechanism**: When a former leader returns after partition with a longer uncommitted log, truncation must be correctly applied. Multiple bugs around when truncation triggers, what position is used, and whether recovery state is updated after truncation.

**Evidence**:
- Historical: `398122ca4d` — returning leader's log needs truncation but protocol didn't support it; added `logTruncatePosition` to NewLeadershipTerm (Critical)
- Historical: `efc8edac2a` — truncation during election doesn't reset to canvass to get leader's truncation point (High)
- Historical: `e78fe85f59` — recovery plan stale after truncation (High)
- Historical: `2a2f02f3fb` — log recording not stopped before creating recovery plan (High)
- Historical: `cda1e79c0e` — vote based on truncated position instead of append position (Critical)
- Historical: `2239f98eaf` / `928d32fbcf` — logPosition reset on truncation applied then reverted (reveals fragility)
- Code analysis: Election.java:454-467 — truncation condition: `nextTermBaseLogPosition < appendPosition`
- Code analysis: Election.java:616-640 — truncation is exception-driven (throws ClusterEvent, caught by handleError → reset to INIT)

**Affected code paths**:
- `Election.onNewLeadershipTerm()` truncation check (Election.java:454-467)
- `ConsensusModuleAgent.truncateLogEntry()` (ConsensusModuleAgent.java:1837-1847)
- `Election.onTruncateLogEntry()` (Election.java:616-640)
- `Election.handleError()` (Election.java:263-273)

**Suggested modeling approach**:
- Variables: `log[Server -> Seq(Entry)]`, `appendPosition[Server]`, `logTruncatePosition` (in NewLeadershipTerm message)
- Actions: `TruncateLog` (follower truncates entries beyond leader's termBaseLogPosition), `NewLeadershipTermWithTruncation` (leader sends truncation point), `RecoverAfterTruncation` (rebuild recovery plan)
- Key: model the interaction between truncation and the election reset (handleError → INIT → re-canvass)

**Priority**: High
**Rationale**: 6+ historical bugs including 2 critical. Log truncation after partition healing is a classic Raft edge case that Aeron has struggled with repeatedly. Exception-driven truncation flow adds complexity.

---

### Family 4: Quorum Calculation with Inactive Members (MEDIUM-HIGH)

**Mechanism**: Quorum position calculation counted crashed/inactive members whose stale log positions poisoned the result. The `isActive()` timeout check was missing or applied inconsistently.

**Evidence**:
- Historical: `b999d5d91d` — crashed members counted in quorum position (Critical)
- Historical: `d37dfa873b` — `hasQuorumAtPosition` counted inactive members (High)
- Historical: `3daabe9f01` — single-node cluster times itself out (regression from b999d5d91d) (Medium)
- Code analysis: ClusterMember.java:867-895 — `quorumPosition()` uses `isActive(nowNs, timeoutNs)` filter
- Code analysis: ClusterMember.java:1015-1036 — `isQuorumLeader` vetoes on any FALSE vote (stricter than Raft)

**Affected code paths**:
- `ClusterMember.quorumPosition()` (ClusterMember.java:867-895)
- `ClusterMember.hasActiveQuorum()` (ClusterMember.java:834-850)
- `ClusterMember.isQuorumLeader()` (ClusterMember.java:1015-1036)
- Leader quorum check in `consensusWork()` (ConsensusModuleAgent.java:2353-2358)

**Suggested modeling approach**:
- Variables: `memberActive[Server -> BOOLEAN]`, `timeOfLastAppendPosition[Server -> Server -> Nat]`
- Actions: `MemberCrash` (sets member inactive), `MemberRecover`, `LeaderCheckQuorum` (with active-member filtering)
- Key: model the interaction between quorum calculation and member liveness detection

**Priority**: Medium-High
**Rationale**: 3 bugs including 1 critical. The active-member quorum is a non-standard Raft extension that had a regression chain.

---

### Family 5: Snapshot State Divergence (MEDIUM-HIGH)

**Mechanism**: Leader and followers process log entries at different points, causing their in-memory state to diverge at the same log position. Snapshots taken at these divergent states produce inconsistent results.

**Evidence**:
- Historical: Issue #1739 / PR #1774 — `nextSessionId` diverges between leader and followers (leader increments on append, followers on replay) (High)
- Historical: PR #1918 — `nextCommittedSessionId` not tracking actual commits; truncation causes incorrect ID (High, still open)
- Historical: PR #1917 — leader uncommitted state (SUSPEND/SNAPSHOT/SHUTDOWN) not rolled back on unexpected election (High)
- Historical: PR #1919 — snapshot with 0 services taken before data committed (High)
- Historical: `6bc6b7d7e6` — session IDs not synchronized across nodes on failover (High)
- Historical: PR #1357 — pending service message state divergence (High)
- Historical: `8d502e02ee` — log adapter not drained before snapshot (High)
- Historical: `73e1e27d15` — uncommitted state not rolled back (Critical)

**Affected code paths**:
- `ConsensusModuleAgent.onTakeSnapshot()` and snapshot-related methods
- `ConsensusModuleAgent.restoreUncommittedEntries()` (ConsensusModuleAgent.java:2929-2966)
- `ConsensusModuleAgent.prepareForNewLeadership()` (ConsensusModuleAgent.java:1315-1388)
- PendingServiceMessageTracker

**Suggested modeling approach**:
- Variables: `nextSessionId[Server]`, `uncommittedState[Server -> Queue]`, `snapshotPosition[Server]`
- Actions: `TakeSnapshot` (captures state at current position), `LeaderAppendSessionOpen` (increments nextSessionId before commit), `FollowerReplaySessionOpen` (increments on replay), `RollbackUncommitted` (on election)
- Key: model the window between leader append and follower replay where snapshots can diverge

**Priority**: Medium-High
**Rationale**: 8+ bugs, multiple still recent (PR #1918 open). Snapshot consistency is fundamental to Raft correctness. The leader-append-vs-follower-replay divergence is systematic and affects multiple state fields.

---

### Family 6: Non-Atomic Persistence / Crash Recovery (MEDIUM)

**Mechanism**: RecordingLog writes are not atomic (no journaling, no checksums). candidateTermId persistence uses a separate NodeStateFile. Crash between writes can corrupt state.

**Evidence**:
- Historical: `a9ddfb24b1` — candidateTermId not persisted across crashes (High)
- Historical: `32d15b81b6` — indexing bug when adding snapshots to RecoveryPlan (High)
- Historical: `789c6c8d22` — RecordingLog.appendTerm stored wrong logPosition (Medium)
- Historical: `f5f6630475` — leadership term wrong after recovery across multiple terms (High)
- Code analysis: RecordingLog.java:1583-1623 — no checksumming on persistence; partial writes undetected
- Code analysis: RecordingLog.java:604-617 — `fileSyncLevel=0` means zero crash durability
- Code analysis: RecordingLog.java:1362-1427 — `ensureCoherent` fills term gaps with placeholders (hidden invariant: term IDs must be sequential)

**Affected code paths**:
- `RecordingLog.commitLogPosition()` (RecordingLog.java:1079-1093)
- `RecordingLog.appendTerm()` (RecordingLog.java:950-975)
- `NodeStateFile.proposeMaxCandidateTermId()` (NodeStateFile.java:257-262)
- `RecordingLog.createRecoveryPlan()` (RecordingLog.java:730-800)

**Suggested modeling approach**:
- Variables: `persistedCandidateTermId[Server]`, `persistedLog[Server]`
- Actions: `Crash` (resets volatile state, recovers from persisted), `RecoverFromDisk` (reads RecordingLog + NodeStateFile)
- Key: model crash between candidateTermId persist and log persist; verify vote safety after crash recovery

**Priority**: Medium
**Rationale**: 4+ bugs. Crash recovery is a classic TLA+ strength. The dual persistence stores (NodeStateFile for candidateTermId, RecordingLog for log/terms) create a crash window.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Three-phase election (Canvass → Nominate → Ballot) | Family 2: unique protocol with 10+ bugs; differs fundamentally from Raft RequestVote | Model canvass message exchange, willVoteFor check, nomination with random delay, ballot with dual quorum checks (unanimous early vs quorum at timeout) |
| Dual term design (candidateTermId vs leadershipTermId) | Family 2: novel safety mechanism, no votedFor persistence | Two separate term variables per server; candidateTermId monotonic + persisted; leadershipTermId only advances on leader establishment |
| Commit position advancement with active-member filtering | Family 1 + 4: 12+ bugs total | Model quorum calculation that excludes inactive members; model proposeMaxRelease monotonicity; model follower-side max() guard |
| Log truncation on NewLeadershipTerm | Family 3: 6+ bugs including exception-driven reset | Model follower receiving NLT with truncation point; truncate entries; reset election to INIT |
| Leader append vs follower replay divergence | Family 5: systematic snapshot divergence | Model window where leader has incremented state (nextSessionId) before followers; model snapshot at divergent points |
| Crash and recovery from dual persistence stores | Family 6: 4+ bugs | Model Crash action; recover candidateTermId from NodeStateFile; recover log state from RecordingLog |
| Single-FALSE-vote veto in isQuorumLeader | Family 2 + 4: stricter than Raft | Model explicit vote rejection blocking quorum; verify no liveness pathology |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Aeron Archive internals | Log replication uses Archive as black box; bugs are in consensus protocol logic, not archive recording mechanics |
| Client sessions / SessionManager | Session management bugs (#1739 nextSessionId) are captured abstractly via Family 5; full session protocol adds complexity without targeting new bug families |
| ClusteredServiceAgent interactions | Runs on separate thread with IPC; service-level bugs are better caught by integration tests |
| ClusterBackup / StandbySnapshotReplicator | Backup agent has its own bug surface (Issues #1652, #1467) but is not part of core consensus |
| Aeron transport / back-pressure / flow control | Network-level issues (Issue #1601) are performance/configuration concerns, not protocol safety |
| appointedLeaderId static leader selection | Configuration feature, not a protocol mechanism; creates known liveness concern but no safety issue |
| Fragment reassembly / SBE encoding | Implementation details below protocol level |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Three-phase election | `electionPhase`, `canvassPositions`, `nominationDeadline` | Model Canvass→Nominate→Ballot instead of direct RequestVote | Family 2 |
| Dual term | `candidateTermId[Server]`, `leadershipTermId[Server]` | Separate vote guard from established term | Family 2 |
| Active-member quorum | `memberActive[Server -> BOOLEAN]`, `lastAppendTime[Server -> Server]` | Filter inactive members from quorum | Family 1, 4 |
| Commit position monotonicity | `notifiedCommitPosition[Server]` | Model proposeMaxRelease + follower max() guard | Family 1 |
| Log truncation with election reset | `logTruncatePosition` (in NLT message) | Model truncation triggering INIT reset | Family 3 |
| Snapshot divergence window | `nextSessionId[Server]`, `uncommittedStateQueue[Server]` | Track leader-vs-follower state at same log position | Family 5 |
| Crash recovery | `persistedCandidateTermId[Server]`, `persistedLogState[Server]` | Dual persistence store crash window | Family 6 |
| Single-FALSE veto | (encoded in vote counting logic) | isQuorumLeader rejects on any NO vote | Family 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per leadershipTermId | Standard, Family 2 |
| LogMatching | Safety | If two logs have an entry with the same position in the same term, all preceding entries are identical | Standard, Family 3 |
| LeaderCompleteness | Safety | Committed entries appear in all future leaders' logs | Standard, Family 1, 3 |
| CommitMonotonicity | Safety | notifiedCommitPosition never decreases on any server | Family 1 |
| CommitBoundedByQuorum | Safety | Leader's published commitPosition <= actual quorum position among active members | Family 1, 4 |
| NoUncommittedReplay | Safety | Follower never replays log entries past min(notifiedCommitPosition, appendPosition) | Family 1 |
| VoteUniqueness | Safety | Each server grants at most one YES vote per candidateTermId | Family 2 |
| CandidateTermMonotonicity | Safety | candidateTermId never decreases (persisted, monotonic) | Family 2, 6 |
| TruncationSafety | Safety | Only uncommitted entries (past leader's termBaseLogPosition) are truncated | Family 3 |
| SnapshotConsistency | Safety | All servers taking snapshots at the same log position produce equivalent state | Family 5 |
| VoteRecovery | Safety | After crash recovery, a server cannot double-vote (candidateTermId persisted) | Family 6 |
| QuorumLeaderLiveness | Liveness | If a majority of servers are active, eventually a leader is elected | Family 2, 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Remove proposeMaxRelease monotonicity guard — can commitPosition regress? | CommitMonotonicity | 1 |
| MC-2 | Remove active-member filtering from quorum — can crashed member's stale position corrupt commit? | CommitBoundedByQuorum | 1, 4 |
| MC-3 | Allow follower to replay past notifiedCommitPosition — can uncommitted entries be applied? | NoUncommittedReplay | 1 |
| MC-4 | Model isQuorumLeader without FALSE-vote veto — can two leaders emerge? | ElectionSafety | 2 |
| MC-5 | Skip leadershipTermId check in Election.onCommitPosition (current code) — any safety violation? | LeaderCompleteness | 2 |
| MC-6 | Remove truncation on returning leader — can committed entries be lost? | LeaderCompleteness | 3 |
| MC-7 | Model snapshot at divergent leader/follower states — does SnapshotConsistency hold? | SnapshotConsistency | 5 |
| MC-8 | Crash between candidateTermId persist and electionComplete — can server double-vote? | VoteUniqueness, VoteRecovery | 6 |
| MC-9 | Drop NewLeadershipTerm for unknown terms (current behavior) — does convergence stall? | QuorumLeaderLiveness | 2 |
| MC-10 | Model candidate ballot timeout (quorum only after full electionTimeout) — verify no split-brain from early quorum | ElectionSafety | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | LogPublisher silent drops after 3 SEND_ATTEMPTS (LogPublisher.java:47) | Integration test with back-pressure injection |
| TV-2 | ConsensusPublisher silent drops when publication is null (ConsensusPublisher.java:60-63) | Unit test: set publication to null, verify canvass/commitPosition messages not sent |
| TV-3 | RecordingLog partial write corruption (RecordingLog.java:1583-1623) | Crash injection test: kill process mid-write, verify reload detects corruption |
| TV-4 | Issue #1923: slow service follower becomes leader with log gap | Multi-node test: slow service processing + forced election |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | onTerminationPosition (ConsensusModuleAgent.java:1137-1147) does not verify sender is the actual leader | Add `leaderMember.id() == leaderMemberId` check |
| CR-2 | timeOfLastLeaderUpdateNs reset for future terms (ConsensusModuleAgent.java:1067-1070) delays failure detection | Move reset after election/state validation |
| CR-3 | RecordingLog.captureEntriesFromBuffer (RecordingLog.java:1625-1674) has no field validation on reload | Add sanity checks on recordingId, leadershipTermId, logPosition |
| CR-4 | Election.java:487-489 comment suggests `replicationTermBaseLogPosition` simplification may affect recording log coherence | Investigate whether NULL_VALUE causes downstream issues |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/aeron/analysis-report.md`
- **Key source files**:
  - `artifact/aeron/aeron-cluster/src/main/java/io/aeron/cluster/ConsensusModuleAgent.java` (3592 lines — core consensus engine)
  - `artifact/aeron/aeron-cluster/src/main/java/io/aeron/cluster/Election.java` (1643 lines — 17-state election machine)
  - `artifact/aeron/aeron-cluster/src/main/java/io/aeron/cluster/ClusterMember.java` (1330 lines — quorum, vote, log comparison)
  - `artifact/aeron/aeron-cluster/src/main/java/io/aeron/cluster/RecordingLog.java` (1790 lines — persistence)
  - `artifact/aeron/aeron-cluster/src/main/java/io/aeron/cluster/ConsensusPublisher.java` (675 lines — consensus messaging)
- **GitHub issues**: PR #1898 (commit position, 5 sub-bugs), #1739/#1774 (snapshot divergence), #1619 (padding frame), #1478 (replay past commit), #604 (recording id=-1)
- **Reference**: Raft (Ongaro & Ousterhout, 2014). Note: Aeron's three-phase election and dual-term design deviate significantly from the paper.
- **Not Jepsen-tested**: Issue #1853 confirms no Jepsen analysis exists for Aeron Cluster.
