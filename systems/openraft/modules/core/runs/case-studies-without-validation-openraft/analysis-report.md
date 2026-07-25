# openraft Code Analysis Report

## 1. Investigation Scope & Method

### Code Analyzed
- **Repository**: `datafuselabs/openraft` (Rust)
- **Core library**: `openraft/src/` — 36,735 lines of non-test code; 46,701 total including tests
- **Key modules analyzed line-by-line**:
  - `engine/engine_impl.rs` (880 lines) — Core consensus state machine
  - `engine/handler/vote_handler/mod.rs` (~250 lines) — Vote/election handling
  - `engine/handler/replication_handler/mod.rs` (~475 lines) — Replication & commitment
  - `engine/handler/following_handler/mod.rs` (~320 lines) — Follower log handling
  - `engine/handler/leader_handler/mod.rs` — Leader operations
  - `core/raft_core.rs` (2,273 lines) — Main runtime event loop
  - `storage/helper.rs` (431 lines) — Crash recovery & state reconstruction
  - `storage/callback.rs` (237 lines) — IO completion callbacks
  - `raft_state/io_state.rs` (291 lines) — IO progress tracking
  - `raft_state/mod.rs` (517 lines) — Raft state management
  - `replication/` (1,713 lines) — Async replication tasks
  - `membership/` (1,077 lines) — Joint consensus membership

### Methods Used
1. **Static code analysis**: Line-by-line reading of all core modules
2. **Git history mining**: ~120 bug-fix commits analyzed, 9 critical commits examined in full diff
3. **GitHub issue verification**: 30+ issues read with full comment threads via `gh issue view --comments`
4. **Cross-reference verification**: Every finding checked against compensating mechanisms elsewhere in the codebase

---

## 2. Codebase Overview

### Architecture Summary

openraft separates the consensus algorithm from I/O through a **command-based architecture**:

```
Application → Raft API → RaftMsg (MPSC) → RaftCore event loop → Engine (pure state machine) → Commands → Storage/Network
```

- **Engine** (`engine/`): Pure, deterministic state machine. Receives events, updates in-memory state, emits `Command` objects. No I/O.
- **RaftCore** (`core/raft_core.rs`): Async event loop that dispatches API messages to the Engine, executes Commands against storage/network, and handles notifications.
- **Replication** (`replication/`): One async task per follower, communicates with RaftCore via watch channels and MPSC notifications.
- **Storage**: Trait-based abstraction (`RaftLogStorage` + `RaftStateMachine`) — pluggable backends.

### Concurrency Model
- **Single-threaded Engine**: The `Engine` struct is driven synchronously within the `RaftCore` event loop. No concurrent access.
- **Async runtime**: Tokio-based by default, with runtime abstraction for alternatives (monoio, compio).
- **Per-follower replication tasks**: Each spawned as an async task communicating via watch channels (for broadcasts) and MPSC (for notifications back).
- **No `RwLock` usage**: All shared state uses `Mutex` (both `std::sync::Mutex` for synchronous data and runtime-abstracted `MutexOf` for async contexts).
- **842 lines reference concurrency primitives** across the codebase.

### Key Deviations from the Raft Paper
1. **Leader lease**: Followers reject vote requests while their leader's lease is active, preventing unnecessary elections.
2. **Leader survival across restart**: A restarted node with a committed vote for itself immediately resumes as leader without re-election.
3. **No pre-vote**: openraft does not implement the pre-vote optimization. It relies on leader lease to prevent disruption from partitioned nodes.
4. **Generalized `Vote` with partial ordering**: Votes are compared using `PartialOrd` rather than simple `(term, candidate_id)` comparison. This allows for more flexible leader ID structures.
5. **Async IO with command batching**: Log appends are buffered and flushed asynchronously via callbacks, rather than synchronously persisted.
6. **Extended membership change**: Uses joint consensus with automatic multi-step transitions toward the target configuration.

---

## 3. Code Analysis Findings

### Finding 1: Linearizable Read Can Return After Leadership Loss

- **Location**: `core/raft_core.rs:509-513`
- **Description**: The linearizable read quorum-confirmation logic is spawned as a fire-and-forget async task:
  ```rust
  // TODO: do not spawn, manage read requests with a queue by RaftCore
  #[allow(clippy::let_underscore_future)]
  let _ = C::spawn(waiting_fu.instrument(tracing::debug_span!("spawn_is_leader_waiting")));
  ```
  The spawned task sends heartbeats to confirm quorum, but if leadership changes while the task is running, it can still confirm and send an `Ok` response to the client. The response includes a `read_log_id` captured *before* spawning (line 333-337), so the client could be told to read from a node that is no longer the leader.
- **Analysis**: This could violate linearizability. If the old leader loses leadership but the detached task still receives quorum acks from a majority (e.g., messages in flight), the client gets a stale `Linearizer`. The TODO at line 509 confirms developers are aware.
- **Verification status**: **Developer-acknowledged issue** (TODO comment)
- **Severity**: High

### Finding 2: `IOFlushed` Callback Has No Drop Guard — Silent Hang if Dropped

- **Location**: `storage/callback.rs:21-37`
- **Description**: The `IOFlushed` enum does not implement `Drop`. If a storage implementation drops the callback without calling `io_completed()`, the `log_progress` flushed cursor never advances. The entire Raft node stalls permanently with no diagnostic.
  ```rust
  pub enum IOFlushed<C> where C: RaftTypeConfig {
      Noop,
      Notify(IOFlushedNotify<C>),
      Signal(OneshotSenderOf<C, Result<(), io::Error>>),
  }
  // No Drop impl
  ```
- **Analysis**: Unlike `OneshotSender` which typically has a `Drop` impl that signals cancellation, `IOFlushed` simply vanishes if dropped. There is no timeout or watchdog. A storage implementation bug that drops the callback (e.g., due to an early return or exception) causes an unrecoverable hang.
- **Verification status**: **Code inconsistency** — the `Signal` variant's `OneshotSender` has its own `Drop`, but `Notify` variant's `WatchSender` does not notify on drop in the same way
- **Severity**: Medium-High

### Finding 3: `establish_leader()` Rebuilds Replication Before Persisting Vote

- **Location**: `engine/engine_impl.rs:663-689`
- **Description**: In the election success path (`establish_leader`), the command ordering is:
  1. Line 675: `rebuild_replication_streams(true)` → `Command::RebuildReplicationStreams`
  2. Line 680: `update_vote()` → `Command::SaveVote`
  3. Line 688: `leader_append_entries([Blank])` → `Command::AppendEntries`

  Replication infrastructure is set up *before* the committed vote is durably persisted. Followers may accept the new leader's vote before the leader has persisted its own vote.
- **Analysis**: If the leader crashes after followers accept the committed vote but before `SaveVote` completes, the leader restarts without knowledge of its own leadership. Followers retain the vote. Raft safety is maintained (the vote exists on a quorum), but the leader cannot immediately re-establish itself. Compare with the `become_leader()` path (vote_handler/mod.rs:168-225), where `SaveVote` is enqueued before `RebuildReplicationStreams`.
- **Verification status**: **Code inconsistency** — two paths to becoming leader have different command orderings
- **Severity**: Medium

### Finding 4: `become_leader()` Does Not Clear Candidate State

- **Location**: `engine/handler/vote_handler/mod.rs:168-225`
- **Description**: When transitioning to leader, `become_leader()` creates a new `Leader` but never clears `self.candidate`:
  ```rust
  pub(crate) fn become_leader(&mut self) {
      // ...creates Leader...
      *self.leader = Some(Box::new(leader));
      // NOTE: self.candidate is NOT set to None
  }
  ```
  Compare with `become_following()` (line 230-244) which clears both `*self.leader = None` and `*self.candidate = None`.
- **Analysis**: In the normal election path (`establish_leader`), the candidate is consumed via `self.candidate.take()` before `become_leader` is called, so this is safe. But in the direct vote receipt path (e.g., leadership transfer), a stale candidate could persist. Stale vote responses matching the old candidate's vote could trigger a second `establish_leader()` call, though guards in `establish_handler` prevent actual double-establishment.
- **Verification status**: **Code inconsistency** — asymmetric cleanup between `become_leader` and `become_following`
- **Severity**: Low-Medium

### Finding 5: Snapshot Installation State Update Before Actual Installation

- **Location**: `engine/handler/following_handler/mod.rs:278-290`
- **Description**: During `install_full_snapshot()`, the engine updates in-memory state before the snapshot is actually installed:
  ```rust
  self.state.accept_log_io(log_io_id.to_io_id());          // Line 278
  self.state.apply_progress_mut().accept(...);              // Line 280
  self.state.snapshot_progress_mut().accept(...);           // Line 281
  self.update_committed_membership(...);                     // Line 283
  self.output.push_command(Command::install_full_snapshot);  // Line 287
  self.state.purge_upto = Some(snap_last_log_id.clone());   // Line 289
  self.log_handler().purge_log();                            // Line 290
  ```
  The `PurgeLog` command is queued *after* `install_full_snapshot`, so command ordering should ensure the snapshot is installed before logs are purged. However, the snapshot installation runs on the state machine worker while log purging runs on the log store — these are separate I/O paths.
- **Analysis**: If the state machine worker is slow and the log store is fast, logs could be purged before the snapshot is fully installed. A crash at this point would lose both logs and snapshot. The `Condition::Snapshot` mechanism should prevent this in practice (the purge waits for snapshot completion), but this depends on correct implementation of the command scheduler.
- **Verification status**: **Robustness issue** — relies on command pipeline ordering across different I/O subsystems
- **Severity**: Medium

### Finding 6: Transient State Machines Silently Lose Committed State on Crash

- **Location**: `storage/v2/raft_log_storage.rs:66-87`, `storage/helper.rs:96-117`
- **Description**: The `save_committed()` and `read_committed()` methods have default no-op implementations:
  ```rust
  async fn save_committed(&mut self, _committed: Option<LogIdOf<C>>) -> Result<(), io::Error> {
      Ok(())  // Default: does nothing
  }
  ```
  For transient (in-memory) state machines, if the implementer does not override `save_committed()`, the committed log ID is never persisted. On crash, committed-but-not-snapshotted entries are silently lost. The recovery code in `helper.rs:113-117` clamps `committed` up to `last_applied`, which may be stale.
- **Analysis**: This is a correctness trap. The default compiles without warning. Issue #1511 (open) explicitly documents this risk for the "leader survival across restart" feature.
- **Verification status**: **Developer-acknowledged issue** (open issue #1511, TODO in helper.rs:113)
- **Severity**: Medium-High

### Finding 7: Heartbeat-Induced Log Reversion Panic (Fixed)

- **Location**: Previously in `core/heartbeat/worker.rs:96-98`
- **Description**: Heartbeats used the cluster's committed log ID as `prev_log_id`, but lagging followers might not have that log, producing a CONFLICT response. If a replication SUCCESS response arrived first (updating `matching`), the stale heartbeat CONFLICT would trigger `assertion failed: conflict < matching.next_index()`.
- **Analysis**: Root cause: using cluster-wide state (committed) for per-follower communication.
- **Verification status**: **Confirmed bug, fixed** — commit `2bdfae5d`. Heartbeats now use per-follower matching log ID.
- **Severity**: High (was a production panic)

### Finding 8: `update_progress()` Error Path Lacks Stream Validation

- **Location**: `engine/handler/replication_handler/mod.rs:297-304`
- **Description**: When a replication error occurs, the inflight state is unconditionally reset:
  ```rust
  Err(err_str) => {
      tracing::warn!("update progress error: {}", err_str);
      if let Some(p) = self.leader.progress.get_mut(&target) {
          p.inflight = Inflight::None;
      };
  }
  ```
  Unlike `try_update_leader_clock()` (line 136) which validates `stream_id`, the error path has no stream ID or inflight ID validation. A stale error response from an old (torn-down) replication stream could clear the inflight state of the current stream.
- **Analysis**: After a membership change triggers `rebuild_replication_streams(false)`, a delayed error from the old stream could disrupt the new stream's in-progress replication. This causes a brief stall or duplicated work, not a safety violation.
- **Verification status**: **Code inconsistency** — asymmetric validation between success and error paths
- **Severity**: Low-Medium

### Finding 9: `save_vote()` Must Fsync But This Is Not Enforced

- **Location**: `storage/v2/raft_log_storage.rs:58-63`
- **Description**: The Raft protocol requires that a node's vote is durably persisted before the vote response is sent. The documentation states: "The vote must be persisted on disk before returning." But this is only a documentation requirement — there is no runtime verification.
  ```rust
  /// The vote must be persisted on disk before returning.
  async fn save_vote(&mut self, vote: &VoteOf<C>) -> Result<(), io::Error>;
  ```
  If a storage implementation buffers the vote in memory without `fsync`, a crash could cause the node to "forget" its vote and vote for a different candidate in the same term, violating Raft's fundamental safety property.
- **Analysis**: This is the most critical correctness requirement in the storage interface. The response conditioning on `Condition::IOFlushed` prevents the vote response from being sent prematurely, but only if `save_vote()` genuinely persists. A buggy storage could silently violate safety.
- **Verification status**: **Design decision** — enforcement delegated to implementers
- **Severity**: High (conceptual — not a bug in openraft but a critical implementer trap)

### Finding 10: Leader Lease Resets on Restart — Latent Linearizable Read Safety Issue

- **Location**: `storage/helper.rs:208-212`
- **Description**: On restart, the vote lease is initialized with zero duration:
  ```rust
  // TODO: If the lease reverted upon restart,
  //       the lease based linearizable read consistency will be broken.
  vote: Leased::new(now, Duration::default(), vote),
  ```
  If a restarted node quickly regains leadership (via the "leader survival across restart" feature), it could serve lease-based reads before the old leader's lease has expired at other nodes, creating a window where two nodes both serve linearizable reads.
- **Analysis**: Currently latent because lease-based reads check `last_quorum_acked` before serving, which is `None` after restart. But the TODO indicates this is a known risk that becomes active if the lease-read path is simplified.
- **Verification status**: **Developer-acknowledged issue** (TODO comment)
- **Severity**: Medium (currently latent)

### Finding 11: `run_engine_commands()` Was Skipped After Channel Drain (Fixed)

- **Location**: `core/raft_core.rs` (previously around line 1244)
- **Description**: `process_raft_msg()` and `process_notification()` returned early (`return Ok(i + 1)`) when the channel was drained, skipping `run_engine_commands()`. Commands generated by message handlers were left unexecuted until the next iteration.
- **Analysis**: This meant that engine state updates from processing messages were not immediately acted upon. Responses could be delayed.
- **Verification status**: **Confirmed bug, fixed** — commit `c37ac891`
- **Severity**: Medium

### Finding 12: `debug_assert`-Only Guards in Release Builds

- **Location**: Multiple locations
- **Description**: Several critical invariants are checked only via `debug_assert!`, which is stripped in release builds:
  - `engine_impl.rs:833-836`: Vote commitment check in `following_handler()` construction
  - `replication_handler/mod.rs:177`: `log_id.is_some()` check in `update_matching()`
  - `following_handler/mod.rs:168`: `since >= last_purged_log_id().next_index()` in `truncate_logs()`
  - `leader_handler/mod.rs` (via `try_leader_handler`): Leader vote >= state vote
- **Analysis**: If any of these invariants are violated in production, the code proceeds with potentially corrupted state rather than failing fast. The most concerning is the vote commitment check: a non-committed vote passed to `following_handler()` would be force-committed via `into_committed()`, potentially corrupting vote state.
- **Verification status**: **Robustness issue**
- **Severity**: Medium

### Finding 13: Snapshot Transmit Handle Never Cleaned Up

- **Location**: `core/raft_core.rs:2182-2183`
- **Description**:
  ```rust
  // TODO: it is not cleaned when snapshot transmission is done.
  node.snapshot_transmit_handle = Some(handle);
  ```
  When a snapshot is sent to a follower, the join handle is stored but never cleaned up. If a new snapshot transmission is triggered, the old handle is silently dropped (orphaning the old task).
- **Analysis**: Resource leak for long-running nodes. Orphaned snapshot transmission tasks may continue sending stale snapshots.
- **Verification status**: **Developer-acknowledged issue** (TODO comment)
- **Severity**: Low-Medium

### Finding 14: `unwrap()` Panic Risk in `rebuild_replication_streams()`

- **Location**: `engine/handler/replication_handler/mod.rs:325`
- **Description**:
  ```rust
  let target_node = membership.get_node(&item.id).unwrap().clone();
  ```
  This `unwrap()` will panic if a node in the progress tracker is not found in the effective membership. While `rebuild_progresses()` is normally called before `rebuild_replication_streams()`, future code changes could break this invariant.
- **Verification status**: **Robustness issue**
- **Severity**: Low

---

## 4. GitHub Issues & PRs Verification

### 4.1 Confirmed Bugs (with verification notes)

| Issue | Title | Status | Root Cause | Severity |
|-------|-------|--------|------------|----------|
| **#1511** | Leader survival across restart causes state machine inconsistency | **OPEN** | `save_committed()` default no-op means committed state is lost on crash; leader resumes serving reads with incomplete state machine | High |
| **#1601** | Panic in replication: `unwrap()` on empty `logs.first()` | Fixed (#1603) | `limited_get_log_entries()` returned empty; production crash in StreamForge (Kafka-like distributed streaming platform) | High |
| **#1500** | Race between heartbeat and replication causes assertion failure | Fixed (`2bdfae5d`) | Heartbeat used committed log ID as `prev_log_id`; lagging follower returned CONFLICT racing with replication SUCCESS | High |
| **#584** | `assertion failed: value > prev` after `change_membership` | Fixed | Stale match-index updates from old replication task arrived after membership change re-spawned new tasks | High |
| **#833** | Replication deadlocks after Unreachable error | Fixed | `drain_events()` blocked forever because both `backoff_drain_events` and `drain_events` were called sequentially instead of exclusively | High |
| **#231** | ReplicationCore doesn't sync commit index to follower | Fixed (#223) | Leader sent AppendEntries with `commit_index=101` but entries up to 102; after follower acked 102, leader never sent updated commit | Medium |
| **#561/#559** | Potential inconsistency when installing snapshot | Fixed | Conflicting logs before `snapshot_meta.last_log_id` not deleted before snapshot install; crash between install and cleanup leaves inconsistent state | High |
| **#607** | Leader doesn't come back after restart (single-node) | Fixed (#609, #640) | Incorrect handling of initial state; `unreachable!()` panic on startup | High |
| **#216** | Assertion failure from stale `self.last_log_id` | Fixed | Replication module used stale log state, triggering `end >= prev_index.next_index()` assertion | Medium |
| **#994** | Assertion failure: `Some(log_id) <= self.committed()` | Closed (user error) | Misconfigured membership caused leader to receive AppendEntries from itself (brain split from wrong node IDs) | N/A |
| **#808** | Leader stuck trying to change membership after node crash | Fixed | `stream_snapshot()` didn't check if input channel was closed; blocked indefinitely | Medium |
| **#387** | `LogIdList::purge()` panic when empty | Fixed | Edge case in purge operation on empty log list | Medium |

### 4.2 Design Defects

| Issue | Title | Notes |
|-------|-------|-------|
| **#1511** | Leader survival across restart inconsistency | By-design feature that creates correctness burden on users; `save_committed()` must be properly implemented |
| **#1467** | Restarted leader briefly reports as leader | Maintainer confirms by-design; recommends checking `last_quorum_acked` field; documented workaround |
| **#898** | Wiped/replaced node causes leader panic | By-design: persisted data must not change; standard Raft limitation; feature flag `loosen-follower-log-revert` added for testing |
| **#918** | Misconfigured node IDs cause cluster failure | No cluster ID verification in protocol; maintainer suggests application-level check; Datafuse itself does not implement this |

### 4.3 Excluded (false/disputed/user-error)

| Issue | Title | Why Excluded |
|-------|-------|-------------|
| **#994** | Raft Core Panicking | Misconfigured membership: duplicate node IDs caused brain split. User error, not a library bug |
| **#1544** | Panic: `limited_get_log_entries` empty | Storage implementation bug: `get_log_reader()` cloned BTreeMap instead of sharing Arc. User's code fixed |
| **#1546** | Assertion failure during learner replication | Duplicate of #1545 |
| **#1329** | New leader election never triggered | User's test environment issue; works correctly in Docker. Likely test timing |
| **#1429** | Previous leader node keeps being candidate | Confirmed network issue by reporter |

### 4.4 Open PRs of Interest

| PR | Title | Status | Relevance |
|----|-------|--------|-----------|
| **#1355** | Move SM worker implementation into SM trait | Open since Apr 2025 | Major architectural change; could affect snapshot/apply ordering |
| **#879** | Add rkyv support | Open since Jun 2023 | Serialization change; low correctness risk |

---

## 5. Historical Bug Patterns

### Bug Hotspot Files
| Module | Bug-fix commits | Assessment |
|--------|----------------|------------|
| `core/` | 34 | **Primary hotspot** — complex event loop with many interactions |
| `engine/` | 19 | State machine logic, election, and commitment |
| `raft/` | 16 | API layer and message handling |
| `replication/` | 12 | High relative to module size (1,713 lines) — error handling prone |
| `membership/` | 9 | Configuration change edge cases |
| `raft_state/` | 7 | IO progress tracking |
| `vote/` | 6 | Vote handling and ordering |
| `storage/` | 5 | Persistence interface |

### Recurring Bug Types

1. **Stale state in concurrent components** (7 bugs): Replication tasks operating with outdated information about membership, log state, or leader status (#584, #216, #231, #1500, #833, #898, heartbeat reversion).

2. **Assertion failures / panics in edge cases** (6 bugs): Missing guards for edge cases like empty logs (#1601), empty LogIdList (#387), purged prev_log_id (#71a290cd), uninitialized leader data (#607), membership change replication (#584).

3. **Crash recovery gaps** (3 bugs): Inconsistency between snapshot and log state on crash (#561/#559), incorrect `last_purged_log_id` loading (#cc8af8cd), committed/applied mismatch on startup.

4. **Command ordering issues** (2 bugs): `run_engine_commands()` skipped after channel drain (#c37ac891), duplicated `SaveCommittedAndApply` (#001e3714), potential deadlock in apply command dependencies (#675fda0d).

5. **Election/vote logic errors** (2 bugs): Vote incorrectly updated on RequestVote response (#b06cbb37), blank-log heartbeat design issues requiring revert to standard heartbeat (#97fa1581).

### Most Refactored Areas
The `Engine` module has undergone significant refactoring:
- Handler pattern introduced to split monolithic engine into focused handlers (vote, leader, following, replication, log, snapshot, server_state, establish)
- IO progress tracking completely rearchitected (IOState with accepted/submitted/flushed stages)
- Vote model refactored with `CommittedVote`/`NonCommittedVote`/`RefVote` types
- Heartbeat system redesigned from blank-log-based to standard empty AppendEntries with leader lease

---

## 6. Summary

### What We Found

#### New Findings from Code Analysis
1. **Linearizable read quorum confirmation can outlive leadership** (Finding 1) — fire-and-forget task spawning allows stale read confirmations
2. **`IOFlushed` callback has no Drop guard** (Finding 2) — a storage implementation bug causes unrecoverable hang
3. **Command ordering inconsistency between election paths** (Finding 3) — `establish_leader` rebuilds replication before persisting vote
4. **Asymmetric state cleanup between `become_leader`/`become_following`** (Finding 4) — candidate state not cleared on leader transition
5. **Snapshot installation updates state before actual install** (Finding 5) — relies on command pipeline ordering across different I/O subsystems
6. **`debug_assert`-only guards for critical invariants** (Finding 12) — vote commitment, log matching, purge boundaries not checked in release
7. **Stale error responses can reset new replication stream's inflight state** (Finding 8) — missing stream ID validation in error path

#### Confirmed Open Bugs
1. **#1511 (OPEN)**: Leader survival across restart can cause state machine inconsistency for external readers when `save_committed()` is not properly implemented

#### Developer-Acknowledged Issues (TODOs)
- Linearizable read should use a managed queue instead of fire-and-forget tasks (`raft_core.rs:509`)
- Lease-based linearizable reads broken on restart (`helper.rs:208-212`)
- Snapshot transmit handle never cleaned up (`raft_core.rs:2182`)
- Leader handler missing vote check (only `debug_assert`) (`leader_handler/mod.rs:53`)
- Multiple untested code paths in replication handler (`replication_handler/mod.rs:232, 412-413`)

### What We Excluded

| Finding | Why Excluded |
|---------|-------------|
| Leader receiving AppendEntries from itself (#994) | User misconfiguration, not a library bug. Application-level cluster ID verification is needed |
| Storage returning empty log entries (#1544) | User's storage implementation cloned data instead of sharing reference |
| `is_expired` using zero-margin lease check | Standard lease-based approach; liveness issue under clock skew but not a safety violation |
| `become_following()` emitting `CloseReplicationStreams` on every heartbeat | Performance issue (TODO acknowledged), not correctness |
| `run_command_threshold = 0` disabling batching | Performance issue (TODO acknowledged), not correctness |
| Balancer starving raft_msg under notification load | Self-correcting over time; liveness not violated |

### Recommended TLA+ Modeling Directions

Based on all findings, the top 5 areas for formal verification:

#### 1. Leader Election and Vote Persistence Ordering
**Why**: The two paths to becoming leader (`establish_leader` vs `become_leader`) have different command orderings for vote persistence vs replication stream setup (Finding 3). Combined with the `save_vote` fsync requirement that cannot be verified at the library level (Finding 9), this is the area most critical for safety.
**Invariants to check**:
- Only one leader per term can have its vote committed
- A leader's committed vote is persisted before any follower accepts it
- No two nodes can both serve as leader in the same term
**Referenced bugs**: #b06cbb37 (vote incorrectly updated on response), #97fa1581 (heartbeat/lease redesign)

#### 2. Snapshot Installation and Log Consistency
**Why**: Snapshot installation involves coordinated updates across state machine and log store with non-atomic crash windows (Finding 5). Historical bugs #559/#561 showed conflicting logs surviving snapshot installation. The recovery code in `helper.rs` has a TODO acknowledging `committed < last_applied` race.
**Invariants to check**:
- After snapshot installation, no log entry conflicts with the snapshot's state
- A crash at any point during snapshot installation leaves the node in a recoverable state
- Log purging never removes entries that the snapshot doesn't cover
**Referenced bugs**: #559, #561, #543, #531, #cc8af8cd

#### 3. Membership Change and Replication Progress
**Why**: Membership changes trigger `rebuild_progresses()` and `rebuild_replication_streams()`, which can cause quorum_accepted to decrease and stale replication responses to disrupt new streams (Finding 8). Historical bug #584 showed stale match-index updates after membership change.
**Invariants to check**:
- During membership transition, committed entries remain committed in both old and new configurations
- Replication progress is never regressed by stale responses from old replication streams
- Joint consensus quorum requirements are maintained throughout the transition
**Referenced bugs**: #584, #808, #898

#### 4. Committed Index Advancement and Application
**Why**: The commitment mechanism involves multiple stages (cluster_committed, local_committed, apply_progress) with subtle ordering dependencies. The `next_progress_driven_command` function (engine_impl.rs:615-651) has complex guards checking leader consistency between submitted and accepted IO. Historical bugs #231 (commit index not synced) and #675fda0d (apply command deadlock) show this area is error-prone.
**Invariants to check**:
- Committed entries are never un-committed
- Applied entries are always committed
- The committed index advances monotonically
- No entry is applied twice or skipped
**Referenced bugs**: #231, #675fda0d, #001e3714, #c37ac891

#### 5. Leader Survival Across Restart
**Why**: This is a non-standard Raft extension unique to openraft. Issue #1511 (open) documents the risk of state machine inconsistency when a leader restarts. The lease reset on restart (Finding 10) adds another dimension. The `startup()` function's leader restoration path has minimal verification.
**Invariants to check**:
- A restarted leader serves consistent state (no stale reads)
- Leader lease expiry prevents two leaders serving simultaneously
- `save_committed()` persistence is sufficient for safe leader restart
- No client can observe a committed value that is then lost after restart
**Referenced bugs**: #1511 (open), #1467, #607, #640
