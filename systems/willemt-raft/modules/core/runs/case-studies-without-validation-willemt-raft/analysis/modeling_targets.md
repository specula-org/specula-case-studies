# Modeling Targets (Prioritized)

## Priority 1: Election Safety + Vote Granting Logic (HIGH)

**Rationale**: Three confirmed bugs (B1, B2, B12) in this area. The `__should_grant_vote` function has a TODO comment suggesting incomplete logic (W1). The interaction between `raft_set_current_term` (which atomically resets votedFor) and `raft_become_follower` (which does NOT reset votedFor since commit 75b0104) is subtle.

**Key code**: `__should_grant_vote` (raft_server.c:535-573), `raft_recv_requestvote` (575-644), `raft_recv_requestvote_response` (655-716), `raft_become_candidate` (179-210), `raft_set_current_term` (raft_server_properties.c:85-101)

**What to model**: Full election lifecycle, term updates, vote granting conditions, leader lease check.

## Priority 2: AppendEntries + Log Consistency + Commit Advancement (HIGH)

**Rationale**: Three confirmed bugs here (B3, B4, B11). The AE handler has complex multi-path logic for matching/deleting/appending entries. Commit advancement logic (W6) only checks majority at `r->current_idx` rather than finding the highest majority-replicated index - this is actually correct per the paper but the implementation has subtle interaction with stale responses.

**Key code**: `raft_recv_appendentries` (385-528), `raft_recv_appendentries_response` (275-383), commit advancement (352-373)

**What to model**: Log consistency invariant, conflict detection and deletion, commit index advancement with correct majority counting.

## Priority 3: AE Response Handling + NextIdx/MatchIdx Management (MEDIUM)

**Rationale**: Multiple bugs (B8, B9) in how AE responses are processed. The `nextIdx` decrement-and-retry logic has had stale response issues. The interaction between non-voting nodes, voting changes, and AE response processing is fragile.

**Key code**: `raft_recv_appendentries_response` (275-383), `raft_node_set_next_idx` (raft_node.c:64-69)

**What to model**: nextIdx management, stale response handling, match_idx advancement.

## Priority 4: Membership Change Safety (MEDIUM)

**Rationale**: Complex 2-step process (ADD_NONVOTING -> ADD_NODE) with `voting_cfg_change_log_idx` guard. Bug B9 showed interaction between voting changes and AE responses. The `raft_offer_log` and `raft_pop_log` callbacks modify membership on log append/delete.

**Key code**: `raft_offer_log` (1129-1176), `raft_pop_log` (1178-1224), `raft_apply_entry` (811-874), `raft_recv_entry` (718-779)

**What to model**: Membership change interleaved with elections and log replication.

## Decision: Focus on Priorities 1-3

We will model elections, log replication, and AE response handling in a single specification. Membership changes will be abstracted (fixed 3-node configuration). This gives us the best chance of finding bugs in the most historically error-prone areas while keeping state space manageable.
