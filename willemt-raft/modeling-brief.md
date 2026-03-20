# Modeling Brief: willemt/raft

## 1. System Overview

- **System**: willemt/raft — C Raft consensus library
- **Language**: C, ~2,200 LOC core logic across 4 source files
- **Protocol**: Raft (Ongaro & Ousterhout, 2014)
- **Key architectural choices**:
  - Callback-based library: all I/O (network, persistence, FSM) delegated to user callbacks
  - Single-threaded event loop: no internal concurrency, all state mutations atomic within a handler call
  - Circular buffer log with compaction support
  - Single-server membership changes (one voting change at a time, tracked by `voting_cfg_change_log_idx`)
  - No PreVote, no pipeline replication, no leader lease, no leadership transfer
  - `persist_term` callback persists term+vote atomically; separate `persist_vote` callback for vote-only changes
- **Concurrency model**: Single-threaded, callback-driven. The only crash windows are between sequential callback invocations within a handler.
- **Maintenance**: Effectively unmaintained since ~2019. PR #118 (9 bugs with tests) has been ignored since Aug 2021.

## 2. Bug Families

### Family 1: Commit Index Advancement Bugs (HIGH)

**Mechanism**: Incorrect commit index advancement — checking single points instead of scanning for highest majority index, committing entries from wrong terms, or advancing commit through side-channel (apply).

**Evidence**:
- Historical: `97c9183` — committed entries from previous terms (Figure 8 violation)
- Historical: `05608a3` — commit index checked same node repeatedly instead of all nodes
- Historical: `cefdd08` — not using matchIndex for commit tracking (pre-paper compliance)
- Historical: `30e4688` — apply_entry incorrectly advanced commit_idx as side effect
- Issue #120 — no no-op entry after leader election (entries from prior terms stuck uncommitted)
- Code analysis: raft_server.c:352-373 — commit advancement only checks the single `r->current_idx` point, not the highest N with majority support per Raft Figure 2

**Affected code paths**:
- `raft_recv_appendentries_response` (raft_server.c:275-383) — leader-side commit logic
- `raft_become_leader` (raft_server.c:157-177) — no no-op entry appended
- `raft_recv_appendentries` (raft_server.c:516-520) — follower commit via leaderCommit

**Suggested modeling approach**:
- Variables: `matchIndex [Server -> Index]`, `commitIndex [Server -> Index]`
- Actions: Model `AdvanceCommitIndex` as a separate action that scans for highest N (paper-correct), AND model the implementation's single-point-check variant. Check whether the single-point check can cause a safety violation (committed entry not on future leader) or only liveness degradation.
- Extension: Add `AppendNoOp` action triggered on `BecomeLeader`. Check whether omitting it can delay commit indefinitely.

**Priority**: High
**Rationale**: 6 historical bugs in this mechanism. The current single-point-check is a deviation from the paper that could interact with out-of-order responses to miss commit opportunities. The missing no-op is a confirmed open issue.

---

### Family 2: Log Consistency Under AppendEntries (HIGH)

**Mechanism**: Incorrect log conflict resolution, duplicate handling, and truncation in AppendEntries — especially when interacting with snapshots/log compaction.

**Evidence**:
- Historical: `3e011ae` — heartbeats (empty AE) deleted uncommitted follower entries
- Historical: `77fb611` — matching entries unnecessarily truncated on heartbeat
- Historical: `396f7b7` — deleting at prevLogIdx could delete committed entries
- Historical: `e4c4029` — duplicate entries appended without dedup
- Historical: `3fc7f32` — only first entry's term compared, not per-entry
- PR #118 Bug 1 — compacted AE entries re-appended when prev_log_idx==0 (UNFIXED)
- PR #118 Bug 2 — empty AE sent when entries exist, causing committed log rollback (UNFIXED)
- Issue #37 — heartbeat RPC deletes uncommitted logs (FIXED, root cause of `3e011ae`)

**Affected code paths**:
- `raft_recv_appendentries` (raft_server.c:385-528) — follower AE handler
- `raft_send_appendentries` (raft_server.c:882-938) — leader AE construction
- `raft_send_appendentries_all` (raft_server.c:939-957) — leader AE broadcast

**Suggested modeling approach**:
- Variables: `log [Server -> Seq(Entry)]`, `snapshotLastIdx [Server -> Index]`, `snapshotLastTerm [Server -> Term]`
- Actions: Model `HandleAppendEntries` with per-entry conflict check and truncation. Model `SendAppendEntries` with snapshot boundary logic. Model empty AEs (heartbeats) as a separate action to test the heartbeat-deletes-entries bug pattern.
- Granularity: The AE handler should be a single atomic action (matching the implementation's single-threaded model). But `SendAppendEntries` should model the snapshot boundary edge case (next_idx near snapshot_last_idx).
- Error injection: Model `LoseMessage` and `DuplicateMessage` to trigger the retransmission/dedup paths.

**Priority**: High
**Rationale**: 8 historical bugs + 3 unfixed PR #118 bugs. The AE handler is the most-fixed function in the codebase. The snapshot interaction bugs are CRITICAL and unaddressed. TLA+ is ideal for exploring message ordering and snapshot boundary edge cases.

---

### Family 3: Vote Safety Violations (HIGH)

**Mechanism**: Violations of the one-vote-per-term invariant through improper vote clearing, stale response acceptance, sentinel collisions, or persistence bypass.

**Evidence**:
- Historical: `daa93cb` — voted_for cleared on becoming leader + follower transition
- Historical: `bdabd1d` — voted_for cleared when candidate received same-term AE
- Historical: `fe60545` — node ID 0 treated as "not voted" (sentinel value collision)
- Historical: `b754309` — stale RV response from old term accepted, corrupting vote count
- Historical: `854a06d` — term and vote not persisted atomically (fixed: persist_term now takes both)
- Code analysis: raft_server.c:1383-1384 — `raft_begin_load_snapshot` directly writes `current_term` and `voted_for` WITHOUT calling persist callbacks, allowing term to decrease (UNFIXED, PR #118 Bug 4)
- Code analysis: raft_server.c:543-545 — `__should_grant_vote` denies re-vote to same candidate (TODO acknowledges deviation from Raft paper Section 5.2)
- PR #116 — repeated RequestVote not re-granted (closed without merge)

**Affected code paths**:
- `__should_grant_vote` (raft_server.c:535-574) — vote granting logic
- `raft_recv_requestvote` (raft_server.c:575-645) — RV handler
- `raft_recv_requestvote_response` (raft_server.c:655-717) — RV response handler
- `raft_set_current_term` (raft_server_properties.c:85-101) — term+vote persistence
- `raft_begin_load_snapshot` (raft_server.c:1359-1417) — snapshot loading

**Suggested modeling approach**:
- Variables: `currentTerm [Server -> Term]`, `votedFor [Server -> Server ∪ {Nil}]`, `persistedTerm`, `persistedVotedFor`
- Actions: Split `HandleRequestVote` into: (1) term update + persist, (2) vote grant + persist. Model `Crash` recovering from persisted (not volatile) state. Model `LoadSnapshot` with the current buggy behavior (direct term/vote write, no persistence).
- Key invariant: `ElectionSafety` — at most one leader per term. The snapshot-load persistence bypass should violate this.

**Priority**: High
**Rationale**: 6 historical CRITICAL bugs + 2 current unfixed issues. The persistence bypass in `load_snapshot` is a confirmed safety violation. The vote re-grant denial is a known paper deviation. TLA+ with crash modeling is the perfect tool.

---

### Family 4: Snapshot/Compaction Lifecycle (HIGH)

**Mechanism**: Snapshot operations interact incorrectly with log state, term management, AE sending, and node tracking.

**Evidence**:
- PR #118 Bug 1 — compacted entries re-appended via AE with prev_log_idx==0
- PR #118 Bug 2 — empty AE sent, committed log rolled back
- PR #118 Bug 3 — load_snapshot rejects necessary snapshot (stale check)
- PR #118 Bug 4 — non-monotonic term on snapshot load
- PR #118 Bug 8 — send_appendentries_all returns early on NEEDS_SNAPSHOT, starving other nodes
- PR #118 Bug 9 — last_log_term returns 0 after compaction, blocking all elections
- Issue #91 — leader enters infinite send_snapshot loop (no nextIndex update)
- Issue #102 — follower infinite AE rejection loop after data loss
- PR #84 — commit_idx changes between begin_snapshot and end_snapshot (unfixed)
- Code analysis: raft_server.c:1258 — begin_snapshot not re-entry safe (no snapshot_in_progress check)
- Code analysis: raft_server.c:1397-1408 — memory leak: deactivated nodes never freed in load_snapshot

**Affected code paths**:
- `raft_begin_snapshot` / `raft_end_snapshot` / `raft_cancel_snapshot` (raft_server.c:1258-1357)
- `raft_begin_load_snapshot` / `raft_end_load_snapshot` (raft_server.c:1359-1435)
- `raft_send_appendentries` (raft_server.c:882-938) — snapshot boundary
- `raft_send_appendentries_all` (raft_server.c:939-957) — early abort

**Suggested modeling approach**:
- Variables: `snapshotLastIdx`, `snapshotLastTerm`, `snapshotInProgress` per server
- Actions: `TakeSnapshot` (compacts log), `SendSnapshot` (triggered when follower behind snapshot), `LoadSnapshot` (follower installs snapshot). Model the boundary between "send AE" vs "send snapshot" decision (next_idx vs snapshot_last_idx).
- Key: Model the `send_appendentries_all` early-abort bug to show cluster stall. Model `LoadSnapshot` with buggy term-setting to show election safety violation.

**Priority**: High
**Rationale**: 9 unfixed PR #118 bugs (5 CRITICAL) + 4 historical + 3 open issues. The snapshot subsystem is the most bug-dense component in the codebase. Multiple bugs can only be found through state-space exploration of snapshot-AE-election interleavings.

---

### Family 5: Configuration Change Races (MEDIUM)

**Mechanism**: Membership changes interact incorrectly with voting, commit tracking, and log management. One-change-at-a-time guard has off-by-one; removed nodes get stuck.

**Evidence**:
- Historical: `c4de21e` — majority calculated using total nodes, not voting nodes
- Historical: `bd54c09` — non-voting nodes could grant votes
- Historical: `218ca95` — voting_cfg_change_log_idx not reset on log delete
- Issue #119 — remove/add same node causes use-after-free
- PR #117 — removed node never commits own removal
- PR #66 — nodes not promoted to voting (off-by-one, unfixed since 2018)
- PR #121 — voting_cfg_change_log_idx set before append succeeds
- Code analysis: raft_server.c:806 — off-by-one in voting_cfg_change_log_idx for followers

**Affected code paths**:
- `raft_add_node` / `raft_remove_node` (raft_server.c:958-1044)
- `raft_apply_entry` config cases (raft_server.c:840-875)
- `raft_recv_entry` config check (raft_server.c:725-779)

**Suggested modeling approach**:
- Variables: `votingNodes [Server -> SUBSET Server]`, `cfgChangeInProgress [Server -> BOOLEAN]`
- Actions: Model `AddNode`, `RemoveNode` as config log entries. Track the one-change-at-a-time constraint. Model the off-by-one: allow a second config change to be appended before the first is committed (on followers).
- Key invariant: `ConfigSafety` — at most one uncommitted voting config change at a time.

**Priority**: Medium
**Rationale**: 3 historical bugs + 5 unfixed issues. Config changes expand the state space significantly. Start with a simplified model (fixed cluster) and extend later if time permits.

---

### Family 6: Broadcast Starvation (MEDIUM)

**Mechanism**: `raft_send_appendentries_all` stops on the first error, preventing remaining nodes from receiving heartbeats or entries. One lagging/failing node blocks the entire cluster.

**Evidence**:
- Code analysis: raft_server.c:950-952 — returns immediately on non-zero return
- Issue #79 — send_appendentries_all returns early (confirmed, open)
- PR #118 Bug 8 — NEEDS_SNAPSHOT from one node starves others
- Code analysis: raft_server.c:762 — recv_entry only sends to caught-up nodes

**Affected code paths**:
- `raft_send_appendentries_all` (raft_server.c:939-957)
- `raft_recv_entry` (raft_server.c:748-764)

**Suggested modeling approach**:
- Actions: Model `SendAppendEntriesAll` with the early-abort behavior. Introduce `NeedsSnapshot [Server -> BOOLEAN]` to trigger the error path.
- Key invariant: `Liveness` — eventually all nodes receive heartbeats (violated by this bug).

**Priority**: Medium
**Rationale**: Confirmed unfixed bug. Primarily a liveness issue, but can cascade to safety violations if followers start unnecessary elections.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Standard Raft (election + replication + commit) | Baseline correctness | Standard Raft spec as foundation |
| Single-point commit check | Family 1: implementation deviates from paper | `AdvanceCommitIndex` only checks `r->current_idx`, not scanning for highest N |
| Log conflict resolution in AE handler | Family 2: 8+ historical bugs in this code path | Per-entry conflict check + truncation. Model heartbeats as empty AE. |
| Snapshot/compaction boundary in AE sending | Family 2+4: snapshot-AE interaction bugs | `SendAppendEntries` with next_idx vs snapshot_last_idx decision |
| Vote persistence with crash windows | Family 3: 6 historical vote safety bugs | Split persist into two steps + `Crash` action. Model `LoadSnapshot` bypassing persistence. |
| Snapshot load with term/vote bypass | Family 3+4: PR #118 Bug 4 (non-monotonic term) | `LoadSnapshot` directly sets term (can decrease) and vote (no persist) |
| `send_appendentries_all` early abort | Family 6: one node blocks entire cluster | `BroadcastAE` stops on first `NeedsSnapshot` node |
| Missing no-op on leader election | Family 1: issue #120, entries from prior terms stuck | Leader doesn't append no-op; check liveness of prior-term entries |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Configuration changes (initially) | Family 5: significant state space expansion. Start with fixed cluster. Can be added as extension. |
| Circular buffer internals | Log management bugs (off-by-ones, wrap-around) are implementation-level, not protocol-level. Better verified by fuzzing. |
| Memory management | Use-after-free, leaks, NULL derefs are C-level bugs, not protocol logic. |
| Error handling / callback failures | Too implementation-specific. The callback error propagation bugs are better tested than model-checked. |
| Node connection tracking | The `connected` field is poorly implemented (#50) but doesn't affect protocol safety. |
| Non-blocking snapshot apply | The `RAFT_SNAPSHOT_NONBLOCKING_APPLY` flag is a performance optimization. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Snapshot lifecycle | `snapshotLastIdx`, `snapshotLastTerm`, `snapshotInProgress` per server | Model snapshot take/load and AE boundary interactions | Family 2, 4 |
| Crash + recovery | `persistedTerm`, `persistedVotedFor`, `crashed` per server | Model crash windows between persist operations | Family 3 |
| Snapshot load term bypass | (use existing `currentTerm` with buggy LoadSnapshot action) | Model non-monotonic term assignment | Family 3, 4 |
| Single-point commit check | (behavioral: AdvanceCommitIndex checks one index) | Model implementation's deviation from paper | Family 1 |
| No-op omission | (behavioral: BecomeLeader does not append entry) | Model stalled commit of prior-term entries | Family 1 |
| Broadcast abort | `needsSnapshot` per (leader, peer) pair | Model early-abort in send_all | Family 6 |
| Message duplication | `DuplicateMessage` action | Test vote re-grant denial and AE dedup | Family 2, 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard + Family 3 |
| LogMatching | Safety | If two logs have entry with same index and term, all preceding entries match | Standard + Family 2 |
| LeaderCompleteness | Safety | Committed entry appears in all future leaders' logs | Standard + Family 1, 2 |
| StateMachineSafety | Safety | If a server has applied entry at index i, no other server applies a different entry at i | Standard |
| CommitMonotonicity | Safety | commitIndex never decreases on any server | Family 1 |
| TermMonotonicity | Safety | currentTerm never decreases on any server | Family 3, 4 (violated by LoadSnapshot bug) |
| VoteSafety | Safety | Each server votes for at most one candidate per term (from persisted state) | Family 3 |
| SnapshotConsistency | Safety | After LoadSnapshot, log base matches snapshot metadata | Family 4 |
| NoCommittedEntryDeletion | Safety | No committed entry is ever deleted from any server's log | Family 2 |
| HeartbeatLiveness | Liveness | Every active follower eventually receives an AE from the leader | Family 6 |
| CommitLiveness | Liveness | If a client entry is replicated to a majority, it is eventually committed | Family 1 (no-op) |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Single-point commit check misses higher majority index (out-of-order responses) | CommitLiveness (liveness only, not safety) | 1 |
| MC-2 | Missing no-op after election: prior-term entries stuck uncommitted | CommitLiveness | 1 |
| MC-3 | LoadSnapshot with term decrease → two leaders in same term | ElectionSafety, TermMonotonicity | 3, 4 |
| MC-4 | LoadSnapshot bypasses vote persistence → double voting after crash | VoteSafety, ElectionSafety | 3 |
| MC-5 | Heartbeat (empty AE) at stale prevLogIdx truncates uncommitted entries | NoCommittedEntryDeletion, LogMatching | 2 |
| MC-6 | send_appendentries_all early abort → follower misses heartbeats → unnecessary election | HeartbeatLiveness | 6 |
| MC-7 | Compacted entries re-appended via AE with prev_log_idx==0 | LogMatching | 2, 4 |
| MC-8 | last_log_term returns 0 after full compaction → no leader elected | CommitLiveness | 4 |
| MC-9 | Vote re-grant denial + message loss → unnecessary election timeout | CommitLiveness (liveness degradation) | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | log_clear_entries off-by-one (raft_log.c:134) | Unit test with callback counter; verify count == expected |
| TV-2 | NULL deref in apply_entry for ADD_NODE (raft_server.c:850) | Unit test: apply ADD_NODE entry with unknown node ID |
| TV-3 | raft_recv_appendentries_response NULL deref in release (raft_server.c:355) | Send AE response with current_idx > leader's log length |
| TV-4 | voting_cfg_change_log_idx off-by-one on follower path (raft_server.c:806) | Follower receives voting config change via AE; check index value |
| TV-5 | begin_snapshot re-entry overwrites saved state (raft_server.c:1258) | Call begin_snapshot twice without end/cancel between |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `__log` uses vsprintf without bounds check (raft_server.c:55) | Replace with vsnprintf |
| CR-2 | log_free doesn't invoke log_clear callbacks (raft_log.c:298) | Add log_clear_entries call before free |
| CR-3 | mod() truncates long int to int (raft_log.c:43) | Change return type to raft_index_t |
| CR-4 | raft_send_requestvote logs node pointer as %d (raft_server.c:790) | Use raft_node_get_id(node) |
| CR-5 | PR #118 has 9 bugs with test cases, ignored since 2021 | Merge or address the PR |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/willemt-raft/analysis-report.md`
- **Key source files**:
  - `artifact/raft/src/raft_server.c` (core logic, 1435 lines)
  - `artifact/raft/src/raft_log.c` (log, 315 lines)
  - `artifact/raft/src/raft_server_properties.c` (persistence, 269 lines)
  - `artifact/raft/include/raft.h` (API + types, 957 lines)
  - `artifact/raft/include/raft_private.h` (server state, 156 lines)
- **GitHub issues**: PR #118 (9 snapshot bugs), #91 (snapshot loop), #102 (AE rejection), #119 (UAF), #120 (no-op)
- **Reference algorithm**: Raft (Ongaro & Ousterhout, 2014), particularly Figure 2 and Section 5.4.2
