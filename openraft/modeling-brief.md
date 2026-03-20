# Modeling Brief: datafuselabs/openraft

## 1. System Overview

- **System**: datafuselabs/openraft — Rust Raft consensus library used by Databend, GreptimeDB, CnosDB, and others
- **Language**: Rust (async), ~6,000 LOC core logic
- **Protocol**: Raft (with joint consensus, leader lease, committed-vote leader identity)
- **Key architectural choices**:
  - **Engine/Runtime separation**: Engine is a pure deterministic state machine producing Commands; RaftCore is the async runtime that executes them sequentially. No concurrent state mutation in the protocol logic.
  - **Committed vote as leader identity**: Vote includes a `committed` flag — a committed vote with the node's own ID means the node is an established leader. This replaces the traditional `(term, state)` pair.
  - **Leader lease**: `Leased<Vote>` wrapper with wall-clock lease. Followers reject VoteRequests from higher-term candidates while lease is active (deviation from standard Raft).
  - **Leader survival across restart**: If a node's persisted vote is a committed vote for itself, it resumes as leader on restart without re-election (non-standard).
  - **IO progress pipeline**: `accepted → submitted → flushed` pipeline with `Condition`-gated responses. Responses are never sent before persistence is confirmed.
  - **`save_committed()` is optional**: Default no-op. Applications that don't implement it rely on state machine `last_applied` for recovery.
- **Concurrency model**: Single-threaded event loop (RaftCore) for all protocol logic; separate per-peer async replication tasks communicate via channels; no shared mutable state between core and replication.

## 2. Bug Families

### Family 1: Vote Handling / Election Safety (HIGH)

**Mechanism**: Incorrect vote state transitions when processing RequestVote responses or encountering higher-term messages, leading to election safety violations or unnecessary disruption.

**Evidence**:
- Historical: `b06cbb37` — Vote updated when seeing higher vote in RequestVote response, breaking consistency (introduced in 0.10)
- Historical: `4015cc38` — Candidate didn't revert to follower immediately on higher vote; compared logs after updating vote (invalidated prior grants)
- Historical: PR #1220 — Equal vote from leader step-down incorrectly treated as granting leadership (0.10)
- Historical: Issue #452 — Candidate with stale log kept campaigning instead of stepping down
- Historical: Issue #920 — `calc_server_state()` and `is_leader()` returned inconsistent results on restart
- Historical: `54aea8a2` — `seen_greater_log` flag lost on state transition (stored inside destroyed Leader/Candidate state)
- Code analysis: `engine_impl.rs:663-664` — `update_vote` failure in `establish_leader` only debug-asserted, not hard-checked in release builds

**Affected code paths**:
- `Engine::handle_vote_resp()` (`engine_impl.rs:292-352`)
- `VoteHandler::update_vote()` (`vote_handler/mod.rs:104-149`)
- `VoteHandler::become_leader()` (`vote_handler/mod.rs:170-227`)
- `EstablishHandler::establish()` (`establish_handler/mod.rs:21-48`)
- `RaftState::calc_server_state()` (`raft_state/mod.rs:415-439`)

**Suggested modeling approach**:
- Variables: `vote[Server]`, `committed[Server -> BOOLEAN]`, `candidateState[Server]`
- Actions: Split `HandleVoteResponse` into accept (grant) vs reject paths. Model vote comparison with partial ordering (committed flag breaks ties for same-term different-node votes). Model election with self-vote + quorum accumulation.
- Key: Model the `committed` flag on votes — a committed vote for self = leader. Uncommitted vote = candidate.

**Priority**: High
**Rationale**: 6+ historical bugs sharing the same mechanism. Multiple bugs introduced in the v0.10 rewrite. The committed-vote design is unique to openraft and deviates from standard Raft.

---

### Family 2: Snapshot Installation / Log Consistency (HIGH)

**Mechanism**: Crash windows or incorrect ordering during snapshot installation leave conflicting logs in the store, enabling committed entries to be overwritten if the node later becomes leader.

**Evidence**:
- Historical: `674e78aa` — Conflicting logs before `snapshot_meta.last_log_id` not deleted before snapshot install. Crash after install but before cleanup → conflicting logs replicated if node becomes leader.
- Historical: `71a290cd` / Issue #511 — Purged `prev_log_id` treated as conflict, causing follower to delete committed logs. Root cause: `committed` could be smaller than `last_applied` after restart.
- Historical: Issue #437 — Logs purged before included in snapshot → neither logs nor snapshot available for recovery.
- Historical: PR #543 — Outdated snapshot (last_log_id < last_applied) could revert applied state.
- Code analysis: `following_handler/mod.rs:89-92` — Crash window between `truncate_logs` and `do_append_entries` (two separate commands), but benign due to IO progress gating.

**Affected code paths**:
- `FollowingHandler::install_full_snapshot()` (`following_handler/mod.rs:244-298`)
- `FollowingHandler::truncate_logs()` (`following_handler/mod.rs:166-185`)
- `FollowingHandler::append_entries()` (`following_handler/mod.rs:64-111`)
- `LogStateReader::has_log_id()` (`log_state_reader.rs:23-35`)

**Suggested modeling approach**:
- Variables: `log[Server -> Seq(LogEntry)]`, `snapshot[Server -> SnapshotMeta]`, `purgedUpTo[Server]`
- Actions: `InstallSnapshot` that (1) truncates conflicting logs, (2) installs snapshot, (3) purges. Model `Crash` action between steps. `HandleAppendEntries` with purged-log detection.
- Key: Model the interaction between purge, snapshot, and log truncation. The `has_log_id` optimization (auto-accepting entries below committed) is critical to model.

**Priority**: High
**Rationale**: 4 historical bugs, including a critical data-corruption bug (`674e78aa`). Snapshot + log interaction is inherently complex and well-suited for TLA+ model checking.

---

### Family 3: Heartbeat / Replication Progress Coordination (MEDIUM)

**Mechanism**: Heartbeat messages use incorrect state (global committed vs per-follower matching), causing false conflict detection, ignored conflicts, or failure to propagate commit index.

**Evidence**:
- Historical: `2bdfae5d` / Issue #1500 — Heartbeat used committed log ID as `prev_log_id`; followers behind commit point returned false conflicts, causing leader panic.
- Historical: `54ffb00d` — Leader ignored conflict responses from heartbeats, preventing discovery of follower log reversion.
- Historical: `ea14fdd0` / Issue #231 — Commit index not synced to followers when no new entries to send.
- Historical: `97fa1581` — Blank-log heartbeat design caused unnecessary IO and leadership seizure during snapshot transfers.
- Historical: Issue #833 — Replication deadlock after `Unreachable` error (backoff + drain_events race).

**Affected code paths**:
- `LeaderHandler::send_heartbeat()` (`leader_handler/mod.rs:104-110`)
- `ReplicationHandler::update_matching()` / `update_conflicting()` (`replication_handler/mod.rs:171-243`)
- `ReplicationCore::main()` (`replication/mod.rs:177-280`)

**Suggested modeling approach**:
- Variables: `matching[Leader -> Server -> LogId]`, `sentPrevLogId[Leader -> Server -> LogId]`
- Actions: `SendHeartbeat` using per-follower matching log ID. `HandleHeartbeatResponse` with conflict detection. `ReplicateEntries` with commit index propagation.
- Key: Model heartbeat as a separate action from log replication to capture the historical mismatch between what heartbeat probes and what the leader tracks.

**Priority**: Medium
**Rationale**: 5 historical bugs. The heartbeat design has been reworked multiple times. Current implementation (per-follower matching) appears correct, but the area is error-prone.

---

### Family 4: Membership Change / Joint Consensus (MEDIUM)

**Mechanism**: Incorrect quorum calculation, progress tracking, or config state during joint consensus transitions, especially when membership changes interact with leader election or replication stream management.

**Evidence**:
- Historical: PR #364 — Fast-commit optimization applied even when membership change altered quorum, potentially committing without proper quorum agreement.
- Historical: `37d69439` — Joint consensus never flattened to uniform config with concurrent membership changes (second step re-applied same change instead of flattening).
- Historical: `c8fccb22` — Adding learner without ensuring last membership was committed → log truncation could lose membership entries.
- Historical: `56486a60` / Issue #584 — Replication progress lost when streams re-spawned during membership change → assertion failure.
- Historical: `918b48bc` / Issue #424 — Duplicate membership entries from overlapping backward log scan.
- Historical: Issue #808 — Leader stuck during membership change when snapshot streaming to crashed node.
- Code analysis: Joint quorum correctly checked against ALL sub-configs (`joint.rs:97-103`). `ensure_committed()` correctly prevents concurrent membership changes (`change_handler.rs:54-67`). Quorum set upgrade is synchronous in the engine.

**Affected code paths**:
- `ReplicationHandler::append_membership()` (`replication_handler/mod.rs:63-91`)
- `ReplicationHandler::rebuild_progresses()` (`replication_handler/mod.rs:97-123`)
- `ChangeHandler::apply()` / `ensure_committed()` (`change_handler.rs:39-67`)
- `Membership::change()` / `next_coherent()` (`membership.rs:304-413`)

**Suggested modeling approach**:
- Variables: `config[Server -> Vec(Set(Server))]` (joint configs), `committedConfig[Server]`, `effectiveConfig[Server]`
- Actions: `ProposeConfigChange` (step 1 → joint), `CommitConfigChange` (step 2 → uniform). Guard with `ensure_committed` (at most one uncommitted membership). `RebuildQuorumSet` on membership append.
- Key: Model joint consensus where quorum = majority in EVERY sub-config. Model the two-step process and the guard preventing concurrent changes.

**Priority**: Medium
**Rationale**: 6 historical bugs in membership handling. Joint consensus is well-suited for TLA+ modeling. Current code appears correct after fixes, but the interaction between membership changes and other features (snapshots, elections) is complex.

---

### Family 5: Restart / Recovery / Leader Survival (MEDIUM)

**Mechanism**: Non-standard leader-survival-across-restart design creates correctness gaps when nodes restart with stale or incomplete state, especially in single-node clusters.

**Evidence**:
- Historical: Issue #1511 (OPEN) — Leader survival across restart can expose stale state machine to readers when `save_committed()` is not implemented.
- Historical: Issue #1246 — Missing log replay on single-node restart (committed index not restored on fast-path leader resume).
- Historical: Issue #607 — Single-node cluster restart panic (leader state not initialized before executing leader commands).
- Historical: PR #884 — Leader restart didn't restore local replication progress.
- Historical: PR #1125 — New leader blank log not flushed before accepting reads → committed data invisible.
- Historical: Issue #1467 — Stale leader metrics after restart (by design, but `last_quorum_acked` needed for correctness).
- Code analysis: `save_committed()` is optional (default no-op in `raft_log_storage.rs:78-81`). Recovery uses `max(read_committed, last_applied)` (`helper.rs:116-118`).

**Affected code paths**:
- `StorageHelper::get_initial_state()` (`helper.rs:88-225`)
- `RaftState::calc_server_state()` (`raft_state/mod.rs:415-439`)
- `VoteHandler::become_leader()` (`vote_handler/mod.rs:170-227`)

**Suggested modeling approach**:
- Variables: `persistedVote[Server]`, `persistedCommitted[Server]`, `crashed[Server -> BOOLEAN]`
- Actions: `Crash` (reset volatile state, recover from persisted). `Restart` (recalculate server state from persisted vote + log).
- Key: Model the leader-survival-across-restart: if persisted vote is committed for self → resume as leader. Check if stale state machine is ever exposed to reads.

**Priority**: Medium
**Rationale**: 6 historical bugs, 1 still open (#1511). The leader-survival design is unique to openraft and untested in other Raft implementations. TLA+ is well-suited for checking crash recovery scenarios.

---

### Family 6: IO / Command Ordering (LOW)

**Mechanism**: Incorrect ordering between command generation, execution, and response delivery, especially when engine commands depend on preceding IO completing before they can safely execute.

**Evidence**:
- Historical: `c37ac891` — `run_engine_commands()` not called after processing messages (commands left unexecuted).
- Historical: `001e3714` — Duplicated `SaveCommittedAndApply` command after refactoring.
- Historical: `675fda0d` — Progress-driven commands depended on preceding commands, creating deadlocks.
- Historical: PR #1180 — Responses sent before IO completion in 0.10.
- Historical: `8594807c` — Metrics updated before engine commands ran.
- Code analysis: The `Condition::IOFlushed` mechanism correctly gates responses. SaveVote blocks the event loop during persistence. Non-Respond commands that can't execute block the entire queue.

**Affected code paths**:
- `RaftCore::run_engine_commands()` (`raft_core.rs:1068-1124`)
- `RaftCore::run_command()` (`raft_core.rs:2017-2200`)
- `EngineOutput::postpone_command()` (`engine_output.rs:61-94`)

**Priority**: Low (for TLA+ modeling)
**Rationale**: IO ordering is an implementation concern, not protocol logic. The Engine/Runtime separation makes the engine deterministic and testable. These bugs are better caught by integration tests and the `Condition` mechanism now prevents the most dangerous variant (response before persistence).

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Committed-vote leader identity | Family 1: 6+ bugs in vote handling, unique design | `committed` flag on vote; committed vote for self = leader |
| Leader lease | Family 1: deviation from standard Raft, affects election safety | `leaseExpiry[Server]` variable; followers reject higher-term votes while lease active |
| Snapshot + log interaction | Family 2: 4 bugs including data corruption | `InstallSnapshot`, `TruncateLog`, `PurgeLog` as separate steps with `Crash` between |
| Joint consensus membership | Family 4: 6 bugs in membership changes | `configs` as vector of voter sets; quorum = majority in ALL sub-configs |
| Two-step membership change | Family 4: flattening bug `37d69439` | Step 1 → joint, Step 2 → uniform. Guard: at most one uncommitted membership |
| Crash and recovery | Family 2, 5: crash windows, restart bugs | `Crash` action resets volatile state; `Restart` recovers from persisted vote + log |
| Leader-survival-across-restart | Family 5: OPEN issue #1511, 6 bugs | If persisted vote is committed for self → resume as leader. Check safety. |
| Heartbeat with matching log ID | Family 3: 3 bugs in heartbeat design | Heartbeat carries per-follower `matching` as `prev_log_id`, not global committed |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| IO progress pipeline (accepted/submitted/flushed) | Family 6: implementation concern. The Engine is deterministic; IO ordering bugs are integration-test territory. |
| Replication task async lifecycle | Replication tasks communicate via channels. Their internal logic (backoff, reconnect, streaming) is implementation detail not protocol logic. |
| Metrics / observability | Family 6: `8594807c` is a timing issue in metrics delivery, not protocol safety. |
| Learner-to-voter transition mechanics | Implementation detail of `upgrade_quorum_set`. The quorum math itself is modeled via joint consensus. |
| `save_committed()` optional semantics | The committed index is always re-derivable from quorum. Modeling committed persistence adds complexity without targeting a protocol-level bug. |
| Pre-vote | openraft does not implement pre-vote. Not applicable. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Committed-vote identity | `vote[Server -> Vote]`, `Vote.committed: BOOLEAN` | Capture openraft's unique vote-as-leader-identity design | Family 1 |
| Leader lease | `leaseExpiry[Server -> Time]`, `clock[Time]` | Model lease-based VoteRequest rejection | Family 1 |
| Snapshot + purge + truncate | `snapshot[Server -> SnapshotMeta]`, `purgedUpTo[Server -> Index]` | Capture crash windows between snapshot install and log cleanup | Family 2 |
| Joint consensus | `configs[Server -> Vec(Set(Server))]`, `committedConfig[Server]` | Model two-step membership change with joint quorum | Family 4 |
| Crash/Recovery | `crashed[Server -> BOOLEAN]`, `persistedVote[Server]`, `persistedLog[Server]` | Model crash between operations and recovery from persisted state | Family 2, 5 |
| Leader survival | (part of Crash/Recovery) | Model restart-as-leader from committed persisted vote | Family 5 |
| Heartbeat with matching | `matching[Leader -> Server -> LogId]` | Model per-follower heartbeat probing | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one committed leader per term | Standard, Family 1 |
| LogMatching | Safety | Same index + same term ⇒ identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard, Family 2 |
| StateMachineSafety | Safety | Applied entries are committed and identical across nodes | Standard |
| VotePersistenceBeforeResponse | Safety | No vote response sent before vote is durable | Family 1, 6 |
| SnapshotLogConsistency | Safety | After snapshot install, no conflicting logs exist below snapshot.last_log_id | Family 2 |
| NoCommittedLogDeletion | Safety | Committed log entries are never deleted (only purged after snapshot) | Family 2 |
| LeaseImpliesLeadership | Safety | If lease is active and node serves reads, a real quorum has term ≤ node's term | Family 1 |
| JointQuorumAgreement | Safety | During joint consensus, commits require majority in ALL sub-configs | Family 4 |
| AtMostOneUncommittedMembership | Safety | At most one uncommitted membership log at any time | Family 4 |
| CommittedMonotonicity | Safety | Committed index never decreases | Family 2, 3 |
| RestartedLeaderSafety | Safety | A leader that resumes after restart has all previously committed entries | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Leader-survival-across-restart with stale state machine (Issue #1511) | RestartedLeaderSafety if `save_committed` not implemented | 5 |
| MC-2 | Snapshot install + crash before conflicting log cleanup (historical `674e78aa`) | SnapshotLogConsistency | 2 |
| MC-3 | Leader lease prevents legitimate higher-term candidate from winning election | LeaseImpliesLeadership (potential false positive) | 1 |
| MC-4 | Joint consensus membership change + leader election interleaving | ElectionSafety, JointQuorumAgreement | 4 |
| MC-5 | Crash between truncate and append on follower (two separate commands) | NoCommittedLogDeletion | 2 |
| MC-6 | Heartbeat with stale matching log ID after leader step-down | CommittedMonotonicity | 3 |
| MC-7 | Two-step membership change: second step with concurrent election | AtMostOneUncommittedMembership | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `establish_leader` `update_vote` failure only debug-asserted (engine_impl.rs:663-664) | Release-mode stress test with concurrent elections |
| TV-2 | Replication progress lost on stream re-spawn (Issue #584 regression) | Integration test: promote learner while replicating |
| TV-3 | `save_committed` not implemented → stale reads after restart | Single-node cluster with transient SM: write, restart, read |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `update_vote` return value not checked in release builds at `engine_impl.rs:663-664` | Change debug_assert to hard error |
| CR-2 | Non-Respond commands that can't execute block the entire command queue | Consider extracting to separate queue like Respond commands |
| CR-3 | `disable_lease()` method exists but has no callers in production code | Remove dead code or document intended use |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/openraft/analysis-report.md`
- **Key source files** (all under `artifact/openraft/openraft/src/`):
  - `core/raft_core.rs` (main runtime, 2272 lines)
  - `engine/engine_impl.rs` (core state machine, 876 lines)
  - `engine/handler/vote_handler/mod.rs` (vote handling, 276 lines)
  - `engine/handler/following_handler/mod.rs` (follower log handling, 342 lines)
  - `engine/handler/replication_handler/mod.rs` (replication + commit, 485 lines)
  - `engine/handler/leader_handler/mod.rs` (leader operations, 155 lines)
  - `membership/membership.rs` (joint consensus, 683 lines)
  - `raft_state/mod.rs` (state definition, 518 lines)
  - `raft_state/io_state.rs` (IO progress tracking, 290 lines)
  - `storage/v2/raft_log_storage.rs` (storage trait, 279 lines)
  - `replication/mod.rs` (replication task, 489 lines)
  - `vote/vote.rs` (vote struct, 261 lines)
- **GitHub issues**: #1511 (open, leader restart safety), #584, #511, #1500, #452, #607, #231, #424, #833, #808, #1246, #437, #920, #898
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
