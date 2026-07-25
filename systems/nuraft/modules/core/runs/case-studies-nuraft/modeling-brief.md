# Modeling Brief: ebay/nuraft

## 1. System Overview

- **System**: ebay/nuraft — C++ Raft consensus library used by ClickHouse, eBay, Memgraph
- **Language**: C++, ~7000 LOC core logic (src/*.cxx), ~14K total
- **Protocol**: Raft (with Pre-Vote, priority-based leader election, streaming replication, full consensus mode, auto-quorum adjustment)
- **Key architectural choices**:
  - **Dual-mutex concurrency**: `cli_lock_` serializes client requests; `lock_` serializes Raft protocol operations. They can run concurrently in `dual_mutex` mode.
  - **Heartbeat = empty AppendEntries**: No separate heartbeat mechanism; same code path as log replication.
  - **Precommit index**: Intermediate index (`precommit_index_`) between log append and state machine commit, updated via CAS.
  - **Auto-quorum adjustment**: In 2-node clusters, quorum can be reduced to 1 when a peer is unresponsive.
  - **Non-atomic `term` + `votedFor` persistence**: `state_->inc_term()` and `state_->set_voted_for()` are separate in-memory operations, persisted by a single `save_state()` call later.
  - **Single-config-change-at-a-time**: Uses `config_changing_` flag (not joint consensus).
- **Concurrency model**: Background threads for commit (`commit_in_bg`), append entries (`append_entries_in_bg`), and per-peer heartbeat timers. Main Raft state machine under `lock_` (recursive mutex).

## 2. Bug Families

### Family 1: Precommit/Commit Order Inversion (HIGH)

**Mechanism**: The `precommit_index_` can be advanced or reverted by concurrent threads, causing commit to run ahead of precommit or log entries to be committed before their pre-commit callbacks fire.

**Evidence**:
- Historical: PR #108 — `peer::set_free()` called before response handler; duplicate logs, precommit order inversion
- Historical: PR #140 — `precommit_index_` reverted by concurrent threads; CAS-based fix introduced
- Historical: PR #554 — config change thread advances precommit_index between log store and precommit in client request path; `cli_lock_` acquired for config entries
- Code analysis: `handle_commit.cxx:363-369` — fatal exit `N23_precommit_order_inversion` if commit runs ahead of precommit (defensive check still present)
- Code analysis: `handle_append_entries.cxx:1146-1167` — CAS retry bounded at 10 attempts

**Affected code paths**:
- `try_update_precommit_index()` (handle_append_entries.cxx:1146-1167)
- `handle_cli_req()` (handle_client_request.cxx:121-142)
- `store_log_entry()` for config entries (raft_server.cxx:1960-1993)
- `commit_in_bg_exec()` (handle_commit.cxx:184-319)

**Suggested modeling approach**:
- Variables: `precommitIndex [Server -> Nat]`, separate from `commitIndex`
- Actions: Split log append and precommit update into separate steps for config entries vs app entries
- Granularity: Model the dual-mutex concurrency as interleaving between client request thread and Raft protocol thread

**Priority**: High
**Rationale**: 3 critical historical bugs sharing the same mechanism. Fixes are in place but the architecture remains complex. CAS-based fix is subtle.

---

### Family 2: Non-Atomic Term/Vote Persistence (MEDIUM)

**Mechanism**: `term` and `votedFor` are modified in memory as separate operations, then persisted by a single `save_state()`. A crash between the in-memory modifications and persistence can leave the node with inconsistent persistent state.

**Evidence**:
- Code analysis: `handle_vote.cxx:241-261` — `inc_term()` → `set_voted_for(-1)` → `set_voted_for(id_)` → `save_state()`. Crash between `inc_term` and `save_state` loses the term increment; node restarts at old term.
- Code analysis: `raft_server.cxx:1572-1580` — `set_term(term)` → `set_voted_for(-1)` → `save_state()`. Crash between `set_term` and `save_state` leaves new term with old votedFor.
- Historical: PR #294 — race between `update_term` and `handle_cli_req` causing log entry with wrong term (CRITICAL, fixed)
- Historical: PR #262 — duplicate `save_state` removed, creating this crash window

**Affected code paths**:
- `initiate_vote()` / `request_vote()` (handle_vote.cxx:241-261)
- `update_term()` (raft_server.cxx:1554-1585)

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor` (on-disk), `volatileTerm`, `volatileVotedFor` (in-memory)
- Actions: Split `RequestVote` into `IncrementTerm` (in-memory only) and `PersistVoteState` (flush to disk). Add `Crash` action recovering from persisted state.
- Key check: Can a node vote twice in the same term after crash recovery?

**Priority**: Medium
**Rationale**: Concrete crash windows. The pre-vote mechanism mitigates most scenarios. Classic TLA+ crash injection target.

---

### Family 3: Configuration Change Races (HIGH)

**Mechanism**: The `config_changing_` guard is not consistently enforced across all config-modifying paths. Multiple state variables (`srv_to_join_`, `srv_to_leave_`, `conf_to_add_`, `uncommitted_config_`) interact with complex lifecycle management, creating windows for lost configs, stale references, and double-vote during join.

**Evidence**:
- Historical: PR #36 — uncommitted config overwritten by next config change (config lost)
- Historical: PR #67 — new leader ignores uncommitted config from previous leader
- Historical: PR #78 — `catching_up_` cleared too early; new node steps down
- Historical: PR #90 — server removed from peer list before config committed (never learns of removal)
- Historical: PR #107 — new leader modified committed config, skipping config commit
- Historical: PR #129 — join stalls after restart (config not persisted during join)
- Historical: PR #562 — `catching_up_` flag made durable to survive restart
- Historical: PR #629, #640 — concurrent join requests, cross-cluster join validation
- Code analysis: `handle_priority.cxx:39-107` — `set_priority()` bypasses `config_changing_` guard (no check)
- Code analysis: `handle_join_leave.cxx:270` — `voted_for` reset to -1 on join request, violating vote uniqueness per term
- Code analysis: `handle_join_leave.cxx:259-286` — non-atomic commit index reset + config save on join (crash gap)

**Affected code paths**:
- `handle_add_srv_req()`, `handle_rm_srv_req()`, `set_priority()`, `flip_learner_flag()`
- `handle_join_cluster_req()`, `sync_log_to_new_srv()`, `rm_srv_from_cluster()`
- `commit_conf()` / `reconfigure()` (handle_commit.cxx:476-1160)

**Suggested modeling approach**:
- Variables: `configChanging`, `srvToJoin`, `srvToLeave`, `uncommittedConfig`, `catchingUp [Server -> BOOLEAN]`
- Actions: `AddServer`, `RemoveServer`, `CommitConfig`, `JoinCluster`, `ReconfigurePeers`
- Key: model the one-change-at-a-time guard and verify it holds across all paths including priority changes
- Add crash during join to test non-atomic commit index + config persistence

**Priority**: High
**Rationale**: 16+ historical bug-fix commits (most of any component). Multiple unfixed issues (learner-becomes-leader #553, TSAN race #493/#644). Priority bypass of `config_changing_` is a new finding.

---

### Family 4: Quorum Calculation Edge Cases (HIGH)

**Mechanism**: The auto-quorum-adjustment feature for 2-node clusters reduces quorum to 1 when the peer is unresponsive, enabling single-node operation but risking split-brain. Full consensus mode has additional edge cases with peer exclusion logic.

**Evidence**:
- Historical: Issue #151 — auto-adjust quorum risks split-brain (maintainer-acknowledged risk)
- Historical: PR #121 — auto-adjust quorum bug in 2-node cluster with snapshot receiver
- Historical: PR #437 — adjusted quorum not reset when becoming follower
- Historical: PR #488 — commit not triggered when quorum becomes 1
- Historical: PR #564 — incorrect quorum calculation for busy connections
- Historical: PRs #602, #606, #612, #647 — multiple full-consensus-mode edge cases
- Code analysis: `handle_vote.cxx:105-123` — both nodes in 2-node cluster can independently lower quorum to 1
- Code analysis: `handle_append_entries.cxx:195-243` — leader auto-adjusts quorum and immediately commits pending logs

**Affected code paths**:
- `request_prevote()` quorum adjustment (handle_vote.cxx:105-123)
- `request_append_entries()` quorum adjustment (handle_append_entries.cxx:195-243)
- `get_expected_committed_log_idx()` full consensus calculation (handle_append_entries.cxx:1523-1608)
- `get_quorum_for_commit()`, `get_quorum_for_election()` (raft_server.cxx:600-640)

**Suggested modeling approach**:
- Variables: `customQuorumSize [Server -> Nat]`, `autoAdjusted [Server -> BOOLEAN]`
- Actions: `AdjustQuorum` (when peer unresponsive), `RestoreQuorum` (when peer responds or become_follower)
- Model 2-node cluster with network partition where both nodes independently lower quorum
- Invariant: Check Agreement (no two nodes commit different values at same index)

**Priority**: High
**Rationale**: Documented split-brain risk. 6+ historical bugs. The auto-adjust feature is widely used (default for 2-node clusters). TLA+ can definitively show the split-brain scenario.

---

### Family 5: Stale Response / Missing Guards in Response Handlers (MEDIUM)

**Mechanism**: Response handlers for AppendEntries and RequestVote lack checks for stale responses (from lower terms) and stale role (node no longer leader/candidate when response arrives).

**Evidence**:
- Code analysis: `handle_append_entries.cxx:1169-1508` — no term comparison in `handle_append_entries_resp`; stale response from lower term can update `matched_idx` and trigger commit
- Code analysis: `handle_vote.cxx:390-428` — `handle_vote_resp` doesn't check `role_ == candidate`; late vote responses after node demoted to follower could trigger `become_leader()`
- Code analysis: `handle_vote.cxx:481-558` — `handle_prevote_resp` doesn't check role; stale pre-vote responses can trigger `initiate_vote()` after term change
- Code analysis: `handle_vote.cxx:431-479` — `handle_prevote_req` missing log up-to-dateness check (deviation from Ongaro thesis §9.6)
- Historical: PR #116 — stale leader ID returned after role change

**Affected code paths**:
- `handle_append_entries_resp()` (handle_append_entries.cxx:1169-1508)
- `handle_vote_resp()` (handle_vote.cxx:390-428)
- `handle_prevote_resp()` (handle_vote.cxx:481-558)
- `handle_prevote_req()` (handle_vote.cxx:431-479)

**Suggested modeling approach**:
- Model message delivery with arbitrary delays (messages from earlier terms arriving later)
- Add role check to `HandleVoteResponse` action
- Compare: what if pre-vote includes log comparison vs. not

**Priority**: Medium
**Rationale**: Multiple code paths missing guards. The existing `update_term` check filters higher-term responses but NOT lower-term ones. Model checking can explore whether stale responses can cause safety violations.

---

### Family 6: Snapshot + Config/Commit Interaction (MEDIUM)

**Mechanism**: Snapshot installation interacts with configuration changes and commit index management in non-atomic ways. Log compaction, state machine application, config update, and commit index reset have crash gaps between them.

**Evidence**:
- Historical: PR #373 — segfault during snapshot install (SM not paused)
- Historical: PR #426 — deadlock between snapshot sync and BG compact
- Historical: PR #566 — snapshot blindly applies stale config
- Historical: PR #610 — race between BG snapshot and removing server
- Historical: Issue #646 (OPEN) — concurrent snapshot finalization crash on role change
- Code analysis: `handle_snapshot_sync.cxx:564-601` — non-atomic sequence: compact log → apply snapshot → update config → update commit indices → save state
- Code analysis: `handle_snapshot_sync.cxx:582-597` — snapshot config applied even if older than uncommitted config
- Code analysis: `handle_append_entries.cxx:943-948` — `sm_commit_index_` rollback with error "may indicate data loss"

**Affected code paths**:
- `handle_install_snapshot_req()` (handle_snapshot_sync.cxx:241-320)
- `handle_snapshot_sync_req()` (handle_snapshot_sync.cxx:464-627)
- `snapshot_and_compact()` (handle_commit.cxx:675-905)
- `on_snapshot_completed()` (handle_commit.cxx:844-904)

**Suggested modeling approach**:
- Variables: `receivingSnapshot [Server -> BOOLEAN]`, `lastSnapshotIndex [Server -> Nat]`
- Actions: `InstallSnapshot` (split into receive + apply), `CompactLog`, `Crash` during snapshot
- Key invariant: `sm_commit_index` should never need rollback (if it does, committed entries were lost)

**Priority**: Medium
**Rationale**: 5+ historical bugs. Issue #646 is still open. The non-atomic snapshot application sequence has concrete crash gaps. However, snapshot modeling significantly expands spec scope.

---

### Family 7: Missing Raft Figure 2 Commit Term Check (MEDIUM)

**Mechanism**: The leader's `get_expected_committed_log_idx()` computes the quorum-based commit index without verifying that the log entry at that index has `term == currentTerm`. Raft §5.4.2 requires this check to prevent committing entries from previous terms that could be overwritten.

**Evidence**:
- Code analysis: `handle_append_entries.cxx:1523-1608` — purely quorum-based commit index calculation, no term check
- Code analysis: `handle_commit.cxx:270-278` — `commit_in_bg_exec` does not check log term before applying
- Implicit mitigation: `become_leader()` at `raft_server.cxx:1173-1195` appends a config entry in the current term, which acts as a barrier (entries from previous terms are only committed after this entry is committed)

**Affected code paths**:
- `get_expected_committed_log_idx()` (handle_append_entries.cxx:1523-1608)
- `commit_in_bg_exec()` (handle_commit.cxx:229-319)

**Suggested modeling approach**:
- Include the config-entry-on-become-leader as part of the `BecomeLeader` action
- Invariant: `LeaderCompleteness` — committed entries appear in all future leaders' logs
- Test: remove the config entry append and verify LeaderCompleteness violation

**Priority**: Medium
**Rationale**: The implicit mitigation (config entry on become_leader) should make this safe, but it is not the standard Raft mechanism. TLA+ can verify whether this mitigation is sufficient.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Log replication with precommit index | Family 1: 3 critical bugs from precommit/commit ordering | Separate `precommitIndex` and `commitIndex`; interleave client request and Raft protocol threads |
| Non-atomic term/vote persistence | Family 2: concrete crash window for double-vote | Split `PersistVote` into two steps + `Crash` action recovering from persisted state |
| Config change with `config_changing_` guard | Family 3: 16+ historical bugs, priority bypass finding | Track `configChanging` flag; model `AddServer`, `RemoveServer`, `SetPriority` with guard checks |
| Auto-quorum adjustment for 2-node clusters | Family 4: documented split-brain risk | `AdjustQuorum` action on peer timeout; 2-node partition scenario |
| Stale response handling | Family 5: missing term/role checks in response handlers | Allow delayed/reordered message delivery; check safety under stale responses |
| Config entry on become_leader | Family 7: implicit mitigation for Raft §5.4.2 | Model `BecomeLeader` appending config entry; verify without it |
| Crash and recovery | Families 2, 3, 6 | `Crash` action resetting volatile state; recover from persisted term/vote/log |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Snapshot transfer | Significantly expands spec scope. Family 6 bugs are mostly race conditions better verified via TSAN or integration tests. |
| Streaming replication | Performance optimization, not protocol safety. Bugs (#532, #568) are networking-level issues. |
| Full consensus mode | Complex peer-exclusion logic with timing dependencies. Better verified via targeted tests. |
| Priority-based election | Extensions beyond Raft paper. Priority check consistency is a code-review finding (Family 3). |
| ASIO networking layer | Transport-level concerns (data races in asio_service.cxx). Not protocol logic. |
| Dual-mutex locking details | Implementation-specific concurrency. Model as non-deterministic interleaving instead. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Precommit tracking | `precommitIndex` | Capture precommit/commit ordering constraint | Family 1 |
| Non-atomic persistence | `persistedTerm`, `persistedVotedFor` | Model crash window between in-memory and disk state | Family 2 |
| Config change guard | `configChanging`, `srvToJoin`, `srvToLeave` | Model one-change-at-a-time constraint and bypass paths | Family 3 |
| Quorum adjustment | `customQuorumSize`, `autoAdjusted` | Model quorum reduction in 2-node clusters | Family 4 |
| Message delay | (action parameter) | Allow responses from previous terms to arrive late | Family 5 |
| Leader config entry | (part of BecomeLeader) | Model implicit Raft §5.4.2 mitigation | Family 7 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Same term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard, Family 7 |
| VoteUniqueness | Safety | Each server votes for at most one candidate per term | Family 2 |
| PrecommitOrdering | Safety | `sm_commit_index <= precommit_index <= log length` | Family 1 |
| NoSplitBrainCommit | Safety | No two servers commit different values at same index | Family 4 |
| ConfigChangeAtomicity | Safety | At most one uncommitted config change at a time | Family 3 |
| NoStaleResponseCommit | Safety | Committed index only advances from responses with current term | Family 5 |
| CrashRecoveryConsistency | Safety | After crash, persisted term >= persisted votedFor's term | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Auto-quorum to 1: both nodes in 2-node cluster independently lower quorum during partition | NoSplitBrainCommit | 4 |
| MC-2 | Crash between inc_term and save_state allows double-vote on recovery | VoteUniqueness | 2 |
| MC-3 | Stale AE response from lower term updates matched_idx, advances commit | NoStaleResponseCommit | 5 |
| MC-4 | Late vote response after node demoted to follower triggers become_leader | ElectionSafety | 5 |
| MC-5 | Priority change bypasses config_changing_ guard, two concurrent config changes | ConfigChangeAtomicity | 3 |
| MC-6 | Remove config-entry-on-become-leader, verify Leader Completeness violation | LeaderCompleteness | 7 |
| MC-7 | voted_for reset on join request allows double-vote in same term | VoteUniqueness | 3 |
| MC-8 | Precommit index not rolled back after log conflict, blocks follower commit progress | PrecommitOrdering (liveness) | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | TSAN race in `reconfigure()` (issues #493, #644) | Thread sanitizer test with concurrent config commit and peer operations |
| TV-2 | Concurrent snapshot finalization crash on role change (issue #646) | Integration test with overlapping snapshot install and leader election |
| TV-3 | `set_user_ctx()` on follower creates divergent config (no leadership check) | Unit test calling set_user_ctx on non-leader node |
| TV-4 | conf_to_add_ stale reference after join abort | Unit test: initiate join, abort via become_follower, initiate different join |
| TV-5 | srv_to_join_ leak on become_follower (no shutdown/cleanup) | Valgrind/ASAN test with join + leader change |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Pre-vote handler missing log up-to-dateness check (deviation from Ongaro §9.6) | Compare with other Raft implementations; submit PR if confirmed |
| CR-2 | `handle_vote_req` does not reset election timer on same-term vote grant | Low impact; discuss with maintainers |
| CR-3 | Learner can become leader via `request_leadership` (issue #553, OPEN) | File PR adding learner guard in request_leadership |
| CR-4 | `set_priority()` missing `config_changing_` check | File PR adding guard |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/nuraft/analysis-report.md`
- **Key source files**:
  - `artifact/nuraft/src/handle_append_entries.cxx` (1653 lines — log replication, commit calculation)
  - `artifact/nuraft/src/raft_server.cxx` (2097 lines — state machine, transitions, persistence)
  - `artifact/nuraft/src/handle_vote.cxx` (562 lines — elections, pre-vote)
  - `artifact/nuraft/src/handle_commit.cxx` (1213 lines — commit loop, snapshot, reconfigure)
  - `artifact/nuraft/src/handle_join_leave.cxx` (710 lines — membership changes)
  - `artifact/nuraft/src/handle_snapshot_sync.cxx` (642 lines — snapshot transfer)
  - `artifact/nuraft/src/handle_client_request.cxx` (377 lines — client request handling)
  - `artifact/nuraft/src/handle_timeout.cxx` (372 lines — election/heartbeat timers)
- **GitHub issues**: #151 (split-brain risk), #185 (committed rollback), #293/#294 (term race), #493/#644 (TSAN), #553 (learner becomes leader), #646 (snapshot crash)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Ongaro thesis §9.6 (Pre-Vote)
