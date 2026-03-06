# Modeling Brief: brpc/braft

## 1. System Overview

- **System**: brpc/braft -- C++ Raft consensus library used by PolarDB-X, AliSQL, and other Baidu/Alibaba distributed systems
- **Language**: C++, ~22,000 LOC total, ~6,000 LOC core logic (node.cpp, replicator.cpp, ballot_box.cpp, log_manager.cpp)
- **Protocol**: Raft with PreVote, joint consensus config changes, leader lease, leadership transfer, witness nodes
- **Key architectural choices**:
  - **Two-sided leader lease**: `LeaderLease` (leader checks quorum contacts) and `FollowerLease` (follower blocks votes while leader recently seen). Leader's `FollowerLease` is always reset, creating an asymmetry (node.cpp:1949)
  - **Heartbeat shares the replication path** but has a separate response handler (`_on_heartbeat_returned` vs `_on_rpc_returned`) with different checks
  - **bthread-based concurrency**: Node mutex (`_mutex`) protects all state transitions; replicators run in separate bthreads with bthread_id-based synchronization
  - **Snapshot install response does NOT check term** (replicator.cpp:895-919), deferring to heartbeat for term discovery
  - **`set_term_and_votedfor()` is a single atomic API** but called under the node mutex (TODO comments acknowledge this bottleneck at node.cpp:1737, 1841, 2269)
- **Concurrency model**: Single node mutex for state machine; per-peer replicator bthreads; single-threaded execution queues for disk I/O and FSM apply

## 2. Bug Families

### Family 1: Leader Lease Asymmetry & Election Disruption (HIGH)

**Mechanism**: The leader's `FollowerLease` is reset on `become_leader()` (node.cpp:1949), so the leader always grants PreVote requests. Followers maintain their lease and reject PreVotes. This asymmetry means a rebooted or partitioned follower can disrupt a stable leader by sending PreVote to the leader directly (who grants it) while being blocked by other followers. Combined with missing lease renewal after voting, this creates windows where election safety may be undermined.

**Evidence**:
- Historical: Issue #365 / PR #366 (open) -- leader grants PreVote to rebooted node, causing unnecessary leader change. Confirmed by maintainer PFZheng.
- Historical: Issue #492 (open) -- `handle_pre_vote_request` checks `_follower_lease` on followers but NOT `_leader_lease` on leaders
- Historical: Issue #405 / PR #406 (open) -- follower lease not renewed after voting, allowing rapid re-election
- Historical: Issue #465 (open) -- election timer not reset after step_down by term change
- Historical: PR #262 (merged) -- leader lease blocks transfers in quorum>2 clusters
- Historical: PR #298 (merged, d23dd8c) -- followers wait for lease when old leader already stepped down
- Code analysis: node.cpp:2150 -- PreVote handler checks `_follower_lease.votable_time_from_now()` which is always 0 on the leader (since `_follower_lease` was reset at become_leader)
- Code analysis: node.cpp:2199-2208 -- disrupted_leader lease bypass only in real vote handler, NOT in PreVote handler

**Affected code paths**:
- `handle_pre_vote_request()` (node.cpp:2109-2174) -- follower lease check, no leader lease check
- `handle_request_vote_request()` (node.cpp:2176-2289) -- disrupted_leader lease bypass
- `handle_pre_vote_response()` (node.cpp:1503-1581) -- lease rejection handling
- `FollowerLease::votable_time_from_now()` (lease.cpp:111-123) -- vote blocking
- `become_leader()` (node.cpp:1949) -- resets follower lease

**Suggested modeling approach**:
- Variables: `leaderLease[Server]`, `followerLease[Server]`, `leaseTimestamp[Server -> Time]`
- Actions: Split RequestVote into PreVote and RealVote. Add `FollowerLeaseExpire` and `FollowerLeaseRenew` actions. Model leader not checking lease on PreVote grant.
- Key: PreVote at leader always grants (follower lease reset); PreVote at followers blocks if lease valid. Model the asymmetry explicitly.
- Granularity: PreVote and RealVote as separate actions; lease as a per-server boolean.

**Priority**: High
**Rationale**: 5+ unfixed issues, confirmed by maintainers. The asymmetry is systematic and affects all election paths. TLA+ can explore whether a specific interleaving of lease expiry, PreVote, and election can violate ElectionSafety or cause unbounded election disruption.

---

### Family 2: Snapshot Response Missing Term Check (HIGH)

**Mechanism**: The `_on_install_snapshot_returned()` handler (replicator.cpp:870-933) does NOT check `response->term()`, unlike the AppendEntries response handler which checks term in both success and failure paths. Additionally, the AppendEntries success path (replicator.cpp:472-479) has an incomplete term check: `response->term() != r->_options.term` logs an error and resets but does NOT step down. These create windows where a stale leader continues operating after a new term exists.

**Evidence**:
- Code analysis: replicator.cpp:895-919 -- snapshot response handler, comment says "Let heartbeat do step down"
- Code analysis: replicator.cpp:472-479 -- successful AppendEntries with mismatched term does not step down
- Code analysis: replicator.cpp:315-333 -- heartbeat response DOES check term (correct)
- Code analysis: replicator.cpp:418-436 -- AppendEntries failure DOES check term (correct)
- Historical: 12 bug-fix commits to replicator.cpp -- most error-prone file in the codebase

**Affected code paths**:
- `Replicator::_on_install_snapshot_returned()` (replicator.cpp:870-933) -- no term check at all
- `Replicator::_on_rpc_returned()` (replicator.cpp:472-479) -- incomplete term check on success
- `Replicator::_on_heartbeat_returned()` (replicator.cpp:315-333) -- correct term check
- `Replicator::_on_timeout_now_returned()` (replicator.cpp:1161-1173) -- correct term check

**Suggested modeling approach**:
- Actions: Split AppendEntries response into `HandleAppendEntriesResponse` (checks term) and `HandleHeartbeatResponse` (checks term). Add `HandleInstallSnapshotResponse` (no term check). Add `HandleAppendEntriesSuccessStaleResponse` (no step-down).
- Key: Model that snapshot response does NOT trigger step-down even when response term is higher. Check if the leader can serve writes or advance commit index while stale.

**Priority**: High
**Rationale**: Three of four response handlers check terms; the snapshot handler does not. This is a clear code path inconsistency. replicator.cpp is the #1 bug hotspot file. The window between snapshot response and next heartbeat could allow stale-leader operations.

---

### Family 3: Non-Atomic Persistence & Crash Recovery (MEDIUM)

**Mechanism**: Critical state (term, votedFor, log entries) is updated in memory before being persisted to disk. If the process crashes in the window between in-memory update and persistence, or if persistence fails silently, the recovered state diverges from the pre-crash in-memory state. In `elect_self()`, RPCs are sent to peers before term/votedFor is persisted.

**Evidence**:
- Code analysis: node.cpp:1705-1707 vs 1738 -- `_current_term++` and `_voted_id = _server_id` in memory; RPCs sent at line 1735; persist at line 1738
- Code analysis: node.cpp:1844-1849 -- persist failure in `step_down()` logged but not handled (TODO comment: "report error")
- Code analysis: node.cpp:1740-1747 -- persist failure in `elect_self()` resets `_voted_id` but NOT `_current_term`
- Historical: PR #311 (merged, ce77c4d) -- term check on init to catch corrupted metadata
- Historical: Issue #462 / PR #461 (open, CRITICAL) -- snapshot error masking causes unrecoverable data loss on full disk
- Historical: PR #437 (merged) -- configuration entries not force-synced in batch ops
- Historical: PR #371 (open) -- data loss with raft_sync enabled but raft_sync_segments disabled
- Historical: PR #436 (merged) -- corrupted in-progress log prevents startup after crash
- Code analysis: raft_meta.cpp:270-292 -- MixedMetaStorage dual-write: file succeeds then LevelDB fails = inconsistency
- Code analysis: raft_meta.cpp:473-479 -- in-memory state updated before `save()` in FileBasedSingleMetaStorage

**Affected code paths**:
- `elect_self()` (node.cpp:1681-1749) -- RPCs before persist, in-memory before persist
- `step_down()` (node.cpp:1793-1875) -- silent persist failure
- `handle_request_vote_request()` (node.cpp:2263-2280) -- persist before response
- `FileBasedSingleMetaStorage::set_term_and_votedfor()` (raft_meta.cpp:465-481)
- `MixedMetaStorage::set_term_and_votedfor()` (raft_meta.cpp:270-292)

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor` (separate from in-memory `currentTerm`, `votedFor`)
- Actions: Split `HandleRequestVoteRequest` grant into `PersistVoteAndRespond` (normal) and add crash between in-memory update and persist. Model `Crash` that recovers from persisted state.
- Also model RPCs-before-persist in elect_self: `BecomeCandidate` updates memory and sends RPCs; `PersistCandidateState` persists; `CrashBeforePersist` restores old state.
- Key: Check if a node can vote for two different candidates in the same term due to crash between memory update and persist.

**Priority**: Medium
**Rationale**: Multiple historical crash-recovery bugs. The `elect_self()` RPCs-before-persist window is a concrete crash scenario. The silent persist failure in `step_down()` is acknowledged by developers (TODO comment). TLA+ with crash actions is ideal for this class of bugs.

---

### Family 4: Configuration Change Safety (MEDIUM)

**Mechanism**: During configuration changes, quorum calculations, election participation, and commit tracking interact in subtle ways. The ballot box force-commits preceding entries when a config-change entry commits with reduced quorum, with an explicit comment that this is "not well proved right now." A node removed from the configuration can still request votes. Joint consensus restart can deadlock the cluster.

**Evidence**:
- Code analysis: ballot_box.cpp:79-88 -- force-commit of preceding entries during config change, comment: "not well proved right now"
- Historical: PR #407 (open) -- membership change failure when cluster restarts after joint stage; no leader election possible
- Historical: Issue #498 (open) -- `list_peers` returns wrong config during reconfiguration
- Historical: Issue #410 (closed) -- BallotBox commit mechanism during membership change concern
- Code analysis: node.cpp:2215-2280 -- `handle_request_vote_request` has NO configuration membership check
- Code analysis: node.cpp:2109-2174 -- `handle_pre_vote_request` has NO configuration membership check
- Code analysis: node.cpp:3296-3301 -- single-peer change optimization skips joint consensus
- Code analysis: node.cpp:1626 -- PreVote checks `_conf.contains(_server_id)` but nothing prevents receiving votes from removed nodes

**Affected code paths**:
- `BallotBox::commit_at()` (ballot_box.cpp:49-96) -- force-commit loop
- `ConfigurationCtx::next_stage()` (node.cpp:3292-3325) -- stage transitions
- `unsafe_apply_configuration()` (node.cpp:2085-2108) -- config change proposal
- `handle_request_vote_request()` (node.cpp:2176-2289) -- no membership check
- `become_leader()` (node.cpp:1972-1973) -- initial config entry as noop

**Suggested modeling approach**:
- Variables: `config[Server]` (current config), `pendingConfig[Server]` (uncommitted config change), joint consensus state
- Actions: `ProposeConfigChange`, `CommitConfigChange` (with force-commit of preceding entries), `CrashDuringJointConsensus`, elections using config for quorum
- Key: Model that removed nodes can still participate in elections. Model the force-commit mechanism.
- Granularity: One action per config change stage (catching_up -> joint -> stable)

**Priority**: Medium
**Rationale**: Unfixed #407 (joint-stage deadlock) is a production safety concern. The "not well proved" force-commit mechanism is an explicit developer acknowledgment of uncertainty. TLA+ model checking can explore whether the force-commit is safe under all interleavings.

---

### Family 5: Replicator Lifecycle & Concurrency Bugs (LOW for TLA+)

**Mechanism**: Complex bthread_id lifecycle with lock ordering violations between NodeImpl._mutex and replicator bthread_ids causes deadlocks and resource leaks. Multiple threads (replicators, disk thread, timer callbacks) access shared state with insufficient synchronization.

**Evidence**:
- Historical: PR #257 (merged, 68cd340) -- deadlock from not destroying replicator on higher term
- Historical: Commit 43f9dcd -- forgotten bthread_id unlock in install_snapshot
- Historical: Commit 247d5cc -- missing unlock in _continue_sending
- Historical: Issue #323 (open) -- deadlock during step_down under high concurrency
- Historical: Issue #309 (open) -- NodeImpl._mutex / LogManager._mutex lock ordering violation
- Historical: Issue #456 (open) -- NodeImpl._mutex deadlock
- Historical: Issue #241 / PR #242 (open) -- NodeImpl destruction deadlock
- Historical: Commit c8e6848 -- reference count race in replicator start

**Priority**: Low (for TLA+)
**Rationale**: These are implementation-level concurrency bugs (lock ordering, reference counting, bthread lifecycle) that are not suitable for TLA+ modeling. They are better addressed by code review, static analysis, and concurrency testing tools. The bthread_id mechanism is too implementation-specific to model at the protocol level.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Two-sided leader lease (LeaderLease + FollowerLease) | Family 1: root cause of 5+ unfixed issues, confirmed asymmetry | `leaderLease`, `followerLease` variables; `FollowerLeaseExpire/Renew` actions; leader always grants PreVote |
| PreVote as separate phase | Family 1: PreVote/RealVote have different lease and term behaviors | Separate `PreVote` and `RequestVote` actions with different guards |
| Disrupted leader lease bypass | Family 1: mechanism for breaking lease deadlock during transfer | Track `disruptedLeader` in vote requests |
| Missing snapshot response term check | Family 2: code path inconsistency between 4 response handlers | `HandleInstallSnapshotResponse` action without term check guard |
| Non-atomic persist in elect_self | Family 3: RPCs sent before persist, crash window | Split into `BecomeCandidate` (memory + RPCs) and `PersistCandidateState` with `Crash` between |
| Silent persist failure | Family 3: step_down continues on persist failure | Model persist as potentially failing; node continues with divergent state |
| Crash and recovery | Family 3: validates persistence correctness | `Crash` action resets volatile state, recovers from `persistedTerm`/`persistedVotedFor` |
| Joint consensus config changes | Family 4: force-commit and quorum interactions | `config`, `pendingConfig` variables; force-commit of preceding entries |
| Removed nodes can vote | Family 4: no membership check in vote handlers | Allow any server to send/receive votes regardless of config |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| bthread_id lifecycle / deadlocks | Family 5: implementation-level concurrency, not protocol logic |
| BallotBox mutex contention | Performance concern, not safety |
| Snapshot file transfer mechanics | Data plane, not consensus protocol |
| Log segment management | Storage implementation detail, not protocol |
| memory_order_relaxed issues | CPU architecture concern, not protocol logic |
| Witness nodes | Orthogonal feature, not involved in any identified bug family |
| Pipeline replication | Optimization; the pipeline's implicit ordering assumption relies on log matching, which is already checked by standard invariants |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Two-sided lease | `leaderLease`, `followerLease`, `leaseTimestamp` | Capture leader/follower lease asymmetry | Family 1 |
| PreVote phase | (split in actions, no new vars beyond `preVoteGranted`) | Distinguish PreVote from real vote for different lease/term handling | Family 1 |
| Disrupted leader tracking | `disruptedLeader` in vote requests | Model lease bypass on leader transfer/disruption | Family 1 |
| Response path variants | (split in actions) | Model that snapshot response doesn't check term | Family 2 |
| Persisted vs volatile state | `persistedTerm`, `persistedVotedFor` | Model crash between memory update and disk persist | Family 3 |
| Persist failure | `persistFailed` flag | Model step_down continuing after persist failure | Family 3 |
| Dual configuration | `config`, `pendingConfig`, `configStage` | Capture joint consensus and force-commit mechanism | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard + all families |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard + Family 4 |
| LeaseImpliesLeadership | Safety | If leader's lease check passes, no other leader exists in that term | Family 1 |
| NoLeaseBypassWithoutDisruption | Safety | FollowerLease is only bypassed when actual disrupted_leader info matches | Family 1 |
| TermDiscoveryCompleteness | Safety | A leader that receives a response with term > currentTerm eventually steps down | Family 2 |
| VoteSafetyAcrossCrash | Safety | A node never votes for two different candidates in the same term, even across crashes | Family 3 |
| PersistBeforeAct | Safety | Term and votedFor are persisted before the node acts on them (or crash recovery is safe) | Family 3 |
| ConfigChangeSafety | Safety | At most one uncommitted config change at a time; force-commit preserves LogMatching | Family 4 |
| RemovedNodeSafety | Safety | A removed node participating in elections does not violate ElectionSafety | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Leader grants PreVote due to reset FollowerLease; disrupts stable cluster | LeaseImpliesLeadership | Family 1 |
| MC-2 | Follower lease not renewed after voting; two leaders within lease window | ElectionSafety or LeaseImpliesLeadership | Family 1 |
| MC-3 | Snapshot response with higher term doesn't trigger step-down; stale leader operates | TermDiscoveryCompleteness | Family 2 |
| MC-4 | AppendEntries success with mismatched term doesn't trigger step-down | TermDiscoveryCompleteness | Family 2 |
| MC-5 | Crash after elect_self() sends RPCs but before persist; node votes differently on restart | VoteSafetyAcrossCrash | Family 3 |
| MC-6 | Persist failure in step_down(); node continues at new term but old term on disk | PersistBeforeAct | Family 3 |
| MC-7 | Force-commit of preceding entries during config change with reduced quorum | LogMatching, LeaderCompleteness | Family 4 |
| MC-8 | Joint-stage restart deadlock: no configuration can form quorum | Liveness (eventual leader election) | Family 4 |
| MC-9 | Removed node wins election via votes from outside current config | ElectionSafety | Family 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Snapshot error masking on full disk (#462) | Fault injection: fill disk during snapshot save, verify node recovers |
| TV-2 | MixedMetaStorage dual-write crash window | Unit test: mock LevelDB to fail after file write succeeds |
| TV-3 | raft_sync_meta=false with raft_sync=false loses metadata on power loss | Integration test with simulated power failure |
| TV-4 | BallotBox `memory_order_relaxed` store vs `memory_order_acquire` load mismatch | Thread sanitizer test with concurrent commit_at and last_committed_index reads |
| TV-5 | Log segment truncation with concurrent snapshot install | Race condition test with concurrent truncate_suffix and install_snapshot |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Three `TODO: outof lock` comments for persistence under mutex (node.cpp:1737, 1841, 2269) | Performance optimization: async persist path |
| CR-2 | `FIXME: it's buggy` reading `_disk_id` without lock (log_manager.cpp:551) | Verify single-threaded access guarantee is documented |
| CR-3 | `FIXME: race with set_peer` in snapshot load (snapshot_executor.cpp:268) | Verify set_peer is never called during normal operation |
| CR-4 | No configuration membership check in vote handlers | Discuss with maintainers if this is intentional |
| CR-5 | `_saving_snapshot` stuck if `done` is NULL on save failure (snapshot_executor.cpp:178-185) | Add cleanup path for NULL done case |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/braft/analysis-report.md`
- **Key source files**:
  - `artifact/braft/src/braft/node.cpp` (core state machine, 3689 lines)
  - `artifact/braft/src/braft/replicator.cpp` (replication + heartbeat, 1603 lines)
  - `artifact/braft/src/braft/ballot_box.cpp` (commit tracking, 188 lines)
  - `artifact/braft/src/braft/log_manager.cpp` (log management, 970 lines)
  - `artifact/braft/src/braft/lease.cpp` (leader lease, 149 lines)
  - `artifact/braft/src/braft/raft_meta.cpp` (persistence, 866 lines)
  - `artifact/braft/src/braft/snapshot_executor.cpp` (snapshot orchestration, 709 lines)
- **GitHub issues**: #365, #492, #405, #465 (Family 1); #462 (Family 3 snapshot); #407, #498, #410 (Family 4)
- **GitHub PRs (unfixed)**: #366, #406, #461, #407, #371
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
