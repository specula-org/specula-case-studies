# Bug Archaeology: willemt/raft

## Bug Pattern Classification

### Category A: Confirmed Bugs (Fixed)

| ID | Source | Summary | Root Cause | Affected Component | Commit/Issue |
|----|--------|---------|------------|-------------------|--------------|
| B1 | commit daa93cb | voted_for cleared on become_leader causing assertion fire | `become_leader` cleared `voted_for`; when a same-term RequestVote arrived at the new leader, `__should_grant_vote` would see `voted_for == -1` and could grant | Election / RequestVote | daa93cb |
| B2 | commit 75b0104 | Rogue leaders caused by missing term step-down | `recv_appendentries_response` and `recv_requestvote` didn't step down on higher term; `become_follower` incorrectly cleared `voted_for` | Election, Term management | 75b0104 |
| B3 | commit 3fc7f32 | Entries not having their term checked in AE handler | `recv_appendentries` deleted entries unconditionally at `prev_log_idx+1` without checking if terms matched one-by-one | AppendEntries, Log consistency | 3fc7f32 |
| B4 | commit c4de21e | Majority counted all nodes, not just voting nodes | Commit index advancement used `num_nodes / 2` instead of `num_voting_nodes / 2` | Commit advancement | c4de21e |
| B5 | commit 14a4e6a | current_leader not discarded on term change | Leader stepping down kept stale `current_leader` pointer, causing wrong leader hints | Term transitions, Leader tracking | 14a4e6a |
| B6 | commit 9de8af4 | Off-by-one in `log_get_from_idx` and `apply_entry` idx | `log_get_from_idx` used `idx < me->base` instead of `idx <= me->base`; applylog callback got wrong index | Log management | 9de8af4 |
| B7 | commit b912ff5 | Multiple circular buffer bugs in log | `back` not wrapped with modulo; `front` not wrapped; `log_delete` incorrect index math; `log_get_at_idx` didn't handle `idx==0` | Log (circular buffer) | b912ff5 |
| B8 | commit f8236e0 + 5e336b8 | AE error response handling: stale responses cause assert | Missing guard for stale AE responses where `current_idx < match_idx` | AE response handling | f8236e0 |
| B9 | commit 236f281 | `has_sufficient_logs` not called after voting change committed | Non-voting node's AE response ignored during voting change, causing promotion callback to never fire | Membership change + AE response | 236f281 |
| B10 | commit fab7d43 | `raft_periodic` error handling for `raft_apply_all` | Wrong error check (`-1 != e` instead of `0 != e`) caused apply errors to be swallowed | Periodic tick | fab7d43 |
| B11 | commit 296c7e0 | No protection against AE conflicting with committed entries | AE handler could delete committed entries; no SHUTDOWN guard | AppendEntries safety | 296c7e0 |
| B12 | commit ab96a76 | No leader lease protection on RequestVote | Removed nodes could disrupt cluster by sending RequestVote; no minimum election timeout check | RequestVote, Leader disruption | ab96a76 |

### Category B: Suspected Weak Spots (Not Yet Confirmed)

| ID | Component | Why Suspicious | Evidence |
|----|-----------|----------------|----------|
| W1 | `__should_grant_vote` missing "re-vote for same candidate" | Code has `TODO: if voted for is candidate return 1` comment at line 543 | raft_server.c:543 |
| W2 | `raft_recv_appendentries` `current_idx` field in response | On success, `r->current_idx` is set incrementally during entry processing, not to final state; on failure it's set to `raft_get_current_idx()` | Complex multi-path logic |
| W3 | `log_get_from_idx` doesn't handle circular buffer wrap | Issue #95: when entries wrap around the circular buffer, only entries up to the end of the array are returned | Open issue #95 |
| W4 | Leader infinite snapshot loop | Issue #91: after compaction, followers behind `snapshot_last_idx` keep getting snapshots sent but `next_idx` never updates | Open issue #91 |
| W5 | Single-node auto-promotion in `raft_periodic` | If only 1 voting node, it auto-becomes leader without election; interacts with membership changes | raft_server.c:229-232 |
| W6 | Commit index advancement uses `r->current_idx` as the point | Only checks majority for `r->current_idx`, not scanning for highest majority-replicated index | raft_server.c:352-373 |

### Category C: Implementation Deviations from Paper

| ID | Deviation | Reason | Risk |
|----|-----------|--------|------|
| D1 | Leader lease check on RequestVote (reject if leader is fresh) | Prevents disruption by removed nodes (ab96a76) | May delay elections after partition heals |
| D2 | No PreVote mechanism | Noted as needed (issue #78) but never implemented | Partitioned nodes can bump terms |
| D3 | `voting_cfg_change_log_idx` guard for single config change at a time | Implementation-specific safety mechanism | Complex interaction with commit advancement |
| D4 | `current_leader` tracked explicitly (not in paper) | Used for client redirection hints | Stale leader tracking caused bug B5 |
| D5 | AE response includes `first_idx` field (not in paper) | Optimization for tracking what was sent | Adds complexity to response handling |
| D6 | 2-step membership change: ADD_NONVOTING -> ADD_NODE | Allows catch-up before promotion | More complex than joint consensus |
| D7 | `raft_recv_entry` sends AE only to caught-up nodes | Optimization: `next_idx == current_idx` check | May delay replication to slow followers |
