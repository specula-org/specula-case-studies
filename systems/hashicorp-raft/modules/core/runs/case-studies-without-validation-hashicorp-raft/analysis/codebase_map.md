# Codebase Map: hashicorp-raft

## Core Files
| Component | File(s) | Lines | Notes |
|-----------|---------|-------|-------|
| State machine / event loops | `raft.go` | 2242 | Main event loop: `run()` → `runFollower()`, `runCandidate()`, `runLeader()`, `leaderLoop()` |
| State variables | `state.go` | 174 | `raftState` struct: currentTerm, commitIndex, lastApplied, state. Atomic ops for thread safety |
| Raft struct & API | `api.go` | 1282 | 43 fields, 16 channels, `NewRaft()` initialization |
| Log replication | `replication.go` | 665 | Per-follower `replicate()` goroutine, `replicateTo()`, heartbeat, pipeline mode |
| Commit index | `commitment.go` | 104 | Quorum-based commit advancement: `match()`, `recalculate()` |
| Message types | `commands.go` | 223 | 5 RPC pairs: AppendEntries, RequestVote, RequestPreVote, InstallSnapshot, TimeoutNow |
| Configuration | `configuration.go` | 368 | Membership: Server, Configuration, ConfigurationChangeCommand |
| Log storage | `log.go` | 192 | Log struct (Index, Term, Type, Data), LogStore interface |
| Snapshot | `snapshot.go` | 278 | SnapshotMeta, SnapshotStore interface, `takeSnapshot()` |
| FSM | `fsm.go` | 286 | `runFSM()` goroutine, FSM.Apply(), batch support |
| Persistence | `stable.go` | 18 | StableStore interface: Set, Get, SetUint64, GetUint64 |
| Transport | `transport.go` | 141 | Transport interface, WithPreVote extension |
| Config validation | `config.go` | 376 | Configuration validation and defaults |
| Futures | `future.go` | 380+ | Async operation patterns |

## Scale
- **Total lines of Raft logic**: ~12,313 (excluding tests)
- **Message types**: 10 (5 request/response pairs)
- **State transitions**: Follower → Candidate → Leader → Follower (+ Shutdown)
- **Core goroutines**: 5 (main loop, FSM, snapshots, per-follower replication, per-follower heartbeat)

## Key State Variables (raftState struct, state.go:47-77)
| Variable | Type | Persistence | Notes |
|----------|------|------------|-------|
| `currentTerm` | uint64 | Persisted via `stable.SetUint64(keyCurrentTerm, t)` | `setCurrentTerm()` in raft.go:2142 persists then caches |
| `commitIndex` | uint64 | In-memory only | Derived from quorum |
| `lastApplied` | uint64 | In-memory only | FSM progress |
| `state` | RaftState | In-memory only | Follower/Candidate/Leader/Shutdown |
| `lastLogIndex/Term` | uint64 | Cached from LogStore | |
| `lastSnapshotIndex/Term` | uint64 | Cached from SnapshotStore | |

## Additional State (not in raftState)
| Variable | Location | Notes |
|----------|----------|-------|
| `votedFor` (keyLastVoteTerm + keyLastVoteCand) | StableStore | **Non-atomic 2-step persist** via `persistVote()` |
| `configurations` | Raft struct | Committed + latest config, derived from log |
| `leaderAddr/leaderID` | Raft struct | Tracked leader, cleared on state change |
| `candidateFromLeadershipTransfer` | atomic.Bool | Leadership transfer flag |
| Per-follower: `nextIndex`, `matchIndex` | `followerReplication` struct | Leader-only state |

## Concurrency Architecture
- **Single-threaded main loop**: All state transitions on one goroutine via `run()` → `runFollower/Candidate/Leader()`
- **Channel-based communication**: 16+ channels for events
- **Atomic operations**: currentTerm, commitIndex, lastApplied, state accessed atomically
- **Separate goroutines**: FSM, snapshots, per-follower replication (each with its own heartbeat goroutine)
- **Critical**: Replication goroutines use `s.currentTerm` (snapshot at start), not `r.getCurrentTerm()`
