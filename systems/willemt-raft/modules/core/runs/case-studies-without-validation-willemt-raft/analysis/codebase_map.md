# Codebase Map: willemt/raft

## Core Files
| Component | File(s) | Lines | Notes |
|-----------|---------|-------|-------|
| State machine & message handling | `src/raft_server.c` | 1435 | Core Raft logic: elections, AppendEntries, log replication, snapshots, membership changes |
| Properties & getters/setters | `src/raft_server_properties.c` | 269 | State accessors, `raft_set_current_term` (resets votedFor atomically) |
| Log management | `src/raft_log.c` | 315 | Circular buffer log implementation |
| Node/peer state | `src/raft_node.c` | 192 | Per-node flags (voting, active, has_sufficient_logs, etc.), next_idx, match_idx |
| Public API | `include/raft.h` | 957 | Public types, message structs, callback typedefs |
| Private structures | `include/raft_private.h` | 156 | `raft_server_private_t` struct with all state variables |
| Log API | `include/raft_log.h` | 60 | Log function declarations |
| Type definitions | `include/raft_types.h` | 28 | raft_term_t, raft_index_t, raft_node_id_t |

## Scale
- Total lines of Raft logic: ~2211 (src/) + ~1201 (include/) = ~3412 total
- Core Raft logic (raft_server.c): 1435 lines
- Message types: 4 (RequestVote, RequestVoteResponse, AppendEntries, AppendEntriesResponse) + snapshot callback
- States: 4 (NONE, FOLLOWER, CANDIDATE, LEADER)
- Log entry types: 5 (NORMAL, ADD_NONVOTING_NODE, ADD_NODE, DEMOTE_NODE, REMOVE_NODE)
- Node flags: 6 (VOTED_FOR_ME, VOTING, HAS_SUFFICIENT_LOG, INACTIVE, VOTING_COMMITTED, ADDITION_COMMITTED)

## Architecture
- Library design: C library with callbacks (no threading, no networking)
- Single-threaded: all operations happen within callback context
- User provides: persistence callbacks, send callbacks, apply callback
- `voted_for` initialized to -1 (meaning "no vote")
- `raft_set_current_term()` atomically resets `voted_for` to -1 when term increases
- Log uses circular buffer with `front`, `back`, `base` pointers
