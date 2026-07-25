# Modeling Brief: apache/kudu Raft Consensus

## 1. System Overview

- **System**: Apache Kudu — C++ distributed columnar storage engine for fast analytics
- **Language**: C++, ~16,000 LOC core consensus logic (src/kudu/consensus/)
- **Protocol**: Raft (Ongaro 2014) with pre-election, leadership transfer, single-server config changes
- **Key architectural choices**:
  - **Spinlock-based concurrency**: Main `lock_` (simple_spinlock) protects all mutable consensus state; `update_lock_` serializes Update() RPCs. Lock ordering: `update_lock_` before `lock_`.
  - **Separate peer threads**: Each remote peer has its own `Peer` object with heartbeat timer; at most one outstanding RPC per peer.
  - **Atomic metadata persistence**: Term + votedFor written in single protobuf flush (`cmeta_->Flush()`). SKIP_FLUSH_TO_DISK optimization defers flush when a subsequent vote flush is guaranteed.
  - **Pending config takes effect immediately**: Config change applied when operation is added to pending ops, not when committed (Ongaro thesis §4.1).
  - **PeerMessageQueue**: Centralized queue tracks per-peer replication state, computes majority watermarks, notifies RaftConsensus of commit index and term changes.
- **Concurrency model**: RaftConsensus uses a single spinlock for state; PeerMessageQueue has its own spinlock. Peer RPCs run on thread pool. Observer callbacks (commit index, term change) dispatched asynchronously.

## 2. Bug Families

### Family 1: Commit Index / Log Matching Safety (HIGH)

**Mechanism**: Incorrect commit index advancement or log state management causes replicas to diverge — entries applied from wrong term, stale entries replicated, or commit index exceeds what was actually received.

**Evidence**:
- Historical: KUDU-639 (639d8d90d) — Replica commits ops from wrong term; commit index in RPC exceeded what was actually sent. Fix: clamp `apply_up_to` to `min(pending, preceding_opid, committed_index)` (raft_consensus.cc:1521-1526)
- Historical: 1eb24183a — Stale ops replicated after abort; LogCache/queue not truncated when ops aborted. Fix: explicit `TruncateOpsAfter()` on abort
- Historical: KUDU-1469 (d68574742) — Tight loop of status-only RPCs after leader change; `last_received_current_leader` not updated for fully-deduped requests
- Historical: KUDU-783 (dd81cd4d4) — Bootstrap failure with duplicate ops after tumultuous leader change
- Historical: KUDU-1778 (b15c0f6e3) — LMP mismatch after restart; followers return committed_index=0 causing leader to fall back to GCed index
- Historical: cdb725387 — Bootstrap applies COMMITs out of order, causing NotFound errors for MUTATEs
- Historical: 9befdeb27 — Watermark advancement bug: incorrect peer index used for commit calculation
- Code analysis: consensus_queue.cc:924-926 — `majority_replicated_index` can go backwards (unconditional overwrite in `AdvanceQueueWatermark`); committed_index itself is guarded by `>` check
- Code analysis: raft_consensus.cc:1285-1290 — Developer TODO acknowledges truncation on term mismatch is "critical" but "should investigate why"

**Affected code paths**:
- `UpdateReplica()` (raft_consensus.cc:1460-1650) — 5-step follower update pipeline
- `ResponseFromPeer()` (consensus_queue.cc:1161-1351) — commit index advancement
- `AdvanceQueueWatermark()` (consensus_queue.cc:890-930) — majority calculation
- `EnforceLogMatchingPropertyMatchesUnlocked()` (raft_consensus.cc:1250-1293)
- `TruncateAndAbortOpsAfterUnlocked()` (raft_consensus.cc:1296-1330)

**Suggested modeling approach**:
- Variables: `log [Server -> Seq(Entry)]`, `commitIndex [Server -> Int]`, `matchIndex [Leader -> Server -> Int]`, `nextIndex [Leader -> Server -> Int]`
- Actions: Model `UpdateReplica` as multi-step: (1) check term/log match, (2) truncate divergent entries, (3) append new entries, (4) advance commit index. Separate `SendHeartbeat` (status-only, no ops) from `SendEntries`.
- Key: Model the clamping fix for KUDU-639 — `apply_up_to = min(lastPending, precedingOpId, request.committedIndex)`
- Inject: `LMP_MISMATCH` responses, partial batches, leader changes mid-replication

**Priority**: High
**Rationale**: 7+ critical/high historical bugs, core Raft safety invariant, multiple production incidents (YCSB, ITBLL clusters).

---

### Family 2: Configuration Change Safety (HIGH)

**Mechanism**: Inconsistent handling of committed vs. pending configuration — pending config not cleared on abort, config change accepted before leader has committed in current term, non-voters counted toward quorum, stale majority size.

**Evidence**:
- Historical: KUDU-1338 (c693d878f) — Pending config not cleared when CHANGE_CONFIG aborted; replica stuck or operates with stale config
- Historical: KUDU-872 (0b7a4fe82) — Leader accepts config change before committing an op in current term (Raft correctness violation per raft-dev)
- Historical: 1277f69a1 — NON_VOTER acks counted toward majority, allowing incorrect commit advancement
- Historical: KUDU-2230 (dc497fec2) — Leader not counted as viable voter in SafeToEvict check
- Historical: KUDU-2443 (cb2037292) — Infinite replacement loop for RF=1 with REPLACE attribute
- Open bug: KUDU-3082 — Tablets stuck in CONSENSUS_MISMATCH for days; "config change already in progress"
- Code analysis: consensus_queue.cc:231 — `majority_size_` computed at `SetLeaderMode` time, not updated when config change is pending
- Code analysis: raft_consensus.cc:868 — `unsafe_config_change` flag bypasses single-pending-config check
- Code analysis: raft_consensus.cc:880-881 — Pending config only set if opid > committed config opid (bootstrap replay guard)

**Affected code paths**:
- `AddPendingOperationUnlocked()` (raft_consensus.cc:849-896) — sets pending config immediately
- `CompleteConfigChangeRoundUnlocked()` (raft_consensus.cc:2930-2970) — commits config
- `ChangeConfig()` / `BulkChangeConfig()` (raft_consensus.cc:1684-1770) — validates and proposes
- `SetLeaderMode()` / `SetNonLeaderMode()` (consensus_queue.cc:218-268) — updates majority_size_
- `RefreshConsensusQueueAndPeersUnlocked()` (raft_consensus.cc:882-884) — propagates config to queue

**Suggested modeling approach**:
- Variables: `committedConfig [Server -> Config]`, `pendingConfig [Server -> Option(Config)]`, `configChangeCommitted [Server -> Bool]`
- Actions: `ProposeConfigChange` (leader only, requires committed op in current term, no pending config), `AcceptConfigChange` (follower sets pending config), `CommitConfigChange` (pending → committed), `AbortConfigChange` (clear pending config)
- Key: Model the single-pending-config constraint and the "must commit in current term first" check
- Inject: Config change + election interleaving, config change abort on leader change

**Priority**: High
**Rationale**: Open bug (KUDU-3082), critical Raft correctness violation (KUDU-872), complex interaction space with elections. TLA+ can exhaustively explore config change + election interleavings.

---

### Family 3: Election / Leader Stability (HIGH)

**Mechanism**: Election storms, incorrect vote granting, or term management issues — partitioned nodes disrupt leaders, slow disks cause false vote granting, election stacking from async failure detection.

**Evidence**:
- Historical: KUDU-2947 (ee22ddcc7) — Slow WAL causes followers to grant votes despite live leader; `withhold_votes_until_` not extended during WAL sync
- Historical: KUDU-2149/2155 (edd41cb40, b32283d2e) — Election stacking from async failure detector firing multiple times
- Historical: KUDU-1057 (c2b2eb0eb) — Election flapping; election timer expires before candidate becomes leader with slow disk
- Historical: KUDU-562 (4870ef20b) — Partitioned node with high term disrupts active leader; fix: withhold votes mechanism (Ongaro thesis §4.2.3)
- Historical: e8187c01c — Even-voter split not detected; VoteCounter CHECK failure
- Historical: 87278941b — Response race in Update(): response filled after releasing lock, election between lock release and response fill
- Historical: KUDU-2335 (f6777db35) — StepDown didn't increment term, causing stale leader reports
- Code analysis: raft_consensus.cc:592-593 — StepDown uses SKIP_FLUSH_TO_DISK; crash could undo step-down (liveness issue, not safety — subsequent vote always flushes term+vote together)
- Code analysis: raft_consensus.cc:936 — `NotifyTermChange()` uses WARN_NOT_OK on `HandleTermAdvanceUnlocked`; if step-down fails, node may continue operating at old term
- Code analysis: leader_election.cc:413 — DCHECK-only validation that voter's term matches election term (compiled out in release builds)

**Affected code paths**:
- `StartElection()` (raft_consensus.cc:471-575) — election initiation
- `RequestVote()` (raft_consensus.cc:1771-1871) — vote granting logic
- `DoElectionCallback()` (raft_consensus.cc:2740-2820) — election result processing
- `BecomeLeaderUnlocked()` (raft_consensus.cc:694-735) — leader initialization
- `WithholdVotes()` / `SnoozeFailureDetector()` (raft_consensus.cc:3014-3025, 2997-3012)

**Suggested modeling approach**:
- Variables: `currentTerm [Server -> Int]`, `votedFor [Server -> Option(Server)]`, `role [Server -> {Leader, Follower, Candidate}]`, `withholdVotesUntil [Server -> Time]`, `leaderAlive [Server -> Bool]`
- Actions: `StartElection`, `RequestVote` (with withhold-votes check), `GrantVote`, `DenyVote`, `BecomeLeader`, `StepDown`
- Key: Model the `withhold_votes_until_` mechanism and its interaction with slow disk/WAL. Model pre-election as non-binding (no term advance, no vote persistence).
- Inject: Network partition (candidate term inflation), slow disk (WAL latency > election timeout)

**Priority**: High
**Rationale**: 7+ historical bugs, election storms are a recurring production issue. The `withhold_votes_until_` mechanism and pre-election are Kudu-specific extensions worth verifying. The `NotifyTermChange` error swallowing (line 936) is a potential safety gap.

---

### Family 4: Operation Ordering / Role Transition Race (MEDIUM)

**Mechanism**: Operations from different terms or roles get interleaved during state transitions — follower-to-leader, leader-to-follower, or shutdown — causing non-commutative operations to diverge.

**Evidence**:
- Historical: KUDU-597 (d36cd08a5) — PREPARE/REPLICATE mis-ordering during follower→leader transition; client op queued as follower, prepared after becoming leader. Fix: double-check term at both submission and replicate time
- Historical: KUDU-1678 (d1f8c23b4) — Abort order dependency; aborting ops in forward order during shutdown caused WRITE_OP to replicate after dependent ALTER_SCHEMA was aborted. Fix: abort in reverse index order
- Historical: KUDU-1035 (f9e0d4ae8) — Bootstrap safe time violation; NO_OP/CHANGE_CONFIG timestamps assigned on different thread, violating monotonicity
- Code analysis: raft_consensus.cc:2815-2818 — `CHECK_OK(BecomeLeaderUnlocked())` crashes on race with shutdown (acknowledged TODO)
- Code analysis: raft_consensus.cc:1467-1470 — Developer TODO: "These failure scenarios need to be exercised in a unit test"

**Affected code paths**:
- `Replicate()` → `CheckLeadershipAndBindTerm()` (raft_consensus.cc:768-815) — term binding
- `BecomeLeaderUnlocked()` (raft_consensus.cc:694-735) — leader initialization with NO_OP
- `BecomeReplicaUnlocked()` (raft_consensus.cc:737-764) — follower transition
- `pending_rounds.cc:64-82` — `CancelPendingOps` doesn't clear the map after notifying abort

**Suggested modeling approach**:
- Variables: `pendingOps [Server -> Seq(Op)]`, `prepareQueue [Server -> Seq(Op)]`
- Actions: Model the prepare-replicate pipeline as two separate steps. Model `BecomeLeader` clearing stale ops before appending NO_OP.
- Key: The term-binding at submission time (not just replicate time) is the critical fix for KUDU-597

**Priority**: Medium
**Rationale**: KUDU-597 was a critical production bug, but the fix is well-understood and in place. The operation ordering concern is somewhat implementation-specific (prepare queue semantics). Worth modeling the NO_OP commit requirement.

---

### Family 5: Crash Recovery / Persistence (MEDIUM)

**Mechanism**: Crash between state changes leaves inconsistent persisted state — term without vote, committed config without WAL COMMIT, metadata loss on certain filesystems.

**Evidence**:
- Historical: KUDU-2195 (5e334de24, 690862082) — Consensus metadata loss on XFS; missing fsync allowed double-voting after power outage
- Historical: KUDU-1735 (cf976a40e) — Crash after committing config to cmeta but before WAL COMMIT; abort crashes trying to clear wrong pending config
- Historical: KUDU-1233 (09e3cabc7) — Committed config changes replayed from WAL during bootstrap; fix: skip if cmeta is "ahead"
- Code analysis: raft_consensus.cc:3187-3188 — `CHECK_OK(cmeta_->Flush())` crashes process on disk I/O failure
- Code analysis: raft_consensus.cc:592-593 — StepDown SKIP_FLUSH: crash undoes term advance (liveness issue)
- Design note: Term + votedFor ARE atomically persisted (single protobuf flush) — Kudu avoids the hashicorp/raft non-atomic persistVote pattern

**Suggested modeling approach**:
- Variables: `persistedTerm [Server -> Int]`, `persistedVotedFor [Server -> Option(Server)]`, `persistedConfig [Server -> Config]`
- Actions: `Crash` (reset volatile state, recover from persisted), `Recover` (replay log, restore config)
- Key: The atomic term+vote persistence means the hashicorp/raft crash window does NOT exist in Kudu. Focus crash modeling on config change persistence ordering (cmeta vs. WAL).

**Priority**: Medium
**Rationale**: Kudu's term+vote persistence is well-designed (atomic). The main crash concern is config change persistence ordering (KUDU-1735, KUDU-1233), which is more subtle.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Log replication with partial batches | Family 1: KUDU-639 root cause, multiple production bugs | Model leader sending subsets of log; follower clamping commit index |
| Log truncation on mismatch | Family 1: critical but not fully understood (TODO at line 1285) | Model `TruncateAndAbort` on term mismatch in log matching check |
| Commit index advancement | Family 1: watermark bugs, clamping fix | Model majority calculation with per-peer matchIndex tracking |
| Config change lifecycle | Family 2: pending→committed, abort on leader change | Two config variables (committed, pending), single-pending-at-a-time |
| Config change + election interleaving | Family 2: KUDU-872, KUDU-1338, KUDU-3082 | Leader must commit op in current term before accepting config change |
| Non-voter distinction | Family 2: NON_VOTER ack-counting bug | Voter/non-voter roles in config; only voters count for quorum |
| Vote withholding mechanism | Family 3: KUDU-562, KUDU-2947 | `withholdVotesUntil` timestamp; suppress votes after hearing from leader |
| Pre-election | Family 3: election storm prevention | Non-binding vote request; no term advance, no vote persistence |
| Step-down term advance | Family 3: KUDU-2335 | StepDown increments term (non-standard Raft) |
| NO_OP on leader election | Family 4: KUDU-597, standard Raft | Leader must replicate NO_OP before accepting client writes |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Prepare queue / operation ordering | Family 4: Implementation-specific (C++ thread pool). The key insight (term-binding at submission) is a local check, not protocol logic. |
| Lock ordering / deadlocks | Family 5 (deadlocks): Concurrency bug class better found with TSAN/thread analyzers |
| Disk I/O failures / CHECK_OK crashes | Implementation-specific error handling, not protocol logic |
| Safe time / timestamp management | Kudu-specific optimization for repeatable reads, not Raft safety |
| Log segment management / GC | Storage layer optimization, not consensus protocol |
| Leadership transfer | No high-priority bugs in this area; adds state space without targeting known issues |
| Crash recovery / bootstrap replay | Family 5: Complex but the atomic persistence design is sound; crash concerns are about config ordering which would require modeling WAL + cmeta separately |
| Multi-raft batching | Performance optimization, not safety-relevant |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Partial batch replication | `sentUpTo [Leader -> Server -> Int]` | Model leader sending subsets of log to followers | Family 1 |
| Commit clamping | (action-level: min of 3 values) | Prevent follower from committing beyond what was received | Family 1 |
| Dual configuration | `committedConfig`, `pendingConfig` | Track committed vs. pending config through lifecycle | Family 2 |
| Config change guard | `hasCommittedInTerm [Server -> Bool]` | Leader must commit in current term before config change | Family 2 |
| Non-voter role | `memberType [Server -> {Voter, NonVoter}]` | Only voters count for quorum | Family 2 |
| Vote withholding | `withholdVotesUntil [Server -> Time]` | Suppress votes after recent leader contact | Family 3 |
| Pre-election | `isPreElection [Bool]` in vote request | Non-binding election round | Family 3 |
| StepDown term bump | (action: term' = term + 1) | Model Kudu's non-standard step-down behavior | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard, Family 3 |
| LogMatching | Safety | If two logs contain an entry with same index and term, logs are identical through that index | Standard, Family 1 |
| LeaderCompleteness | Safety | Committed entries appear in all future leaders' logs | Standard, Family 1 |
| CommitIndexMonotonicity | Safety | A server's commitIndex never decreases | Family 1 (watermark regression) |
| CommitIndexBoundedByReceived | Safety | Follower's commitIndex ≤ last received index from current leader | Family 1 (KUDU-639) |
| SinglePendingConfig | Safety | At most one uncommitted config change at a time | Family 2 |
| ConfigChangeRequiresCommit | Safety | Leader only proposes config change after committing in current term | Family 2 (KUDU-872) |
| VoterOnlyQuorum | Safety | Only VOTER members count toward commit quorum | Family 2 |
| VoteSafety | Safety | Each server votes for at most one candidate per term | Family 3 |
| WithholdVotesImpliesRecentLeader | Safety | If withholdVotesUntil > now, a leader contacted this server recently | Family 3 |
| NoTermRegression | Safety | A server's term never decreases (in the non-crash case) | Family 3 |
| LeaderNOOPBeforeWrite | Safety | Leader does not accept client writes before its NO_OP is replicated | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Partial batch with high commit index causes follower to commit ops from wrong term (pre-KUDU-639 fix) | CommitIndexBoundedByReceived | 1 |
| MC-2 | Config change accepted before leader commits in current term (pre-KUDU-872 fix) | ConfigChangeRequiresCommit | 2 |
| MC-3 | Pending config not cleared on abort; subsequent leader uses stale config | SinglePendingConfig | 2 |
| MC-4 | Non-voter counted toward quorum advances commit index unsafely | VoterOnlyQuorum | 2 |
| MC-5 | Partitioned node inflates term, disrupts leader after rejoin (pre-withhold fix) | ElectionSafety (liveness) | 3 |
| MC-6 | NotifyTermChange failure (line 936) allows node to continue at old term | NoTermRegression | 3 |
| MC-7 | Pre-election + real election race: pre-election wins but real election uses stale config | ElectionSafety | 3 |
| MC-8 | Config change + election interleaving causes CONSENSUS_MISMATCH stuck state (KUDU-3082) | SinglePendingConfig, Liveness | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | consensus_queue.cc:1314 — VLOG dereferences `std::nullopt` when `first_index_in_current_term` has no value | Enable VLOG level 2, trigger response before leader NO_OP |
| TV-2 | `CancelPendingOps()` doesn't clear `pending_ops_` map (pending_rounds.cc:64-82) | Unit test: cancel then check `GetNumPendingOps()` |
| TV-3 | `MarkDirty()` captures raw `this` pointer in lambda (raft_consensus.cc:2857) | ASAN test with rapid consensus shutdown |
| TV-4 | `DumpStatusHtml()` accesses queue_ without lock during shutdown (raft_consensus.cc:2649-2672) | TSAN test with concurrent DumpStatusHtml and Shutdown |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | DCHECK-only validation of voter term in election (leader_election.cc:413) | Consider upgrading to runtime CHECK |
| CR-2 | `NotifyTermChange` swallows step-down errors (raft_consensus.cc:936) | Consider upgrading WARN_NOT_OK to RETURN_NOT_OK or CHECK_OK |
| CR-3 | `EndLeaderTransferPeriod()` modifies state without lock (raft_consensus.cc:654) | Verify atomicity is sufficient |
| CR-4 | StepDown SKIP_FLUSH could undo step-down on crash (raft_consensus.cc:592) | Verify no safety impact (liveness only) |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/kudu/analysis-report.md`
- **Key source files**:
  - `src/kudu/consensus/raft_consensus.cc` (3,332 lines — core state machine)
  - `src/kudu/consensus/consensus_queue.cc` (1,607 lines — replication queue, commit advancement)
  - `src/kudu/consensus/consensus_peers.cc` (785 lines — per-peer RPC management)
  - `src/kudu/consensus/leader_election.cc` (446 lines — election logic)
  - `src/kudu/consensus/consensus_meta.cc` (426 lines — persistent state)
  - `src/kudu/consensus/pending_rounds.cc` (256 lines — in-flight operation tracking)
- **JIRA issues**: KUDU-639, KUDU-597, KUDU-872, KUDU-1338, KUDU-3082 (open), KUDU-2947, KUDU-2149, KUDU-562
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Ongaro thesis §4.1 (config changes), §4.2.3 (pre-vote)
- **Bug-fix commit count**: 342 out of 863 total consensus commits (40%)
