# Modeling Brief: tikv/raft-rs + tikv/raftstore

## 1. System Overview

- **System**: tikv/raft-rs — Rust Raft consensus library used by TiKV (PingCAP's distributed KV store)
- **Language**: Rust, ~8800 LOC core (raft-rs), ~28500 LOC integration layer (raftstore)
- **Protocol**: Raft (with PreVote, joint consensus, group commit, leadership transfer, async persistence, election priority)
- **Key architectural choices**:
  - **Async persistence model**: Leader sends AppendEntries *before* persisting entries locally; leader's own `pr.matched = persisted` (not `last_index`) — raft.rs:1033, raw_node.rs:555
  - **`max_apply_unpersisted_log_limit`**: Leader can apply committed entries before they are persisted — raft_log.rs:44-46
  - **Leader lease + ReadIndex**: TiKV-layer lease (`Suspect/Valid/Expired`) wraps raft-rs `check_quorum` — util.rs:461-509
  - **Two storage engines**: HardState in Raft engine, apply state in KV engine — crash window between writes — peer_storage.rs:169-183
  - **Election priority**: Non-standard priority-based vote rejection — raft.rs:1495
  - **Commit fast-forward via vote messages**: Candidates carry `commit`/`commit_term` — raft.rs:1319-1320, 2219-2250
- **Concurrency model**: Single-threaded FSM per region; async write worker; separate apply thread; local reader thread with `RemoteLease` via atomics

## 2. Bug Families

### Family 1: Leader Lease / ReadIndex Linearizability (HIGH)

**Mechanism**: Multiple paths where a leader serves reads via lease or ReadIndex that return stale data — due to transfer abort, lease timing, or missing term checks.

**Evidence**:
- Historical: raft-rs #234 — Transfer leader + lease read safety (OPEN, filed by core maintainer, 2020)
- Historical: raft-rs #140 — Lease-based reads without `check_quorum` serve stale data from partitioned leader (fixed)
- Historical: raft-rs `8c95a3f` — New leader serves ReadIndex before committing own-term entry (fixed)
- Historical: raft-rs `e6784ab` — ReadIndex requests silently dropped (fixed)
- Historical: tikv #9239 — Stale read index after transferring leader (fixed)
- Historical: tikv #9549 — Stale result for read index command (fixed)
- Code analysis: raft.rs:2176-2181 — LeaseBased reads served immediately, staleness window = election_timeout
- Code analysis: raft.rs:1129-1131 + 1969 — Aborted transfer with in-flight MsgTimeoutNow creates dual-leader window
- Code analysis: peer.rs:2020 — PeerStorage commit_index (not raft-rs committed) used for read safety
- Code analysis: peer.rs:6302-6305 — Dual lease check (`in_lease()` + TiKV `Lease`) as defense

**Affected code paths**:
- `step_leader` ReadIndex handling (raft.rs:2145-2184)
- `handle_heartbeat` commit advancement (raft.rs:2562-2573)
- `inspect_lease` (peer.rs:6290-6310)
- `maybe_renew_leader_lease` (peer.rs:3869-3907)
- `read_index` (peer.rs:4280-4419)
- MsgTimeoutNow sending/receiving (raft.rs:1852-1863, 2398-2418)

**Suggested modeling approach**:
- Variables: `lease[Server -> {Expired, Suspect, Valid}]`, `leaseExpiry[Server -> Timespec]`
- Actions: Split ReadIndex into `ProposeReadIndex`, `ConfirmReadIndex` (heartbeat quorum), `ServeRead`. Model `TransferLeadership` + `AbortTransfer` with in-flight MsgTimeoutNow.
- Add `ReadStaleData` action modeling read serving during lease window.
- Key: model the `check_quorum` timer and election timeout to detect overlapping valid leases.

**Priority**: High
**Rationale**: raft-rs #234 is OPEN since 2020, filed by maintainer. 6+ historical bugs. Lease-based reads are TiKV's primary read optimization. Stale reads are silent data corruption from the client's perspective.

---

### Family 2: Election Safety / PreVote Interaction (HIGH)

**Mechanism**: Interactions between PreVote, CheckQuorum (lease protection), election priority, and leader transfer create scenarios where elections deadlock, produce incorrect results, or violate the one-leader-per-term guarantee.

**Evidence**:
- Historical: raft-rs `3012d3c` — Deadlock during prevote migration (cluster stuck)
- Historical: raft-rs `37ad3a1` — PreVote + CheckQuorum: stale `leader_id` blocks valid elections after partition
- Historical: raft-rs `d7d36bf` — PreVote response carries wrong term, election fails
- Historical: raft-rs #511 — PreVote + priority: term=0 init causes panic (OPEN)
- Historical: tikv #8381 — Two same-term leaders from uninitialized peer hard state
- Historical: tikv #9579 — Two same-term leaders from uninitialized split voter (OPEN)
- Historical: tikv `fac3d728d` — Unsafe vote after start: two leaders hold lease simultaneously
- Code analysis: raft.rs:1495 — Priority check blocks `CAMPAIGN_TRANSFER` votes (priority not bypassed)
- Code analysis: raft.rs:1199-1218 — `become_pre_candidate` does not call `reset()` (by design, but subtle effects)
- Code analysis: raft.rs:2721-2731 — Leader removed from config does NOT step down (TODO acknowledged)

**Affected code paths**:
- `campaign()` (raft.rs:1283-1329)
- `step()` term handling (raft.rs:1347-1478)
- Vote grant logic (raft.rs:1483-1529)
- `poll()` vote tallying (raft.rs:2252-2287)
- `become_pre_candidate()` (raft.rs:1199-1218)
- `check_quorum_active()` (tracker.rs:336-351)

**Suggested modeling approach**:
- Variables: `priority[Server -> Int]`, `preVoteState[Server -> {None, PreCandidate}]`
- Actions: Model `PreVote` and `Vote` as separate actions with different term/state effects. Model `CheckQuorum` as periodic leader self-check. Model priority as additional vote guard.
- Granularity: PreVote request/response and Vote request/response should be separate actions. CheckQuorum should be a separate leader action.
- Key: model `leader_id` persistence across PreCandidate state and its interaction with lease protection.

**Priority**: High
**Rationale**: 7+ historical bugs including 2 CRITICAL election safety violations (tikv #8381, #9579 still OPEN). PreVote+CheckQuorum+priority is a 3-way feature interaction not present in original Raft. tikv's uninitialized peer hard state is a production split-brain vector.

---

### Family 3: Configuration Change Safety (HIGH)

**Mechanism**: Configuration changes interact with elections, leader transfer, commit advancement, and auto-leave joint consensus in ways that can cause liveness failures, safety violations, or stuck configurations.

**Evidence**:
- Historical: raft-rs #221 — Votes not updated on conf change (election failure)
- Historical: raft-rs `2672ac5` — Missing pending conf change check before transfer campaign
- Historical: raft-rs `c7c230f` — Vote messages must carry commit info for conf change discovery
- Historical: raft-rs #192 — Joint consensus can get stuck (no rollback mechanism, acknowledged)
- Historical: tikv #10384 — Leader could propose removing itself (fixed: always reject)
- Historical: tikv `a27a28bda` — Lost vote messages during split (new regions can't elect leader)
- Code analysis: raft.rs:984 — TODO: auto_leave fails if leader steps down before enter_joint is applied
- Code analysis: raft.rs:2721-2731 — Leader removed from config continues operating (heartbeats prevent new election)
- Code analysis: raft.rs:2219-2250 — `maybe_commit_by_vote` can commit conf change mid-election, causing step-down

**Affected code paths**:
- `propose_conf_change` (raft.rs:2083-2131)
- `post_conf_change` (raft.rs:2704-2736)
- `commit_apply` auto-leave (raft.rs:984-1004)
- `check_conf_change` (util.rs:1001-1126)
- `exec_change_peer` (apply.rs:2167-2420)
- `on_ready_change_peer` (fsm/peer.rs:4442-4605)

**Suggested modeling approach**:
- Variables: `config[Server -> {incoming: Set, outgoing: Set}]`, `pendingConfIndex[Server -> Index]`
- Actions: `ProposeConfChange`, `ApplyConfChange`, `EnterJoint`, `LeaveJoint`. Model auto-leave as conditional action on leader applying the joint entry.
- Key: model `pendingConfIndex` enforcement (at most one pending conf change). Model the commit-by-vote conf change discovery path.

**Priority**: High
**Rationale**: 6+ historical bugs. Joint consensus + auto-leave liveness is acknowledged as fragile (TODO in code). The commit-by-vote conf change step-down creates a novel interaction. Configuration changes are the hardest part of Raft to get right.

---

### Family 4: Async Persistence Model (MEDIUM)

**Mechanism**: The async persistence model (leader sends before persisting, `persisted` index tracks durability, `max_apply_unpersisted_log_limit` allows applying unpersisted entries) introduces subtle crash windows and ordering constraints.

**Evidence**:
- Historical: raft-rs `2f5d963` — `Ready.must_sync` didn't include entries (data loss on crash)
- Historical: raft-rs `7e7322b` — Persisted index bug with sequential snapshots
- Historical: raft-rs `a76fb6e` — Applied upper bound panic when limit dynamically reduced
- Historical: tikv `14622f301` — `apply_unpersisted_log_limit` not reset on leader demotion
- Code analysis: raft.rs:1033 — Leader `pr.matched = persisted` (not `last_index`)
- Code analysis: raft.rs:1060-1082 — `on_persist_entries` advances leader's own match
- Code analysis: raft_log.rs:283-285 — Log truncation decreases `persisted`
- Code analysis: raft_log.rs:540-568 — `maybe_persist` with `first_update_index` guard
- Code analysis: peer_storage.rs:169-183 — Two-engine crash window (KV written before Raft)

**Affected code paths**:
- `on_persist_entries` / `on_persist_snap` (raft.rs:1060-1082)
- `maybe_persist` / `maybe_persist_snap` (raft_log.rs:540-590)
- `maybe_append` truncation (raft_log.rs:262-292)
- `ready()` / `on_persist_ready()` (raw_node.rs:487-651)
- `handle_raft_ready_append` (peer.rs:2876-3075)

**Suggested modeling approach**:
- Variables: `persisted[Server -> Index]`, `unstableEntries[Server -> Seq(Entry)]`, `pendingPersist[Server -> Set(Ready)]`
- Actions: Split persistence into `ProposeEntry` (adds to unstable), `PersistEntries` (advances persisted, sends deferred messages), `Crash` (resets to persisted state). Model `max_apply_unpersisted_log_limit` as an option allowing applied > persisted.
- Key: model the invariant `pr.matched[self] = persisted` for the leader, and verify commit safety when leader sends before persisting.

**Priority**: Medium
**Rationale**: 4 historical bugs directly in the async persistence path. The model would verify the core safety argument: that `pr.matched = persisted` prevents committing unpersisted entries. This is a novel Raft extension not present in the original paper.

---

### Family 5: Snapshot + Region Lifecycle Races (LOW for TLA+)

**Mechanism**: Complex interactions between snapshot generation/application, peer creation/destruction, region split/merge, and async message delivery create numerous race conditions in the raftstore layer.

**Evidence**:
- Historical: tikv #097aa4f89 — Data loss from concurrent destroy + snapshot apply (CRITICAL, reverted)
- Historical: tikv 8 snapshot bugs + 8 peer destroy/lifecycle bugs
- Historical: tikv #9495 — Region meta inconsistency during splitting
- Historical: tikv #15423 — Meta inconsistency destroying uninitialized peer during split
- Historical: tikv #18309 — Meta corruption in `destroy_peer` (OPEN)
- Code analysis: peer_storage.rs:169-183 — Two-phase KV/Raft engine write crash window
- Code analysis: apply.rs:428-440 — SST deletion ordering during crash replay

**Priority**: Low (for TLA+ modeling)
**Rationale**: These bugs are primarily in the raftstore integration layer, not the core Raft protocol. They involve TiKV-specific concepts (regions, stores, split, merge) that would require a much larger spec. The underlying Raft protocol logic is correct — these are integration bugs. Better verified by Jepsen-style testing (which already finds many of them).

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Leader lease + ReadIndex | Family 1: 6+ bugs, #234 OPEN, stale reads are silent corruption | `lease` variable, `ServeRead`/`ConfirmReadIndex` actions, clock-based lease expiry |
| Leader transfer + lease interaction | Family 1: Transfer abort + in-flight MsgTimeoutNow creates dual-leader read window | `TransferLeadership`, `AbortTransfer`, `MsgTimeoutNow` as separate actions |
| PreVote protocol | Family 2: 7+ bugs, novel 3-way interaction with CheckQuorum + priority | PreCandidate state, separate PreVote request/response actions |
| CheckQuorum | Family 2: Leader self-demotion on quorum loss, interacts with lease and PreVote | `CheckQuorum` action + `recentActive` tracking |
| Election priority | Family 2: Non-standard, blocks transfer votes, liveness concern | `priority` variable as additional vote guard |
| Joint consensus | Family 3: Auto-leave liveness, stuck joint state | Dual config variables, `EnterJoint`/`LeaveJoint` actions |
| Commit-by-vote fast-forward | Family 3: Config change discovery during election | Vote messages carry `commit`/`commit_term`, `maybe_commit_by_vote` action |
| Async persistence | Family 4: Core safety argument needs verification | `persisted` index, split Append into unstable+persist, `Crash` action |
| `max_apply_unpersisted_log_limit` | Family 4: Applied > persisted on leader, crash scenarios | `appliedUpperBound` considering both committed and persisted |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Region split/merge | TiKV-specific integration concept, not core Raft. Would require 2x spec scope. Better verified by Jepsen. |
| Peer creation/destruction lifecycle | raftstore-layer concern with region IDs, store metadata. Not protocol logic. |
| Snapshot generation/transfer mechanics | Transport-layer concern. Model snapshot as an atomic InstallSnapshot action. |
| Group commit | Low bug count, additive optimization. Can be added later if needed. |
| Batch append optimization | No correctness bugs found. Pure performance optimization. |
| Disk full handling | 4 tikv bugs, but these are operational error handling, not protocol logic. |
| Witness/non-voter extensions | TiKV-specific feature, low bug density. |
| Two-engine crash recovery | peer_storage crash window is correctly handled by `recover_from_applying_state`. Implementation detail. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Leader lease | `lease[Server]`, `leaseExpiry[Server]` | Track lease state for read linearizability | Family 1 |
| ReadIndex | `pendingReads[Server -> Set(ReadReq)]` | Model ReadIndex confirmation via heartbeat quorum | Family 1 |
| Leader transfer | `transferTarget[Server]`, `transferAborted[Server]` | Model transfer lifecycle and MsgTimeoutNow race | Family 1 |
| PreVote | `preVoteGranted[Server -> Set(Server)]` | Separate PreVote from Vote to model 3-way interaction | Family 2 |
| CheckQuorum | `recentActive[Server -> Set(Server)]` | Model leader self-demotion on quorum loss | Family 2 |
| Election priority | `priority[Server -> Int]` | Model priority-based vote rejection | Family 2 |
| Joint consensus | `incoming[Server -> Set]`, `outgoing[Server -> Set]` | Dual config for joint consensus + auto-leave | Family 3 |
| Pending conf index | `pendingConfIdx[Server -> Index]` | At-most-one pending conf change enforcement | Family 3 |
| Async persistence | `persisted[Server -> Index]` | Model write durability boundary | Family 4 |
| Apply limit | `maxApplyUnpersisted[Server -> Nat]` | Model applied > persisted on leaders | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard + Family 2 |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard + Family 4 |
| LeaseLinearizability | Safety | If a read is served via lease, no conflicting write is committed by another leader during the lease window | Family 1 |
| ReadIndexSafety | Safety | ReadIndex result reflects state at or after the request time | Family 1 |
| NoStaleReadAfterTransfer | Safety | After leader transfer completes, old leader does not serve reads | Family 1 |
| PreVoteSafety | Safety | PreVote does not disrupt a stable leader or increment terms | Family 2 |
| CheckQuorumLiveness | Liveness | If a leader loses quorum, a new leader is eventually elected | Family 2 |
| PriorityLiveness | Liveness | With priority, elections eventually succeed when a candidate can reach a majority | Family 2 |
| ConfChangeSafety | Safety | At most one uncommitted conf change at a time | Family 3 |
| JointLiveness | Liveness | Joint consensus eventually resolves to a single config (auto-leave) | Family 3 |
| CommitByVoteSafety | Safety | Commit fast-forward via vote messages does not commit incorrect entries | Family 3 |
| AsyncPersistSafety | Safety | Committed entries are persisted on a majority before the leader counts them | Family 4 |
| CrashRecoverySafety | Safety | After crash, recovered state (from persisted) satisfies all safety invariants | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Transfer abort + in-flight MsgTimeoutNow + lease-based read | LeaseLinearizability, NoStaleReadAfterTransfer | 1 |
| MC-2 | CheckQuorum lease protection + PreVote: stale leader_id blocks valid elections | CheckQuorumLiveness | 2 |
| MC-3 | Priority blocks CAMPAIGN_TRANSFER votes (liveness) | PriorityLiveness | 2 |
| MC-4 | Auto-leave joint consensus fails when leader steps down mid-apply | JointLiveness | 3 |
| MC-5 | Leader removed from config continues sending heartbeats (liveness delay) | CheckQuorumLiveness | 3 |
| MC-6 | `maybe_commit_by_vote` commits conf change causing step-down mid-election | CommitByVoteSafety, ElectionSafety | 3 |
| MC-7 | Leader sends before persist: `pr.matched = persisted` prevents unsafe commit | AsyncPersistSafety | 4 |
| MC-8 | Log truncation decreases `persisted`, interacts with async `on_persist_entries` | CrashRecoverySafety | 4 |
| MC-9 | `max_apply_unpersisted_log_limit` + leader demotion + crash | CrashRecoverySafety | 4 |
| MC-10 | Heartbeat `commit_to` without term verification relies on `pr.matched` accuracy | LeaderCompleteness | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | PreVote + priority=0 initialization panic (#511) | Unit test: create node with term=0, priority != 0, trigger PreVote rejection |
| TV-2 | `find_conflict_by_term` edge case at index 0 | Unit test: compact log to index 1, call with index=1, term=MAX |
| TV-3 | Applied upper bound overflow with large `max_apply_unpersisted_log_limit` | Unit test: set limit to u64::MAX, check for arithmetic overflow |
| TV-4 | SST deletion ordering during crash replay | Integration test: inject crash between SST delete and WriteBatch write |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `INVALID_INDEX` used where `INVALID_ID` is semantically correct (raft.rs:2624) | Both are 0; submit cleanup PR |
| CR-2 | `restore()` assertion at raft.rs:2693 flagged as "untested and likely unneeded" | Either test it or remove it |
| CR-3 | apply.rs:670-701 — Debug panic code for duplicate lock CF keys in production | Remove before release |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/tikv/analysis-report.md`
- **Key source files (raft-rs)**:
  - `artifact/raft-rs/src/raft.rs` (2966 LOC — core state machine)
  - `artifact/raft-rs/src/raft_log.rs` (1904 LOC — log management)
  - `artifact/raft-rs/src/raw_node.rs` (840 LOC — Ready/persistence interface)
  - `artifact/raft-rs/src/confchange/changer.rs` (350 LOC — joint consensus)
- **Key source files (raftstore)**:
  - `artifact/tikv/components/raftstore/src/store/peer.rs` (7003 LOC — peer state machine)
  - `artifact/tikv/components/raftstore/src/store/fsm/peer.rs` (7935 LOC — FSM message handler)
  - `artifact/tikv/components/raftstore/src/store/fsm/apply.rs` (8232 LOC — apply thread)
  - `artifact/tikv/components/raftstore/src/store/peer_storage.rs` (2446 LOC — persistence)
  - `artifact/tikv/components/raftstore/src/store/util.rs` (2906 LOC — lease, conf change validation)
- **GitHub issues**: raft-rs #234 (transfer+lease, OPEN), #511 (prevote+priority, OPEN), #192 (joint stuck); tikv #9579 (two leaders, OPEN), #18309 (meta corruption, OPEN)
- **Reference**: Raft paper (Ongaro & Ousterhout, 2014), Raft dissertation §9.6 (PreVote), §6.4 (ReadIndex), §4.3 (Joint Consensus)
