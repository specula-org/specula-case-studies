# Analysis Report: ebay/nuraft

## Executive Summary

NuRaft is a C++ Raft consensus library (~14K LOC) used by ClickHouse, eBay, and Memgraph. This analysis covered 78 bug-fix commits, 50+ deeply-read GitHub issues, and systematic file-by-file deep code analysis of all 8 core source files.

**Key findings**: 7 Bug Families identified, 8 model-checkable findings, 5 test-verifiable findings, 4 code-review-only findings. The most critical areas are precommit/commit ordering, configuration change safety, and quorum calculation edge cases.

---

## 1. Coverage Statistics

### Git History
- **Total commits in repo**: ~407
- **Bug-fix commits touching core files**: 78 confirmed
- **Keywords searched**: fix (104 hits), bug (31), hang (30), race (23), correct (15), issue (15), missing (8), stale (7), overflow (6), edge case (6), wrong (5), crash (4), segfault (3), leak (2), revert (2), deadlock (1)

### GitHub Issues & PRs
- **Total issues scanned**: ~130
- **Issues deeply read (full discussion)**: ~50
- **Confirmed bugs**: ~29
- **Design defects/limitations**: ~8
- **Disputed/user error**: ~3
- **Open bugs**: #553 (learner becomes leader), #493/#644 (TSAN race in reconfigure), #646 (snapshot crash)

### Deep Analysis
- **Files analyzed**: 8 core source files (handle_vote.cxx, handle_append_entries.cxx, handle_commit.cxx, handle_join_leave.cxx, handle_snapshot_sync.cxx, raft_server.cxx, handle_client_request.cxx, handle_timeout.cxx)
- **Subagents used**: 6 parallel deep analysis agents
- **Total findings**: 80+ individual findings, grouped into 7 Bug Families

---

## 2. Codebase Structure

### Core Files (by LOC, descending)

| File | LOC | Component | Bug-Fix Touches |
|------|-----|-----------|----------------|
| asio_service.cxx | 2495 | Network/RPC | 10 |
| raft_server.cxx | 2097 | State machine, transitions | 27 |
| handle_append_entries.cxx | 1653 | Log replication | 29 (highest) |
| handle_commit.cxx | 1213 | Commit loop, snapshot, reconfig | 19 |
| handle_join_leave.cxx | 710 | Membership changes | 14 |
| handle_snapshot_sync.cxx | 642 | Snapshot transfer | 8 |
| handle_vote.cxx | 562 | Elections, pre-vote | 9 |
| handle_client_request.cxx | 377 | Client requests | 9 |
| handle_timeout.cxx | 372 | Timer handlers | 7 |

### Concurrency Model

**Locks**:
- `lock_` (recursive_mutex): Main Raft state (role, term, peers, election, replication)
- `cli_lock_` (recursive_mutex): Client request path (log append, precommit)
- `commit_lock_` (mutex): Commit thread serialization
- `config_lock_` (mutex): Cluster config pointer
- `last_snapshot_lock_` (mutex): Snapshot pointer
- `commit_ret_elems_lock_` (mutex): Pending client requests

**Background Threads**:
- `commit_in_bg`: Applies committed log entries to state machine
- `append_entries_in_bg`: Sends AppendEntries to followers
- Per-peer heartbeat timers (via scheduler)

**Key Atomics**: `role_`, `leader_`, `hb_alive_`, `precommit_index_`, `quick_commit_index_`, `sm_commit_index_`, `leader_commit_index_`, `serving_req_`, `write_paused_`, `stopping_`

---

## 3. Historical Bug Classification

### By Component

| Component | Count |
|-----------|-------|
| Log replication / precommit / commit | 19 |
| Configuration change (join/leave) | 16 |
| Election / vote / term | 9 |
| Snapshot | 8 |
| ASIO / networking / RPC | 8 |
| Core / concurrency / lifecycle | 7 |
| Quorum / full consensus | 6 |
| Serialization / overflow | 5 |

### By Root Cause

| Root Cause | Count |
|------------|-------|
| Logic error / missing check | 42 |
| Race condition / data race | 20 |
| Integer overflow / type error | 6 |
| Null pointer / segfault | 4 |
| Memory / resource leak | 4 |
| Deadlock / hang | 3 |
| Off-by-one | 1 |

### By Severity

| Severity | Count |
|----------|-------|
| CRITICAL | 8 |
| HIGH | 20 |
| MEDIUM | 38 |
| LOW | 13 |

### Critical Historical Bugs (Safety-Violating)

1. **PR #54** — Rollback in wrong order corrupts state machine
2. **PR #57** — Commits stale logs awaiting rollback (violates Raft safety)
3. **PR #106** — Memory corruption from concurrent RPC on same client
4. **PR #108** — Precommit/commit order inversion via race
5. **PR #140** — Precommit index reverted by concurrent threads
6. **PR #294** — Log written with wrong term due to race between update_term and handle_cli_req
7. **PR #426** — Deadlock between RPC service and background compaction
8. **PR #554** — Precommit/commit order inversion during membership change

---

## 4. Deep Analysis Findings

### 4.1 handle_vote.cxx (20 findings)

**Key findings**:
- F1: Non-atomic term+votedFor persistence in `initiate_vote` (handle_vote.cxx:241-261). Crash between `inc_term` and `save_state` loses term increment. **Model-checkable, MEDIUM**.
- F4: `handle_vote_req` does not reset election timer on same-term vote grant (handle_vote.cxx:316-388). Deviation from Raft paper. **Model-checkable, LOW-MEDIUM**.
- F10: `handle_vote_resp` missing role check (handle_vote.cxx:390-428). Late vote responses after demotion to follower could trigger `become_leader()`. **Model-checkable, MEDIUM**.
- F16: Auto-adjust quorum to 1 in 2-node cluster (handle_vote.cxx:105-123). Both nodes can independently lower quorum, enabling split-brain. **Model-checkable, HIGH**.
- F19: `handle_prevote_resp` does not check role (handle_vote.cxx:481-558). Stale pre-vote responses can trigger `initiate_vote` after term change. **Model-checkable, LOW-MEDIUM**.

**Historical fixes verified**: PR #106 (busy_flag_ race — FIXED), PR #262 (duplicate save_state — FIXED), PR #294 (update_term race — FIXED).

### 4.2 handle_append_entries.cxx (20 findings)

**Key findings**:
- F1: Missing Raft Figure 2 term check on commit (handle_append_entries.cxx:1523-1608). No `log[N].term == currentTerm` check. Implicit mitigation via config entry on become_leader. **Model-checkable, MEDIUM**.
- F5: Non-atomic rollback of commit indices (handle_append_entries.cxx:937-949). `sm_commit_index_` rollback with error "may indicate data loss". **Model-checkable, HIGH**.
- F9: Stale AE response from lower term not filtered (handle_append_entries.cxx:1169-1508). Can update matched_idx and trigger commit. **Model-checkable, MEDIUM**.
- F11: Leader counts non-durable entries toward quorum in non-parallel mode (handle_append_entries.cxx:1530-1531). Uses `precommit_index_` not `durable_index`. **Model-checkable, MEDIUM**.
- F19: Auto-adjust quorum split-brain in 2-node cluster (handle_append_entries.cxx:195-243). Same mechanism as vote F16. **Model-checkable, HIGH**.

### 4.3 handle_commit.cxx (39 findings)

**Key findings**:
- HC-2: `sm_commit_index_` regression during rollback indicates data loss (handle_commit.cxx:229-278, handle_append_entries.cxx:948). **MEDIUM**.
- HC-5: State machine commit not atomic with sm_commit_index_ update (handle_commit.cxx:270-278). Requires idempotent state machine. **MEDIUM**.
- HC-20/21: `commit()` iterates `peers_` without `lock_` while `reconfigure()` modifies it under `lock_` (handle_commit.cxx:54, 999). **Data race, HIGH**.

**Historical fixes verified**: PR #94 (sm_commit_index wrongly updated — FIXED), PR #140 (precommit order inversion — FIXED), PR #215 (commit callback not invoked — FIXED), PR #278 (memory leak — FIXED), PR #534 (typo — FIXED), PR #592 (infinite loop on SM pause — FIXED).

### 4.4 handle_join_leave.cxx + handle_snapshot_sync.cxx (20 findings)

**Key findings**:
- JL-1: Priority change bypasses `config_changing_` guard (handle_priority.cxx:39-107). **NEW FINDING, HIGH**.
- JL-5: Single-node cluster accepts join from any source (handle_join_leave.cxx:155-213). **HIGH**.
- JL-6: Non-atomic commit index reset + config save on join (handle_join_leave.cxx:259-286). Crash gap. **HIGH**.
- JL-12: Non-atomic log compaction + snapshot application (handle_snapshot_sync.cxx:564-601). Crash gap. **HIGH**.
- JL-20: `voted_for` reset to -1 on join, violates vote uniqueness per term (handle_join_leave.cxx:270). **MEDIUM**.

### 4.5 raft_server.cxx (20 findings)

**Key findings**:
- RS-1.4: `precommit_index_` not reset in `become_follower()`. After log rollback, stale high value could block follower commit progress. **MEDIUM**.
- RS-2.4: `set_user_ctx()` missing leadership check. Follower could create divergent config. **MEDIUM**.
- RS-9.3: `get_quorum_for_commit()` doesn't check `is_regular_member()` before decrementing for snapshot receivers. **LOW**.

### 4.6 handle_client_request.cxx + handle_timeout.cxx (14 findings)

**Key findings**:
- CR-1.1: In async replication mode, client gets success before replication. If leader crashes, entry is silently lost. Design trade-off. **MEDIUM**.
- CR-6.2: In dual-mutex mode, `request_prevote()` changes role to candidate without holding `cli_lock_`. However, guarded by `role_ == leader` check in election timeout handler. **False alarm after deeper analysis**.

**Historical fixes verified**: PR #526 (handle_cli_req bug — FIXED), PR #554 (precommit race with cluster change — FIXED).

---

## 5. Bug Family Details

### Family 1: Precommit/Commit Order Inversion

**Historical bug density**: 3 CRITICAL bugs (PR #108, #140, #554)
**Current status**: Fixed via CAS-based `try_update_precommit_index()` and `cli_lock_` for config entries
**Remaining risk**: CAS retry bounded at 10 attempts; `N23_precommit_order_inversion` fatal exit still in code as defensive check
**TLA+ suitability**: HIGH — the precommit/commit ordering is a protocol-level property

### Family 2: Non-Atomic Term/Vote Persistence

**Historical bug density**: 1 CRITICAL (PR #294), 1 LOW (PR #262)
**Current status**: PR #294 fixed the race. Crash window between inc_term and save_state remains by design.
**Remaining risk**: Crash during vote initiation could theoretically allow double-vote
**TLA+ suitability**: HIGH — classic crash injection modeling

### Family 3: Configuration Change Races

**Historical bug density**: 16+ commits (most of any component)
**Current status**: Many fixes applied. Priority bypass of `config_changing_` is a NEW finding.
**Remaining risk**: `set_priority()` has no config_changing_ check. `voted_for` reset on join. Multiple lifecycle management issues with `srv_to_join_`, `srv_to_leave_`, `conf_to_add_`.
**TLA+ suitability**: HIGH — config change interaction with election is a known Raft complexity area

### Family 4: Quorum Calculation Edge Cases

**Historical bug density**: 6+ bugs (PRs #121, #437, #488, #564, #602, #606, #612, #647)
**Current status**: Many edge cases fixed. Auto-adjust quorum is a documented risk.
**Remaining risk**: Both nodes in 2-node cluster can independently lower quorum to 1
**TLA+ suitability**: VERY HIGH — split-brain is a quintessential TLA+ verification target

### Family 5: Stale Response / Missing Guards

**Historical bug density**: 1 MEDIUM (PR #116)
**Current status**: `update_term` filters higher-term responses but not lower-term ones
**Remaining risk**: Late vote responses, stale AE responses from previous terms
**TLA+ suitability**: HIGH — message reordering/delay is natural in TLA+

### Family 6: Snapshot + Config/Commit Interaction

**Historical bug density**: 5+ bugs (PRs #373, #426, #566, #610, Issue #646 OPEN)
**Current status**: Several fixes applied. Issue #646 still open.
**Remaining risk**: Non-atomic snapshot application sequence, crash gaps
**TLA+ suitability**: MEDIUM — snapshot significantly expands spec scope

### Family 7: Missing Raft Figure 2 Commit Term Check

**Historical bug density**: 0 (no known bugs from this)
**Current status**: Implicitly mitigated by config entry append on become_leader
**Remaining risk**: If config entry append is removed or fails, safety property could be violated
**TLA+ suitability**: HIGH — simple invariant check, easy to verify

---

## 6. Reference Deviation Analysis (vs. Raft Paper Figure 2)

| Raft Paper Rule | NuRaft Implementation | Status |
|----------------|----------------------|--------|
| Persistent state: term + votedFor atomic | Non-atomic: separate set_term/set_voted_for, single save_state | **Deviation** — crash gap exists |
| RequestVote: reset election timer on grant | Not reset on same-term re-grant | **Minor deviation** |
| AppendEntries: reject if term < currentTerm | Handled in `process_req` via `update_term` before dispatch | **Correct** |
| AppendEntries: prevLogIndex/prevLogTerm check | Implemented at handle_append_entries.cxx:783-789 | **Correct** |
| Leader commit: only commit if log[N].term == currentTerm | NOT explicitly checked; implicit via config entry on become_leader | **Deviation** — implicitly safe |
| Pre-Vote (Ongaro §9.6): check log up-to-dateness | NOT checked in handle_prevote_req | **Deviation** — safety maintained by real vote |
| Config change: one at a time | `config_changing_` guard, but bypassed by `set_priority()` | **Partial deviation** |
| Joint consensus | NOT implemented; uses one-at-a-time changes | **Design choice** |

---

## 7. Open Issues Summary

| Issue | Description | Status | Severity |
|-------|-------------|--------|----------|
| #553 | Learner can become leader via request_leadership | OPEN | HIGH |
| #493/#644 | TSAN race in reconfigure() | OPEN | HIGH |
| #646 | Concurrent snapshot finalization crash | OPEN | HIGH |
| #38 | Dynamic quorum size change is unsafe | ACKNOWLEDGED | Design limitation |
| #463 | Leadership yielding not synchronized with uncommitted log | ACKNOWLEDGED | Design limitation |
| #190 | Concurrent save_logical_snp_obj and create_snapshot | ACKNOWLEDGED | Design limitation |
