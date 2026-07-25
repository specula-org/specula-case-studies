# Modeling Brief: baidu/braft

## 1. System Overview

- **System**: baidu/braft — C++ Raft consensus library, ~15 KLOC core, built on brpc; used in production for KV/SQL/meta services at Baidu.
- **Language / scale**: C++; `node.cpp` (3689), `replicator.cpp` (1602), `log.cpp` (1302), `snapshot.cpp` (1040), `log_manager.cpp` (970), plus 5 smaller core files (~3 KLOC).
- **System category**: **Category A (Distributed / Message-Passing)** — Raft consensus with election, log replication, snapshot install, conf change. Crash-fault model, no Byzantine assumptions.
- **Protocol**: Raft + PreVote + Leader Transfer (TimeoutNow) + Leader Lease + Joint Consensus + Witness role.
- **Key architectural deviations from Raft paper**:
  - **Witness peer**: a peer that stores log/term but not state data; election timer absent unless `FLAGS_raft_enable_witness_to_leader` (`node.cpp:508-519`); becomes leader only transiently and is forced to step down by stepdown timer (`node.cpp:843-853`).
  - **Leader lease** (`lease.cpp`): `_follower_lease` tracks last leader contact; `_leader_lease` tracks self-leadership. PreVote and RequestVote consult only `_follower_lease`, never the local `_leader_lease` (`node.cpp:2150-2156, 2236-2249`).
  - **`disrupted_leader` field** on RequestVote (`raft.proto`): candidate signals it has disrupted the prior leader so peers can immediately expire `_follower_lease` (`node.cpp:2199-2208`). Only honored on RequestVote, not PreVote.
  - **`_virtual_first_log_id`** in `LogManager`: virtual head separate from physical `_first_log_index`, used to keep log entries in memory across snapshot bursts (`log_manager.cpp:656-678`). Replicator does not consult it (`replicator.cpp:533, 673`).
  - **Single-peer conf change** skips JOINT stage and falls through to STABLE (`node.cpp:3294-3305`).
  - **Three meta-store backends** (`raft_meta.cpp`): `FileBased`, `KVBasedMerged` (leveldb), `Mixed`. `Mixed` writes single synchronously and merged asynchronously — diverges on crash.
- **Concurrency model**: single `NodeImpl._mutex` for the main state machine; per-peer `Replicator` with `bthread_id` lock; `FSMCaller` and `LogManager._disk_queue` on bthread execution queues. Three TODO("outof lock") comments around `set_term_and_votedfor`.

## 2. Bug Families

### Family 1: Lease Bypass on Vote Paths (HIGH)

**Mechanism**: (Pre)vote handlers consult only the follower lease, never the leader lease; vote-grant path never renews the follower lease. A current leader can grant a (pre)vote that disrupts itself, and a follower can vote twice within a single election timeout.

**Evidence**:
- Historical (open): #492 PreVote missing `_leader_lease`; #463 RequestVote missing `_leader_lease`; #405 vote-grant doesn't renew follower lease (acknowledged); #365 PreVote bypasses term-already-leader (PFZheng acknowledged "should reject").
- Historical (fixed) as evidence of mechanism: commit `3cfb1f1` introduced `_follower_lease.expire()` for the candidate-with-`disrupted_leader` case — addresses one slice of the same mechanism; commit `d23dd8c` ("old leader steps down → followers do not need to wait leader lease") another slice.
- Code analysis: `node.cpp:2150-2156` (PreVote checks only `_follower_lease`); `node.cpp:2236-2249` (RequestVote checks only `_follower_lease`); `node.cpp:2263-2280` (vote-grant has no `_follower_lease.renew()`); `node.cpp:2199-2208` (`disrupted_leader` clears lease only for RequestVote, not PreVote).

**Affected code paths**: `NodeImpl::handle_pre_vote_request`, `NodeImpl::handle_request_vote_request`, `NodeImpl::handle_pre_vote_response`, `NodeImpl::handle_request_vote_response`, `FollowerLease::renew/expire/expired`.

**Suggested modeling approach**:
- Variables: `leaderLease[Server] ∈ {valid, expired}` (the self-leadership lease), `followerLease[Server] -> {leader, ts}` (last-contact lease).
- Actions: split the vote handler into `HandlePreVoteWithLease` and `HandleRequestVoteWithLease`; the lease check should consult **both** `leaderLease[self]` and `followerLease[self]`. A `RenewFollowerLeaseOnVote` modeling choice for the corrected version. Add `disruptedLeader` field on RequestVote and a `ExpireFollowerLease` action on its receipt.
- Granularity: time-step abstraction via a `lease_age[Server]` counter advanced by an explicit `Tick` action.

**Priority**: High
**Rationale**: 4 confirmed open issues with maintainer/contributor acknowledgement, no fix landed. Lease is a non-paper extension, so the spec must explicitly model it. TLA+ can express "if leader L's lease covers term T, then no other server can hold leader-state in T" as a checkable invariant.

---

### Family 2: Non-Atomic Persistence (term / votedFor / snapshot meta / log meta) (HIGH)

**Mechanism**: Multi-step durable updates with no rollback on partial failure. Crash between steps leaves persistent state inconsistent with in-memory state.

**Evidence**:
- Code analysis: `elect_self` sends vote RPCs BEFORE persisting `(term, votedFor)` to disk (`node.cpp:1733-1748`); `step_down` advances `_current_term` in memory then writes, with no in-memory rollback on failure (`node.cpp:1838-1848` — "TODO report error"); `MixedMetaStorage::set_term_and_votedfor` writes single sync then merged async (`raft_meta.cpp:270-292`); `ProtoBufFile::load` returns -1 for any error, caller treats `errno == ENOENT` as empty-bootstrap and overwrites disk (`protobuf_file.cpp:87-120` + `log.cpp:706-731`); `LocalSnapshotStorage::close` deletes target then renames temp with a crash window between (`snapshot.cpp:643-649`); same `close()` returns 0 on non-EIO failures masking close errors (`snapshot.cpp:670`).
- Historical (fixed) evidence: commit `bd2387a` "sync log immediately when there is configuration"; commit `a7738d7` adds `raft_recover_log_from_corrupt` flag.
- Historical (open) confirming bug-proneness: #462 disk full → empty snapshot + truncated log → unrecoverable; #499 LocalSnapshotStorage::close error code; #403 ProtoBufFile::load wipe-on-load; #346 follower log corruption with matching checksum.

**Affected code paths**: `NodeImpl::elect_self`, `NodeImpl::step_down`, `NodeImpl::handle_request_vote_request`, `MixedMetaStorage::set_term_and_votedfor`, `LocalSnapshotStorage::close`, `SegmentLogStorage::init / save_meta / load_meta`.

**Suggested modeling approach**:
- Variables: `persistedTerm[Server]`, `persistedVotedFor[Server]`, `volatileTerm[Server]`, `volatileVotedFor[Server]`, `persistedSnapshotIndex[Server]`, `persistedLogPrefix[Server]`, `pendingMetaSwap[Server]`.
- Actions: split persistence-touching transitions into `BumpTermVolatile`, `SendVoteRPC` (allowed only on `pendingMetaSwap=true`), `CompletePersistTerm`. Snapshot install split into `WriteNewSnapshot`, `DeleteOldSnapshot`, `TruncateLog`, with a `Crash` action that can fire in any partial state. Optionally model both `Mixed`-storage backends.
- Granularity: extra action variants per persistence step; `Crash` resets volatile state.

**Priority**: High
**Rationale**: 4+ confirmed bugs sharing this mechanism (open or partly-mitigated); persistence ordering is a classic TLA+ strength; braft's three storage backends amplify the surface.

---

### Family 3: Replicator Pipeline & next_index Accounting (HIGH)

**Mechanism**: Pipelined AppendEntries with disabled cache, plus `_reset_next_index()` rolling back by `_flying_append_entries_size`, plus an explicit `--_next_index`, plus out-of-order RPC completion, plus `_virtual_first_log_id` divergence from `_first_log_index`, produces a `_next_index` smaller than the follower's committed prefix → `unsafe_truncate_suffix` CHECK fails on "Can't truncate logs before _applied_id" or `CHECK_LT(prev_log_index, first_log_index())` aborts.

**Evidence**:
- Open: #421 (confirmed by ehds), #479, #515, #528.
- Code analysis: `replicator.cpp:418-466` (`_on_rpc_returned` failure branch); `replicator.cpp:1086` (`_reset_next_index`); `replicator.cpp:533, 673` (`first_log_index()` used, not `_virtual_first_log_id`); `replicator.cpp:472-479` (success path skips step-down on higher term); `replicator.cpp:907-911` (InstallSnapshot deliberately defers term-check to heartbeat); `log_manager.cpp:307-313` (`LOG(FATAL)` on `last_index_kept < _applied_id.index`); `replicator.cpp:221-228` (block-timeout always sets state to IDLE losing install-snapshot intent).

**Affected code paths**: `Replicator::_on_rpc_returned`, `Replicator::_send_entries`, `Replicator::_fill_common_fields`, `Replicator::_install_snapshot`, `Replicator::_on_block_timedout_in_new_thread`, `LogManager::unsafe_truncate_suffix`, `LogManager::clear_bufferred_logs`, `LogManager::set_snapshot`, `LogManager::unsafe_get_term`.

**Suggested modeling approach**:
- Variables: `nextIndex[Leader -> Follower -> Int]`, `flyingRPCs[Leader -> Follower -> Seq]`, `virtualFirstLogId[Server]`, `physicalFirstLogId[Server]`.
- Actions: model `SendAppendEntries` returning either before/after a sibling RPC; `HandleAppendResponseFailure` should be split into `ResponseFromUpToDateFollower` (decrement next_index) and `ResponseDueToReorder` (no-op); add an action `LeaderInstallSnapshot` that takes the `min(virtualFirstLogId, physicalFirstLogId)` path; allow `virtualFirstLogId != physicalFirstLogId`.
- Granularity: keep the failure branch as multiple discrete actions to expose the over-decrement window.

**Priority**: High
**Rationale**: 4 open issues directly traceable to the same mechanism; CHECK crashes are availability-fatal; the `_virtual_first_log_id` divergence is a non-paper invariant that the brief must capture; TLA+ can express `next_index >= first_log_index` invariants.

---

### Family 4: Snapshot Lifecycle Cross-Product (MEDIUM)

**Mechanism**: Concurrent install_snapshot retries, racy refcounting on the storage directory, term-advance during in-flight load, all combined with the non-atomic close (Family 2). Two install_snapshot in flight can corrupt or leak; a stale leader's snapshot can finalize state under a new term.

**Evidence**:
- Open: #462 disk-full unrecoverability; #459 re-snapshot on idle restart; #494 wiped follower + heartbeats stall; #317 restart deadlock; #423 long load + RPC timeout install loop; #402 install-snapshot state ordering.
- Historical (fixed) as mechanism evidence: `b24858c` "follower readonly mode change → two install_snapshot simultaneously"; `902cc43` "pre-set state to INSTALLING_SNAPSHOT"; `42cfd9a` "_node ref not released during install_snapshot leader stepdown"; `857f4fb` "hole between _last_but_one_snapshot_id and last_snapshot_id"; `0366072` "forbid install_snapshot from witness".
- Code analysis: `snapshot_executor.cpp:443-449` (unlocked join of `_cur_copier`); `snapshot_executor.cpp:557-587` (retry branch overwrites `*m` in-place); `snapshot_executor.cpp:600-611` (interrupt advances term but cannot interrupt load); `snapshot.cpp:673-693` (open reader-refcount race); `node.cpp:2660-2670` (install handler no ABA, no witness guard).

**Affected code paths**: `SnapshotExecutor::install_snapshot / register_downloading_snapshot / load_downloading_snapshot / on_snapshot_load_done / interrupt_downloading_snapshot`, `LocalSnapshotStorage::open / close / destroy_snapshot / ref / unref`, `NodeImpl::handle_install_snapshot_request`.

**Suggested modeling approach**:
- Variables: `installingSnapshot[Server] ∈ {none, copying, loading}`, `snapshotMeta[Server]` (term, index, conf), `snapshotRefs[Server -> Int]`.
- Actions: `BeginInstallSnapshot(from, to, meta)`, `ConcurrentInstallSnapshot` that may interrupt the prior, `FinalizeSnapshotLoad` that can run under a new term, `OpenSnapshotReader` racing with `CloseSnapshotWriter`. Add `Crash` between `delete_file(new_path)` and `rename(temp_path, new_path)`.
- Granularity: split into multi-step actions, allow term to advance between steps.

**Priority**: Medium
**Rationale**: Many small bugs (5+ open), but each affects different code paths; the snapshot lifecycle is complex enough that a separate spec or focused extension is warranted. TLA+ can prove "snapshot install advances state monotonically" and "leader-term consistency holds across install/load."

---

### Family 5: Witness Role Invariants (MEDIUM)

**Mechanism**: Witness is a peer that must never store data, must rarely become leader, and must not receive snapshots. The defenses are scattered and partial: `_election_timer` and `_vote_timer` are not initialized for witness, but only when the flag is off; `check_witness` reactively steps down after the witness becomes leader; the vote/election handlers and `handle_install_snapshot_request` do not gate on `is_witness()`.

**Evidence**:
- Open: #445 `NodeTest.LeaderFailWithWitness` unstable; #443 check follower log gap before transferring leader to it (witness-adjacent).
- Historical (fixed): `ed36465` "transfer leader when witness temporarily be leader"; `0366072` "forbid install_snapshot from witness".
- Code analysis: `node.cpp:508-519` (witness timer init guarded by flag); `node.cpp:843-853` (`check_witness` is reactive); `node.cpp:1114` (`handle_timeout_now_request` no witness check); `node.cpp:1286` (`vote()` API no witness check); `node.cpp:2660-2670` (install handler no witness check); `replicator.cpp:633, 774, 1552` (only sites consulting `is_witness()`).

**Affected code paths**: `NodeImpl::init` (timer init), `NodeImpl::check_witness`, `NodeImpl::handle_timeout_now_request`, `NodeImpl::handle_install_snapshot_request`, `NodeImpl::vote`, `Replicator::_prepare_entry / _install_snapshot`.

**Suggested modeling approach**:
- Variables: `role[Server] ∈ {voter, witness}`, `data_state[witness] ∈ {empty}`.
- Actions: `TransferLeadershipToWitness` (TimeoutNow received by witness), `WitnessBecomesLeaderTransiently`, `WitnessStepdownOnStepdownTimer`. Invariant: "no committed data entry depends on the witness's persisted log."
- Granularity: small extension on top of the standard election spec.

**Priority**: Medium
**Rationale**: Witness is a deviation from the paper with a unique state-transition pattern (transient-leader-then-stepdown). Bug history is thinner than other families, but unmodeled behaviour is the highest-risk category.

---

### Family 6: Configuration-Change ↔ Commit Interactions (LOW)

**Mechanism**: `list_peers` returns inconsistent view during joint; `unsafe_register_conf_change` short-circuits via equality on `_conf.conf` ignoring `_conf.old_conf`; ballot box advances `last_committed_index` greedily; single-peer changes skip JOINT.

**Evidence**:
- Open: #498 `list_peers` returns C_new during joint; #243 `initial_conf` + restart → log conflict; #410 BallotBox commit during joint (closed without fix, doc-acknowledged proof gap).
- Code analysis: `ballot_box.cpp:65-90` (greedy commit with documented proof gap); `node.cpp:884-888` (short-circuit on `_conf.conf.equals`); `node.cpp:3294-3305` (single-peer skips JOINT).

**Affected code paths**: `NodeImpl::unsafe_register_conf_change / list_peers / next_stage`, `BallotBox::commit_at`.

**Suggested modeling approach** *(only if the Spec author wants to broaden scope)*:
- Variables: `commitConfig[Server]` (committed conf) vs `latestConfig[Server]` (latest applied conf, possibly joint).
- Actions: split `AdvanceCommitIndex` and `ApplyConfigChange`.
- Granularity: dual-config model similar to hashicorp/raft Family 2.

**Priority**: Low (for this analysis round)
**Rationale**: Each ballot has correct per-entry quorum baked in (Finding 3 in analysis report), so the documented "proof gap" is conservative. The other items are local code-quality issues better fixed by direct PRs. If broadened, it composes with Family 1 / 2.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Leader-lease + follower-lease, with vote handler **consulting both** | Family 1: 4 open issues with maintainer ack | Two lease variables; split `HandlePreVote` and `HandleRequestVote` actions to check `leaderLease[self]` and `followerLease[self]`; `RenewFollowerLeaseOnVote` toggleable |
| `disrupted_leader` field on RequestVote and follower-lease expiry on receipt | Family 1 ↔ commit `3cfb1f1` | Optional field in RequestVote message; `ExpireFollowerLease` action triggered by receipt |
| Non-atomic `set_term_and_votedfor` with the "vote RPC out before persist" ordering | Family 2: confirms paper-level violation | Split `elect_self` into `BeginCandidate`, `SendVoteRPCs`, `CompletePersistTermAndVote`; `Crash` may fire between |
| Non-atomic snapshot install: delete-then-rename, close-returns-0-on-non-EIO | Family 2 + Family 4: #462/#499 unrecoverability | Split `LocalSnapshotStorage::close` into `DeleteOldTarget`, `RenameTempToTarget`; allow `Crash` between |
| Pipeline & `_next_index` accounting with out-of-order RPC | Family 3: 4 open issues | Allow RPCs to commit out-of-order; model the over-decrement window |
| `_virtual_first_log_id` vs `_first_log_index` divergence on replicator routing decisions | Family 3: #528 | Separate variables; replicator `Install` decision uses `_first_log_index` only |
| Witness role: transient-leader + reactive stepdown | Family 5: paper deviation, untested | Role variable + reactive step-down action |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| `ProtoBufFile::load` errno conflation (#403) | Pure C++ error-handling bug; verify by unit test (mock failing read with various errno) |
| `LocalSnapshotStorage::close` returning 0 instead of -1 (#499) | Confirmed by code reading; fix is a one-line change; not interesting for TLA+ |
| `bthread_id_unlock` missing / use-after-free fixes | C++ memory-safety / locking hygiene; out of scope |
| Per-byte sync policy, raft_sync_per_bytes | Performance tuning, not protocol logic |
| `list_peers` returning wrong configuration during joint (#498) | Single-function fix; verify by integration test |
| `NodeImpl::_mutex` step-down deadlock (#530) | Bthread scheduler ↔ lock interaction; not protocol logic; PR exists |
| Closure leak in `_closure_queue` after rollback (#439, F-F2) | Implementation detail; verify by unit test |
| Detailed brpc transport / TimeoutNow plumbing | Library/RPC concerns; covered by simpler abstraction |
| FSMCaller out-of-order apply (#395) | Maintainer-confirmed: queue is FIFO; verified correct |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Dual lease | `leaderLease[Server]`, `followerLease[Server]`, `leaseClock` | Capture leader-vs-follower lease bypass on (pre)vote | Family 1 |
| disrupted_leader propagation | `pendingDisruptedLeader[Server]` | Capture `RequestVote.disrupted_leader` field semantics | Family 1 |
| Non-atomic term/vote persistence | `persistedTerm`, `persistedVotedFor`, `volatileTerm`, `volatileVotedFor` | Model the disk-write-after-rpc ordering | Family 2 |
| Mixed meta-store | `persistedSingle[Server]`, `persistedMerged[Server]` | Capture `MixedMetaStorage` divergence on crash | Family 2 |
| Snapshot rename window | `newSnapshotStaged[Server]`, `targetSnapshotDeleted[Server]` | Model close()'s delete-then-rename gap | Family 2 / 4 |
| Replicator next_index with pipeline | `nextIndex`, `flyingRPCs`, `physicalFirstLog`, `virtualFirstLog` | Capture pipeline + virtual-vs-physical mismatch | Family 3 |
| Snapshot install lifecycle | `installingSnapshot[Server]`, `cur_copier_term[Server]`, `snapshot_load_term[Server]` | Capture interrupt + finalize-under-new-term | Family 4 |
| Witness role | `role[Server]`, `witnessAsLeader[Server]` | Capture transient witness-leader and reactive stepdown | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Matching `(term, index)` implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in all future leaders' logs | Standard |
| LeaseImpliesLoyalty | Safety | If `leaderLease[L]` is valid in term T, no other server holds leader-state in T | Family 1 |
| VoteAfterPersist | Safety | A server's `voted` message in term T is sent only after `persistedTerm[s] >= T` AND `persistedVotedFor[s] == candidate` | Family 2 |
| StepDownPersistInvariant | Safety | After successful step_down(T), persistedTerm >= T (i.e., disk write succeeded) OR a `step_down_failed` flag is set | Family 2 |
| MetaStoreCoherence | Safety | After a `Crash`, recovery selects the more-recent of `persistedSingle` / `persistedMerged` (or both if equal); the chosen state is never "stale vote" | Family 2 |
| SnapshotInstallMonotone | Safety | `persistedSnapshotIndex[s]` is monotone — even across Crash | Family 4 |
| SnapshotCompletesOrRestores | Safety | After any Crash window in `close()`, there exists a snapshot on disk recoverable in `init()` (either old or new, never neither) | Family 2 / 4 |
| ReplicatorIndexInvariant | Safety | `nextIndex[L->F] > 0`; `prev_log_index < first_log_index ⇒ leader sends InstallSnapshot` | Family 3 |
| VirtualVsPhysicalLog | Safety | `_virtual_first_log_id.index ≤ _first_log_index` always; queries to `unsafe_get_term(_virtual_first_log_id.index)` consistent with that index actually being inside the log | Family 3 / V1 |
| WitnessNeverHoldsData | Safety | No committed data entry is durably stored only on a witness | Family 5 |
| WitnessLeaderTransient | Safety | If a witness ever has `_state == LEADER`, within one stepdown_timer it returns to FOLLOWER | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

Each item is an **open mechanism question** about unaudited behaviour, not a reproduction of a closed PR. Items whose only honest verdict would be "hardening / documented design choice" have been demoted to § 7.

| ID | Description | Expected invariant violation | Family |
|----|-------------|------------------------------|--------|
| MC1 | A leader L holds a valid `leaderLease[L]`; can a peer P at the same term grant a PreVote that disrupts L (no other condition violated)? | LeaseImpliesLoyalty | 1 |
| MC2 | A follower votes for candidate A in term T; can the same follower also vote for a different candidate B in term T+1 without waiting one election_timeout? | Combined with sub-optimal randomization, no safety bug expected, but a related liveness invariant should expose if "two elections per election_timeout" is reachable | 1 |
| MC3 | `elect_self` sends vote RPCs and crashes BEFORE `set_term_and_votedfor` succeeds; on recovery, can the same node vote for a different candidate in the same term without violating ElectionSafety? | VoteAfterPersist; if expressed correctly, ElectionSafety | 2 |
| MC4 | `step_down(term, ...)` advances `_current_term` in memory but `set_term_and_votedfor` fails; the node continues serving RPCs with the new in-memory term; on crash, in-memory term is lost. Can this lead to ElectionSafety violation or to two leaders in the same term? | ElectionSafety / StepDownPersistInvariant | 2 |
| MC5 | `MixedMetaStorage::set_term_and_votedfor` writes `single` synchronously, schedules `merged` async; crash between them. Can recovery select a stale vote (i.e., vote not appearing in single but appearing in merged)? | MetaStoreCoherence | 2 |
| MC6 | `LocalSnapshotStorage::close` deletes the target then renames temp; crash between. Can `init()` on restart find neither old nor new snapshot? Combined with `_log_manager->set_snapshot` already having truncated logs — can the resulting node be unrecoverable? | SnapshotCompletesOrRestores | 2 / 4 |
| MC7 | Replicator has pipeline depth 2 with cache disabled; RPC2 returns `!success` first, then RPC1 returns `!success` second. Trace whether `_next_index` underruns `_applied_id` and the `unsafe_truncate_suffix` precondition fails. | ReplicatorIndexInvariant | 3 |
| MC8 | After a snapshot lands at `last_included_index = K` while `_logs_in_memory` still has entries `[K-100, K+100]`, replicator routes to InstallSnapshot for a follower at `_next_index = K-50`, even though logs are physically available. Can this cascade into a livelock of repeated installs? | ReplicatorIndexInvariant / VirtualVsPhysicalLog | 3 |
| MC9 | Two concurrent `install_snapshot` RPCs (e.g., from a stale leader and a new leader after term advance). The interrupt path advances `_term` but the in-flight `on_snapshot_load_done` finalizes the *old* leader's snapshot under the new term. Does the post-load state agree with any committed configuration in the new term? | SnapshotInstallMonotone + LeaderCompleteness | 4 |
| MC10 | A witness receives `transfer_leadership_to` (TimeoutNow) and becomes leader. Within the stepdown_timer window, it may accept client `apply()`, advance commit index, or issue InstallSnapshot. Can a committed data entry exist whose only durable replica is the witness? | WitnessNeverHoldsData | 5 |
| MC11 | PreVote candidate's `_follower_lease.expired()` is the gate, but the new term it elects to is `local + 1`. If the local term equals the current leader's term, the leader receiving this PreVote grants it (Issue #365). Trace whether this can be exploited under any timing to disrupt a healthy leader. | LeaseImpliesLoyalty | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested approach |
|----|-------------|-------------------|
| T1 | `ProtoBufFile::load` errno conflation (#403) — write fault-injection unit test that returns EAGAIN, EIO, ENOENT, parse-failure | Mock `FileAdaptor::read` |
| T2 | `LocalSnapshotStorage::close` returning 0 for non-EIO failures (#499) — inject EEXIST / generic errno | Mock `_fs->rename`/`delete_file` |
| T3 | Pipeline-disabled-cache `_next_index` over-decrement (#421) — unit test driving Replicator with two pre-baked failure responses | Test harness around `Replicator` |
| T4 | `_virtual_first_log_id` divergence from `_first_log_index` (#528) — write a test that compacts logs with `_virtual_first_log_id` lagging the physical head and verifies replicator does not InstallSnapshot | Integration test |
| T5 | `list_peers` during joint (#498) — assert `list_peers` includes union during joint | Unit test |
| T6 | `set_error_and_rollback` running closures after error (#439) — observe `done->Run()` invocation count | Unit test |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| R1 | `node.cpp:884-888` short-circuit on `_conf.conf.equals(new_conf)` ignoring `_conf.old_conf` | Add joint-state-aware equality |
| R2 | `node.cpp:1114` `handle_timeout_now_request` no `is_witness()` guard | Add explicit guard when `!FLAGS_raft_enable_witness_to_leader` |
| R3 | `node.cpp:2660-2670` install-snapshot handler no ABA re-check after `lck.unlock()` | Add term re-check |
| R4 | `replicator.cpp:472-479` success path doesn't step down on higher response term | Add step-down call symmetric to the `!success` branch |
| R5 | `log.cpp:706-731` empty-bootstrap branch wipes log on any ENOENT-mapped error | Distinguish open-failure from missing-file |
| R6 | PR #530 step-down deadlock | Review and merge upstream |
| R7 | Persistence ordering in `elect_self` — comment "// TODO: outof lock" should be paired with persisting BEFORE sending RPCs | Refactor |

## 7. Reference Pointers

- **Analysis report**: `/home/ubuntu/Specula/case-studies/braft_3/.specula-output/analysis-report.md` (detailed findings with citations and coverage statistics).
- **Key source files**:
  - `src/braft/node.cpp` (3689 LOC; main state machine; sections of interest: `handle_pre_vote_request` 2118-2174, `handle_request_vote_request` 2176-2288, `elect_self` 1685-1750, `step_down` 1801-1880, `check_witness` 843-853, `unsafe_register_conf_change` 855-888)
  - `src/braft/replicator.cpp` (1602 LOC; `_on_rpc_returned` 360-525, `_fill_common_fields` 527-554, `_send_entries` 641-730, `_install_snapshot` 770-870, `_on_install_snapshot_returned` 880-940, `_on_block_timedout_in_new_thread` 221-228)
  - `src/braft/log_manager.cpp` (970 LOC; `set_snapshot` 619-680, `clear_bufferred_logs` 682-688, `unsafe_get_term` 703-727, `unsafe_truncate_suffix` 307-332)
  - `src/braft/snapshot.cpp` + `snapshot_executor.cpp` (`LocalSnapshotStorage::close` 613-671, `register_downloading_snapshot` 530-590, `interrupt_downloading_snapshot` 600-611)
  - `src/braft/lease.cpp` (`FollowerLease::votable_time_from_now` 105-127, `expire` 134-141, `expired` 129-132)
  - `src/braft/ballot_box.cpp` (`commit_at` 53-95, `clear_pending_tasks` 96-107)
  - `src/braft/raft_meta.cpp` (`MixedMetaStorage::set_term_and_votedfor` 270-292, `FileBasedSingleMetaStorage` 465-481/528-551, `KVBasedMergedMetaStorageImpl` 747-765)
  - `src/braft/raft.proto` (full RPC schema)
- **Open GitHub issues (top-priority)**: #421, #479, #515, #528 (Replicator family); #492, #463, #405, #365 (Lease family); #462, #499, #403 (Persistence family); #410, #498 (Config family); #445 (Witness); #530/#531 (Step-down deadlock).
- **Closed historical fixes used as mechanism evidence** (NOT modeling targets): commits `3cfb1f1`, `d23dd8c`, `858b26d`, `68cd340`, `247d5cc`, `b9e1293`, `a171a95`, `5dd342f`, `c50fa09`, `a7738d7`, `bd2387a`, `10cd9e3`, `740908b`, `04092b2`, `8d0128e`, `0366072`, `ed36465`, `42cfd9a`, `857f4fb`, `b24858c`, `902cc43`.
- **Reference paper**: Ongaro & Ousterhout, "In Search of an Understandable Consensus Algorithm (Extended Version)", 2014.
- **Existing braft TLA+ instrumentation**: commit `9c2df3d` "feat: Add TLA+ trace instrumentation" on the sibling `braft` case-study branch (`/home/ubuntu/Specula/case-studies/braft/artifact/braft`).
