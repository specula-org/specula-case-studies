# Analysis Report: brpc/braft

## Table of Contents
1. [Codebase Reconnaissance](#1-codebase-reconnaissance)
2. [Bug Archaeology](#2-bug-archaeology)
3. [Deep Analysis](#3-deep-analysis)
4. [Bug Families](#4-bug-families)
5. [Excluded Findings](#5-excluded-findings)

---

## 1. Codebase Reconnaissance

### 1.1 System Overview

braft is a C++ Raft implementation built on top of Baidu's brpc framework. It is used in production by PolarDB-X, AliSQL, and other distributed systems.

**Scale**: ~22,000 LOC across ~60 files. Core logic: ~6,000 LOC.

### 1.2 Core Modules

| Component | Files | LOC | Description |
|-----------|-------|-----|-------------|
| State Machine | node.cpp, node.h | 4,229 | Elections, state transitions, RPC handlers |
| Replication | replicator.cpp, replicator.h | 1,984 | Log replication, heartbeat, snapshot install |
| Commit Tracking | ballot_box.cpp, ballot.cpp | 455 | Quorum tracking, commit index advancement |
| Log Management | log_manager.cpp, log.cpp | 2,272 | In-memory log, disk write batching, segments |
| Persistence | raft_meta.cpp | 1,064 | Term/votedFor storage (file + LevelDB) |
| Snapshot | snapshot.cpp, snapshot_executor.cpp | 1,979 | Save/load/install snapshots |
| Lease | lease.cpp, lease.h | 239 | Leader and follower lease |
| Configuration | configuration_manager.cpp, configuration.h | 511 | Membership management, joint consensus |
| FSM Caller | fsm_caller.cpp | 832 | State machine apply queue |

### 1.3 Architecture

```
Client Request
     |
     v
NodeImpl (node.cpp)           <-- Single mutex (_mutex) protects all state
  |-- State: FOLLOWER/CANDIDATE/LEADER/TRANSFERRING
  |-- _current_term, _voted_id (volatile + persisted via raft_meta)
  |-- _conf (ConfigurationEntry: conf + old_conf for joint consensus)
  |
  |-- [LEADER] ReplicatorGroup
  |     |-- Replicator per peer (bthread, bthread_id synchronization)
  |     |     |-- _send_entries() / _send_empty_entries(is_heartbeat)
  |     |     |-- _on_rpc_returned() / _on_heartbeat_returned()
  |     |     |-- _install_snapshot() / _on_install_snapshot_returned()
  |     |
  |     |-- BallotBox (commit tracking)
  |           |-- commit_at(first_index, last_index, peer)
  |           |-- Ballot per entry (quorum from new + old config)
  |
  |-- LogManager
  |     |-- _logs_in_memory (ring buffer)
  |     |-- disk_thread (bthread ExecutionQueue, batched writes)
  |     |-- SegmentLogStorage (append-only segments on disk)
  |
  |-- FSMCaller (bthread ExecutionQueue, serialized apply)
  |     |-- do_committed() -> user FSM::on_apply()
  |     |-- do_snapshot_save() / do_snapshot_load()
  |
  |-- SnapshotExecutor
  |     |-- do_snapshot() -> save
  |     |-- install_snapshot() -> download + load
  |
  |-- Timers: ElectionTimer, VoteTimer, StepdownTimer, SnapshotTimer
  |
  |-- LeaderLease (leader checks quorum contacts)
  |-- FollowerLease (follower blocks votes while leader recently seen)
```

### 1.4 Concurrency Model

- **Node mutex (`_mutex`)**: All state transitions, term changes, and vote grants are under this single mutex
- **Replicator bthreads**: Each peer has a replicator running in its own bthread, synchronized via `bthread_id`
- **Disk thread**: Single ExecutionQueue for LogManager disk I/O; batches writes
- **FSM thread**: Single ExecutionQueue for state machine operations; serialized apply
- **Timer threads**: bthread timers for election/vote/stepdown/snapshot timeouts

### 1.5 Persistence Model

- **Term + VotedFor**: Atomic write via `set_term_and_votedfor()` API. Three backends:
  - FileBasedSingleMetaStorage: write-to-temp-then-rename (atomic at FS level)
  - KVBasedMergedMetaStorage: LevelDB WriteBatch (atomic at DB level)
  - MixedMetaStorage: writes to BOTH sequentially (non-atomic between the two)
- **Log entries**: SegmentLogStorage with append-only segments. fsync policy configurable.
- **Snapshots**: Directory-per-snapshot with protobuf metadata.

### 1.6 Bug Hotspot Files

From git history mining:

| Rank | File | Bug-Fix Commits |
|------|------|-----------------|
| 1 | replicator.cpp | 12 |
| 2 | node.cpp | 10 |
| 3 | snapshot.cpp | 6 |
| 4 | log_manager.cpp | 5 |
| 5 | log.cpp | 4 |

---

## 2. Bug Archaeology

### 2.1 Git History Findings

Total significant bug-fix commits analyzed: 31
- Critical: 8
- High: 15
- Medium: 8

#### Replicator Bugs (12 commits)

| ID | Commit | Summary | Root Cause | Severity |
|----|--------|---------|------------|----------|
| R1 | 68cd340 | Deadlock: missing _destroy() on higher term | Lock ordering: replicator lock vs node mutex | Critical |
| R2 | 43f9dcd | Deadlock: forgotten bthread_id unlock in install_snapshot | Missing unlock on duplicate snapshot reader path | Critical |
| R3 | 247d5cc | Missing bthread_id unlock in _continue_sending | Missing unlock on ETIMEDOUT + _wait_id != 0 path | Critical |
| R4 | 902cc43 | State not pre-set to INSTALLING_SNAPSHOT | Throttled snapshot install with wrong state | High |
| R5 | 643f0d7 | Pipeline race with readonly mode | Duplicate replication triggers from concurrent paths | High |
| R6 | b24858c | Duplicate install_snapshot from readonly toggle | _reader assertion failure from concurrent install | High |
| R7 | 42cfd9a | Node ref leak during step_down in install_snapshot | _node ref and _catchup_closure not cleaned | High |
| R8 | c5a3068 | Memory leak in _prepare_entry | entry->Release() missing on EREADONLY path | Medium |
| R9 | 124789d | Snapshot reader leak on load_meta failure | _reader not closed before error report | Medium |
| R10 | c8e6848 | Race in replicator AddRef before assignment | AddRef after bthread_id_create but before bthread starts | High |

#### Node / Election Bugs (10 commits)

| ID | Commit | Summary | Root Cause | Severity |
|----|--------|---------|------------|----------|
| N1 | b9e1293 | UAF in handle_timeout_now_request | Closure invoked before request read | Critical |
| N2 | d23dd8c | Leader election blocked by follower lease | Followers wait for lease when old leader stepped down | High |
| N3 | 740908b | CHECK core from grant-self timer race | Timer fires after state transition from CANDIDATE | Critical |
| N4 | 3cfb1f1 | Vote/transfer fails with lease + quorum>2 | Followers reject votes due to valid lease | High |
| N5 | 725242d | Election failure from vote timeout behavior | Disruptive candidate keeps raising term | High |
| N6 | 3300a83 | Duplicated node removes wrong node from manager | Identity check missing in _remove_node | High |
| N7 | ce77c4d | Missing term check on init | Corrupted metadata allows term=0 with higher-term logs | High |

#### Snapshot Bugs (9 commits)

| ID | Commit | Summary | Root Cause | Severity |
|----|--------|---------|------------|----------|
| S1 | d8e4e21 | Writer close failure not propagated | Error silently ignored, corrupted snapshot loaded | Critical |
| S2 | 5204e09 | Wrong read size in snapshot transfer | File hole returns 0 bytes, treated as full read | Critical |
| S3 | 3d2e65c | Incomplete files not cleaned on writer init | Orphan files from crash during do_snapshot | High |
| S4 | e8a991e | SaveSnapshotDone leak when done is NULL | Guard prevents cleanup closure from running | Medium |
| S5 | ed605b3 | read_partly flag mishandled in transfer | Offset calculation wrong when flag disabled | Medium |
| S6 | 8afd3e6 | Snapshot URI error kills node | Transient error escalated to fatal | Medium |

#### Log Manager Bugs (5 commits)

| ID | Commit | Summary | Root Cause | Severity |
|----|--------|---------|------------|----------|
| L1 | 5dd342f | get_term() crash on stale index | Missing index < first_log_index check | Critical |
| L2 | 04092b2 | disk_id.term zero after empty storage init | _disk_id not updated from snapshot | High |
| L3 | 857f4fb | _last_but_one_snapshot_id hole | Persistent class member creates gaps in term lookups | High |
| L4 | c50fa09 | _virtual_first_log_id not reset in clear_bufferred_logs | Stale value after prefix truncation | Medium |
| L5 | 8ef6fdb | disk_id update in set_snapshot causes corner cases | Memory log entries incorrectly considered flushed | High |

#### Log Storage Bugs (4 commits)

| ID | Commit | Summary | Root Cause | Severity |
|----|--------|---------|------------|----------|
| LS1 | 10cd9e3 | Truncate suffix ordering violates crash safety | Front-to-back truncation creates non-contiguous segments | Critical |
| LS2 | a49557e | Single-entry segment rejected as invalid | Off-by-one: first_index >= last_index should be > | Medium |
| LS3 | bd2387a | Configuration entries not synced immediately | RAFT_SYNC_BY_BYTES policy applies to config entries | High |

#### Other Bugs

| ID | Commit | Summary | Root Cause | Severity |
|----|--------|---------|------------|----------|
| F1 | a15f5a4 | Wrong condition for on_configuration_committed | old_peers != NULL should be == NULL | High |
| F2 | 382441b | max_committed_index not updated in batched processing | Empty COMMITTED case in switch | High |
| M1 | efa0712 | Coredump in concurrent raft group creation | scoped_refptr by-value copy race | High |

### 2.2 GitHub Issues & PRs

#### Unfixed Bugs (confirmed, with proposed but unmerged fixes)

| Issue/PR | Summary | Severity | Component |
|----------|---------|----------|-----------|
| #462/#461 | Snapshot error masking causes unrecoverable data loss on full disk | Critical | Snapshot |
| #365/#366 | Leader grants PreVote to rebooted node | High | Election/Lease |
| #492 | Leader doesn't check leader lease on PreVote | High | Election/Lease |
| #405/#406 | Follower lease not renewed after voting | Medium-High | Election/Lease |
| #465 | Election timer not reset after step_down by term change | Medium-High | Election |
| #407 | Membership change failure after joint-stage restart | High | Configuration |
| #371 | Data loss with raft_sync + raft_sync_segments disabled | High | Log Storage |
| #323 | Deadlock during step_down under high concurrency | Medium-High | NodeImpl |
| #309 | NodeImpl/LogManager lock ordering violation | Medium-High | Concurrency |
| #456 | NodeImpl._mutex deadlock | Medium-High | Concurrency |
| #241/#242 | NodeImpl destruction deadlock | Medium-High | Lifecycle |
| #498 | list_peers returns wrong config during reconfiguration | Medium | Configuration |
| #421 | Pipeline + NoCache: incorrect log truncation on out-of-order responses | Medium | Replicator |
| #479 | prev_log_index < first_log_index assertion failure | Medium-High | Log Manager |
| #515 | LogManager::unsafe_truncate_suffix crash | Medium | Log Manager |
| #494 | Follower with cleared data not triggering snapshot fetch | Medium | Snapshot |

#### Design Defects

| Issue | Summary |
|-------|---------|
| #365, #463, #492 | Leader does not maintain _follower_lease, creating asymmetric lease behavior |
| #518 | Memory log unbounded growth under partition |
| #468 | Leader cannot serve reads during transfer_leadership |
| #292 | Follower with cleared data can rejoin and cause silent data loss |

#### Verified False Positives

| Issue | Summary | Verdict |
|-------|---------|---------|
| #357 | Unpersisted data applied to FSM | FALSE: disk queue serialization ensures persistence |
| #197 | Data loss when clearing ClosureQueue during stepdown | FALSE: on_apply decoupled from closures |
| #367 | Segfault under heavy load | HARDWARE: resolved by switching machines |

---

## 3. Deep Analysis

### 3.1 State Transitions (node.cpp)

#### step_down() (node.cpp:1793-1875)

**Operation sequence**:
1. Guard: `is_active_state(_state)` (line 1801)
2. Timer cleanup by current state (lines 1805-1819)
3. Reset leader_id (line 1822)
4. `_state = STATE_FOLLOWER` -- in-memory only (line 1826)
5. Config/cache cleanup (lines 1828-1835)
6. **Persist only if `term > _current_term`** (lines 1838-1850):
   ```cpp
   if (term > _current_term) {
       _current_term = term;
       _voted_id.reset();
       //TODO: outof lock
       status = _meta_storage->set_term_and_votedfor(term, _voted_id, _v_group_id);
       if (!status.ok()) {
           // TODO report error
           LOG(ERROR) << ...;
       }
   }
   ```
7. Replicator cleanup (lines 1853-1862)
8. Start election timer (line 1874)

**Finding**: Persist failure at line 1844 is silently logged (TODO: report error). Node continues with in-memory state diverging from disk.

#### elect_self() (node.cpp:1681-1749)

**Critical sequence**:
```
Line 1705: _state = STATE_CANDIDATE       (in-memory)
Line 1706: _current_term++                 (in-memory)
Line 1707: _voted_id = _server_id          (in-memory)
Line 1711: _vote_timer.start()             (timer)
Line 1719-1723: unlock, get last_log_id, relock
Line 1735: request_peers_to_vote()         (RPCs SENT)
Line 1738: set_term_and_votedfor()         (PERSIST)
```

**Finding**: RPCs are sent at line 1735 before persistence at line 1738. A crash between these lines means the node told peers about a new term but didn't persist its vote.

**Finding**: If persist fails (lines 1740-1747), `_voted_id` is reset but `_current_term` is NOT rolled back. The node continues operating at the incremented term with no votedFor persisted.

### 3.2 Vote Handling Comparison

#### handle_request_vote_request (node.cpp:2176-2289) checks:
1. Active state (line 2180)
2. Parse candidate_id (line 2192)
3. **Disrupted leader lease expire** (lines 2199-2208)
4. Stale term rejection (line 2215)
5. Log up-to-date check (line 2236)
6. **Follower lease check** (lines 2238-2251)
7. Step down on higher term (lines 2254-2260)
8. Grant vote + persist (lines 2263-2280)

#### handle_pre_vote_request (node.cpp:2109-2174) checks:
1. Active state (line 2113)
2. Parse candidate_id (line 2125)
3. Stale term rejection (line 2135)
4. Log up-to-date check (implied in grantable calculation)
5. **Follower lease check** (line 2150)
6. Set disrupted flag if this node is leader (line 2170)

**Missing in PreVote vs RealVote**:
- No disrupted_leader lease bypass (lines 2199-2208 only in RealVote)
- No step_down on higher term (correct for PreVote design)
- No configuration membership check (missing in BOTH)

### 3.3 Replication Response Handlers Comparison

| Handler | File:Line | Term Check | Step-Down | Notes |
|---------|-----------|------------|-----------|-------|
| `_on_rpc_returned` (failure) | replicator.cpp:418-436 | `response->term() > r->_options.term` | YES | Correct |
| `_on_rpc_returned` (success) | replicator.cpp:472-479 | `response->term() != r->_options.term` | **NO** | Logs error, resets, but no step-down |
| `_on_heartbeat_returned` | replicator.cpp:315-333 | `response->term() > r->_options.term` | YES | Correct |
| `_on_install_snapshot_returned` | replicator.cpp:895-919 | **NONE** | **NO** | Comment: "Let heartbeat do step down" |
| `_on_timeout_now_returned` | replicator.cpp:1161-1173 | `response->term() > r->_options.term` | YES | Correct |

**3 of 5 handlers correctly check terms; 2 have gaps.**

### 3.4 Persistence Atomicity

`set_term_and_votedfor()` is always called as a single operation (term + votedFor together). The underlying storage backends handle atomicity:

- **FileBasedSingleMetaStorage**: write-to-temp + fsync + rename (atomic on POSIX)
- **KVBasedMergedMetaStorage**: LevelDB WriteBatch (atomic in WAL)
- **MixedMetaStorage**: Writes to file THEN LevelDB sequentially. **NOT atomic between the two.** Crash between writes creates inconsistency. Reconciliation on restart at raft_meta.cpp:294-397.

**Critical**: When `raft_sync=false` AND `raft_sync_meta=false`, the file-based storage does NOT fsync before rename. A power loss could corrupt the metadata.

### 3.5 Leader Lease Implementation

Two-class system:

**LeaderLease** (lease.cpp:58-82):
- Tracks `_last_active_timestamp` from quorum replicator contacts
- Valid if `now < _last_active_timestamp + _election_timeout_ms`
- SUSPECT state triggers a recheck via `NodeImpl::get_leader_lease_status()` which may call `step_down()`

**FollowerLease** (lease.cpp:111-123):
- Tracks `_last_leader_timestamp` from last AppendEntries/heartbeat
- Blocks votes until `_election_timeout_ms + _max_clock_drift_ms` after last leader contact
- `become_leader()` resets FollowerLease to empty (line 1949)

**Asymmetry**: When a PreVote request arrives at the leader, `_follower_lease.votable_time_from_now()` returns 0 (lease expired because it was reset). The leader grants the PreVote. There is no `_leader_lease` check in the PreVote handler.

### 3.6 Ballot Box Force-Commit

ballot_box.cpp:79-88:
```cpp
// When removing a peer off the raft group which contains even number of
// peers, the quorum would decrease by 1, e.g. 3 of 4 changes to 2 of 3. In
// this case, the log after removal may be committed before some previous
// logs, since we use the new configuration to deal the quorum of the
// removal request, we think it's safe to commit all the uncommitted
// previous logs, which is not well proved right now
for (int64_t index = _pending_index; index <= last_committed_index; ++index) {
    _pending_meta_queue.pop_front();
}
```

All entries from `_pending_index` to `last_committed_index` are force-committed when ANY entry in the range achieves quorum. During config changes that reduce quorum, a later entry can commit before earlier entries have quorum under the old configuration. The comment explicitly says this is "not well proved."

### 3.7 Developer Signals

| Location | Signal | Content |
|----------|--------|---------|
| node.cpp:1737 | TODO | `outof lock` (persist in elect_self under mutex) |
| node.cpp:1841 | TODO | `outof lock` (persist in step_down under mutex) |
| node.cpp:1848 | TODO | `report error` (persist failure silently ignored) |
| node.cpp:1963 | TODO | `check return code` (add_replicator ignored in become_leader) |
| node.cpp:2269 | TODO | `outof lock` (persist in vote handler under mutex) |
| log_manager.cpp:551 | FIXME | `it's buggy` (reading _disk_id without lock) |
| ballot_box.cpp:52 | FIXME | `The critical section is unacceptable` (global mutex in commit_at) |
| snapshot_executor.cpp:268 | FIXME | `race with set_peer, not sure if this is fine` |

---

## 4. Bug Families

### Family 1: Leader Lease Asymmetry & Election Disruption

**Mechanism**: Asymmetric lease checking between leader and follower nodes in vote/prevote handlers.

**Historical bugs**: N2 (d23dd8c), N4 (3cfb1f1), N5 (725242d)
**Unfixed issues**: #365, #492, #405, #465
**Code findings**: node.cpp:1949, node.cpp:2150, node.cpp:2199-2208

**Assessment**: 5+ unfixed issues, 3 historical fixes, confirmed by maintainers. TLA+ highly suitable.

### Family 2: Response Handler Path Inconsistency

**Mechanism**: Four response handler paths with inconsistent term checking; snapshot handler has no term check.

**Code findings**: replicator.cpp:870-933 (no term check), replicator.cpp:472-479 (incomplete term check)
**Historical context**: replicator.cpp has 12 bug-fix commits -- the most error-prone file.

**Assessment**: Clear path inconsistency pattern. TLA+ can model the different handler behaviors.

### Family 3: Non-Atomic Persistence

**Mechanism**: In-memory state updated and RPCs sent before persistence; persist failures silently ignored.

**Code findings**: node.cpp:1705-1738 (RPCs before persist), node.cpp:1844-1849 (silent failure)
**Historical bugs**: N7 (ce77c4d), LS1 (10cd9e3), LS3 (bd2387a)
**Unfixed issues**: #462, #371

**Assessment**: Multiple historical crash-recovery bugs. Classic TLA+ crash-action modeling.

### Family 4: Configuration Change Safety

**Mechanism**: Force-commit mechanism during quorum reduction; joint consensus restart deadlock.

**Code findings**: ballot_box.cpp:79-88 ("not well proved"), node.cpp:2176-2289 (no membership check)
**Unfixed issues**: #407, #498

**Assessment**: The "not well proved" comment is a direct invitation for formal verification.

### Family 5: Replicator Lifecycle & Concurrency

**Mechanism**: bthread_id lifecycle, lock ordering violations, reference count races.

**Historical bugs**: R1-R10 (12 commits)
**Unfixed issues**: #323, #309, #456, #241

**Assessment**: Implementation-level concurrency. Not suitable for TLA+ (too low-level).

---

## 5. Excluded Findings

### 5.1 False Positives Investigated and Ruled Out

| Finding | Why Excluded |
|---------|-------------|
| "Heartbeat doesn't check term" (similar to hashicorp/raft) | VERIFIED FALSE: braft's `_on_heartbeat_returned()` (replicator.cpp:315) DOES check `response->term()` and steps down. Unlike hashicorp/raft, braft's heartbeat response handler is correct. |
| Issue #357: unpersisted data applied to FSM | VERIFIED FALSE: disk queue serialization ensures persistence before apply callback. |
| Issue #197: data loss on ClosureQueue clear | VERIFIED FALSE: on_apply is decoupled from closures; committed logs always trigger on_apply. |
| Ballot double-grant | VERIFIED FALSE: ballot.cpp:52-54 uses `found` flag to prevent double-counting. |
| Joint consensus quorum calculation | VERIFIED CORRECT: ballot.cpp requires majority from BOTH old and new configurations via independent quorum tracking. |

### 5.2 Not Modeled (with rationale)

| Item | Why Not Modeled |
|------|----------------|
| bthread_id lifecycle | Implementation-level concurrency (Family 5), not protocol logic |
| BallotBox mutex contention (FIXME) | Performance concern, not safety |
| Snapshot file transfer mechanics | Data plane, not consensus |
| Log segment management | Storage implementation detail |
| memory_order_relaxed issues | CPU architecture concern |
| Witness nodes | Orthogonal feature, no identified bug family |
| Pipeline replication ordering | Relies on log matching (already verified by standard invariants) |
| Log manager _virtual_first_log_id | Implementation optimization for avoiding unnecessary snapshot installs |
