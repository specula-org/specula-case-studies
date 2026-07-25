# Analysis Report: datafuselabs/openraft

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git keyword searches performed | 12 (fix, bug, race, panic, deadlock, correctness, safety, inconsistent, wrong, stale, crash, corrupt) |
| Bug-fix commits analyzed | ~35 unique |
| GitHub issues collected | 50 |
| GitHub issues deeply read (full comments) | 36 |
| Confirmed bugs | 25 |
| Design defects | 5 |
| User error / false positives | 11 |
| Open PRs reviewed | 6 (none are bug fixes) |
| Core source files deeply read | 15 |
| Parallel analysis agents used | 10 (4 issue batches + 6 file analysis) |

---

## Phase 1: Reconnaissance

### 1.1 Core Modules

| Component | File(s) | LOC | Purpose |
|-----------|---------|-----|---------|
| Runtime / Event Loop | `core/raft_core.rs` | 2272 | Main async loop, command execution, message dispatching |
| Engine (State Machine) | `engine/engine_impl.rs` | 876 | Pure deterministic Raft state machine producing Commands |
| Vote Handler | `engine/handler/vote_handler/mod.rs` | 276 | Vote validation, leader/follower transitions |
| Following Handler | `engine/handler/following_handler/mod.rs` | 342 | Follower log append, truncation, snapshot install |
| Replication Handler | `engine/handler/replication_handler/mod.rs` | 485 | Progress tracking, quorum commit, membership streams |
| Leader Handler | `engine/handler/leader_handler/mod.rs` | 155 | Leader append, heartbeat, transfer |
| Log Handler | `engine/handler/log_handler/mod.rs` | 114 | Log purging and retention policies |
| Snapshot Handler | `engine/handler/snapshot_handler/mod.rs` | 69 | Snapshot build and metadata |
| Establish Handler | `engine/handler/establish_handler/mod.rs` | 48 | Candidate → Leader conversion |
| Command Types | `engine/command.rs` | 537 | 19 command variants with conditions |
| Raft State | `raft_state/mod.rs` | 518 | Complete Raft state (persistent + volatile) |
| IO State | `raft_state/io_state.rs` | 290 | IO progress tracking (accepted/submitted/flushed) |
| Membership | `membership/membership.rs` | 683 | Joint consensus membership |
| Vote Types | `vote/vote.rs`, `vote/raft_vote.rs` | 553 | Vote struct with committed flag |
| Replication Task | `replication/mod.rs` | 489 | Per-peer async replication |
| Storage Traits | `storage/v2/raft_log_storage.rs` | 279 | Log + vote persistence trait |

### 1.2 Concurrency Model

- **Single-threaded Engine**: All protocol state transitions happen inside the Engine, which is a pure function producing Commands. No locks, no concurrency.
- **Single-threaded Runtime**: RaftCore runs on one async task, processing messages (rx_api) and notifications (rx_notification) in a biased select loop.
- **Per-peer Replication Tasks**: Each follower gets a `ReplicationCore` async task that reads logs from storage and sends AppendEntries RPCs. Communication back to RaftCore is via `Notification` enum on an mpsc channel.
- **IO Completion Forwarder**: A separate async task that batches IOFlushed callbacks (1μs interval) and forwards them as `Notification::LocalIO` to the main loop.
- **State Machine Worker**: A separate task that applies committed entries to the state machine.

### 1.3 Atomicity Boundaries

- **Engine operations are atomic**: Each engine method (handle_vote_req, handle_append_entries, etc.) runs to completion without interruption. Commands are generated as a batch.
- **Commands execute sequentially**: `run_engine_commands()` pops and executes commands one at a time. `SaveVote` blocks until persistence completes. `AppendEntries` returns after submission (flush is asynchronous).
- **Truncate + Append are NOT atomic**: These are two separate commands. A crash between them leaves the log truncated but not yet extended. This is safe because the committed index doesn't advance past unflushed entries.
- **Vote and Log IO are serialized**: The storage trait requires all write-IO (vote + log) to be serialized. They are dispatched sequentially from the command queue.

### 1.4 Key Deviations from Standard Raft

| Deviation | Description | Risk |
|-----------|-------------|------|
| Committed vote = leader identity | Vote includes `committed` flag. Leader = node with committed vote for itself. | New voting semantics, partial ordering with committed flag |
| Leader lease | Followers reject higher-term VoteRequests while lease active | Can prevent legitimate elections during partitions |
| Leader survival across restart | Node resumes as leader if persisted vote is committed for self | Can serve stale reads (Issue #1511) |
| No pre-vote | openraft does not implement the PreVote extension | N/A |
| Joint consensus with >2 configs | `configs: Vec<BTreeSet<NID>>` allows N sub-configs | More general than standard two-config joint consensus |
| `save_committed()` optional | Default no-op. Committed index re-derived from quorum on restart | Stale state machine on restart if SM is transient |

---

## Phase 2: Bug Archaeology — Detailed Findings

### 2.1 Git History Mining Results

**Search keywords**: fix, bug, race, panic, deadlock, correctness, safety, inconsistent, wrong, stale, crash, corrupt
**Total unique bug-fix commits found**: ~35

#### Critical Protocol Correctness Bugs

| # | Commit/PR | Summary | Root Cause | Component |
|---|-----------|---------|------------|-----------|
| 1 | `b06cbb37` / PR #1146 | Vote updated on seeing higher vote in RequestVote response | Incorrectly updated `state.vote` from response without grant | Election |
| 2 | `674e78aa` / PR #561 | Conflicting logs not deleted before snapshot install | Crash window: conflicting logs survive restart | Snapshot |
| 3 | `4015cc38` / PR #159 | Candidate didn't revert to follower on higher vote | Compared logs after updating vote (invalidated grants) | Election |
| 4 | `71a290cd` / PR #512 | Purged prev_log_id treated as conflict → committed log deletion | Used `committed` instead of `last_applied` after restart | Log replication |
| 5 | `97fa1581` | Blank-log heartbeat replaced with standard heartbeat | IO overhead + leadership seizure during snapshot transfer | Heartbeat |
| 6 | `c8fccb22` / PR #685 | Adding learner without ensuring last membership committed | Log truncation could lose uncommitted membership entries | Membership |
| 7 | `37d69439` | Joint consensus never flattened to uniform | Second step re-applied same change instead of flattening | Membership |

#### High Severity Bugs

| # | Commit/PR | Summary | Root Cause | Component |
|---|-----------|---------|------------|-----------|
| 8 | `cc8af8cd` / PR #643 | `last_purged_log_id` not loaded correctly | LogIdList couldn't distinguish None from index-0 | Startup |
| 9 | `918b48bc` / PR #425 | Wrong range when searching membership entries (#424) | Off-by-one in backward batch scan | Membership |
| 10 | `56486a60` / PR #585 | Assertion `value > prev` after change_membership (#584) | Replication stream re-spawn lost matching progress | Membership |
| 11 | `54ffb00d` / PR #1389 | Heartbeat conflict responses ignored | Leader didn't process conflicts from heartbeat RPCs | Heartbeat |
| 12 | `2bdfae5d` / PR #1501 | Heartbeat-induced log reversion panic (#1500) | Heartbeat used committed (not matching) as prev_log_id | Heartbeat |
| 13 | `c37ac891` | Engine commands not executed after processing messages (0.10) | Early return skipped `run_engine_commands()` call | Command execution |
| 14 | `001e3714` | Duplicated SaveCommittedAndApply (0.10) | Explicit command + progress-driven command both generated | Command execution |
| 15 | PR #1220 | Equal vote incorrectly treated as granting leadership (0.10) | Leader step-down created vote that was treated as a grant | Election |
| 16 | PR #1125 | New leader blank log not flushed | Committed data invisible after restart | Startup |
| 17 | PR #1180 | Responses sent before IO completion (0.10) | Missing Condition::IOFlushed on Respond commands | IO ordering |
| 18 | PR #364 | Fast-commit with quorum change | Fast-commit applied even when membership altered quorum | Membership |

#### Medium Severity Bugs

| # | Commit/PR | Summary | Root Cause | Component |
|---|-----------|---------|------------|-----------|
| 19 | `26dc8837` | `is_log_range_inflight()` checked entry not range | Allowed purging logs still being replicated | Log purge |
| 20 | `59ddc982` / PR #473 | LogId created with uninitialized `matched.leader_id` (#471) | Used LogId constructor when only index was needed | Learner |
| 21 | `ea14fdd0` / Issue #231 | Replication not syncing commit index | Leader didn't send updated committed when no new entries | Replication |
| 22 | `54aea8a2` | `seen_greater_log` flag lost on state transition | Flag stored inside destroyed Leader/Candidate state | Election |
| 23 | `675fda0d` | Progress-driven commands deadlock | Commands depended on preceding commands completing | Command execution |
| 24 | `8594807c` | Metrics updated before engine commands | Application saw state change before internal state updated | Metrics |
| 25 | `f994c862` / Issue #1601 | Panic on empty `limited_get_log_entries` | `.unwrap()` on `logs.first()` when storage returned empty | Replication |

### 2.2 GitHub Issue Verification Results

#### Issues Deeply Read and Classified

| Issue | Title | Classification | Fixed? |
|-------|-------|---------------|--------|
| #1511 | Leader survival across restart inconsistency | Design defect | OPEN |
| #584 | Assertion `value > prev` after change_membership | Confirmed bug | Fixed |
| #511 | Purged prev_log_id causes log deletion | Confirmed bug | Fixed |
| #1500 | Heartbeat/log replication race condition | Confirmed bug | Fixed |
| #452 | Candidate should step down on higher log | Design defect | Fixed |
| #607 | Single-node cluster restart panic | Confirmed bug | Fixed |
| #231 | Commit index not synced to follower | Confirmed bug | Fixed |
| #424 | Duplicate membership entries from log scan | Confirmed bug | Fixed |
| #833 | Replication deadlock after Unreachable | Confirmed bug | Fixed |
| #808 | Leader stuck during membership + snapshot | Confirmed bug | Fixed |
| #597 | Leader does not step down (non-voting leader) | Design defect | Fixed |
| #1329 | New leader election never triggered | User error | N/A |
| #1246 | Missing log replay on single-node restart | Confirmed bug | Fixed |
| #157 | Stale reads on non-leader | Design defect | Fixed |
| #550 | Example hangs at change-membership | Disputed (cargo/openssl) | Workaround |
| #1467 | Stale leader state after restart | By-design / User error | N/A |
| #1429 | Previous leader keeps being candidate | User error (network) | N/A |
| #1544 | Panic during membership + replication | User error (storage impl) | User fix |
| #1545 | Assertion failure during learner replication | Disputed (unresolved) | Closed |
| #1546 | Assertion failure (duplicate of #1545) | Duplicate | Closed |
| #1556 | Truncate to T0-N0 at beginning | Design defect (docs) | Clarified |
| #994 | Raft Core Panicking | User error (misconfiguration) | N/A |
| #920 | "it has to be a leader!!!" | Confirmed bug | Fixed |
| #898 | debug_assert causes leader to panic | Design defect | Fixed (feature flag) |
| #437 | Log purge before snapshot | Confirmed bug | Fixed |
| #58 | CI test `stepdown` failed | Confirmed bug (flaky test) | Fixed |
| #471 | Panic in `add_learner` assertion | Confirmed bug | Fixed |
| #927 | Learner restart doesn't sync state | User error | By design |
| #826 | Snapshot failure "No applied entry" | User error (storage impl) | Self-resolved |
| #883 | Single-node leader restart re-apply | Design defect | Fixed |
| #1535 | Node cannot join after restart | User error (misuse of Initialize) | Explained |
| #1238 | Watch::Ref blocks RaftCore | Design defect | Documented |
| #228 | Race condition with cloned metrics | Confirmed bug | Fixed |
| #1601 | Panic on empty logs.first().unwrap() | Confirmed bug | Fixed |
| #1252 | IO sequence handling in initialization | User error (storage impl) | User fix |
| #1330 | Node stuck in CPU-consuming loop | User error (wrong error variant) | Explained |

### 2.3 Bug Hotspot Analysis

| Component | Bug Count | Critical | High | Medium |
|-----------|-----------|----------|------|--------|
| Election / Vote | 7 | 3 | 2 | 2 |
| Membership / Config | 6 | 2 | 3 | 1 |
| Heartbeat / Replication | 6 | 1 | 3 | 2 |
| Snapshot / Log consistency | 4 | 2 | 1 | 1 |
| Restart / Recovery | 6 | 0 | 2 | 4 |
| IO / Command ordering | 5 | 0 | 3 | 2 |

---

## Phase 3: Deep Analysis — Detailed Findings

### 3.1 Vote Handler Analysis

**File**: `engine/handler/vote_handler/mod.rs` (276 lines)

**Persistence-before-response**: Correctly enforced. VoteResponses are gated on `Condition::IOFlushed` (raft_core.rs:1468-1474). SaveVote blocks until persistence completes (raft_core.rs:2091). No path sends a VoteResponse before the vote is durable.

**Vote comparison**: Uses partial ordering (`RefVote` at ref_vote.rs:36-57). Committed vote beats uncommitted for same-term incomparable leader_ids. This is correct and unique to openraft.

**Leader lease**: Followers reject VoteRequests while lease is active (engine_impl.rs:251-261). Uses `is_expired(now, Duration::from_millis(0))` with zero tolerance. This is a deliberate deviation from Raft — could prevent legitimate elections during partitions but prevents disruption from partitioned nodes.

**`establish_leader` debug_assert**: At engine_impl.rs:663-664, `update_vote` failure is only debug-asserted. In release builds, if the vote update fails (which the comment says "can't happen"), the code continues with the leader established but the vote not updated — a potential safety violation. Recommendation: make this a hard error.

**Non-committed downgrade on rejection**: At engine_impl.rs:348, when a vote response is rejected, the candidate updates to the non-committed version of the responder's vote. This prevents a state-reverted node from reusing a committed vote from a response to claim leadership — a defensive measure not in standard Raft.

### 3.2 Following Handler Analysis

**File**: `engine/handler/following_handler/mod.rs` (342 lines)

**Purged prev_log_id handling**: `has_log_id()` (log_state_reader.rs:23-35) auto-accepts entries below `committed.next_index()`. This is correct because committed entries are guaranteed identical across all nodes. The debug_assert on line 25 verifies this in debug builds.

**Crash window between truncate and append**: Two separate commands (TruncateLog + AppendEntries) at following_handler/mod.rs:89-92. A crash between them is benign: committed index doesn't advance past unflushed entries (guarded by `calculate_local_committed` at io_state.rs:257-281).

**Snapshot install safety**: Stale snapshots (last_log_id <= committed) are silently ignored (line 250). Conflicting logs are truncated to committed+1 before snapshot install (lines 272-278). Purge target is set to snapshot.last_log_id (line 292).

**Committed index monotonicity**: `cluster_committed` uses `MonotonicIncrease` (rejects non-increasing). `update_local_committed` only updates when `committed > self.committed()`. Multiple layers of defense prevent committed index regression.

### 3.3 Replication Handler Analysis

**File**: `engine/handler/replication_handler/mod.rs` (485 lines)

**Quorum calculation**: Uses `Joint.is_quorum()` (joint.rs:97-103) which requires majority in ALL sub-configs. Correct for joint consensus.

**Quorum set upgrade on membership change**: `rebuild_progresses()` (lines 97-123) calls `upgrade_quorum_set()` which atomically replaces the quorum set and recalculates quorum-accepted. No window for wrong-quorum commit.

**Leader term check on commit**: `try_commit_quorum_accepted()` (line 206-209) only commits entries whose `committed_leader_id` matches the current leader's vote. Prevents committing previous-term entries — correct per Raft Section 5.4.2.

**Post-step-down replication safety**: Multiple layers prevent a stepped-down leader from committing: (1) `self.leader = None` prevents `try_replication_handler()` from returning a handler, (2) replication tasks check leader vote on each iteration, (3) `CloseReplicationStreams` command terminates tasks.

**Quorum-accepted can revert during membership expansion**: Documented at lines 156-165. Adding a new config weakens quorum requirements, potentially reverting the quorum-accepted value. This is correct behavior — the system waits for more acknowledgments.

### 3.4 RaftCore Runtime Analysis

**File**: `core/raft_core.rs` (2272 lines)

**Command execution ordering**: Commands execute eagerly after every message (`run_command_threshold = 0`). `run_engine_commands()` is called after every `handle_api_msg()` (line 1265) and every `handle_notification()` (line 1320).

**SaveVote blocks the event loop**: At raft_core.rs:2091, `save_vote()` is awaited (blocking). During this time, no messages or notifications can be processed. This is safe but adds latency proportional to vote persistence time.

**IOFlushed callback mechanism**: AppendEntries uses asynchronous persistence (lines 2048-2082). The `IOFlushed` callback goes through: callback → watch channel → io_completion_forwarder (1μs batching) → mpsc notification → `try_flush`. Responses are gated on `Condition::IOFlushed`, ensuring persistence before response.

**HigherVote handling**: `become_following()` clears leader state and queues `CloseReplicationStreams`. Brief window where replication tasks are alive after engine transitions to follower — safe because stale notifications are filtered by `does_leader_vote_match`.

**State machine cannot apply before commit**: `next_progress_driven_command()` (engine_impl.rs:598-637) requires: (1) vote match between submitted and accepted, (2) `applicable_upto = min(log_submitted, apply_accepted)`, (3) apply_accepted only advances when committed index advances. Multiple guards prevent premature application.

### 3.5 Membership and Quorum Analysis

**Files**: `membership/membership.rs` (683 lines), `membership/effective_membership.rs`, `change_handler.rs`

**Joint consensus**: Correctly implemented. `configs: Vec<BTreeSet<NID>>` supports arbitrary-length joint configs (though in practice only 1 or 2). `is_quorum` iterates ALL sub-configs.

**Concurrent membership change prevention**: `ensure_committed()` (change_handler.rs:54-67) rejects new membership changes if `effective.log_id() != committed.log_id()`. This is the "at most one uncommitted membership" invariant.

**Two-step change flow**: Step 1 creates joint config. Step 2 sends `AddVoterIds(empty)` which triggers `next_coherent()` to flatten. This was previously buggy (`37d69439`) but is now correct.

**`MembershipState.append()` promotion**: When appending a new membership, the old effective is promoted to committed (lines 171-185). This relies on the invariant that only one uncommitted membership exists.

### 3.6 IO State and Persistence Analysis

**Files**: `raft_state/io_state.rs` (290 lines), `storage/v2/raft_log_storage.rs` (279 lines)

**IO ordering**: Storage trait requires all write-IO to be serialized (line 30-32). SaveVote must persist before returning (line 62-63). This is enforced at the trait level and by sequential command execution.

**`save_committed()` is optional**: Default no-op (line 78-81). Recovery uses `max(read_committed, last_applied)` (helper.rs:116-118). If SM is transient, `save_committed` is needed for crash recovery — but most users don't implement it.

**Crash between save_vote and first append**: Safe. Vote is durable, first entry is not. On restart, the node has the saved vote but no entries from this term. Normal Raft election/replication resumes.

**`calculate_local_committed`** (io_state.rs:257-281): Returns `min(accepted.last_log_id, cluster_committed.last_log_id)` only if `accepted_vote >= cluster_committed_vote`. This prevents applying entries from an outdated leader's term.

---

## Phase 4: Bug Family Cross-Reference

### Family Formation Logic

The 25 confirmed bugs + 5 design defects were grouped into 6 families by mechanism:

| Family | Mechanism | Bug Count | Bug IDs |
|--------|-----------|-----------|---------|
| 1: Vote/Election | Incorrect vote state transitions | 7 | b06cbb37, 4015cc38, #452, #920, 54aea8a2, PR #1220, engine_impl.rs:663 |
| 2: Snapshot/Log | Crash windows in snapshot+log operations | 5 | 674e78aa, 71a290cd, #437, PR #543, following_handler:89-92 |
| 3: Heartbeat/Replication | Heartbeat uses wrong state | 6 | 97fa1581, 2bdfae5d, 54ffb00d, ea14fdd0, d836d85c, #833 |
| 4: Membership | Quorum/config inconsistencies during changes | 7 | PR #364, 37d69439, c8fccb22, 56486a60, 918b48bc, PR #362, #808 |
| 5: Restart/Recovery | Non-standard restart behavior | 7 | #1511, #1246, #607, PR #884, PR #1125, #920, #883 |
| 6: IO/Command Ordering | Command execution sequence errors | 5 | c37ac891, 001e3714, 675fda0d, PR #1180, 8594807c |

### False Positives Excluded

| Issue | Why Excluded |
|-------|-------------|
| #1329 | User error: network configuration prevented election |
| #1429 | User error: network connectivity issue |
| #1544 | User error: storage implementation violated API contract (cloned instead of sharing log reader) |
| #994 | User error: membership misconfiguration (two nodes with same ID) |
| #927 | By design: non-persistent storage violates Raft assumptions |
| #826 | User error: storage implementation bug |
| #1535 | User error: calling Initialize() on every restart |
| #1252 | User error: storage IO ordering violation |
| #1330 | User error: wrong error variant (NetworkError vs Unreachable) |
| #550 | Disputed: cargo/openssl interaction, not openraft bug |
| #1467 | By design: use `last_quorum_acked` for leader validation |
