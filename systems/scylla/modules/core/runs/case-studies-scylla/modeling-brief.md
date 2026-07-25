# Modeling Brief: scylladb/scylla (Raft Library)

## 1. System Overview

- **System**: ScyllaDB's built-in Raft library — C++20, Seastar-based consensus implementation
- **Language**: C++20 with Seastar async framework, ~6100 LOC core logic across 8 files
- **Protocol**: Raft (Ongaro 2014) with PreVote, joint consensus config changes, read barriers, leadership transfer
- **Key architectural choices**:
  - **Shared failure detector** instead of per-group AppendEntries heartbeats (`raft.hh:803-815`). Leader liveness relies on an external `failure_detector::is_alive()` rather than actual message exchange.
  - **Single-call term+vote persistence** (`persistence::store_term_and_vote()` at `raft.hh:729`). Unlike hashicorp/raft, this is atomic — no crash window between writing term and vote.
  - **Pre-persistence stable index advance** — `get_output()` advances `stable_idx` before entries are actually persisted (`fsm.cc:397-404`). Safety relies on crash-stop: if persistence fails, `io_fiber` stops the server.
  - **Two-fiber architecture**: `io_fiber` handles persistence + message sending; `applier_fiber` handles state machine application and snapshot creation. Communication via a bounded queue.
- **Concurrency model**: Single-threaded per Seastar core (cooperative scheduling). No locks; all interleaving happens at `co_await` yield points.

## 2. Bug Families

### Family 1: Commit Index Over-Advancement (CRITICAL)

**Mechanism**: Follower advances commit index based on leader-provided values without verifying that its own log actually matches the leader up to that point.

**Evidence**:
- Historical: `1216f39977` / #9965 — `advance_commit_idx(request.leader_commit_idx)` without clamping to `last_new_idx`. Follower marks obsolete entries as committed.
- Historical: `1eb849c3d7` / #10578 — Same class of bug via `read_quorum` messages. Leader sent raw `_commit_idx` in read_quorum without clamping to `match_idx`.
- Code analysis: Both fixes are in place (`fsm.cc:667` uses `std::min(leader_commit_idx, last_new_idx)`; `fsm.cc:1059` uses `std::min(p.match_idx, _commit_idx)`).

**Affected code paths**:
- `fsm::append_entries()` (fsm.cc:633-670)
- `fsm::broadcast_read_quorum()` (fsm.cc:1052-1063)
- `fsm::step()` follower handler for `read_quorum` (fsm.hh:552-556)

**Suggested modeling approach**:
- Variables: per-server `commitIndex`, `log[]`, `matchIndex[]` (leader)
- Actions: `HandleAppendEntries` must include the clamping. Model a `BuggyHandleAppendEntries` variant that omits clamping to reproduce the bug. Model `BuggyBroadcastReadQuorum` that sends raw commit_idx.
- Invariant: `CommitIndexSafety` — no server's committed entries diverge from the leader's.

**Priority**: High
**Rationale**: 2 critical safety violations sharing the same mechanism (unclamped commit advancement). Both fixed, but the pattern is systematic — any new code path that conveys commit information to followers could reintroduce it.

---

### Family 2: Joint Consensus Quorum Miscalculation (HIGH)

**Mechanism**: Incorrect voter identification or quorum calculation during joint configuration transitions, causing either safety violations (wrong quorum) or liveness failures (elections/operations stuck).

**Evidence**:
- Historical: `8f64a6d2d2` — `configuration::can_vote()` returned early from `current` config lookup without checking `previous` config. Joint-config voters incorrectly reported as non-voters.
- Historical: `f31f73b1e8` / #10618 — `voters()` set construction used `unordered_set::insert()` with duplicates, producing undefined results. A voter in `previous` but non-voter in `current` was excluded from the voter set, preventing it from voting for itself. Caused cluster unavailability.
- Historical: `b3cb4f3966` — Leader activity check counted non-voters and didn't handle joint config dual-majority correctly.
- Code analysis: **New finding** — `broadcast_read_quorum()` at `fsm.cc:1055` uses `p.can_vote` to decide who gets read_quorum requests, but `p.can_vote` reflects only the `current` config's voter status (due to `tracker::set_configuration` at `tracker.cc:114-118` skipping duplicates from `previous`). A server that is a voter only in the `previous` config won't receive read_quorum requests, yet its ack IS needed by `tracker::committed<read_id>()`. This stalls read barriers during voter demotion in joint consensus.

**Affected code paths**:
- `configuration::can_vote()` (raft.hh:206-217)
- `votes::votes()` constructor (tracker.cc:219-232)
- `tracker::set_configuration()` (tracker.cc:101-133) — `can_vote` field set from first config seen
- `broadcast_read_quorum()` (fsm.cc:1052-1063) — uses `p.can_vote` for filtering
- `tracker::committed<read_id>()` (tracker.cc:178-214) — uses `_previous_voters` for quorum

**Suggested modeling approach**:
- Variables: `currentConfig`, `previousConfig` (per server), `isVoter[server][config]`
- Actions: Model `JointConfigChange` (enter_joint, leave_joint). Model `ReadBarrier` with the filtering mismatch.
- Key: `set_configuration` must model the `can_vote` field assignment bug (uses current config only).

**Priority**: High
**Rationale**: 3 historical bugs + 1 new finding. Joint consensus is complex and error-prone. The read barrier stall is an unfixed liveness issue. TLA+ can exhaustively explore joint config state space.

---

### Family 3: Snapshot Lifecycle & Persistence Inconsistency (HIGH)

**Mechanism**: Complex interaction between snapshot application, log truncation, and persistence ordering creates windows for inconsistent state — especially around trailing entry counts and remote vs. local snapshot handling.

**Evidence**:
- Historical: `bdf7d1a411` / #9551 — Remote snapshots used `_config.snapshot_trailing` (non-zero) instead of 0 for persistence truncation. Could leave stale entries that corrupt state after restart.
- Historical: `88a6e2446d` / #9550 — Commit notifications and snapshot application ran in different fibers, violating ordering assumptions. Assertion failures.
- Historical: `a59779155f` / #9552 — Leader re-sent entries inside follower's snapshot. Follower rejected them, but reply never reached leader → replication stuck forever.
- Historical: `c3e52ab942` / #16817/#20080 — `store_snapshot_descriptor` received configured trailing instead of actual preserved count.
- Historical: `210d9dd026` / #11530 — Multiple snapshots between io_fiber polls overwrite `fsm_output.snp`, losing snapshot drops (memory leak).
- Historical: `55f047f33f` / #15222 — Duplicate snapshot from same host caused assertion failure.
- Code analysis: Pre-persistence stable index advance (`fsm.cc:397-404`) is safe under crash-stop but fragile — `advance_stable_idx` → `maybe_commit` can advance commit_idx before disk write.

**Affected code paths**:
- `fsm::apply_snapshot()` (fsm.cc:982-1018)
- `log::apply_snapshot()` (log.cc:231-279)
- `process_fsm_output()` snapshot handling (server.cc:1114-1127)
- `applier_fiber()` snapshot handling (server.cc:1419-1451)
- `replicate_to()` snapshot transfer trigger (fsm.cc:895-906)

**Suggested modeling approach**:
- Variables: `persistedSnapshotIdx`, `persistedLog[]`, `inMemoryLog[]`, `trailingCount`
- Actions: `TakeLocalSnapshot`, `ReceiveRemoteSnapshot`, `PersistSnapshot` (with trailing parameter), `Crash` + `Recover`.
- Granularity: Split persistence operations to model crash windows between them.

**Priority**: High
**Rationale**: 6+ historical bugs. Snapshot + persistence interaction is a classic TLA+ target. The crash recovery ordering is critical for safety.

---

### Family 4: Configuration Change Liveness (MEDIUM)

**Mechanism**: When a server participates in its own removal from the cluster, operations hang because the server stops receiving replication updates or loses leadership mid-operation.

**Evidence**:
- Historical: `28b5792481` / #9981 — Follower forwarding `modify_config` that removes itself waits for local commit that never arrives.
- Historical: `6cdd5b9ff5` / #10010 — `modify_config` removing the leader hangs because `io_fiber` aborts waiters on leadership loss.
- Historical: #10833 — Leader calling `modify_config` to remove itself gets stuck.
- Historical: `efad6fe9b4` / #11288 — Promise for non-joint config commit not connected to abort source; hangs forever on leadership loss.

**Affected code paths**:
- `server_impl::set_configuration()` (server.cc:1692-1748)
- `server_impl::modify_config()` (server.cc:866-918)
- `server_impl::execute_modify_config()` (server.cc:805-864)
- `fsm::transfer_leadership()` (fsm.cc:1020-1039)

**Suggested modeling approach**:
- Variables: `pendingConfigChange`, `configChangeWaiter`
- Actions: Model `ProposeConfigChange`, `CommitJointConfig`, `CommitNonJointConfig`, `LeaderStepdown`.
- Key: Model the case where the leader or a follower removes itself, verifying the operation eventually completes or returns an error.

**Priority**: Medium
**Rationale**: 4 historical bugs, all fixed. The pattern is well-understood now. Good for verifying liveness properties (leads-to).

---

### Family 5: Election Disruption & Failure Detector Dependence (MEDIUM)

**Mechanism**: The shared failure detector replaces per-group heartbeats, creating coupling between failure detector accuracy and election correctness / liveness.

**Evidence**:
- Historical: `bf823e34a4` — "Sticky leadership" rule (don't vote if leader alive) combined with shared failure detector caused cluster unavailability: removed servers still appeared alive, blocking elections.
- Historical: `5c8092cf42` — Disruptive candidate without prevote caused permanent election deadlock in 4-node clusters.
- Historical: `bce8cb11a7` — Missing election timer reset on vote grant allowed successful elections to be disrupted.
- Code analysis: `tick_leader()` at `fsm.cc:523-529` uses `failure_detector.is_alive()` for activity tracking. Stale FD → leader doesn't step down. This is documented and intentional, affecting only liveness.
- Code analysis: `has_stable_leader()` at `fsm.cc:590-606` suppresses elections based on FD. If FD says leader is alive but leader is partitioned from this follower, election is delayed.
- Code analysis: `vote_request::force` flag (raft.hh:408) is set during leadership transfer but **never read** by the receiver's `request_vote()` handler (fsm.cc:778-831). It's dead code — the disruptive server check it would bypass was removed.

**Affected code paths**:
- `fsm::tick()` (fsm.cc:587-631) — election suppression
- `fsm::tick_leader()` (fsm.cc:512-585) — activity tracking
- `fsm::request_vote()` (fsm.cc:778-831) — vote granting
- `fsm::become_candidate()` (fsm.cc:208-308) — candidacy decision

**Suggested modeling approach**:
- Variables: `failureDetectorView[server -> SUBSET Server]` (which servers each server sees as alive)
- Actions: `FDUpdate` to model stale/incorrect failure detector state. `Tick` triggers election suppression or leader stepdown based on FD.
- Key: Model FD staleness as a form of non-determinism independent of actual connectivity.

**Priority**: Medium
**Rationale**: 3 historical bugs. The FD dependence is architectural and well-documented. Pre-voting mitigates most issues. Good for verifying that safety holds regardless of FD accuracy.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Commit index clamping | Family 1: 2 critical safety violations | Model AppendEntries and ReadQuorum with both correct (clamped) and buggy (unclamped) variants |
| Joint consensus quorum | Family 2: 3 bugs + 1 new liveness finding | Two config variables (current, previous); dual-majority quorum for commits and elections |
| Read barrier during joint config | Family 2: New finding — `can_vote` field mismatch stalls reads | Model `broadcast_read_quorum` filtering using `can_vote` vs voter set membership |
| Snapshot application + log truncation | Family 3: 6+ bugs | Separate `persistedLog` from `inMemoryLog`; model trailing entry count |
| Crash and recovery | Family 3: persistence ordering matters | `Crash` action resets volatile state; `Recover` loads from persisted state |
| Failure detector abstraction | Family 5: FD staleness affects liveness | Model FD as a non-deterministic oracle with possible staleness |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Log memory management / semaphore backpressure | Performance optimization, not protocol logic |
| Message serialization / RPC transport | Below protocol abstraction level |
| Applier fiber queuing details | Server-layer implementation detail; model as atomic apply |
| Leadership transfer timeout mechanics | Complex server-layer timing; stepdown abort is liveness-only |
| Pre-vote optimization | Pre-vote adds state space without targeting known bug families. The bugs it prevents (disruptive candidates) are better modeled via FD abstraction |
| Entry forwarding from follower to leader | Server-layer convenience feature; not protocol logic |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Commit clamping variants | (action variants, no new vars) | Test clamped vs unclamped commit advancement | Family 1 |
| Dual configuration | `currentConfig`, `previousConfig` per server | Model joint consensus transitions | Family 2 |
| Voter status tracking | `canVote[server]` in tracker | Capture `can_vote` field mismatch for read barriers | Family 2 |
| Separate persistence | `persistedTerm`, `persistedVote`, `persistedLog`, `persistedSnapshotIdx` | Model crash recovery from durable state | Family 3 |
| Trailing entry count | `trailingCount` per snapshot | Capture incorrect trailing parameter | Family 3 |
| Failure detector oracle | `fdView[server -> SUBSET Server]` | Model FD staleness independently of connectivity | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Same index+term ⇒ identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard |
| CommitIndexSafety | Safety | No server commits an entry that differs from the leader's entry at that index | Family 1 |
| JointQuorumAgreement | Safety | During joint config, commit requires majority in BOTH current and previous configs | Family 2 |
| ReadBarrierLiveness | Liveness | A read barrier request eventually completes (under fairness + connectivity) | Family 2 |
| CrashRecoveryConsistency | Safety | After crash+recovery, persisted state is a valid Raft state | Family 3 |
| SnapshotLogContinuity | Safety | After snapshot application, log has no gaps (first_idx = snapshot.idx + 1 or entries follow continuously) | Family 3 |
| NoPhantomLease | Safety | Leader's FD-based activity check does not allow committed entries without actual quorum replication | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Unclamped commit advancement in AppendEntries | CommitIndexSafety | 1 |
| MC-2 | Unclamped commit advancement in ReadQuorum | CommitIndexSafety | 1 |
| MC-3 | Read barrier stall during voter demotion in joint config | ReadBarrierLiveness | 2 |
| MC-4 | `can_vote` field mismatch — tracker uses current config only | JointQuorumAgreement (for reads) | 2 |
| MC-5 | Remote snapshot with non-zero trailing corrupts log after restart | CrashRecoveryConsistency | 3 |
| MC-6 | Pre-persistence stable index advance + crash before disk write | CrashRecoveryConsistency | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T-1 | `vote_request::force` flag is dead code (never read by receiver) | Code comparison: grep for `force` usage in `request_vote()` |
| T-2 | Use-after-free in applier_fiber / handle_background_error (#23816) | UBSAN test with specific random seed |
| T-3 | Add_entry spanning multiple terms (#26189) | Integration test: leader change between memory permit and add_entry |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `vote_request::force` field is vestigial — disruptive server check was removed but field remains | Remove dead field or add comment explaining it's intentionally unused |
| CR-2 | `FIXME: replace this with a different exception type` in wait_for_entry (server.cc:581) | Low priority, improves client error handling |
| CR-3 | Snapshot lifecycle fragility (#9956) — snapshot may be dropped before application | Design review of snapshot ordering guarantees |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/scylla/analysis-report.md`
- **Key source files**:
  - `artifact/scylla/raft/fsm.cc` (core state machine, 1169 lines)
  - `artifact/scylla/raft/server.cc` (server wrapper, 1961 lines)
  - `artifact/scylla/raft/log.cc` (log management, 287 lines)
  - `artifact/scylla/raft/tracker.cc` (follower tracking + quorum, 294 lines)
  - `artifact/scylla/raft/raft.hh` (types + interfaces, 832 lines)
  - `artifact/scylla/raft/fsm.hh` (FSM class + step dispatch, 678 lines)
- **GitHub issues**: #9965, #10578 (Family 1); #10618 (Family 2); #9551, #9552, #9550 (Family 3); #9981, #10010 (Family 4)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Raft PhD thesis (Ongaro, 2014)
