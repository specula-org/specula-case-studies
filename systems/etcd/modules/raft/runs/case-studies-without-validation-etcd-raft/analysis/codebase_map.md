# Codebase Map: etcd-raft

## Core Files
| Component | File(s) | Lines (non-test) | Notes |
|-----------|---------|-------------------|-------|
| State machine (core) | `raft.go` | 2158 | Main raft struct, state transitions, Step(), stepLeader/stepCandidate/stepFollower |
| Log management | `log.go`, `log_unstable.go` | 574 + 245 = 819 | raftLog struct, maybeAppend, findConflict, commit tracking |
| Message handling | (in `raft.go`) | — | send(), handleAppendEntries, handleHeartbeat, handleSnapshot |
| Node/rawnode interface | `node.go`, `rawnode.go` | 610 + 562 = 1172 | Ready struct, Advance, async storage writes |
| Storage | `storage.go` | 313 | MemoryStorage, Storage interface, persistence |
| Config changes | `confchange/confchange.go`, `confchange/restore.go` | 419 + 155 = 574 | Joint consensus, EnterJoint, LeaveJoint, Simple |
| Progress tracking | `tracker/progress.go`, `tracker/tracker.go` | 314 + 281 = 595 | Progress state machine (Probe/Replicate/Snapshot), ProgressTracker |
| Quorum logic | `quorum/majority.go`, `quorum/joint.go` | 198 + 75 = 273 | MajorityConfig, JointConfig, CommittedIndex, VoteResult |
| Read-only handling | `read_only.go` | 121 | ReadIndex implementation |
| Bootstrap | `bootstrap.go` | 80 | Initial cluster setup |
| Protobuf types | `raftpb/raft.pb.go` | 3110 | Entry, Message, HardState, ConfState, ConfChange |

## Scale
- Total lines of core Raft logic (non-test, non-protobuf): ~5,200
- Message types: 24 (MsgHup through MsgForgetLeader)
- State types: 4 (Follower, Candidate, Leader, PreCandidate)
- Progress states: 3 (Probe, Replicate, Snapshot)
- Campaign types: 3 (PreElection, Election, Transfer)

## Key State Variables (raft struct, raft.go:341-435)
| Variable | Type | Code Location | Paper Equivalent | Notes |
|----------|------|---------------|-----------------|-------|
| `Term` | uint64 | raft.go:344 | `currentTerm` | Persisted in HardState |
| `Vote` | uint64 | raft.go:345 | `votedFor` | Persisted in HardState |
| `raftLog` | *raftLog | raft.go:350 | `log[]` | Contains committed, applying, applied |
| `state` | StateType | raft.go:357 | `state` | Includes PreCandidate (not in paper) |
| `lead` | uint64 | raft.go:380 | N/A | Tracked leader ID (implementation-specific) |
| `leadTransferee` | uint64 | raft.go:382 | N/A | Leader transfer target |
| `pendingConfIndex` | uint64 | raft.go:390 | N/A | Prevents concurrent config changes |
| `trk` | ProgressTracker | raft.go:355 | `matchIndex`, `nextIndex` | Includes JointConfig, Progress states |
| `msgs` / `msgsAfterAppend` | []Message | raft.go:366/377 | N/A | Two-phase message delivery |
| `checkQuorum` | bool | raft.go:411 | N/A | Leader steps down if quorum inactive |
| `preVote` | bool | raft.go:412 | N/A | PreVote extension |

## Architecture Notes
- Single-threaded raft state machine (no internal goroutines)
- All state mutations happen via `Step()` method
- Two message queues: `msgs` (immediate) and `msgsAfterAppend` (after persistence)
- AsyncStorageWrites mode splits persistence from state machine
- Joint consensus for config changes (Voters[0] = incoming, Voters[1] = outgoing)
