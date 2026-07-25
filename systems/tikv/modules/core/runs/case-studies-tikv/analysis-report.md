# Analysis Report: tikv/raft-rs + tikv/raftstore

## Coverage Statistics

| Metric | Count |
|--------|-------|
| **raft-rs git commits analyzed** | 70 unique (22 significant bug fixes) |
| **tikv raftstore git commits analyzed** | 273 unique (60 significant bug fixes) |
| **raft-rs GitHub issues deeply read** | 38 |
| **tikv GitHub issues deeply read** | 35 |
| **Total confirmed bugs** | 18 (raft-rs) + 48 (tikv) = 66 |
| **Excluded as false positive/user error** | 20 (raft-rs) + 0 explicitly |
| **Core files read in full** | 11 files, ~40,000 LOC |
| **Bug families identified** | 5 |

---

## 1. Codebase Structure

### raft-rs Core Library (~8800 LOC)

| File | LOC | Purpose |
|------|-----|---------|
| `src/raft.rs` | 2966 | Core Raft state machine: election, replication, commit |
| `src/raft_log.rs` | 1904 | Log management: append, truncate, commit, persist tracking |
| `src/raw_node.rs` | 840 | Ready/LightReady interface for application |
| `src/storage.rs` | 812 | Storage trait + MemStorage reference impl |
| `src/log_unstable.rs` | 482 | In-memory unstable entries/snapshot buffer |
| `src/config.rs` | 218 | Configuration validation |
| `src/read_only.rs` | 136 | ReadIndex/LeaseBased read-only request handling |
| `src/tracker/progress.rs` | ~250 | Per-peer replication progress tracking |
| `src/tracker/inflights.rs` | ~160 | In-flight message ring buffer |
| `src/confchange/changer.rs` | ~350 | Joint consensus conf change logic |
| `src/quorum/majority.rs` | ~260 | Majority quorum calculation |
| `src/quorum/joint.rs` | ~90 | Joint quorum (incoming + outgoing) |

### raftstore Integration Layer (~28500 LOC)

| File | LOC | Purpose |
|------|-----|---------|
| `store/peer.rs` | 7003 | Peer wrapper: proposals, lease, read, snapshot lifecycle |
| `store/fsm/peer.rs` | 7935 | FSM message handler: raft messages, ticks, ready processing |
| `store/fsm/apply.rs` | 8232 | Apply thread: entry application, conf change, split/merge |
| `store/peer_storage.rs` | 2446 | HardState/log persistence, snapshot application |
| `store/util.rs` | 2906 | Lease impl, conf change validation, region helpers |

### Concurrency Model

- **Per-region FSM**: Single-threaded event loop (batch-system poller)
- **Async write worker**: Persists entries/HardState to Raft engine
- **Apply thread**: Processes committed entries, writes to KV engine
- **Local reader thread**: Serves reads via `RemoteLease` (atomic shared state)
- **Background workers**: Snapshot gen, GC, PD heartbeat, split check

### Key Deviations from Standard Raft

| Deviation | Source | Risk |
|-----------|--------|------|
| PreVote | Raft dissertation §9.6 | 3-way interaction with CheckQuorum + priority |
| Election priority | raft-rs specific | Liveness concerns, blocks transfer votes |
| CheckQuorum (leader lease) | etcd-derived | Lease protection can mask dead leaders |
| Commit fast-forward via vote msgs | raft-rs specific | Non-standard commit path |
| Async persistence (leader sends before persist) | Raft thesis §10.2.1 | Novel safety argument needed |
| `max_apply_unpersisted_log_limit` | raft-rs specific | Applied > persisted on leaders |
| Group commit (cross-DC) | TiKV specific | Liveness with group_id=0 nodes |
| Joint consensus with auto-leave | Ongaro + extension | Liveness if leader steps down mid-apply |

---

## 2. Bug Archaeology: raft-rs

### 2.1 Critical Bugs (6)

**`3012d3c` — Deadlock during prevote migration**
- Rolling upgrade from non-prevote to prevote. Node with prevote silently drops `MsgRequestPreVote` from lower-term peers.
- Root cause: Missing rejection message for PreVote with lower term.
- Component: Election (PreVote)

**`37ad3a1` — PreVote + CheckQuorum interaction**
- Partitioned node as PreCandidate retains stale `leader_id`. After partition heals and leader crashes, surviving nodes reject valid PreVote due to lease protection.
- Root cause: `become_pre_candidate()` did not reset `leader_id`.
- Component: Election (PreVote + CheckQuorum)

**`d7d36bf` — PreVote response wrong term**
- PreVote responses used local term instead of message term, causing campaigning node to ignore them.
- Root cause: Vote responses didn't set term field correctly.
- Component: Election (PreVote)

**`8c95a3f` — ReadIndex before leader commits own-term entry**
- New leader serves ReadIndex immediately without committing an entry in its own term.
- Root cause: Missing check that leader's committed index has current-term entry.
- Component: Read-only (ReadIndex)

**`2f5d963` — Ready.must_sync missing entries**
- `must_sync` only checked HardState changes, not new entries. Application could skip fsync.
- Root cause: Missing `!rd.entries.is_empty()` check.
- Component: Persistence — **DATA LOSS risk**

**`9f7fd78` — Off-by-one in conflict check**
- `conflict_idx < self.committed` should be `conflict_idx <= self.committed`. Allowed overwriting committed entries.
- Root cause: Off-by-one error.
- Component: Log Replication — **SAFETY violation**

### 2.2 High Bugs (9)

| Commit | Summary | Component |
|--------|---------|-----------|
| `e6784ab` | ReadIndex requests silently dropped (Option vs Vec) | ReadIndex |
| `7e7322b` | Persisted index bug with sequential snapshots | Snapshot + Async |
| `2ebbed5` | Initialized storage term incorrect | Snapshot + Storage |
| `24280e8` | Learner check wrong node in transfer leader | Leader Transfer |
| `b36756b` | Inverted condition in RawNode::step (! missing) | Message Routing |
| `0465147` | Wrong slice: variable shadowing drops stored entries | Log Retrieval |
| `c7c230f` | Vote messages carry commit info for conf change discovery | Election + ConfChange |
| `2672ac5` | Missing pending conf change check before transfer campaign | Transfer + ConfChange |
| `fc1ef2f` | Snapshot term from hard_state instead of entry term | Snapshot + Storage |

### 2.3 Medium Bugs (7)

| Commit | Summary | Component |
|--------|---------|-----------|
| `0e6fe65` | Leader doesn't respond to learner ReadIndex in single-voter | ReadIndex |
| `326716a` | Panic in remove_node with learners | ConfChange |
| `782a009` | Panic removing all nodes | ConfChange |
| `e6d28ef` | Panic setting max_inflight_msgs to 0 | Flow Control |
| `2a3d7b6` | Panic on async callback after node removal | Async + ConfChange |
| `a76fb6e` | Applied upper bound panic on dynamic limit change | Log Application |
| `68dc65c` | Missing continue in check_quorum_active | CheckQuorum |

### 2.4 Open Issues

| # | Title | Severity | Status |
|---|-------|----------|--------|
| #234 | Transfer leader not safe for lease read | HIGH | OPEN (2020) |
| #511 | PreVote + priority: term=0 panic | MEDIUM | OPEN |
| #426 | progress.committed_index inaccurate | LOW | OPEN |
| #192 | Joint consensus can get stuck | DESIGN | CLOSED (acknowledged limitation) |

---

## 3. Bug Archaeology: tikv/raftstore

### 3.1 By Category

| Category | Count | Critical | High |
|----------|-------|----------|------|
| Leader Lease / Election Safety | 5 | 1 | 3 |
| Region Metadata Inconsistency | 5 | 3 | 2 |
| Snapshot Handling | 8 | 0 | 6 |
| Split / Merge Correctness | 10 | 2 | 4 |
| Peer Destroy / Lifecycle | 8 | 1 | 6 |
| Commit State / Log Management | 6 | 1 | 2 |
| Read Index / Linearizability | 4 | 0 | 3 |
| Race Conditions | 4 | 0 | 3 |
| Disk Full Handling | 4 | 0 | 2 |
| Miscellaneous | 6 | 0 | 3 |
| **TOTAL** | **60** | **8** | **34** |

### 3.2 Most Critical tikv Bugs

**`fac3d728d` — Two leaders hold lease simultaneously (#15085)**
- Peer grants vote immediately after node start. If timed right, old leader's lease overlaps with new leader's lease.
- Fix: Suppress votes for one election timeout after start.

**`097aa4f89` — Data loss from destroy + snapshot race (#17275)**
- Region worker deletes data from range where snapshot was just applied.
- Fix: REVERTED the original optimization entirely.

**`65548bb3b` / `40b225f70` — Region meta inconsistency during split (#9495, #15423)**
- `on_ready_split_region` adds region to `region_ranges` before checking existence.
- Uninitialized peer destroys metadata of initialized peer.

**tikv #8381 / #9579 — Two same-term leaders from uninitialized hard state**
- TiKV doesn't persist HardState for uninitialized peers. On restart, peer can vote twice in same term.
- #9579 (from split) is STILL OPEN.

**`6383a8534` — DR auto-sync broken by store_id/peer_id mixup (#10818)**
- `assign_commit_groups` called with `store_id` instead of `peer_id`, breaking cross-DC replication mode.

### 3.3 Key tikv GitHub Issues

| # | Title | Status | Category |
|---|-------|--------|----------|
| 8381 | Two same-term leaders (uninitialized peer) | Closed | Election Safety |
| 9579 | Two same-term leaders (split voter) | **OPEN** | Election Safety |
| 9239 | Stale read index after transfer | Closed | ReadIndex |
| 9549 | Stale read index command | Closed | ReadIndex |
| 18309 | Meta corruption in destroy_peer | **OPEN** | Metadata |
| 16429 | Hibernate region can't re-elect | Closed | Liveness |
| 10595 | 2-replica remove voter = unavailable | **OPEN** | Liveness |
| 18405 | Panic: smaller ready number | **OPEN** | Async Persistence |
| 19421 | Panic: commit_since_index assertion (Jepsen) | **OPEN** | Async Persistence |
| 17258 | TPCC data inconsistency | Closed | Data Consistency |
| 18249 | Bank inconsistency (DR auto-sync) | Closed | Data Consistency |

---

## 4. Deep Analysis Findings

### 4.1 raft.rs Election/Term Analysis

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| 1 | Priority can block CAMPAIGN_TRANSFER votes | 1495 | Model-checkable |
| 3 | Aborted transfer + in-flight MsgTimeoutNow = stale reads | 1129, 1969, 2410 | Model-checkable |
| 4 | commit-by-vote triggers conf change step-down mid-election | 2219-2250 | Model-checkable |
| 5 | Leader removed from config continues operating (TODO) | 2721-2731 | Model-checkable |
| 9 | CheckQuorum + lease-based reads staleness window | 2052, 2176 | Model-checkable |
| 10 | Auto-leave joint consensus misses window on leader change | 984-1004 | Model-checkable |
| 15 | Priority blocks PreVote equally (liveness risk) | 1495 | Model-checkable |

### 4.2 raft.rs/raft_log.rs Replication/Commit Analysis

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| 1.1 | Heartbeat advances commit without term verification | raft.rs:2563, raft_log.rs:299 | Model-checkable |
| 2.1 | Leader sends before persist; pr.matched=persisted is safety mechanism | raw_node.rs:555, raft.rs:1033 | Model-checkable |
| 2.3 | max_apply_unpersisted_log_limit: applied > persisted on leaders | raft_log.rs:44-46, 460-465 | Model-checkable |
| 3.1 | maybe_append truncation decreases persisted | raft_log.rs:283-285 | Model-checkable |
| 4.1 | Group commit liveness with group_id=0 nodes | majority.rs:119-123 | Model-checkable |
| 6.2 | Heartbeat commit_to without term check (relies on pr.matched) | raft.rs:2563, 871 | Model-checkable |

### 4.3 raftstore peer.rs Analysis

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| 1.2 | Lease suspect on MsgTimeoutNow (correct) | 1903-1911 | Verified safe |
| 2.2 | PeerStorage commit_index (not raft-rs committed) for reads | 2020 | Verified correct |
| 6.1 | Lease suspect -> never auto-transitions to Expired | util.rs:488 | Design pattern |
| 6.2 | Split blocks lease renewal but not existing reads | 2536-2573 | Model-checkable |
| 6.3 | Dual lease check (raft-rs in_lease + TiKV Lease) | 6302-6305 | Defense-in-depth |

### 4.4 raftstore fsm/peer.rs Analysis

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| 1 | Messages to pending_remove peers silently dropped | 2849 | Design pattern |
| 2 | No additional raftstore-layer term checks (relies on raft-rs) | 2988 | By design |
| 3 | Persistence failure is fatal (panic) | peer.rs:3042 | By design |
| 4 | Ticks suppressed during snapshot handling (no election timeout) | 2437-2443 | Design pattern |
| 5 | Message drop during check_msg when snapshot is being applied | 3457 | Potential liveness |
| 6 | Async destroy: ReadyToDestroyPeer may arrive for wrong peer_id | 1711-1723 | Race handled |

### 4.5 raftstore apply.rs Analysis

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| 1 | Save-point per-entry rollback for deterministic errors | 1524-1535 | Verified correct |
| 2 | Apply state (KV engine) and HardState (Raft engine) in separate WALs | 1092-1098 | Design documented |
| 3 | Crash window: finish_for reports ahead of write_to_db | 463-469 | Safe via Raft replay |
| 4 | SST deletion after write but before callback: crash = missing SST on replay | 428-440 | Known concern |
| 5 | DeleteRange bypasses WriteBatch save-point | 2030-2058 | Design concern |
| 6 | Debug panic code in production (duplicate lock CF key) | 670-701 | Active debug |

### 4.6 peer_storage.rs + util.rs Analysis

| # | Finding | Lines | Classification |
|---|---------|-------|----------------|
| 1 | Two-phase KV/Raft engine write crash window, correctly recovered | ps:169-183 | Verified safe |
| 2 | RAFT_INIT_LOG_TERM=5 forces snapshot sync for new peers | ps:63-66 | By design |
| 3 | RemoteLease max_drift (max_lease/3) is conservative (safe) | util:527, 557-563 | Verified safe |
| 4 | Lease suspect on transfer, expire_remote_lease immediately | util:569 | Verified correct |
| 5 | Clock drift assumption: election_timeout > max_lease | util:496-498 | Configuration-dependent |
| 6 | check_conf_change quorum safety via promoted_commit_index | util:1100-1126 | Verified correct |

---

## 5. Bug Family Evidence Summary

### Family 1: Leader Lease / ReadIndex Linearizability

| Source | Evidence | Status |
|--------|----------|--------|
| raft-rs #234 | Transfer abort + in-flight MsgTimeoutNow | OPEN |
| raft-rs #140 | Lease without check_quorum | Fixed |
| raft-rs `8c95a3f` | ReadIndex before own-term commit | Fixed |
| raft-rs `e6784ab` | ReadIndex requests dropped | Fixed |
| tikv #9239 | Stale read after transfer | Fixed |
| tikv #9549 | Stale read index | Fixed |
| tikv `fac3d728d` | Two leaders hold lease | Fixed |
| Deep: raft.rs:2176 | Lease-based staleness window | Active |
| Deep: peer.rs:6302 | Dual lease check defense | Active |

### Family 2: Election Safety / PreVote

| Source | Evidence | Status |
|--------|----------|--------|
| raft-rs `3012d3c` | PreVote migration deadlock | Fixed |
| raft-rs `37ad3a1` | PreVote + CheckQuorum interaction | Fixed |
| raft-rs `d7d36bf` | PreVote response wrong term | Fixed |
| raft-rs #511 | PreVote + priority panic | OPEN |
| tikv #8381 | Two same-term leaders (uninit peer) | Fixed |
| tikv #9579 | Two same-term leaders (split) | OPEN |
| tikv `fac3d728d` | Unsafe vote after start | Fixed |
| Deep: raft.rs:1495 | Priority blocks transfer votes | Active |
| Deep: raft.rs:2721 | Removed leader doesn't step down | Active (TODO) |

### Family 3: Configuration Change Safety

| Source | Evidence | Status |
|--------|----------|--------|
| raft-rs #221 | Votes not updated on conf change | Fixed |
| raft-rs `2672ac5` | Missing check before transfer campaign | Fixed |
| raft-rs `c7c230f` | Vote commit fast-forward for conf change | Fixed |
| raft-rs #192 | Joint consensus stuck | Acknowledged |
| tikv #10384 | Leader self-removal | Fixed |
| tikv `a27a28bda` | Lost votes during split | Fixed |
| Deep: raft.rs:984 | Auto-leave liveness | Active (TODO) |
| Deep: raft.rs:2219 | Commit-by-vote conf change step-down | Active |

### Family 4: Async Persistence Model

| Source | Evidence | Status |
|--------|----------|--------|
| raft-rs `2f5d963` | must_sync missing entries | Fixed |
| raft-rs `7e7322b` | Persisted index with snapshots | Fixed |
| raft-rs `a76fb6e` | Applied upper bound panic | Fixed |
| tikv `14622f301` | Limit not reset on demotion | Fixed |
| tikv #18405 | Ready number panic | OPEN |
| tikv #19421 | commit_since_index assertion (Jepsen) | OPEN |
| Deep: raft.rs:1033 | pr.matched=persisted invariant | Active |
| Deep: raft_log.rs:283 | Truncation decreases persisted | Active |

### Family 5: Snapshot + Region Lifecycle

| Source | Evidence | Status |
|--------|----------|--------|
| tikv `097aa4f89` | Data loss (destroy + snapshot race) | Fixed (reverted) |
| tikv 8 snapshot bugs | Various | Mostly fixed |
| tikv 8 lifecycle bugs | Various | Mostly fixed |
| tikv #18309 | Meta corruption in destroy_peer | OPEN |
| tikv 18 panic issues | Various raftstore panics | 6 OPEN |

---

## 6. Modeling Scope Recommendation

### In Scope (Core Raft + Extensions)
1. Standard Raft: election, log replication, commit advancement, leader completeness
2. PreVote: separate PreCandidate state, no term increment, leader_id handling
3. CheckQuorum: periodic quorum check, lease protection on vote rejection
4. Election priority: additional vote guard
5. Leader transfer: MsgTimeoutNow, bypass PreVote, lease suspect
6. Joint consensus: incoming/outgoing configs, auto-leave
7. Commit-by-vote: vote messages carry commit info
8. Async persistence: persisted index, leader sends before persist
9. Leader lease: three-state lease (Valid/Suspect/Expired), ReadIndex
10. Crash and recovery: from persisted state

### Out of Scope (raftstore integration layer)
1. Region split/merge
2. Peer creation/destruction lifecycle
3. Snapshot generation/transfer mechanics
4. Group commit
5. Two-engine crash recovery
6. Batch append optimization
7. Disk full handling
8. Witness/non-voter extensions
