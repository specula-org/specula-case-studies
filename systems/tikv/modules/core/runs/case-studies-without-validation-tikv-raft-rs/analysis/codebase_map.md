# tikv/raft-rs Codebase Map

## Core Files

| Component | File(s) | Lines | Notes |
|-----------|---------|-------|-------|
| State machine / Raft core | `src/raft.rs` | 2966 | Main Raft struct (RaftCore + Raft), step(), campaign(), become_*, vote handling |
| Log management | `src/raft_log.rs` | 1918 | RaftLog, maybe_append, maybe_commit, find_conflict_by_term |
| Unstable log | `src/log_unstable.rs` | 482 | Unstable entries/snapshot not yet persisted |
| Message handling | `src/raft.rs` (step_leader, step_follower, step_candidate) | ~700 | Dispatched by role within raft.rs |
| Progress tracking | `src/tracker/progress.rs` | 411 | Progress struct (matched, next_idx, state, paused, inflights) |
| Progress state | `src/tracker/state.rs` | 40 | ProgressState enum: Probe, Replicate, Snapshot |
| Progress tracker | `src/tracker.rs` | 388 | ProgressTracker: manages per-peer progress, quorum calc |
| Inflights window | `src/tracker/inflights.rs` | 426 | Sliding window for in-flight messages |
| Quorum (majority) | `src/quorum/majority.rs` | 255 | AckedIndexer, majority commit index |
| Quorum (joint) | `src/quorum/joint.rs` | 98 | Joint consensus quorum calculation |
| Config changes | `src/confchange/changer.rs` | 357 | EnterJoint, LeaveJoint, Simple config changes |
| Config restore | `src/confchange/restore.rs` | 107 | Restore config from ConfState |
| Raw node | `src/raw_node.rs` | 831 | RawNode: external API, Ready handling |
| Storage | `src/storage.rs` | 813 | Storage trait, MemStorage |
| Config | `src/config.rs` | 219 | Config struct with validation |
| Read only | `src/read_only.rs` | 136 | ReadOnly mechanism (Safe/LeaseBased) |
| Lib / exports | `src/lib.rs` | 598 | Re-exports, module declarations |
| Utilities | `src/util.rs` | 178 | Entry size calculation, limits |
| Errors | `src/errors.rs` | 174 | Error types |
| Status | `src/status.rs` | 53 | Status reporting |

## Scale
- **Total lines of Raft logic**: ~10,948 (core src + tracker + quorum + confchange)
- **Core Raft logic** (raft.rs + raft_log.rs): ~4,884 lines
- **Message types**: 19 (MsgHup through MsgRequestPreVoteResponse)
- **State roles**: 4 (Follower, Candidate, Leader, PreCandidate)
- **Progress states**: 3 (Probe, Replicate, Snapshot)
- **Entry types**: 3 (EntryNormal, EntryConfChange, EntryConfChangeV2)

## Key State Variables (RaftCore struct, raft.rs:158-259)
| Variable | Type | Paper Equivalent | Notes |
|----------|------|-----------------|-------|
| `term` | u64 | currentTerm | |
| `vote` | u64 | votedFor | INVALID_ID (0) = not voted |
| `state` | StateRole | state | Includes PreCandidate |
| `leader_id` | u64 | N/A | Tracked leader, not in paper |
| `raft_log` | RaftLog | log | Includes committed, applied, persisted |
| `pending_conf_index` | u64 | N/A | Guards concurrent config changes |
| `lead_transferee` | Option<u64> | N/A | Leadership transfer target |
| `check_quorum` | bool | N/A | CheckQuorum feature |
| `pre_vote` | bool | N/A | PreVote feature |
| `election_elapsed` | usize | N/A | Ticks since last election event |
| `priority` | i64 | N/A | Election priority |
| `promotable` | bool | N/A | Whether node can become leader |

## Key Implementation Deviations from Paper
1. **PreVote** (PreCandidate state): Extra phase before actual election
2. **CheckQuorum**: Leader steps down if can't reach quorum
3. **Leader transfer**: Explicit MsgTimeoutNow mechanism
4. **Election priority**: Nodes can have different election priorities
5. **Commit-by-vote**: Fast-forward commit via vote message commit info
6. **pending_conf_index**: Prevents concurrent config changes
7. **Progress states** (Probe/Replicate/Snapshot): Flow control optimization
8. **Batch append**: Batching append messages for performance
9. **Joint consensus** (ConfChangeV2): Full joint consensus for membership changes
