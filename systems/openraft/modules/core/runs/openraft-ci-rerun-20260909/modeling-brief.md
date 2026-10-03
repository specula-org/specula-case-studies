# Modeling Brief: databendlabs/openraft

## Incremental Update 2026-09-09

- Old source revision: `0f4e195474e4a902b391b99497bdbb3535b89749`; new source revision: `15f927e1358d41ffc1297516f781029dbf8ca86a`.
- Disposition: **MODEL_CHANGE_REQUIRED**. The update changes Scenario 2's durable-completion boundary and initialization's response/election ordering.
- IO callback bridge: `IOFlushed::Notify` now stores an `IOId` plus a watch sender and `io_completed()` synchronously updates the watch value with error permanence (`openraft/src/storage/callback.rs:80-115`). A new `io_completion_forwarder()` later converts the latest watch value into `Notification::LocalIO` or `Notification::StorageError` (`openraft/src/raft/mod.rs:315-359`). The model must therefore split durable append completion from LocalIO delivery and permit watch coalescing of intermediate successful IOIds.
- Initialization ordering: `Engine::initialize()` now appends the initial membership and returns without electing (`openraft/src/engine/engine_impl.rs:190-205`). `RaftCore::handle_initialize()` queues the initialization response behind `Condition::IOFlushed` for the accepted IOId, then calls `engine.elect()` (`openraft/src/core/raft_core.rs:697-726`). The model keeps ordinary election as a separate action and adds update-focused harness coverage for the new order.

## 1. System Overview

- **System/category**: OpenRaft 0.10.0, Rust, incremental target `15f927e1358d41ffc1297516f781029dbf8ca86a` from old input `0f4e195474e4a902b391b99497bdbb3535b89749`; about 17,210 production LOC. **Category A (Distributed / Message-Passing)**, crash-fault Raft, not BFT.
- **Protocol/deviations**: Raft with joint/extended membership, learners, transfer, ReadIndex, lease reads, and snapshots. Default ordered `(term,node_id)` LeaderId permits successive leaders in one term; committed may persist; a leader may resume without election; commit, heartbeat, and replication paths are separate (`openraft/src/docs/faq/02-core-concepts/01-differences-from-raft.md:1-7`).
- **Concurrency/storage**: one RaftCore/Engine loop executes ordered log-store commands while SM, snapshot, per-peer replication/heartbeat, vote/read, and tick tasks run independently; Engine can advance ahead of `accepted/submitted/flushed` durability (`openraft/src/raft/mod.rs:345-420`, `openraft/src/raft_state/io_state.rs:23-72`).

## 2. Scenarios

### Scenario 1: Restored Leadership Before Application Recovery

**Mechanism**: A persisted committed self-vote can restore Leader state while the state machine and optional persisted committed pointer are behind the state previously observed by clients.

**Evidence**:

- Historical: commits `86b46a08` and `681d04da` repeatedly repaired sole-leader restart and replay; issue #1511 identifies the remaining transient-state/read hazard.
- Code analysis: startup recovers vote, optional committed, snapshot, and state machine separately (`openraft/src/storage/helper.rs:87-148`), while `Engine::startup()` immediately restores a persisted leader (`openraft/src/engine/engine_impl.rs:145-159`). `save_committed()` is optional (`openraft/src/storage/v2/raft_log_storage.rs:57-85`).

**Affected code paths**: `StorageHelper::get_initial_state`, `Engine::startup`, `VoteHandler::become_leader`, `RaftCore::handle_ensure_linearizable_read`, `Linearizer::try_await_ready`.

**Suggested modeling approach**:

- Variables: `persistentVote`, `persistentLog`, `persistedCommitted`, `snapshotLast`, `smApplied`, `role`, `recoveryReady`, `readBarrier`.
- Actions: split `Crash`, `Restart`, `RestoreSnapshot`, `ReplayCommitted`, `RestoreLeader`, `ReconfirmCommit`, `ReadIndex`, and `LeaseRead`; permit restart between each durable/volatile step.
- Granularity: leader role restoration and read admission must be separate from snapshot restore, replay, and quorum re-confirmation. Trace vote, recovered pointers, role, read policy/barrier, and applied cursor.

**Priority**: High<br>
**Rationale**: High-severity live design boundary, dense repair history, and a direct crash/recovery/read interaction well suited to state exploration.

### Scenario 2: Persistence-before-Ack in the Decoupled I/O Pipeline

**Mechanism**: Engine state, durable vote/log state, cluster commit, saved commit, state-machine apply, and client/RPC responses advance at different atomicity boundaries.

**Evidence**:

- Historical: `ee460f37` fixed RPC replies before vote/log flush; `a9f696a9` fixed committing a leader no-op without the normal durable path; `674e78aa` fixed snapshot installation before conflicting-log cleanup.
- Code analysis: command execution marks append submitted before the callback-backed watch update (`openraft/src/core/raft_core.rs:1839-1870`), waits on `Condition::IOFlushed` for protocol replies (`openraft/src/engine/command.rs:251-335`), and persists committed before dispatching apply (`openraft/src/core/raft_core.rs:1928-1937`).

**Affected code paths**: `Engine::handle_append_entries`, `VoteHandler::update_vote`, `RaftCore::run_engine_commands`, `RaftRuntime::run_command`, `IOProgress`, `sm::Worker::apply`.

**Suggested modeling approach**:

- Variables: `acceptedIO`, `submittedIO`, `flushedIO`, `clusterCommitted`, `localCommitted`, `savedCommitted`, `applySubmitted`, `smApplied`, `pendingResponses`.
- Actions: split accept/submit/flush/respond; split quorum grant, local commit, save-commit, apply, and completion notification. Model notification reorder only where the storage contract permits it.
- Granularity: one TLA+ action per durability or channel-visible boundary. Trace IOId `(vote,log)`, command kind, condition, and response release.

**Priority**: High<br>
**Rationale**: Three Critical historical fixes and the implementation's central architectural deviation from atomic textbook handlers.

### Scenario 3: Extended Membership Transactions and Session Fencing

**Mechanism**: Membership becomes effective on append, commits later, may require joint then uniform entries, and concurrently initiated two-stage API requests can carry conflicting per-request intent.

**Evidence**:

- Historical: `c8fccb22`, `a5064712`, `d5c2c55c`, and `56486a60` fixed outstanding-change, quorum, committed/effective, and replication-progress errors.
- Current: open issue #1395 documents cross-request `retain` pollution and mixed voter/node Batch semantics. The API releases between joint and uniform phases (`openraft/src/raft/api/management.rs:61-124`); membership stores only committed/effective (`openraft/src/raft_state/membership_state/mod.rs:21-51`) and rebuilds sessions on effective change (`openraft/src/engine/handler/replication_handler/mod.rs:56-112`).

**Affected code paths**: `ManagementApi::change_membership`, `ChangeHandler::apply`, `Membership::change/next_coherent`, `MembershipState::{append,commit,truncate}`, `ReplicationHandler::rebuild_replication_streams`, replication-session validation.

**Suggested modeling approach**:

- Variables: `committedMembership`, `effectiveMembership`, `membershipLog`, `changeRequests`, `requestPhase`, `retainIntent`, `replicationSession`, `matchIndex`.
- Actions: `ProposeMembership`, `CommitMembership`, `FlattenJoint`, concurrent request start/resume, leader change, session rebuild, and stale progress delivery.
- Granularity: separate append/effective, durable commit, API completion, and phase-two submission. Trace request ID, change/retain, voter/learner sets, membership log ID, and session ID.

**Priority**: High<br>
**Rationale**: Five substantive history fixes plus an acknowledged open concurrency/design defect; quorum and crash composition can affect safety, not only API ergonomics.

### Scenario 4: Snapshot, Membership, and Purge Lifecycle

**Mechanism**: Snapshot build/install, membership reconciliation, log truncation, and purge are separately scheduled and can observe different logical and durable frontiers.

**Evidence**:

- Historical: `674e78aa`, `04e40606`, `26dc8837`, and `1a781e1b` repaired crash order and snapshot/log boundaries; later issues #1808 and #1829 confirm this checkout's snapshot-membership and trigger-state paths remained fragile.
- Code analysis: install updates in-memory snapshot/membership before worker completion, while purge/response wait on snapshot progress (`openraft/src/engine/handler/following_handler/mod.rs:249-302`); background build completion races other snapshot advancement (`openraft/src/engine/engine_impl.rs:524-565`); policy bookkeeping precedes trigger acceptance (`openraft/src/core/raft_core.rs:737-747`).

**Affected code paths**: `FollowingHandler::install_full_snapshot`, `SnapshotHandler`, `LogHandler`, `sm::Worker::{build_snapshot,install}`, `StorageHelper::restore_from_snapshot`, snapshot transport.

**Suggested modeling approach**:

- Variables: `snapshotAccepted/submitted/flushed`, `snapshotMembership`, `buildingSnapshot`, `purgeUpto`, `durablePurged`, `retainedMembershipLogs`.
- Actions: split receive/install/complete/purge; allow background build and install to interleave with apply and membership append; model snapshot data as metadata only.
- Granularity: preserve the command-queue barrier explicitly. Trace snapshot last-log/membership, build accepted/rejected, install completion, and purge.

**Priority**: High<br>
**Rationale**: One Critical historical crash fix and a dense recovery × membership × compaction cross-product. Closed upstream fixes are context, not targets to recreate.

### Scenario 5: Independent Heartbeat, Replication, and Read Paths

**Mechanism**: Separate tasks enforce related leader/vote/session rules through different paths, so delayed replies and path-specific guards can diverge.

**Evidence**:

- Historical: #1500/`2bdfae5d` fixed heartbeat/replication response reordering; `a9e2fc46` restored heartbeat feedback. Later issues #1747 and #1805 expose read/transfer guard differences in this pinned source.
- Code analysis: heartbeat has a per-peer worker and watch channel (`openraft/src/core/heartbeat/worker.rs:26-49`); progress is fenced by leader vote plus membership log ID (`openraft/src/core/raft_core.rs:1742-1762`); ReadIndex creates separate quorum tasks (`openraft/src/core/raft_core.rs:305-444`).

**Affected code paths**: `HeartbeatWorker::do_run`, `ReplicationCore`, `RaftCore::{handle_ensure_linearizable_read,handle_notification}`, `Leader::last_quorum_acked_time`.

**Suggested modeling approach**:

- Variables: `network`, `heartbeatEvent`, `replicationInflight`, `sessionId`, `clockAck`, `readQuorum`, `leaderLease`.
- Actions: independent heartbeat and payload AppendEntries send/receive, loss/reorder/timeout, stale notification, ReadIndex quorum, and lease read.
- Granularity: send, receive, and RaftCore notification handling are distinct. Trace send time, response kind, vote, membership/session, and ack set.

**Priority**: Medium<br>
**Rationale**: Important for faithful reads and liveness, but leadership-transfer details should remain a focused follow-up rather than enlarge the initial baseline.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Advanced and standard LeaderId modes | Default OpenRaft election safety differs from textbook per-term uniqueness | Parameterize leader IDs; check standard ElectionSafety conditionally and ordered-vote safety in both modes |
| Crash/recovery and optional persisted commit | Scenario 1 | Split persistent/volatile state; restore snapshot and replay before/alongside leader restoration |
| Accepted/submitted/flushed pipeline | Scenario 2 | Explicit IOId cursors, command conditions, callbacks, and response queue |
| Effective/committed extended membership | Scenario 3 | Two membership variables, request/phase state, coherent quorum transitions, session fencing |
| Snapshot metadata lifecycle | Scenario 4 | Metadata-only build/install/purge actions with worker completion barriers |
| Async network, heartbeat, replication, ReadIndex, lease | Scenario 5 | Explicit messages/tasks, nondeterministic loss/reorder/timeout, conservative send-time lease |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Reverted pre-fix implementations | Closed fixes are evidence only; recreating them adds no system information |
| Snapshot bytes/chunk buffers and concrete codecs | Model session/offset outcome and metadata; byte transport belongs in tests |
| Rust generics, allocator/channel/metrics details, numeric/unwrap defects | Implementation/performance or local robustness concerns with no protocol-state payoff |
| Faulty storage that violates ordered durable writes or immediate reader visibility | Explicit environment assumptions; exercise with conformance tests, not valid-Raft actions |
| `allow_log_reversion` and misbound NodeId→endpoint mappings | Opt-in unsafe/operator-fault behavior outside the crash-fault model |
| Leadership-transfer internals in baseline V1 | Known pinned-head defects have later regressions/fixes; add only after the five core mechanisms stabilize |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Ordered vote identity | `leaderId`, `voteCommitted` | Represent default advanced and standard modes | 1, 5 |
| Durable recovery | `persistentVote`, `persistentLog`, `persistedCommitted`, `smApplied`, `recoveryReady` | Expose crash windows and restart admission | 1, 2 |
| I/O pipeline | `acceptedIO`, `submittedIO`, `flushedIO`, `pendingResponses` | Preserve durability-before-ack boundaries | 2 |
| Decoupled commit/apply | `clusterCommitted`, `localCommitted`, `savedCommitted`, `applySubmitted` | Represent commit-only propagation and replay | 1, 2 |
| Extended membership transaction | `committedMembership`, `effectiveMembership`, `changeRequests`, `requestPhase` | Model coherent joint/uniform transitions and concurrency | 3 |
| Replication session | `sessionId`, `matchIndex`, `inflight` | Fence stale vote/membership progress | 3, 5 |
| Snapshot lifecycle | `snapshotProgress`, `snapshotMembership`, `buildingSnapshot`, `purgeUpto` | Compose install/build/purge/recovery | 4 |
| Read/lease control paths | `readBarrier`, `readQuorum`, `clockAck`, `leaderLease` | Check ReadIndex and lease safety | 1, 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| StandardElectionSafety | Safety | In standard LeaderId mode, at most one leader per term | Standard Raft |
| OrderedVoteSafety | Safety | Persisted/accepted votes never decrease; a leader is established only by an effective-membership quorum | 1, 3, 5 |
| LogMatching | Safety | Equal log ID at an index implies identical prefix | Standard Raft |
| LeaderCompleteness | Safety | Every committed entry is present in every later valid leader log | Standard Raft, 1-4 |
| StateMachineSafety | Safety | Nodes never apply different commands at the same index | Standard Raft, 1, 2, 4 |
| DurableBeforeAck | Safety | Granted votes and accepted AppendEntries are not acknowledged before the corresponding IOId is flushed | 2 |
| CursorOrder | Safety | `purged <= snapshot <= applied <= applySubmitted <= localCommitted <= accepted`; `applySubmitted`, `flushed`, and durable log IO stay below submitted log IO | 2, 4 |
| RecoveryReadSafety | Safety | A successful documented read barrier never exposes state older than a previously completed operation | 1, 5 |
| MembershipAgreement | Safety | Committed membership at one log ID is unique and every transition preserves quorum coherence | 3 |
| EffectiveMembershipBacked | Safety | Effective membership is backed by retained log/snapshot state and is not solely derived from purged data | 3, 4 |
| SessionFence | Safety | Progress/clock acknowledgments affect state only for the current `(leader vote,membership log)` session | 3, 5 |
| SnapshotPurgeSafety | Safety | A purge occurs only after a durable snapshot covers the purged prefix and its membership | 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | Can a fast-restored leader complete documented ReadIndex/LeaseRead before replay or quorum re-confirmation covers all previously observable state? | RecoveryReadSafety | 1, 5 |
| MC-2 | Can two membership requests separated by a leader crash/change and snapshot recovery commit incompatible or non-request-owned successors despite pairwise coherent steps? | MembershipAgreement, OrderedVoteSafety | 3, 4 |
| MC-3 | Can a delayed heartbeat/read acknowledgment cross a leader or membership-session change and still establish a lease/read quorum? | SessionFence, RecoveryReadSafety | 5 |
| MC-4 | Across crash points between saved commit, apply, snapshot install, and purge, can recovery lose the only source for a committed entry? | LeaderCompleteness, SnapshotPurgeSafety | 1, 2, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | #1395 concurrent `retain` intent and mixed voter/node Batch behavior | Deterministic barrier test between joint and uniform phases with two callers |
| TV-2 | Snapshot numeric boundaries: threshold addition overflow, `LogsSinceLast(0)`, and zero chunk size | Boundary tests for `SnapshotPolicy::should_snapshot` and chunk-transfer progress; validate/reject unsafe values |
| TV-3 | Bounded built-in term types violate `term < term.next()` at their maximum (`vote/raft_term/raft_term_impls.rs:3-19`) | Property test every built-in term type at boundary values |
| TV-4 | Transfer to self/non-voter/unreachable target has no validation or rollback | Integration tests with elections disabled; require rejection or bounded recovery |
| TV-5 | Unbounded RaftCore→state-machine channel can grow without bound under slow apply | Load test with blocked SM and sustained commits; bound or expose backpressure |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | `Notification::ReplicationProgress` display reverses `has_payload` labels (`core/notification.rs:114-116`) | Correct labels and add a display test |
| CR-2 | `SetNodes` can violate identity binding by design (`change_members.rs:38-54`) | Keep explicit operator precondition; consider safer typed API |
| CR-3 | `allow_next_revert` docs say absent target is ignored, implementation returns `NodeNotFound` (`raft/trigger.rs:97-108`, `engine/handler/replication_handler/mod.rs:233-245`) | Align documentation or API behavior |
| CR-4 | Purge threshold adds user-sized values without saturation (`engine/handler/log_handler/mod.rs:92`) | Audit numeric bounds alongside PR #2075 |
| CR-5 | Public `StorageHelper::get_initial_state()` panics if `with_id()` was omitted on a fresh store (`storage/helper.rs:61-94`) | Make ID required by construction or document/return an error |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/analysis-report.md`
- **Key source**: core/Engine `openraft/src/core/raft_core.rs:144-202`, `openraft/src/engine/engine_impl.rs:62-99`; recovery/IO `openraft/src/storage/helper.rs:83-223`, `openraft/src/raft_state/io_state.rs:23-142`; membership `openraft/src/raft_state/membership_state/mod.rs:21-185`; replication/snapshot `openraft/src/replication/mod.rs:82-105`, `openraft/src/engine/handler/following_handler/mod.rs:230-302`.
- **Issues/reference**: #1395, #1511, #1500, #1747, #1805, #1808, #1829, #1601, #1872; open PR #2075; Ongaro and Ousterhout (2014), summarized in `raft-essentials.md`.
