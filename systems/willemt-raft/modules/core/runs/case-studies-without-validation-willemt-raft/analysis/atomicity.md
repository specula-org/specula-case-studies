# Atomicity Boundaries: willemt/raft

## Design: Single-Threaded Callback Library

This is a C library (not a server). There are NO threads, NO goroutines, NO locks.
All operations are called by the user synchronously. This simplifies atomicity analysis significantly.

## Atomic Operations (Single Function Call)

Each of these API calls runs atomically from the perspective of the Raft state machine:

1. **`raft_recv_appendentries()`** - Receives AE, modifies log/term/state, fills response struct
2. **`raft_recv_appendentries_response()`** - Processes AE response, advances commit index
3. **`raft_recv_requestvote()`** - Receives vote request, modifies term/state, fills response
4. **`raft_recv_requestvote_response()`** - Processes vote response, may become leader
5. **`raft_recv_entry()`** - Client submits entry, leader appends and sends AEs
6. **`raft_periodic()`** - Time tick: may trigger election, send heartbeats, apply entries

## Interleaving Model

Since the library is single-threaded, the interleaving happens at the **message delivery** level:
- Messages are sent via callbacks (`send_requestvote`, `send_appendentries`)
- Messages can be delivered in any order, duplicated, or dropped
- The user controls when `raft_recv_*` is called for each node

## Key Atomicity Points for TLA+ Model

1. **Term update + votedFor reset**: `raft_set_current_term()` at raft_server_properties.c:85-101 atomically sets the new term AND resets `voted_for = -1`. In TLA+, this is a single assignment.

2. **Become candidate**: `raft_become_candidate()` at raft_server.c:179-210 does: increment term, reset all vote flags, vote for self, set state to CANDIDATE, send RequestVotes. This is all one atomic step in TLA+.

3. **AE response + commit advancement**: `raft_recv_appendentries_response()` updates match_idx, then checks majority for commit advancement — all in one atomic step.

4. **No partial message delivery**: Each `raft_recv_*` call processes exactly one complete message.

## Persistence Callbacks

The library calls persistence callbacks (persist_term, persist_vote, log_offer, log_poll, log_pop) during message processing. For TLA+ modeling:
- We abstract persistence as instantaneous (correct for single-threaded model)
- Crash recovery is NOT modeled (would need to model persist callback failures)
