# Code Analysis Report: baidu/braft

System: C++ Raft consensus library, ~15 KLOC core, used inside Baidu for storage, SQL, meta services.
Working artifact: `/home/ubuntu/Specula/case-studies/braft_3/artifact/braft`.
Date: 2026-05-16. Branch: master @ `ab0017f` (most recent baidu/braft master).

---

## Phase 1: Reconnaissance

### 1.1 Category Classification

**Category A — Distributed / Message-Passing.** braft implements the Raft consensus protocol with PreVote, Leader Transfer (TimeoutNow), leader lease, joint-consensus config change, snapshot install, and a Witness role. Faults exposed: crash, network partition, message reorder/loss, non-atomic disk persistence, config-change interleaving, snapshot install racing with replication. No Byzantine threat model — pure crash-fault Raft.

### 1.2 Core Files (LOC)

| File | LOC | Role |
|------|-----|------|
| `src/braft/node.cpp` | 3689 | Main state machine (NodeImpl): elections, RPC handlers, conf change, leader transfer |
| `src/braft/replicator.cpp` | 1602 | Per-peer log replication, pipeline, install snapshot driver |
| `src/braft/log.cpp` | 1302 | SegmentLogStorage: on-disk log segments, checksum, recovery |
| `src/braft/snapshot.cpp` | 1040 | LocalSnapshotStorage / writer / reader / copier |
| `src/braft/log_manager.cpp` | 970 | LogManager: in-memory + disk queue, applied/disk IDs, truncate |
| `src/braft/raft_meta.cpp` | 866 | term/votedFor persistence (single/merged/mixed) |
| `src/braft/snapshot_executor.cpp` | 709 | Snapshot driver in NodeImpl |
| `src/braft/fsm_caller.cpp` | 630 | State-machine apply dispatcher |
| `src/braft/ballot_box.cpp` | 188 | Quorum tracking; commit advance |
| `src/braft/lease.cpp` | 149 | Leader/follower lease |

### 1.3 RPC surface (`src/braft/raft.proto`)

`pre_vote`, `request_vote`, `append_entries`, `install_snapshot`, `timeout_now`. RequestVote has an optional `disrupted_leader` field (lease handoff). AppendEntries has `committed_index` and optional `readonly` flag.

### 1.4 Concurrency model

- Single `NodeImpl::_mutex` guards core state in `node.cpp`.
- Per-peer `Replicator` runs on bthread, locked via `bthread_id`.
- `FSMCaller` runs on a `bthread::execution_queue`.
- `LogManager` has its own `_disk_queue` (execution queue) for disk thread.
- Multiple TODO comments acknowledge "outof lock" intent for `set_term_and_votedfor` (`node.cpp:1737, 1841, 2269`).

---

## Phase 2: Bug Archaeology

### 2.1 Coverage

- **Git commits** (touching core files): 73 (node.cpp), 65 (replicator.cpp), 20+ (log_manager.cpp), 20+ (snapshot_executor.cpp). All bug-fix commits scanned via `git log --grep`. 30+ commits deeply read (`git show`).
- **GitHub issues**: 337 total. Filtered to 100+ bug-related. **30+ deeply read** with `gh issue view --comments` across three parallel verification agents.
- **Open PRs**: PR #455 (PeerId role ordering), PR #530 (step-down deadlock — actionable, has patch).

### 2.2 Confirmed Bug Inventory

#### Confirmed open bugs (maintainer or contributor acknowledged)

| Issue | Title | Mechanism | Status |
|-------|-------|-----------|--------|
| #421 | Pipeline+NoCache → "Can't truncate logs before _applied_id" | Replicator `_next_index` spurious decrement, then CHECK crash | confirmed by ehds; open |
| #479 | Process crashes: prev_log_index < first_log_index | same family as #421; CHECK at `replicator.cpp:533` | open |
| #515 | LogManager::unsafe_truncate_suffix crash | same family | open |
| #528 | Replicator ignores `_virtual_first_log_id` → snapshot storms | `replicator.cpp:533, 673` uses `first_log_index()` not `_virtual_first_log_id` | open |
| #492 | Leader missing `_leader_lease` check on PreVote | `node.cpp:2150-2156` consults only `_follower_lease` | open |
| #463 | `_leader_lease` should also be considered when handling vote | `node.cpp:2236-2238` | open |
| #405 | Vote-grant doesn't renew follower lease → two elections in `election_timeout` | `node.cpp:2267-2280` | open, acknowledged by ehds |
| #365 | Leader grants vote to reboot node (PreVote bypasses term-already-leader) | PFZheng acknowledged "should reject" | open |
| #530 | Leader stepdown deadlock | `NodeImpl::step_down` schedules closures under `_mutex`; bthread `push_rq` spins | PR #530 unmerged |
| #531 | Companion to #530 | same | open |
| #498 | `list_peers` returns C_new during joint | `node.cpp` `NodeImpl::list_peers` uses `_conf.conf` not `_conf.list_peers()` | open |
| #410 | BallotBox commit during config change | `ballot_box.cpp:65-90` advances last_committed_index greedily (doc-acknowledged) | closed without fix |
| #526 | Vote handler ABA over-rejection | `node.cpp:2229-2234` strict `previous_term != _current_term` | open |
| #465 | Election timer not restarted after step-down by term change | `node.cpp:2267` step_down resets timer but logic-loop subtle | open |
| #403 | ProtoBufFile::load ignores read errors → can wipe log | `protobuf_file.cpp:87-120` errno conflation, `log.cpp:706-731` ENOENT-only branch | open |
| #499 | LocalSnapshotStorage::close returns 0 on non-EIO failure | `snapshot.cpp:670` | open, isaacwong96 confirmed |
| #462 | Disk-full produces empty snapshot, log truncated → unrecoverable | compound: #499 + executor `_log_manager->set_snapshot` always called | open |
| #346 | Follower on_apply found corrupted log entry with matching checksum | checksum computed pre-write; no leader→follower digest revalidation | open |
| #243 | add-peer two-phase + restart → log conflict | `initial_conf` allows new peer to self-elect | acknowledged design limitation |
| #91 | Leader's own apply gets empty done (semantics) | PFZheng confirmed; EPERM ambiguous | open |
| #439 | `set_error_and_rollback` calls `done->Run()` for unapplied entries | `fsm_caller.cpp:619-628` | open, API design |
| #459 | Re-receive full snapshot every restart when idle | `_last_snapshot_id` not persisted | open |
| #494 | Wiped follower + heartbeats-only doesn't trigger snapshot pull | heartbeat path lacks snapshot-required detection | open |

#### Already-fixed historical bugs (used as **evidence** for bug-prone mechanisms, not modeling targets)

| Commit | Description | Family |
|--------|-------------|--------|
| 3cfb1f1 | Candidate gets vote from prev leader → expire `_follower_lease`; added `disrupted_leader` field | Lease ↔ Vote interaction |
| 858b26d | UAF: `handle_append_entries_request` uses request fields after transfer to out-of-order cache | Lock release / ownership transfer |
| 68cd340 | Deadlock: `replicator._on_rpc_returned` forgot `_destroy()` before `increase_term_to` | Replicator step-down |
| 247d5cc | `bthread_id_unlock` missing in `_continue_sending` | Replicator lock hygiene |
| b9e1293 | UAF in `handle_timeout_now_request`: closure may run before `elect_self` reads `request` | Closure lifecycle |
| a171a95 | Check term at init Node | Bootstrap state mismatch |
| d23dd8c | Old leader steps down → followers shouldn't wait lease (added `old_leader_stepped_down`) | Lease ↔ Vote interaction |
| 5dd342f | `get_term` should check `index < first_log_index` | Range-query corner |
| c50fa09 | `_virtual_first_log_id` must reset in `clear_bufferred_logs` | Virtual-index invariant |
| a7738d7 + bd2387a | Add log corrupt recovery flag; force sync on configuration entries | Crash-window persistence |
| 10cd9e3 | SegmentLogStorage truncate suffix bug | Truncate-suffix preconditions |
| 740908b | "grant self timer reach timeout but node already stepped down" CHECK core | Timer ↔ state race |
| 04092b2 | disk_id.term may be 0 after init | Bootstrap meta |
| 8d0128e | `raft_sync_per_bytes` flag — per-byte sync | Persistence policy |
| 0366072 | Forbid install_snapshot from witness | Witness invariant |

---

## Phase 3: Deep Analysis Findings

Verified findings, each with `file:line` and code snippet. Grouped by mechanism.

### 3.1 Lease–Vote Interaction Family

**F-L1** [HIGH safety] `handle_pre_vote_request` does NOT consult `_leader_lease`. A node that IS a current leader (`_state == STATE_LEADER`) will reach the grant decision based only on `_follower_lease.votable_time_from_now()`. Since a leader never updates its own `_follower_lease` (only updated on AppendEntries receipt, `node.cpp:2456`), `votable_time == 0` always for a leader, so a leader can pre-grant a PreVote and respond `disrupted=true` (`node.cpp:2170`) without ever checking that its own lease is still valid. Confirms issue #492.

```cpp
// node.cpp:2150-2156
int64_t votable_time = _follower_lease.votable_time_from_now();
bool grantable = (LogId(...) >= last_log_id);
if (grantable) {
    granted = (votable_time == 0);
    rejected_by_lease = (votable_time > 0);
}
```

**F-L2** [HIGH safety] `handle_request_vote_request` similarly omits `_leader_lease`. Same code shape at `node.cpp:2236-2249`. A vote can be granted while we are still a valid leader. Confirms issue #463.

**F-L3** [MEDIUM safety] Vote-grant path at `node.cpp:2263-2280` does NOT call `_follower_lease.renew(_voted_for)`. After voting, the follower's `_last_leader_timestamp` is unchanged, so a follower can vote again as soon as the next election timeout fires — within one `election_timeout_ms` of its previous grant. The Raft paper's election-restriction invariant ("if a server has voted, restart election timer") is fulfilled via `step_down(...)` at `:2267` resetting `_election_timer`, but the follower lease (which gates PreVote acceptance) is not refreshed. Confirms issue #405.

**F-L4** [MEDIUM safety] Asymmetry: `disrupted_leader` flag clears `_follower_lease.expire()` only inside `handle_request_vote_request` (`node.cpp:2199-2208`); the same protection is absent in `handle_pre_vote_request`. A PreVote from a candidate that already disrupted the leader cannot expire this follower's lease.

**F-L5** [LOW safety] `lease.cpp:112-114` makes `votable_time_from_now()` a no-op when `FLAGS_raft_enable_leader_lease == false`, but `lease.cpp:129-132` `expired()` is gated independently. The PreVote skip in `pre_vote()` at `node.cpp:1074` uses `expired()`, so a node with the flag disabled but a recent leader contact still skips pre-vote — internal-consistency hazard if the flag is flipped at runtime.

---

### 3.2 Non-Atomic Persistence Family (term/votedFor + log + snapshot meta)

**F-P1** [HIGH safety] `set_term_and_votedfor` is invoked under `_mutex` (`node.cpp:1738-1745, 1841-1848, 2269-2278`) and performs synchronous disk I/O. Three TODO comments mark "outof lock" intent. More critically, in `elect_self`:

```cpp
// node.cpp:1705-1707, 1733-1748
_state = STATE_CANDIDATE;
_current_term++;
_voted_id = _server_id;          // in-memory
...
request_peers_to_vote(peers, _vote_ctx.disrupted_leader());   // RPC out
status = _meta_storage->set_term_and_votedfor(_current_term, _server_id, _v_group_id);
if (!status.ok()) { _voted_id.reset(); return; }
```

Vote RPCs are sent BEFORE persistence completes. Raft Figure 2 mandates "Updated on stable storage before responding to RPCs." If we crash after sending RPCs but before persistence completes, peers may have granted us votes (durably) while we re-emerge at the old term with no record. Election safety still holds in this single scenario (we can't be a leader of the new term without persisting), but the persistence ordering violates the canonical rule and creates a potential for re-voting in another term.

**F-P2** [HIGH safety] `MixedMetaStorage::set_term_and_votedfor` (`raft_meta.cpp:270-292`) writes single first, then submits to merged via `_merged_impl->set_term_and_votedfor(..., &done)` *asynchronously*. On crash between, the two stores diverge. Recovery (`raft_meta.cpp:300-397`) reconciles via `single_newer_than_merged`, but the reconciliation can revert a vote if the rules don't dominate the merged-store value — see Finding 20 from `ballot_lease_fsm_meta` analysis.

**F-P3** [HIGH safety] In `step_down` (`node.cpp:1838-1848`), `_current_term` is advanced in memory, then `set_term_and_votedfor` is called; on write failure only "TODO report error" — no in-memory rollback. A subsequent AppendEntries reply uses the new term but disk has the old term; on crash, recovery sees the old term while followers already saw the new term. Compared to `elect_self`'s reset of `_voted_id` (`:1746`), `step_down` is incomplete.

**F-P4** [HIGH safety] `ProtoBufFile::load` (`protobuf_file.cpp:87-120`) returns -1 for ANY failure (open / short-read / parse) with caller-opaque errno. `SegmentLogStorage::init` (`log.cpp:706-731`) only treats `errno == ENOENT` as the empty-bootstrap case but then **overwrites disk** via `save_meta(1)` on the empty path. A transient ENOENT from FUSE/NFS or a partially-renamed meta file would wipe the log on next call. Confirms issue #403.

**F-P5** [HIGH safety] `LocalSnapshotStorage::close` (`snapshot.cpp:613-670`) sequence:
1. `_fs->delete_file(new_path, true)` (line 643) — deletes the old "target" path
2. `_fs->rename(temp_path, new_path)` (line 649) — installs new snapshot

Between (1) and (2), a crash leaves the on-disk world with the target directory deleted. On restart, `init()` rescans and either finds the temp directory (which is destroyed by line 457-468 unconditionally) or finds nothing. **No on-disk reservoir of the last snapshot exists during the rename window.**

**F-P6** [CRITICAL safety] `LocalSnapshotStorage::close` returns `ret != EIO ? 0 : -1` (line 670). Any non-EIO failure (notably `EEXIST` at line 632; transient `rename` failures with other errno) is masked as success. The executor then advances `_last_snapshot_index` and calls `_log_manager->set_snapshot(&meta)` (`snapshot_executor.cpp:228-235`), truncating logs. Compound with F-P5 → confirms #462 and #499: disk full → empty new snapshot, old snapshot deleted, log truncated, node unrecoverable.

**F-P7** [MEDIUM safety] Config-entry sync (`log.cpp:769-781`) is bound to the *batch* having `has_conf`, not the specific entry. If the batch spans a segment rotation, the previous segment's `close()` (`log.cpp:553-557`) fsyncs only when `FLAGS_raft_sync_segments` (default false). A config entry at the tail of a sealing segment may be renamed-but-not-fsynced.

---

### 3.3 Heartbeat / Replicator Independent Loop Family

**F-R1** [HIGH safety] Pipeline + NoCache spurious `_next_index` decrement. `_on_rpc_returned` (`replicator.cpp:418-466`) on `!response->success()` calls `_reset_next_index()` *and* decrements `_next_index` (`:443-456`). `_reset_next_index()` rolls back by `_flying_append_entries_size` and cancels in-flight RPCs (`:1086`). With pipeline depth ≥ 2 and follower lagging, repeated `success=false` returns over-decrement `_next_index` until the next `_send_empty_entries(false)` issues `prev_log_index=0` or fails the `CHECK_LT(prev_log_index, first_log_index())` at `:533`. Confirms #421/#479.

**F-R2** [HIGH safety] Replicator routes to InstallSnapshot via `first_log_index()` only, never via `_virtual_first_log_id`. Two call sites:

```cpp
// replicator.cpp:533
CHECK_LT(prev_log_index, _options.log_manager->first_log_index());
// replicator.cpp:673
if (_next_index < _options.log_manager->first_log_index()) {
    _reset_next_index();
    return _install_snapshot();
}
```

After compaction with `_virtual_first_log_id > 0`, the virtual head moves; physical head may be behind. A follower whose `_next_index` falls in `[_virtual_first_log_id+1, _first_log_index]` is in-bounds virtually but out-of-bounds physically. Confirms #528.

**F-R3** [MEDIUM safety] Heartbeat path on `success=true` checks `response->term() != _options.term` and just resets next_index (`:472-479`), but does NOT step the leader down if `response->term() > _options.term`. The fix from commit `68cd340` (adding `r->_destroy()` before `increase_term_to`) was applied only to the `!success` branch (`:419-435`). Heartbeat path (`_send_heartbeat`'s callback at `:315-340`) DOES step down; but the **AppendEntries success path** does not. A buggy/stale follower returning `success=true` with a higher term — observable with replays or buggy peer code — silently bypasses step-down.

**F-R4** [HIGH safety] `_on_install_snapshot_returned` deliberately delegates term-check to heartbeat (`replicator.cpp:907-911`): comment "Let heartbeat do step down". An InstallSnapshot whose follower has advanced term is not caught at install-response time; the new term is only acted on at the next heartbeat tick (`raft_election_heartbeat_factor` later). During this window, replicator keeps sending stale-term RPCs.

**F-R5** [MEDIUM safety] `_block_timedout_in_new_thread` (`replicator.cpp:221-228`) **unconditionally** sets `_st.st = IDLE` even if `_block` was reached from `_install_snapshot()` due to throttle. The pending install-snapshot intent is silently lost; `_continue_sending(ETIMEDOUT)` then issues `_send_empty_entries(false)` which may re-enter `_install_snapshot` only on `_fill_common_fields` failure. Two install-snapshot intents can race. Issue #402.

---

### 3.4 Virtual / Snapshot / Log Index Consistency Family

**F-V1** [HIGH safety] `set_snapshot` has three branches that assign `_virtual_first_log_id`:
- `term == 0`: `_virtual_first_log_id = _last_snapshot_id`, `truncate_prefix(last_included+1)` (`log_manager.cpp:656-661`)
- `term == last_included_term && last_but_one.index > 0`: `_virtual_first_log_id = last_but_one_snapshot_id`, `truncate_prefix(last_but_one+1)` (`:662-672`)
- otherwise: `_virtual_first_log_id = _last_snapshot_id`, `reset(last_included+1)` (`:673-678`)

Middle branch only assigns when `last_but_one.index > 0` — first-ever snapshot leaves `_virtual_first_log_id` unchanged. Combined with `unsafe_get_term`'s check order (`:708-727`): `_virtual_first_log_id.index` is checked before `_last_snapshot_id.index` and before range, so a stale `_virtual_first_log_id` returns a wrong term for an index that's outside the current log. A follower receiving `prev_log_index = stale_virtual.index, prev_log_term = stale_virtual.term` would match its `get_term()` even though no real log exists there.

**F-V2** [MEDIUM safety] `clear_bufferred_logs` (`log_manager.cpp:682-688`) is a no-op when `_last_snapshot_id.index == 0`. The early-life invariant "buffered logs are always cleanable" is silently violated; `_virtual_first_log_id` is left as set by an earlier (now reset) snapshot.

**F-V3** [HIGH availability] `unsafe_truncate_suffix` does `LOG(FATAL)` and then `return` without aborting the disk thread (`log_manager.cpp:307-313`). `LOG(FATAL)` aborts the process in default config but the existence of the `return` and the symptom in #421/#479/#515 ("Can't truncate logs before _applied_id") confirm this is reachable.

---

### 3.5 Configuration-Change Family

**F-C1** [MEDIUM safety] `unsafe_register_conf_change` short-circuits on `_conf.conf.equals(new_conf)` (`node.cpp:884-888`) without inspecting `_conf.old_conf`. If we are in joint consensus and the user requests a conf matching the new peers, the change is reported done while joint state is still active. The `is_busy()` check at line 874 catches *concurrent* changes but not this same-target shortcut.

**F-C2** [MEDIUM safety] `NodeImpl::list_peers` uses `_conf.conf.list_peers()` (the new committed conf) rather than the union during joint. Issue #498 confirmed bug, unfixed. Self-managing clusters reading `list_peers` during joint get a misleading view.

**F-C3** [LOW safety] `next_stage` for single-peer add/remove (`node.cpp:3294-3305`) skips JOINT and falls through to STABLE. Long-standing deviation from the paper. Documented "legacy optimization."

**F-C4** [MEDIUM safety] BallotBox greedy commit advancement (`ballot_box.cpp:65-90`, documented at `:79-85`): "we think it's safe to commit all the uncommitted previous logs, which is not well proved right now." Each ballot has its own (joint vs stable) configuration baked in, so the per-ballot quorum requirement isn't relaxed — but the doc-acknowledged proof gap is the rationale for issue #410.

---

### 3.6 Witness Role Family

**F-W1** [HIGH safety] When `options.witness == true && FLAGS_raft_enable_witness_to_leader == false` (default), the witness gets **no `_election_timer` and no `_vote_timer` init** (`node.cpp:508-519` — the `else` branch initializes both; the `if` branch only initializes them when the flag is true). So a default-config witness cannot start an election on its own.

**F-W2** [HIGH safety] Despite F-W1, a witness CAN still become a candidate via:
- `vote()` API call (`node.cpp:1286`) sets `_vote_triggered`
- `transfer_leadership_to(witness)` causing the witness to receive `TimeoutNow`
- `handle_timeout_now_request` (`node.cpp:1114`) only checks `_state == STATE_FOLLOWER`, not `is_witness()`

A witness becoming leader is meant to be transient — `check_witness` (`node.cpp:843-853`) is invoked from `handle_stepdown_timeout` and forces `step_down(_current_term, true, ...)`. But this is **reactive** — the witness IS leader for up to one election_timeout before stepping down. During this window the witness can:
- Accept client `apply()` (data not durable on witness)
- Receive AppendEntries replies and update commit index
- Issue InstallSnapshot to followers (the leader-side has guard at `replicator.cpp:774`; node-side does not)

**F-W3** [HIGH safety] `handle_install_snapshot_request` does not check `is_witness()`. A witness receiving InstallSnapshot will call `_snapshot_executor->install_snapshot()` (`node.cpp:2670`). With `copy_file=false` configured for witness (`node.cpp:261`), the executor is in a degraded mode but there is no centralized refusal.

---

### 3.7 Step-Down / Election-Timer Reset Family

**F-S1** [HIGH liveness] `step_down` (`node.cpp:1801-1880`) schedules done closures while still holding `NodeImpl._mutex`. Under load, the bthread it needs to drain may itself be blocked on `_mutex` → deadlock. Confirms #530/#531. PR #530 proposes moving closure scheduling outside the lock.

**F-S2** [MEDIUM liveness] `step_down` unconditionally restarts `_election_timer.start()` (`node.cpp:1874`). A follower receiving same-term RequestVote calls `step_down(request->term(), false, status)` (`node.cpp:2267`), re-arming the election timer with fresh random delay. Issue #465.

**F-S3** [LOW safety] `check_step_down` (`node.cpp:1898+`) cascades multiple step_down conditions; invoked in `handle_append_entries_request:2438` BEFORE the `server_id != _leader_id` split-brain check at 2440. A spoof same-term sender can repeatedly induce candidate cancellation. Requires Byzantine-ish behavior; mitigated by transport authentication.

---

### 3.8 Snapshot Lifecycle Family

**F-SN1** [HIGH safety] Two install_snapshot can race in `register_downloading_snapshot` retry branch (`snapshot_executor.cpp:559-587`). Replaces `*m` while old `_cur_copier->join()` is in progress. Compound with F-P6 → snapshot data corruption / leak path.

**F-SN2** [HIGH safety] `_downloading_snapshot.store(NULL, memory_order_relaxed)` (line 472) versus `release` (line 484) versus `relaxed` readers (line 534) inconsistent — readers may observe stale `_downloading_snapshot`. May cause double install.

**F-SN3** [MEDIUM safety] `interrupt_downloading_snapshot` (`snapshot_executor.cpp:600-611`) advances `_term` regardless but cannot interrupt an in-flight `_loading_snapshot`. The subsequent `on_snapshot_load_done` (`:247-285`) unconditionally writes `_last_snapshot_index` and embedded config — under the **new term** but with the **old leader's snapshot**.

**F-SN4** [HIGH safety] `LocalSnapshotStorage::open` reader-refcount race: increments `_ref_map[old_index]` (line 677) then unlocks. Concurrent `close(SnapshotWriter*)` flow: `ref(new)`; lock; update `_last_snapshot_index`; unlock; `unref(old)`. The writer's `unref(old)` may drop the count to 0, deleting the directory while the reader holds it.

---

### 3.9 FSMCaller / Apply Family

**F-F1** [LOW safety] `set_error_and_rollback` followed by `run_the_rest_closure_with_error` (`fsm_caller.cpp:619-628`) invokes every closure between `_cur_index` and `_committed_index` with the error status, **even though those entries were never applied**. Issue #439 API design concern.

**F-F2** [LOW liveness] After any `_error` is set, `do_committed` early-exits at `:264-266`; subsequent COMMITTED tasks silently dropped. Closures for log indices > `_committed_index` are never popped from `_closure_queue` and leak.

---

### 3.10 RPC Handler ABA Family

**F-A1** [MEDIUM safety] `handle_install_snapshot_request` releases `_mutex` to dereference `_log_manager->last_log_id()` for logging (`node.cpp:2660-2670`) and then dispatches to `_snapshot_executor->install_snapshot()` with no ABA re-check. Other handlers re-check (`handle_request_vote_request:2230`, `pre_vote:1638`, `elect_self:1725`). Install-snapshot is the odd one.

**F-A2** [LOW safety] `handle_pre_vote_request` comment explicitly says "pre_vote not need ABA check after unlock&lock" (`node.cpp:2148`). The response uses `_current_term` from after the re-lock (line 2167), which may be larger than the term at the start. Caller correctly handles `response.term() > current_term` by stepping down, but the response says `granted=false`, which may mislead.

**F-A3** [MEDIUM safety] `handle_request_vote_request`'s ABA check at `:2230` uses `previous_term != _current_term` and breaks unconditionally. If `_current_term` advanced to `request->term()` (the requester's term) via a concurrent leader heartbeat, the vote would still be legitimately grantable but is rejected. Issue #526.

---

## Phase 3 Coverage Summary

| File | Read in full | Findings |
|------|--------------|----------|
| node.cpp | yes | F-A1, F-A2, F-A3, F-C1, F-L1..5, F-P1, F-P3, F-S1..3, F-W1..3 |
| replicator.cpp | yes | F-R1..5, F-V3 (via CHECK), F-W2 (replicator-side witness gate) |
| log_manager.cpp + log.cpp | yes | F-V1, F-V2, F-V3, F-P4, F-P7 |
| snapshot.cpp + snapshot_executor.cpp | yes | F-P5, F-P6, F-SN1..4 |
| ballot_box.cpp + lease.cpp + fsm_caller.cpp + raft_meta.cpp | yes | F-C2..4, F-F1..2, F-L5, F-P2 |

**Verification**: All cited code locations were re-read in the main context after subagent reports. Key claims (snapshot close return value, pre/request-vote lease usage, `_virtual_first_log_id` ignored by replicator, log meta error handling, witness timer init, elect_self persistence order) confirmed via direct Read.

---

## Phase 4: see modeling-brief.md
