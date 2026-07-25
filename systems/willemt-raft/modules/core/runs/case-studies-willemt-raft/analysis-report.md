# Analysis Report: willemt/raft

## 1. Codebase Overview

- **System**: willemt/raft — C Raft consensus library
- **Language**: C, ~2,200 LOC core logic (1,435 + 315 + 192 + 269)
- **Protocol**: Raft (Ongaro & Ousterhout, 2014)
- **Architecture**: Callback-based library, single-threaded event loop model
- **Repository**: https://github.com/willemt/raft
- **Maintenance status**: Effectively unmaintained since ~2019. Last merge: Jan 2021 (typo fix).

### Core Files

| File | LOC | Role |
|------|-----|------|
| `src/raft_server.c` | 1,435 | Main Raft logic: state machine, RPC handlers, snapshot, config |
| `src/raft_log.c` | 315 | Log management (circular buffer) |
| `src/raft_node.c` | 192 | Node/peer state tracking |
| `src/raft_server_properties.c` | 269 | Property getters/setters, term/vote persistence |
| `include/raft.h` | 957 | Public API, message types, callback signatures |
| `include/raft_private.h` | 156 | Server state struct |
| `include/raft_log.h` | 60 | Log API |
| `include/raft_types.h` | 28 | Type definitions |

### Concurrency Model

Single-threaded, callback-driven. No internal threads, locks, or async operations. The library is a pure state machine driven by:
- `raft_periodic()` — timer ticks
- `raft_recv_*()` — incoming RPC handlers
- `raft_recv_entry()` — client requests

All I/O (network, persistence) is delegated to user-provided callbacks. This means:
- **Atomicity**: All state mutations within a single `raft_recv_*` or `raft_periodic` call are atomic (no interleaving).
- **Crash windows**: Only exist between callback invocations (e.g., between `persist_term` and `persist_vote`).

---

## 2. Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits in repo | 363 |
| Bug-fix commits analyzed | 78 (21.5%) |
| GitHub issues (all states) | 52 |
| GitHub PRs (all states) | 68 |
| Issues/PRs deeply read with comments | 55+ |
| Confirmed bugs (historical) | 60+ |
| Unfixed bugs (from open PRs/issues) | 12+ |
| Core source files analyzed line-by-line | 4 (all) |
| New findings from code analysis | 30+ |

### Bug Hotspot Analysis

| File | Appearances in bug-fix commits | % |
|------|-------------------------------|---|
| `src/raft_server.c` | 67 | 86% |
| `tests/test_server.c` | 49 | 63% |
| `src/raft_log.c` | 14 | 18% |
| `src/raft_node.c` | 6 | 8% |
| `src/raft_server_properties.c` | 6 | 8% |

---

## 3. Historical Bug Summary by Category

### 3.1 Raft Protocol Safety Violations (16 commits)

| Commit | Summary | Severity |
|--------|---------|----------|
| `97c9183` | Committed entries from previous terms (Figure 8 violation) | CRITICAL |
| `05608a3` | Commit index checked same node repeatedly, not all nodes | CRITICAL |
| `daa93cb` | voted_for cleared on state transition, allowing double-voting | CRITICAL |
| `bdabd1d` | voted_for cleared in AE handler, allowing double-voting | CRITICAL |
| `fe60545` | Node ID 0 treated as "not voted" (sentinel collision) | CRITICAL |
| `b754309` | Stale RequestVote response from old term accepted | CRITICAL |
| `854a06d` | Term and voted_for not persisted atomically | CRITICAL |
| `74f27d8` | last_log_term in RV set to current_term, not log entry's term | CRITICAL |
| `5adcd8b` | last_log_term not set at all in RequestVote message | CRITICAL |
| `cefdd08` | commitIndex not using matchIndex-based tracking | CRITICAL |
| `3e011ae` | Heartbeats deleted uncommitted follower entries | CRITICAL |
| `396f7b7` | Deleting entries at prevLogIdx could delete committed entries | CRITICAL |
| `30e4688` | apply_entry incorrectly advanced commit_idx | CRITICAL |
| `bd54c09` | Non-voting nodes could grant votes | HIGH |
| `ab96a76` | Removed nodes disrupt cluster with future-term RequestVote | HIGH |
| `c4de21e` | Majority calculated with total nodes, not voting nodes | CRITICAL |

### 3.2 State Transition Bugs (10 commits)

| Commit | Summary | Severity |
|--------|---------|----------|
| `eb9b3e0` | Candidate/leader didn't step down on RV with higher term | CRITICAL |
| `760b29f` | Leader didn't step down on AE with same term | HIGH |
| `0baa4b0` | Candidate didn't step down on RV response with higher term | HIGH |
| `271f080` | Candidate didn't become follower on same-term leader AE | HIGH |
| `75b0104` | Rogue leader: AE response missing term check + voted_for issues | CRITICAL |
| `14a4e6a` | current_leader not reset on term change (stale leader hint) | HIGH |
| `51e049f` | Negative timeout_elapsed from candidacy delayed first heartbeat | HIGH |
| `1a30fff` | Non-voting node or lone node started election | HIGH |
| `2b469cb` | Single voting node couldn't become leader | HIGH |
| `e60bd38` | Leader stepped down on any RequestVote, even stale | HIGH |

### 3.3 Log Management Bugs (14 commits)

| Commit | Summary | Severity |
|--------|---------|----------|
| `ef057f6` | Use-after-free in circular buffer capacity expansion | CRITICAL |
| `77fb611` | Matching AE entries unnecessarily truncated | HIGH |
| `e4c4029` | Duplicate entries appended (no dedup) | HIGH |
| `3fc7f32` | Only first entry's term compared, not all | HIGH |
| `d4792de` | current_idx started at 1 instead of 0 | HIGH |
| `661032d` | Multiple AE response handling bugs, wrong next_idx init | CRITICAL |
| `fed506d` | log_pop passed wrong entry to callback | HIGH |
| `b912ff5` | Multiple circular buffer edge cases found by fuzzer | HIGH |
| `9de8af4` | Off-by-one in log_get_from_idx and applylog callback index | HIGH |
| `a1fbc29` | AE response with current_idx=0 silently dropped | HIGH |
| `f297457` | next_idx could go below 1 | HIGH |
| `d855e95` | Wrong entry sent when next_idx=1 | MEDIUM |
| `3e5b1a6` | prev_log_idx set to entry ID instead of actual index | CRITICAL |
| `9c07ad7` | send_appendentries completely broken | CRITICAL |

### 3.4 Snapshot Bugs (from PR #118, all UNFIXED)

| Bug | Summary | Severity |
|-----|---------|----------|
| #118-1 | Compacted AE entries re-appended when prev_log_idx==0 | CRITICAL |
| #118-2 | Empty AE sent when entries should be included | CRITICAL |
| #118-3 | raft_begin_load_snapshot rejects necessary snapshot | HIGH |
| #118-4 | current_term set non-monotonically during snapshot load | CRITICAL |
| #118-5 | AE handling when prev_log_idx is compacted | MEDIUM |
| #118-7 | next_idx decreased to match_idx (unnecessary retransmission) | LOW |
| #118-8 | send_appendentries_all returns early on NEEDS_SNAPSHOT | HIGH |
| #118-9 | raft_get_last_log_term returns 0 for compacted logs → elections blocked | CRITICAL |

---

## 4. New Findings from Deep Analysis

### 4.1 Commit Index Advancement (raft_server.c:352-373)

**Finding**: The leader's commit advancement only checks the single index reported in the AE response (`r->current_idx`), not the highest index with majority support. Per Raft Figure 2, the leader should find the highest N where a majority of `matchIndex[i] >= N` and `log[N].term == currentTerm`.

**Impact**: If AE responses arrive out of order, commit index advances more slowly than it should. A follower's high-match response can be "stale-guarded" at line 343-344 (`r->current_idx <= match_idx`), preventing the commit check from running at all.

**Severity**: HIGH (liveness degradation, not safety)

### 4.2 Vote Re-Grant Denied (raft_server.c:543-545)

**Finding**: `__should_grant_vote` returns 0 (deny) if the server has already voted, even if the vote was for the same candidate. The Raft paper Section 5.2 says: "If votedFor is null **or candidateId**". A TODO at line 543 acknowledges this.

**Impact**: Lost RequestVote responses force unnecessary election timeouts. Liveness degradation in lossy networks.

**Severity**: MEDIUM (liveness only, acknowledged by developer)

### 4.3 raft_begin_load_snapshot Bypasses Persistence (raft_server.c:1383-1384)

**Finding**: `raft_begin_load_snapshot` directly writes `me->current_term = last_included_term` and `me->voted_for = -1` without calling `raft_set_current_term` or `persist_vote`. This bypasses persistence callbacks AND allows the term to decrease (violating monotonicity).

**Impact**: (a) Term can go backward, potentially allowing two leaders in the same term. (b) Vote state not persisted — crash recovery can lead to double voting.

**Severity**: CRITICAL (safety violation, from PR #118 Bug 4)

### 4.4 voting_cfg_change_log_idx Off-by-One (raft_server.c:806)

**Finding**: `raft_append_entry` sets `voting_cfg_change_log_idx = raft_get_current_idx(me_)` BEFORE appending. The correct index is `current_idx + 1`. For the leader path, `raft_recv_entry` at line 776 overwrites with the correct value. For followers (AE handler calling `raft_append_entry`), the off-by-one persists.

**Impact**: The one-voting-change-at-a-time guard may clear prematurely (one entry too early) for followers. Could allow a second config change to be appended before the first is committed.

**Severity**: MEDIUM (config safety)

### 4.5 send_appendentries_all Stops on First Error (raft_server.c:950-952)

**Finding**: If sending to one node returns `RAFT_ERR_NEEDS_SNAPSHOT`, the function aborts without sending to remaining nodes. One lagging node blocks heartbeats to the entire cluster.

**Impact**: Cluster-wide liveness failure. Combined with issue #91 (infinite snapshot loop), this can stall the entire cluster permanently.

**Severity**: HIGH (liveness, confirmed by issue #79 and PR #118 Bug 8)

### 4.6 No No-Op Entry on Leader Election (raft_server.c:157-177)

**Finding**: After winning election, the new leader does not append a no-op entry. Per Raft Section 5.4.2, entries from previous terms can only be committed indirectly (by committing an entry from the current term). Without a no-op, uncommitted entries from prior terms remain uncommitted indefinitely.

**Impact**: Committed entries from prior terms may appear uncommitted to clients. Stale reads possible.

**Severity**: MEDIUM (liveness, confirmed by issue #120)

### 4.7 log_clear_entries Off-by-One (raft_log.c:134)

**Finding**: Loop `for (i = me->base; i <= me->base + me->count; i++)` iterates `count+1` times, calling the `log_clear` callback on an out-of-bounds slot (the slot past the last valid entry).

**Impact**: Callback invoked on garbage data. Could cause user's cleanup code to operate on invalid entry.

**Severity**: MEDIUM

### 4.8 raft_recv_appendentries_response NULL Deref (raft_server.c:346-356)

**Finding**: The assert at line 346 (`assert(r->current_idx <= raft_get_current_idx(me_))`) is compiled out in release builds. If a buggy follower sends `current_idx` exceeding the leader's log, `raft_get_entry_from_idx` at line 355 returns NULL, and line 356 dereferences `ety->term` — a NULL pointer crash.

**Severity**: HIGH (crash, defense-in-depth)

### 4.9 NULL raft_apply_entry for ADD_NODE (raft_server.c:849-857)

**Finding**: When applying a `RAFT_LOGTYPE_ADD_NODE` entry, the code calls `raft_node_set_addition_committed(node, 1)` without checking if `node` is NULL. The `REMOVE_NODE` and `DEMOTE_NODE` cases DO check for NULL. Inconsistent null-safety.

**Severity**: MEDIUM (crash if node removed before entry applied)

### 4.10 Snapshot Begin Not Re-Entry Safe (raft_server.c:1258-1291)

**Finding**: `raft_begin_snapshot` does not check `snapshot_in_progress`. Calling it twice overwrites `saved_snapshot_last_idx/term`, making `raft_cancel_snapshot` unable to restore the original state.

**Severity**: LOW (API misuse, but no guard)

### 4.11 Memory Leak in raft_begin_load_snapshot (raft_server.c:1397-1408)

**Finding**: Deactivated non-self nodes are never freed. `raft_node_set_active(node, 0)` only sets a flag; the node objects are leaked when `num_nodes = 1` at line 1408.

**Severity**: LOW (memory leak, confirmed by PR #98)

---

## 5. Bug Families

### Family 1: Commit Index Safety

**Mechanism**: Incorrect commit index advancement — advancing on minority, from wrong terms, or at wrong speed.

**Evidence**:
- `97c9183`: Committed entries from previous terms (Figure 8 violation)
- `05608a3`: Commit index checked same node repeatedly instead of all
- `cefdd08`: Not using matchIndex for commit tracking
- `30e4688`: apply_entry incorrectly advanced commit_idx
- Issue #120: No no-op entry after leader election
- Code: raft_server.c:352-373 only checks single point, not highest N

**Affected code paths**: `raft_recv_appendentries_response` (L275-383), `raft_apply_entry` (L820-875), `raft_become_leader` (L157-177)

**Assessment**: 6 historical bugs + 2 current issues. The commit logic has been rewritten multiple times and STILL has a suboptimal implementation (single-point check instead of highest-N scan). The missing no-op is confirmed open (#120). HIGH priority for modeling.

### Family 2: Log Consistency Under AppendEntries

**Mechanism**: Incorrect handling of log conflicts, duplicates, and truncation in AppendEntries, especially interacting with snapshots/compaction.

**Evidence**:
- `3e011ae`: Heartbeats deleted uncommitted entries
- `77fb611`: Matching entries unnecessarily truncated
- `e4c4029`: Duplicate entries appended
- `3fc7f32`: Only first entry compared, not all
- `396f7b7`: Committed entries deleted at prevLogIdx
- PR #118 bugs 1,2: Compacted entries re-appended, empty AE with wrong commit
- PR #118 bug 5: prev_log_idx compacted but not handled
- Issue #37: Heartbeat deletes uncommitted logs

**Affected code paths**: `raft_recv_appendentries` (L385-528), `raft_send_appendentries` (L882-938)

**Assessment**: 8 historical bugs + 3 unfixed PR #118 bugs. The AE handler has been the most-fixed code in the repository. The snapshot interaction bugs (PR #118) are CRITICAL and completely unaddressed. HIGH priority for modeling.

### Family 3: Vote Safety

**Mechanism**: Violations of the one-vote-per-term invariant through improper vote clearing, stale response processing, or persistence gaps.

**Evidence**:
- `daa93cb`: voted_for cleared on state transition
- `bdabd1d`: voted_for cleared in AE handler
- `fe60545`: Node ID 0 treated as "not voted"
- `b754309`: Stale RV response from old term accepted
- `854a06d`: Term and vote not persisted atomically
- PR #116: Repeated RequestVote not re-granted (Raft paper deviation)
- Code: raft_server.c:543-545 (TODO: re-grant to same candidate)
- Code: raft_begin_load_snapshot:1383-1384 bypasses persistence

**Affected code paths**: `__should_grant_vote` (L535-574), `raft_recv_requestvote` (L575-645), `raft_recv_requestvote_response` (L655-717), `raft_set_current_term` (properties:85-101), `raft_begin_load_snapshot` (L1359-1417)

**Assessment**: 6 historical bugs + 2 current issues. The persistence bypass in load_snapshot is CRITICAL (can cause two leaders in same term). HIGH priority for modeling.

### Family 4: State Transition / Term Management

**Mechanism**: Missing step-down on higher term, non-monotonic term changes, stale leader hints.

**Evidence**:
- `eb9b3e0`: No stepdown on RV with higher term
- `760b29f`: Leader didn't step down on same-term AE
- `0baa4b0`: Candidate didn't step down on RV response with higher term
- `271f080`: Candidate didn't become follower on leader's AE
- `75b0104`: Rogue leader (multiple missing checks)
- `14a4e6a`: current_leader not reset on term change
- PR #118 bug 4: Non-monotonic term on snapshot load
- PR #118 bug 9: last_log_term=0 after compaction blocks elections

**Affected code paths**: All `raft_recv_*` handlers, `raft_become_*` functions, `raft_begin_load_snapshot`

**Assessment**: 8 historical bugs + 2 unfixed. Most historical bugs have been fixed, but the snapshot-related ones (PR #118) remain. MEDIUM priority — most are fixed, but the pattern shows this area is error-prone.

### Family 5: Snapshot/Compaction Interactions

**Mechanism**: Snapshot operations interact incorrectly with log, term, AE sending, and commit index management.

**Evidence**:
- PR #118: 9 bugs, mostly snapshot-related (5 CRITICAL)
- `eaa9e5c`: Copy-paste bug in snapshot validation
- Issue #91: Infinite snapshot send loop
- Issue #102: Infinite AE rejection loop after data loss
- PR #84: commit_idx changes during snapshot (unfixed)
- Code: send_appendentries_all stops on NEEDS_SNAPSHOT (L950-952)
- Code: begin_load_snapshot memory leak (L1397-1408)
- Code: begin_snapshot not re-entry safe (no snapshot_in_progress check)

**Affected code paths**: `raft_begin_snapshot` (L1258-1291), `raft_end_snapshot` (L1308-1357), `raft_begin_load_snapshot` (L1359-1417), `raft_send_appendentries` (L882-938), `raft_send_appendentries_all` (L939-957)

**Assessment**: 9 unfixed PR #118 bugs + 4 historical + 3 open issues. The snapshot subsystem is the MOST BUG-DENSE component. Many bugs have never been fixed because PR #118 was completely ignored. HIGH priority for modeling.

### Family 6: Configuration Change Races

**Mechanism**: Membership changes interact incorrectly with voting, node tracking, and log management.

**Evidence**:
- `c4de21e`: Majority calculated using total nodes, not voting nodes
- `bd54c09`: Non-voting nodes could grant votes
- `218ca95`: voting_cfg_change_log_idx not reset on log delete
- Issue #119: Remove/add same node causes use-after-free
- PR #117: Removed node never commits own removal
- PR #66: Nodes not promoted to voting (off-by-one)
- PR #121: voting_cfg_change_log_idx set before append succeeds
- Code: raft_server.c:806 off-by-one in voting_cfg_change_log_idx for followers

**Affected code paths**: `raft_add_node` (L958-1001), `raft_remove_node` (L1021-1044), `raft_apply_entry` (L820-875), `raft_recv_entry` (L718-779)

**Assessment**: 3 historical bugs + 5 unfixed issues. The one-change-at-a-time guard has a confirmed off-by-one on the follower path. Multiple open issues with no maintainer response. MEDIUM priority for modeling.

---

## 6. Developer Signals

| Location | Type | Text |
|----------|------|------|
| raft_server.c:543 | TODO | `if voted for is candidate return 1 (if below checks pass)` |
| raft_server.c:558 | TODO | `add test` (snapshot fallback path untested) |
| raft_server.c:774 | FIXME | `is this required if raft_append_entry does this too?` |

---

## 7. Notable Open Issues/PRs (Unfixed)

| Issue/PR | Summary | Severity | Open Since |
|----------|---------|----------|------------|
| PR #118 | 9 snapshot bugs (comprehensive, with test cases) | CRITICAL | Aug 2021 |
| #91 | Infinite snapshot send loop | HIGH | 2018 |
| #102 | Infinite AE rejection after data loss | HIGH | 2019 |
| #119 | Remove/add same node UAF | HIGH | 2021 |
| #120 | No no-op entry after leader election | MEDIUM | 2021 |
| PR #66 | Node promotion failure | HIGH | May 2018 |
| PR #84 | End snapshot commit_idx assumption | MEDIUM | 2018 |
| PR #117 | Removed node never commits own removal | MEDIUM | 2021 |
| PR #116 | Repeated RequestVote not re-granted | MEDIUM | 2020 |
| PR #121 | voting_cfg_change_log_idx set before append | MEDIUM | 2024 |
| #78 | No PreVote support | MEDIUM | 2018 |
| #95 | log_get_from_idx doesn't include wrapped entries | MEDIUM | 2018 |
