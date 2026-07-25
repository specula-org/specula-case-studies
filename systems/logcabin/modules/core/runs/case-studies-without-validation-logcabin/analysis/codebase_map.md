# LogCabin Raft Codebase Map

## Core Files
| Component | File(s) | Lines | Notes |
|-----------|---------|-------|-------|
| State machine + consensus | Server/RaftConsensus.cc | 3037 | Main Raft logic: elections, log replication, config changes |
| State machine header | Server/RaftConsensus.h | 1725 | Class declarations, state variables, Configuration class |
| Invariant checks | Server/RaftConsensusInvariants.cc | 306 | Runtime invariant checking (checkBasic, checkDelta, checkPeerBasic) |
| RPC dispatch | Server/RaftService.cc | 110 | Thin dispatcher to handleAppendEntries/handleRequestVote/handleInstallSnapshot |
| RPC protocol | Protocol/Raft.proto | 339 | Protobuf: RequestVote, AppendEntries, InstallSnapshot messages |
| Log metadata | Protocol/RaftLogMetadata.proto | 21 | Persists current_term and voted_for |

## Scale
- Total lines of Raft logic: ~5200 (RaftConsensus.cc + .h + Invariants.cc + RaftService.cc)
- Message types: 3 RPCs (RequestVote, AppendEntries, InstallSnapshot)
- State transitions: 3 states (Follower, Candidate, Leader)
- Entry types: 4 (UNKNOWN, CONFIGURATION, DATA, NOOP)
- Configuration states: 4 (BLANK, STABLE, STAGING, TRANSITIONAL)

## Key State Variables (RaftConsensus members)
| Variable | Type | Description |
|----------|------|-------------|
| currentTerm | uint64_t | Latest term seen, persisted |
| state | State enum | FOLLOWER, CANDIDATE, LEADER |
| votedFor | uint64_t | Who voted for in this term (0=none), persisted |
| log | Storage::Log* | Log entries |
| commitIndex | uint64_t | Highest committed entry index |
| leaderId | uint64_t | Current leader hint (0=unknown) |
| lastSnapshotIndex | uint64_t | Last index covered by snapshot |
| lastSnapshotTerm | uint64_t | Term of last snapshot entry |
| currentEpoch | uint64_t | Logical clock for leadership confirmation |
| withholdVotesUntil | TimePoint | Don't process RequestVote until this time |
| configuration | Configuration* | Current cluster configuration |

## Key Peer State Variables
| Variable | Type | Description |
|----------|------|-------------|
| nextIndex | uint64_t | Next entry to send to follower |
| matchIndex | uint64_t | Last known matching entry |
| suppressBulkData | bool | Don't send bulk data until heartbeat ack |
| haveVote_ | bool | Whether this peer granted vote |
| requestVoteDone | bool | Whether vote request completed |
| lastAckEpoch | uint64_t | Last epoch peer acknowledged |
| isCaughtUp_ | bool | Whether peer is caught up (for config changes) |

## Configuration Change Model
LogCabin uses the joint consensus approach from the Raft paper:
1. BLANK → STABLE: Bootstrap with initial config
2. STABLE → STAGING: New servers added as non-voting observers
3. STAGING → TRANSITIONAL: C_old,new joint config committed
4. TRANSITIONAL → STABLE: C_new config committed
The leader automatically creates Cnew after Cold,new is committed (in advanceCommitIndex).

## Threading Model
- One main mutex protects all state
- Peer threads: one per remote server, handles RPCs
- LeaderDisk thread: flushes log to disk asynchronously for leaders
- Timer thread: triggers elections
- StepDown thread: detects leadership loss
- StateMachineUpdater thread: manages state machine version upgrades

## Key Implementation Details
1. **Leader disk writes are deferred**: Leaders don't sync log immediately; leaderDiskThread does it asynchronously. LocalServer::lastSyncedIndex tracks what's been flushed.
2. **Followers sync immediately**: Followers write to disk synchronously in append().
3. **withholdVotesUntil**: Prevents disruptive servers from triggering unnecessary elections (Section 9.6 of dissertation).
4. **suppressBulkData**: After RPC failure or new leadership, only send heartbeats until ack received.
5. **No PreVote**: Despite the response having a log_ok field for PreVote, LogCabin does NOT implement PreVote.
6. **Epoch-based liveness**: currentEpoch used by stepDownThread and upToDateLeader to confirm leadership.
