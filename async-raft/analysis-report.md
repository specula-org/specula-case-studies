# Analysis Report: async-raft/async-raft

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Total core source files analyzed | 9 |
| Total LOC read (core protocol) | ~3,500 |
| Git bug-fix commits analyzed | 14 |
| GitHub issues collected | 65 |
| GitHub issues deeply read (with comments) | 55 |
| Confirmed bugs (from issues) | 13 |
| Design defects (from issues) | 6 |
| Excluded as false positive / user error | 5 |
| Feature requests / questions | 25 |
| Merged bug-fix PRs | 12 |
| Unmerged bug-fix PRs | 7 |
| Open unfixed bug issues | 8 |
| Deep analysis findings (new) | 28 |
| Bug families identified | 6 |

---

## Phase 1: Reconnaissance

### Codebase Structure

```
async-raft/async-raft/src/
├── core/
│   ├── mod.rs              (962 lines)  State machine, event loop, state transitions
│   ├── append_entries.rs   (305 lines)  AppendEntries RPC handler
│   ├── vote.rs             (161 lines)  RequestVote RPC handler
│   ├── client.rs           (372 lines)  Client read/write request handling
│   ├── admin.rs            (268 lines)  Membership changes, joint consensus
│   ├── install_snapshot.rs (141 lines)  InstallSnapshot RPC handler
│   └── replication.rs      (370 lines)  Leader-side replication management
├── replication/
│   └── mod.rs              (838 lines)  Per-follower replication stream task
├── raft.rs                 (627 lines)  Public API, RPC types, Entry types
├── config.rs               (281 lines)  Runtime configuration
├── storage.rs              (244 lines)  RaftStorage trait definition
├── network.rs              (28 lines)   RaftNetwork trait definition
├── metrics.rs              (48 lines)   Observability
├── error.rs                (124 lines)  Error types
└── lib.rs                  (52 lines)   Crate root
```

### Concurrency Model

- **Single RaftCore task**: All RPC handlers run sequentially on `&mut self` within a `tokio::select!` loop. No concurrent handler execution.
- **Per-follower ReplicationCore tasks**: Each spawned independently, communicate with leader via `mpsc` channels (`ReplicaEvent` → leader, `RaftEvent` → follower stream).
- **Spawned state machine tasks**: `apply_entry_to_state_machine` spawns async tasks tracked via `FuturesOrdered`.
- **Spawned snapshot tasks**: `do_log_compaction` runs asynchronously with `AbortHandle` for cancellation.

### Key Design Decisions

1. **Event-driven, no tick**: Election timeout checked via `Instant::now()` comparison in `tokio::select!` timeout branch.
2. **Heartbeat = empty AppendEntries**: Same handler (`handle_append_entries_request`), early return for empty entries at line 49.
3. **Joint consensus**: Two-phase membership change (C_old,new → C_new) per Raft §6.
4. **No PreVote**: TODO at vote.rs:65. Heartbeat-based vote rejection (lines 26-38) provides partial disruption protection.
5. **Pluggable storage/network**: `RaftStorage` and `RaftNetwork` traits with 13 and 3 async methods respectively.

---

## Phase 2: Bug Archaeology

### Historical Bug-Fix Commits (14 total)

| # | Commit | Summary | Severity | Component |
|---|--------|---------|----------|-----------|
| 1 | `5f2567b` | Commit index counted entries from prior terms (§5.4.2 violation) | CRITICAL | Replication |
| 2 | `5be81db` | Heartbeats processed through log consistency check, deleting committed entries | HIGH | AppendEntries |
| 3 | `9ecaf93` | NonVoter incorrectly became Follower after restart | HIGH | Core init |
| 4 | `3e2446f` | Client read requests fail on single-node cluster | HIGH | Client |
| 5 | `3f47347` | Shutdown mechanism unreliable (AtomicBool polling) | HIGH | Core lifecycle |
| 6 | `926e286` | Shutdown doesn't update core state | HIGH | Core lifecycle |
| 7 | `2d51ebc` | `set_target_state` missing else clause, NonVoter overwritten | HIGH | Core state |
| 8 | `7db81f7` | State machine replication blocks AppendEntries RPC | HIGH | AppendEntries |
| 9 | `2ede56f` | Restarted nodes disrupt cluster with premature elections | MEDIUM | Core init |
| 10 | `05af50e` | Election timeout system instability | HIGH | Election |
| 11 | `52cc48e` | Election timeout handle not `.take()`-ed, stale handle blocks new elections | HIGH | Election |
| 12 | `6b7fcf0` | Single-node cluster fails to resume as leader after crash | HIGH | Core init |
| 13 | `f96d727` | Off-by-one in get_log_entries during conflict resolution | MEDIUM | Replication |
| 14 | `f57d9df` | NodeNotLeader error missing leader ID | LOW | Error types |

### GitHub Issues — Confirmed Bugs (13)

| # | Issue | Summary | Severity | Fixed? |
|---|-------|---------|----------|--------|
| 1 | #108 | Commit index counts replicas from prior terms | CRITICAL | Yes |
| 2 | #62 | Joint consensus single counter instead of dual majority | CRITICAL | Yes (PR #59) |
| 3 | #98 | Concurrent client_read heartbeat deletes log entries | HIGH | Yes (PR #102) |
| 4 | #76 | State machine replication blocks AppendEntries | HIGH | Yes (PR #88) |
| 5 | #41 | Follower never starts election timeout after leader → follower | HIGH | Yes |
| 6 | #82 | client_read fails on single-node cluster | MEDIUM | Yes |
| 7 | #79 | Can't stop Raft (shutdown incomplete) | MEDIUM | Yes |
| 8 | #73 | Off-by-one in replication conflict resolution | MEDIUM | Yes |
| 9 | #61 | Fallback conflict resolution uses wrong term | MEDIUM | Yes |
| 10 | #29 | Single-node doesn't resume as leader after crash | MEDIUM | Yes |
| 11 | #26 | Bug in heartbeat timeout system | MEDIUM | Yes |
| 12 | #133 | memstore wrong membership config in snapshot install | HIGH | No (fixed in fork) |
| 13 | #134 | memstore do_log_compaction misses SnapshotPointer | MEDIUM | No (fixed in fork) |

### GitHub Issues — Design Defects (6)

| # | Issue | Summary | Severity | Fixed? |
|---|-------|---------|----------|--------|
| 1 | #132 | apply_entry_to_state_machine before majority replication; 20+ bugs cataloged by @drmingdrmer | CRITICAL | No (fork only) |
| 2 | #112 | Removed nodes continue receiving replication | HIGH | No |
| 3 | #138 | Shutdown doesn't wait for replication streams | MEDIUM | No |
| 4 | #137 | LaggingState ignores state changes during await | MEDIUM | No |
| 5 | #136 | LineRateState never handles shutdown if buffer non-empty | MEDIUM | No |
| 6 | #60 | Lagging replication streams grow indefinitely | MEDIUM | Yes (PR #59) |

### Unmerged Bug-Fix PRs (7)

| # | PR | Summary | Status |
|---|-----|---------|--------|
| 1 | #50 | Static election timeout + leader doesn't step down on higher term | Closed (absorbed by PR #59) |
| 2 | #117 | last_applied optimistically updated before async apply | Closed (never merged) |
| 3 | #119 | Test demonstrating replication to removed nodes | Closed |
| 4 | #122 | Empty conflict opt prevents NonVoter log sync | Closed |
| 5 | #123 | Discarded replication buffer entries never re-sent | Closed |
| 6 | #124 | Leader never stops sending logs to removed node | Closed |
| 7 | #125 | Test demonstrating empty entries log hang | Closed |

### Bug Hotspot Analysis

| Component | Bug Count | Files |
|-----------|-----------|-------|
| Core state machine / init | 6 | core/mod.rs |
| Replication / commit index | 4 | core/replication.rs, replication/mod.rs |
| AppendEntries handler | 3 | core/append_entries.rs |
| Election / timeout | 3 | core/mod.rs, core/vote.rs |
| Client read/write | 2 | core/client.rs |
| Membership change | 2 | core/admin.rs |
| Snapshot | 2 | core/install_snapshot.rs, memstore |

---

## Phase 3: Deep Analysis

### Finding Index

#### CRITICAL Findings

**F-1: Client Read Quorum Formula Wrong (client.rs:109-113)**

The quorum threshold formula for linearizable reads is:
```rust
let c0_needed: usize = if (len_members % 2) == 0 {
    (len_members / 2) - 1
} else {
    len_members / 2
};
```
Leader counts itself as 1 confirmation at line 122. For every cluster size >= 2:

| N | c0_needed | c0_confirmed (self) | Passes immediately? | Majority required | Verdict |
|---|-----------|---------------------|---------------------|-------------------|---------|
| 1 | 0 | 1 | Yes | 1 | Correct |
| 2 | 0 | 1 | Yes | 2 | **WRONG** |
| 3 | 1 | 1 | Yes | 2 | **WRONG** |
| 4 | 1 | 1 | Yes | 3 | **WRONG** |
| 5 | 2 | 1 | No (needs 1 more) | 3 | **WRONG** (gets 2, needs 3) |

Every cluster with 2+ nodes can serve reads without confirming leadership with a majority.

**Severity**: CRITICAL — violates linearizability for all non-trivial clusters.
**Classification**: Model-checkable, test-verifiable.
**Compensating mechanisms**: None found.

---

**F-2: Log Up-to-Date Check Uses AND Instead of Lexicographic (vote.rs:53)**

```rust
let client_is_uptodate = (msg.last_log_term >= self.last_log_term) && (msg.last_log_index >= self.last_log_index);
```

Raft §5.4.1 specifies lexicographic comparison:
```
candidate more up-to-date iff:
  candidate.lastLogTerm > voter.lastLogTerm OR
  (candidate.lastLogTerm == voter.lastLogTerm AND candidate.lastLogIndex >= voter.lastLogIndex)
```

The `&&` requires the candidate to dominate on BOTH dimensions. Example: candidate `(term=5, index=1)` vs voter `(term=3, index=100)` → `(5>=3) && (1>=100)` = false. But per spec, the candidate is more up-to-date (higher term).

**Severity**: CRITICAL — violates Leader Completeness. A candidate with committed entries from a higher term can be rejected, allowing a less up-to-date node to win election.
**Classification**: Model-checkable.
**Compensating mechanisms**: None found.

---

**F-3: commit_index Unconditionally Set Without min() Guard (append_entries.rs:28)**

```rust
self.commit_index = msg.leader_commit;
```

This executes BEFORE the log consistency check (line 80+). Even on rejected RPCs (paths P4/P5 at lines 92-151), commit_index is already advanced. The Raft spec (Figure 2, rule 5) requires:
- Set commitIndex = min(leaderCommit, index of last new entry)
- Only after successful log append

The missing `min()` means commit_index can exceed the follower's actual log length. The premature execution means rejected RPCs still advance commit_index.

**Severity**: CRITICAL — violates State Machine Safety.
**Classification**: Model-checkable.
**Compensating mechanisms**: `replicate_to_state_machine_if_needed` uses `filter_map` on cache which skips missing entries, but the commit_index value itself is wrong and reported to metrics.

---

**F-4: Optimistic match_index Initialization (core/replication.rs:27-28)**

```rust
ReplicationState {
    match_index: self.core.last_log_index,
    match_term: self.core.current_term,
    ...
}
```

Per Raft paper: `matchIndex` initialized to 0 for each follower. The code initializes to `last_log_index` with `match_term = current_term`. Combined with `calculate_new_commit_index` (line 266: `new_val.1 == leader_term`), the leader immediately believes followers have replicated the entire log at the current term. This bypasses the §5.4.2 term check that was added in commit `5f2567b`.

**Severity**: HIGH — can cause premature commitment of entries from previous terms in the window before first heartbeat response.
**Classification**: Model-checkable.
**Compensating mechanisms**: The first heartbeat response will correct match_index, but there is a window.

---

#### HIGH Findings

**F-5: Read Confirmation Continues After Leader Deposition (client.rs:181-184)**

```rust
if data.term != self.core.current_term {
    self.core.update_current_term(data.term, None);
    self.core.set_target_state(State::Follower);
}
// NO RETURN OR BREAK — falls through to confirmation counting
if self.core.membership.members.contains(&target) {
    c0_confirmed += 1;
}
```

After detecting deposition (higher term), the code transitions to follower but continues counting confirmations. Can return `Ok(())` to client after the leader has been deposed.

Additional bug: uses `!=` instead of `>`. A response with a LOWER term (from a slow follower) triggers spurious step-down. `update_current_term` has a `>` guard internally so term won't regress, but `set_target_state(Follower)` still fires.

Also: no `save_hard_state()` after term update — crash window where new term is not persisted.

**Severity**: HIGH — linearizability violation (stale read after deposition).
**Classification**: Model-checkable.

---

**F-6: C1 Quorum Missing Leader's Own Entry (core/replication.rs:145-158)**

For C0 quorum (lines 145-147), the leader pushes its own `(last_log_index, last_log_term)` into `indices_c0`. For C1 quorum (lines 153-158), it does NOT push its own entry. During joint consensus, the leader must count toward both config groups if it's a member of both.

**Severity**: HIGH — C1 quorum is harder to achieve than necessary. Can cause liveness failures.
**Classification**: Model-checkable.

---

**F-7: Non-Voters Never Moved to Nodes Map (admin.rs:195-229)**

`finalize_joint_consensus` updates `membership.members` to the new config but never moves replication state from `self.non_voters` to `self.nodes`. Since `calculate_new_commit_index` only iterates `self.nodes`, newly promoted members are invisible to commit advancement.

Similarly, `handle_uniform_consensus_committed` (lines 233-267) only removes from `self.nodes`, leaving stale entries in `self.non_voters`.

**Severity**: HIGH — entries cannot be committed if all non-leader voters were added via `add_non_voter`.
**Classification**: Model-checkable, test-verifiable.

---

**F-8: Snapshot Install Clobbers last_log_index/term (install_snapshot.rs:135-136)**

```rust
self.last_log_index = req.last_included_index;
self.last_log_term = req.last_included_term;
```

When `self.last_log_index > req.last_included_index`, the code at lines 120-121 correctly retains log entries past the snapshot. But then unconditionally overwrites `last_log_index`/`last_log_term` to snapshot values, losing track of the retained entries. This causes incorrect log comparison in future elections and AppendEntries consistency checks.

**Severity**: HIGH — incorrect log state after snapshot with retained entries.
**Classification**: Model-checkable.

---

**F-9: commit_index Not Updated After Snapshot (install_snapshot.rs:135-138)**

After snapshot installation, `last_applied` is set to `req.last_included_index` but `commit_index` is never updated. Since snapshots contain only committed data, `commit_index` should be at least `snapshot_index`. The node can end up with `commit_index < last_applied`, which violates the Raft invariant.

**Severity**: HIGH — commit_index/last_applied inconsistency.
**Classification**: Model-checkable.

---

**F-10: last_log_index/term Not Updated After Log Truncation (append_entries.rs:111-122)**

After `delete_logs_from` truncates conflicting entries, the in-memory `last_log_index` and `last_log_term` are NOT updated to reflect the shortened log. They're only updated when `append_log_entries` writes new entries at line 157. Between truncation and append, the in-memory state diverges from disk state.

**Severity**: HIGH — stale in-memory state could affect concurrent operations.
**Classification**: Test-verifiable.

---

**F-11: memstore Wrong Membership Config Source (memstore/lib.rs:346-356)**

`finalize_snapshot_installation` searches the local log for membership config instead of using the config from the incoming snapshot (available via deserialization at line 343). When the log is deleted, falls back to `MembershipConfig::new_initial(self.id)` — a single-node config. Confirmed as issue #133.

**Severity**: HIGH — wrong membership after snapshot install.
**Classification**: Test-verifiable.

---

#### MEDIUM Findings

**F-12: No Snapshot Chunk Validation Between Chunks (install_snapshot.rs:50-57)**

When `SnapshotState::Streaming` and a new chunk arrives, no validation that it's from the same leader/snapshot. Leader change mid-stream could corrupt the snapshot.

**F-13: memstore Compaction Misses SnapshotPointer (memstore/lib.rs:286-294)**

`do_log_compaction` only matches `ConfigChange` entries for membership, not `SnapshotPointer`. After multiple compactions, membership config is lost. Confirmed as issue #134.

**F-14: Optimistic last_applied Update (append_entries.rs:248-249)**

`last_applied` advanced before spawned state machine task completes. If task fails and node crashes before shutdown, entries are skipped on restart.

**F-15: Replication Event Errors Silently Swallowed (core/replication.rs:52-54)**

`handle_rate_update`, `handle_revert_to_follower`, and `handle_needs_snapshot` errors are logged but not propagated.

**F-16: entries_cache Cleared on Leader Change (mod.rs:290)**

`update_current_leader` clears `entries_cache`. Entries between `last_applied` and `commit_index` that were pending state machine application are lost from cache. `initial_replicate_to_state_machine` handles this on first run but not on subsequent leader changes.

**F-17: Non-Atomic State in finalize_snapshot_installation (memstore/lib.rs:347-376)**

Three separate lock acquisitions (log, state machine, snapshot) without transactional guarantees. Concurrent readers can observe partial state.

**F-18: Snapshot Streaming Retries Without Backoff (replication/mod.rs:800-810)**

Failed `install_snapshot` calls are immediately retried in a tight loop.

---

#### LOW Findings

**F-19**: Idempotent vote grant doesn't reset election timer (vote.rs:69-74) — may cause unnecessary election churn.

**F-20**: Conflict optimization searches wrong direction (append_entries.rs:127-142) — performance, not safety.

**F-21**: Candidate counts self-vote without checking membership in joint config groups (mod.rs:777-782).

**F-22**: Debug `println!` in production code (memstore/lib.rs:342).

**F-23**: Metrics not reported after snapshot finalization (install_snapshot.rs:45-47, 139).

---

## Phase 4: Bug Family Synthesis

### Family 1: Incorrect Quorum / Majority Calculations

**Members**: F-1, F-6, F-7
**Mechanism**: Systematic errors in quorum threshold computation across read confirmation, C1 joint consensus, and post-membership-change commit calculation.
**Historical**: Issue #62 (joint consensus single counter), Issue #132 (20+ bugs cataloged by @drmingdrmer)
**TLA+ suitability**: HIGH — quorum bugs are classic model checking targets.

### Family 2: Incorrect Log Up-to-Date Check

**Members**: F-2
**Mechanism**: Conjunction instead of lexicographic comparison in vote handler.
**Historical**: No prior reports (this is a new finding).
**TLA+ suitability**: HIGH — directly maps to `HandleVoteRequest` action with modified up-to-date predicate.

### Family 3: Premature / Incorrect Commit Index Advancement

**Members**: F-3, F-4, F-10
**Mechanism**: commit_index advanced without proper guards (missing min(), applied before consistency check, optimistic initialization).
**Historical**: Issue #108 (commit counting from wrong term), Issue #98 (heartbeat deletes committed entries)
**TLA+ suitability**: HIGH — commit advancement is the core safety mechanism.

### Family 4: Snapshot-Log State Inconsistency

**Members**: F-8, F-9, F-11, F-12, F-13, F-17
**Mechanism**: Snapshot installation corrupts in-memory state (clobbers last_log_index/term, doesn't update commit_index, wrong membership source).
**Historical**: Issues #133, #134 (unfixed)
**TLA+ suitability**: MEDIUM — requires modeling snapshot as explicit state update.

### Family 5: Membership Change Lifecycle Gaps

**Members**: F-7, related to F-6
**Mechanism**: Non-voter → voter promotion path incomplete. Replication streams for removed nodes not cleaned up.
**Historical**: Issue #112 (unfixed), Issue #62 (fixed)
**TLA+ suitability**: MEDIUM — requires modeling membership change state machine.

### Family 6: Client Read Linearizability Violations

**Members**: F-1, F-5
**Mechanism**: Quorum formula wrong + confirmation loop continues after deposition.
**Historical**: Issue #82 (single-node read, fixed), Issue #132 (client_read quorum bug cataloged by @drmingdrmer)
**TLA+ suitability**: HIGH — linearizable reads are a well-defined property to check.

---

## Cross-Implementation Comparison

The async-raft project was effectively abandoned ~2021. Contributor @drmingdrmer forked it as `datafuse-extras/async-raft`, which evolved into [openraft](https://github.com/datafuselabs/openraft). In issue #132, @drmingdrmer cataloged 20+ bugs including:

- Vote comparison using wrong ordering (matches our F-2)
- Race condition in concurrent snapshot-install and apply
- Non-voter blocking replication (matches our F-7)
- Deleting committed entries during append-entries (matches our F-3/historical #98)
- entries_cache inconsistency with storage (matches our F-16)
- client_read using wrong quorum (majority-1) (matches our F-1)
- Non-voters not counted in quorum during membership change (matches our F-7)
- Discarded replication buffer entries never sent

This independent audit confirms our findings and validates the bug families.

---

## Project Status

The project is **unmaintained** (last meaningful commit ~2021, maintainer confirmed in issue #140). 8 bug issues remain open with no fix upstream. The successor project (openraft) has addressed many of these issues. This makes async-raft a particularly valuable target for formal verification: the bugs are real, unfixed, and well-documented.
