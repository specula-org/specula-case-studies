# Modeling Brief: async-raft/async-raft

## 1. System Overview

- **System**: async-raft — Rust Raft consensus library (tokio-based async runtime)
- **Language**: Rust, ~3,500 LOC core protocol logic (`core/` + `replication/`)
- **Protocol**: Raft (Ongaro & Ousterhout, 2014) with joint consensus membership changes
- **Key architectural choices**:
  - **Event-driven, no tick**: fully reactive async loop (no periodic tick); election timeout via `Instant` comparison
  - **Single RaftCore task** processes all RPCs and state transitions sequentially (no concurrent handlers)
  - **Per-follower ReplicationStream** tasks: each runs independently, communicates via `mpsc` channel events
  - **Heartbeats are empty AppendEntries**: same handler, same code path (no separate heartbeat goroutine — unlike hashicorp/raft)
  - **Optimistic match_index initialization**: new replication streams assume `match_index = last_log_index` (spec says 0)
  - **No PreVote**: TODO in code (vote.rs:65), but not implemented
- **Concurrency model**: Single tokio task for core state machine; N spawned tasks for replication streams; spawned tasks for state machine application

## 2. Bug Families

### Family 1: Incorrect Quorum / Majority Calculations (CRITICAL)

**Mechanism**: The quorum threshold formula for linearizable reads is systematically wrong, requiring fewer confirmations than a true majority. Additionally, joint consensus C1 quorum omits the leader's own log progress.

**Evidence**:
- Code analysis: `client.rs:109-113` — formula `(len/2)-1` (even) or `len/2` (odd). For N=3: needs 1 confirmation total (self=1), but majority requires 2. For N=5: needs 2, but majority requires 3. Every cluster size >= 2 is affected.
- Code analysis: `core/replication.rs:153-158` — C1 quorum never includes leader's own `(last_log_index, last_log_term)`, unlike C0 (lines 145-147)
- Code analysis: `core/replication.rs:153-158` + `admin.rs:195-229` — non-voters promoted via membership change are never moved from `non_voters` to `nodes` map, so they are invisible to commit index calculation

**Affected code paths**:
- `LeaderState::handle_client_read_request` (client.rs:105-210)
- `LeaderState::handle_update_match_index` → `calculate_new_commit_index` (core/replication.rs:138-166)
- `LeaderState::finalize_joint_consensus` (admin.rs:195-229)

**Suggested modeling approach**:
- Variables: model read confirmation as a separate action with explicit quorum check
- Actions: `ClientReadRequest` sends heartbeats, `ClientReadConfirm` counts responses. Invariant checks that reads only succeed after majority confirmation.
- For joint consensus: model C0/C1 quorum separately, ensure both require true majority including leader

**Priority**: High
**Rationale**: Affects every even-sized cluster and every 3+ node cluster for reads. Directly violates linearizability. C1 quorum bug affects all additive membership changes.

---

### Family 2: Incorrect Log Up-to-Date Check in Elections (CRITICAL)

**Mechanism**: The vote handler uses conjunction (`&&`) instead of lexicographic comparison for the log up-to-date check, rejecting candidates with higher last log term but lower index.

**Evidence**:
- Code analysis: `vote.rs:53` — `(msg.last_log_term >= self.last_log_term) && (msg.last_log_index >= self.last_log_index)`
- Raft paper §5.4.1 specifies lexicographic: higher term wins regardless of index; equal term → longer log wins
- Impact: candidate with `(term=5, index=1)` rejected by voter with `(term=3, index=100)` — wrong per spec

**Affected code paths**:
- `RaftCore::handle_vote_request` (vote.rs:51-63)

**Suggested modeling approach**:
- Model the buggy check as-is in the spec. The standard `ElectionSafety` and `LeaderCompleteness` invariants should detect the violation.
- Split into: `BuggyUpToDate(candidate, voter)` vs `CorrectUpToDate(candidate, voter)` to demonstrate the difference.

**Priority**: High
**Rationale**: Violates Leader Completeness (Raft §5.4.1). Can cause committed entries to be lost if a candidate with an older but longer log wins election over one with a shorter but higher-term log. Also causes liveness failures (legitimate candidates cannot get elected).

---

### Family 3: Premature / Incorrect Commit Index Advancement (CRITICAL)

**Mechanism**: Multiple code paths advance `commit_index` without proper guards: (a) AppendEntries sets `commit_index = leader_commit` unconditionally (missing `min()` and applied before log consistency check), (b) initial `match_index` + `match_term` optimism can cause premature commit on leader side.

**Evidence**:
- Code analysis: `append_entries.rs:28` — `self.commit_index = msg.leader_commit` with no `min(leaderCommit, lastNewEntry)` per Raft Figure 2 rule 5. Executes before log consistency check (line 80+), so even rejected RPCs advance commit_index.
- Code analysis: `core/replication.rs:27-28` — `match_index: self.core.last_log_index, match_term: self.core.current_term`. When leader is newly elected, followers are assumed to have replicated the leader's entire log at the leader's current term. Combined with `calculate_new_commit_index` (line 266: `new_val.1 == leader_term`), this can cause the leader to commit entries from a previous term in the window before the first heartbeat round-trip.
- Historical: Issue #108 / commit `5f2567b` — prior-term entries committed by counting replicas (fixed with term check, but initial match_term bypasses the fix)

**Affected code paths**:
- `RaftCore::handle_append_entries_request` (append_entries.rs:14-76)
- `LeaderState::spawn_replication_stream` (core/replication.rs:13-33)
- `calculate_new_commit_index` (core/replication.rs:259-271)

**Suggested modeling approach**:
- Variables: `commitIndex[s]` per server, `matchIndex[leader][follower]`, `matchTerm[leader][follower]`
- Actions: model AppendEntries receiver with the buggy unconditional commit_index update. Model leader with optimistic match_index initialization.
- Invariant: `CommitIndexSafety` — committed entries must appear in every future leader's log

**Priority**: High
**Rationale**: Directly violates State Machine Safety. The AppendEntries commit_index bug affects every follower on every RPC. The match_index initialization has a narrow window but is a real safety violation.

---

### Family 4: Snapshot-Log State Inconsistency (HIGH)

**Mechanism**: After snapshot installation, in-memory state (`last_log_index`, `last_log_term`, `commit_index`) becomes inconsistent with actual on-disk state. The reference storage implementation (memstore) also uses wrong membership config source.

**Evidence**:
- Code analysis: `install_snapshot.rs:135-136` — `last_log_index` and `last_log_term` unconditionally set to snapshot values, even when log retains entries past the snapshot index (line 120-121 correctly keeps them)
- Code analysis: `install_snapshot.rs:135-138` — `commit_index` never updated after snapshot install (remains at 0 or stale value)
- Issue #133 — `finalize_snapshot_installation` reads membership from local log instead of incoming snapshot
- Issue #134 — `do_log_compaction` misses `SnapshotPointer` entries when searching for membership config
- Code analysis: `memstore/lib.rs:356` — fallback `MembershipConfig::new_initial(self.id)` creates single-node config when log is empty

**Affected code paths**:
- `RaftCore::finalize_snapshot_installation` (install_snapshot.rs:114-141)
- `MemStore::finalize_snapshot_installation` (memstore/lib.rs:333-377)
- `MemStore::do_log_compaction` (memstore/lib.rs:270-325)

**Suggested modeling approach**:
- Variables: `snapshotIndex[s]`, `snapshotTerm[s]`, `snapshotMembership[s]`
- Actions: `InstallSnapshot` with explicit log truncation semantics. `TakeSnapshot` with membership extraction.
- Invariant: `SnapshotConsistency` — after snapshot install, `last_log_index >= snapshot_index`, `commit_index >= snapshot_index`, membership reflects snapshot content

**Priority**: Medium (snapshot bugs are important but harder to trigger than quorum/election bugs; some are memstore-specific)
**Rationale**: 2 open unfixed issues. Wrong membership after snapshot can cause permanent cluster partition. But the core protocol bugs (Families 1-3) are higher priority for model checking.

---

### Family 5: Membership Change Lifecycle Gaps (HIGH)

**Mechanism**: The non-voter → voter promotion path is incomplete: nodes added via `add_non_voter` + `change_membership` remain in `non_voters` map instead of being moved to `nodes` map, making them invisible to commit index calculation. Removed nodes' replication streams are never cleaned up.

**Evidence**:
- Issue #112 (OPEN) — removed nodes continue receiving replication indefinitely
- Issue #62 (fixed in PR #59) — joint consensus used single counter instead of dual majority
- Code analysis: `admin.rs:195-229` — `finalize_joint_consensus` updates `membership.members` but never moves entries from `self.non_voters` to `self.nodes`
- Code analysis: `admin.rs:233-267` — `handle_uniform_consensus_committed` only removes from `self.nodes`, ignoring `self.non_voters`
- 3 unmerged fix PRs (#122, #123, #124) from @drmingdrmer

**Affected code paths**:
- `LeaderState::finalize_joint_consensus` (admin.rs:195-229)
- `LeaderState::handle_uniform_consensus_committed` (admin.rs:233-267)
- `LeaderState::handle_update_match_index` (core/replication.rs:100-197)

**Suggested modeling approach**:
- Variables: `membership[s]` (current config), `pendingConfig[s]` (joint consensus pending), `replicationTarget[leader]` (set of nodes receiving replication)
- Actions: `AddNonVoter`, `ChangeMembership` (enter joint), `CommitJointConfig`, `CommitUniformConfig`
- Invariant: `MembershipQuorum` — all voting members participate in quorum calculation. `ReplicationComplete` — removed members eventually stop receiving replication.

**Priority**: Medium
**Rationale**: Issue #112 is unfixed. The non-voter promotion bug means additive membership changes effectively break commit advancement. But membership changes require a larger state space to model.

---

### Family 6: Client Read Linearizability Violations (HIGH)

**Mechanism**: Beyond the quorum formula bug (Family 1), the read confirmation loop has control flow errors: it does not abort after detecting leader deposition, and it uses `!=` instead of `>` for term comparison, causing spurious step-downs.

**Evidence**:
- Code analysis: `client.rs:181-184` — after detecting `data.term != self.core.current_term`, code sets `target_state = Follower` but does NOT return error or break from loop. Execution falls through to confirmation counting (lines 187-203), potentially returning `Ok(())` to client after deposition.
- Code analysis: `client.rs:181` — uses `!=` instead of `>`. A response with a lower term triggers spurious `update_current_term` + `set_target_state(Follower)`. (`update_current_term` has a `>` guard internally, so term doesn't regress, but the follower transition fires.)
- Code analysis: `client.rs:183` — no `save_hard_state()` after term update (crash window: new term not persisted)

**Affected code paths**:
- `LeaderState::handle_client_read_request` (client.rs:105-210)

**Suggested modeling approach**:
- Model as part of `ClientRead` action. After receiving response, check if leader is still valid before responding.
- Invariant: `LinearizableRead` — read returns only values committed at or after the read was initiated

**Priority**: High (combines with Family 1 for devastating linearizability impact)
**Rationale**: Even if the quorum formula is fixed, the control flow bug allows stale reads after leader deposition.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Buggy quorum formula for reads | Family 1: systematic error in every cluster >= 2 nodes | Model `ClientRead` with explicit confirmation counting using the buggy formula |
| Buggy log up-to-date check | Family 2: AND instead of lexicographic violates Leader Completeness | Model `HandleVoteRequest` with the buggy conjunction check |
| Unconditional commit_index update in AppendEntries | Family 3: commit_index advanced without min() guard and before consistency check | Model `HandleAppendEntries` with commit_index set at the start |
| Optimistic match_index initialization | Family 3: initial match_index=last_log_index, match_term=current_term | Model `BecomeLeader` initializing match state optimistically |
| Joint consensus with C0/C1 quorum | Family 1, 5: C1 missing leader's entry, non-voters invisible | Model dual quorum with separate C0/C1 tracking |
| Client read deposition handling | Family 6: confirmation loop continues after step-down | Model the buggy control flow where read succeeds after deposition |
| Snapshot installation state updates | Family 4: last_log_index/term clobbered, commit_index not updated | Model `InstallSnapshot` with the buggy state updates |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Async task scheduling / tokio internals | Implementation detail, not protocol logic. The single-threaded core guarantees sequential handler execution. |
| memstore-specific bugs (#133, #134) | Storage implementation bugs, not protocol bugs. The trait interface is the abstraction boundary. |
| Shutdown lifecycle (#79, #138, #136) | Operational concern, not consensus safety. |
| Non-atomic persistence (term/vote) | The single-threaded architecture makes crash-between-writes unlikely to surface in testing, and the Raft spec itself doesn't mandate atomic persistence (just "persistent state"). Lower priority than active safety violations. |
| PreVote | Not implemented in this codebase. |
| Election timeout randomization | Liveness optimization, not safety concern. |
| Replication buffer management (Lagging/LineRate states) | Performance optimization. Safety is maintained by fetching from storage. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Buggy quorum formula | `readConfirmed[s]`, `readNeeded[s]` | Capture the incorrect quorum threshold | Family 1, 6 |
| Buggy log comparison | (modify VoteRequest handler logic) | Use `&&` instead of lexicographic | Family 2 |
| Unconditional commit update | (modify AppendEntries handler logic) | Set commit_index = leader_commit without min() | Family 3 |
| Optimistic match init | `matchIndex[leader][follower]` | Initialize to last_log_index instead of 0 | Family 3 |
| Dual quorum (C0/C1) | `membershipC0[s]`, `membershipC1[s]` | Model joint consensus with separate quorum tracking | Family 1, 5 |
| Snapshot state clobber | `snapshotIndex[s]` | Model incorrect last_log_index/term after snapshot | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Same index + same term → identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entry present in every future leader's log | Standard, Family 2 |
| StateMachineSafety | Safety | No two servers apply different entries at the same index | Standard, Family 3 |
| CommitIndexSafety | Safety | commit_index only advances to entries replicated to a majority | Family 3 |
| LinearizableRead | Safety | Read response reflects state committed at or after request | Family 1, 6 |
| QuorumConfirmation | Safety | Read succeeds only after majority-of-cluster confirmation | Family 1 |
| JointQuorum | Safety | During joint consensus, both C0 and C1 majorities agree | Family 1, 5 |
| SnapshotConsistency | Safety | After snapshot: last_log_index >= snapshot_index, commit_index >= snapshot_index | Family 4 |
| VoteUpToDate | Safety | Vote granted only to candidate with lexicographically >= log | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Quorum formula allows reads without majority confirmation (N=3: leader alone suffices) | QuorumConfirmation, LinearizableRead | 1 |
| MC-2 | AND instead of lexicographic in up-to-date check rejects valid candidates | LeaderCompleteness, ElectionSafety | 2 |
| MC-3 | commit_index set to leader_commit without min() guard, even on failed RPCs | CommitIndexSafety, StateMachineSafety | 3 |
| MC-4 | Optimistic match_index=last_log_index + match_term=current_term allows premature commit | CommitIndexSafety | 3 |
| MC-5 | Read confirmation loop continues after leader deposition | LinearizableRead | 6 |
| MC-6 | C1 quorum calculation omits leader's own entry | JointQuorum | 1 |
| MC-7 | last_log_index/term clobbered after snapshot install with retained entries | ElectionSafety (wrong log comparison), SnapshotConsistency | 4 |
| MC-8 | commit_index not updated after snapshot installation | SnapshotConsistency | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Single-node cluster read returns immediately (correct) but 3-node also returns immediately (wrong) | Unit test: 3-node cluster `client_read` without network should fail, but succeeds |
| TV-2 | Non-voter promoted to voter via membership change has no commit quorum participation | Integration test: add node via add_non_voter + change_membership, verify writes commit |
| TV-3 | Removed node continues receiving replication indefinitely (Issue #112) | Integration test: remove node, verify replication stream terminates |
| TV-4 | Optimistic last_applied update before async SM task completes (client.rs:248) | Mock storage: fail apply task, verify last_applied not advanced |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | heartbeat guard (vote.rs:26-38) blocks higher-term vote requests before term update | Design decision — similar to PreVote but incomplete |
| CR-2 | Replication event handler errors silently swallowed (core/replication.rs:52-54) | Add error propagation or shutdown trigger |
| CR-3 | Conflict optimization searches wrong direction (append_entries.rs:127-142) | Performance concern only, not safety |
| CR-4 | entries_cache cleared on leader change (mod.rs:290) can orphan pending SM replication | Review if gap-fill mechanism handles all cases |
| CR-5 | Debug println! in memstore finalize_snapshot_installation (memstore/lib.rs:342) | Remove before production use |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/async-raft/analysis-report.md`
- **Key source files**:
  - `artifact/async-raft/async-raft/src/core/mod.rs` (962 lines — state machine, event loop)
  - `artifact/async-raft/async-raft/src/core/append_entries.rs` (305 lines — AppendEntries handler)
  - `artifact/async-raft/async-raft/src/core/vote.rs` (161 lines — RequestVote handler)
  - `artifact/async-raft/async-raft/src/core/client.rs` (372 lines — client read/write)
  - `artifact/async-raft/async-raft/src/core/replication.rs` (370 lines — leader-side replication)
  - `artifact/async-raft/async-raft/src/core/admin.rs` (268 lines — membership changes)
  - `artifact/async-raft/async-raft/src/core/install_snapshot.rs` (141 lines — snapshot install)
  - `artifact/async-raft/async-raft/src/replication/mod.rs` (838 lines — replication stream task)
- **GitHub issues**: #108 (commit counting), #62 (joint consensus), #98 (heartbeat log deletion), #112 (zombie replication), #132 (20+ bugs catalog), #133/#134 (snapshot membership)
- **Reference**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
- **Successor project**: [openraft](https://github.com/datafuselabs/openraft) (fork by @drmingdrmer that fixed many of these bugs)
