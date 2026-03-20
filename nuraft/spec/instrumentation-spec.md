# Instrumentation Spec: nuraft

Action-to-code mapping for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a single JSON line (NDJSON):

```json
{
  "tag": "trace",
  "event": "<EventName>",
  "nid": <server_id>,
  "state": {
    "term": <uint64>,
    "role": "<follower|candidate|leader>",
    "commitIndex": <uint64>,
    "smCommitIndex": <uint64>,
    "precommitIndex": <uint64>,
    "lastLogIndex": <uint64>,
    "lastLogTerm": <uint64>
  },
  ... event-specific fields ...
}
```

### State Fields

| Implementation getter/field | TLA+ variable | Type |
|---|---|---|
| `state_->get_term()` | `currentTerm` | uint64 |
| `role_` (srv_role enum) | `state` | string: "follower"/"candidate"/"leader" |
| `quick_commit_index_` | `commitIndex` | uint64 |
| `sm_commit_index_` | `smCommitIndex` | uint64 |
| `precommit_index_` | `precommitIndex` | uint64 |
| `log_store_->next_slot() - 1` | `LastLogIndex` | uint64 |
| `term_for_log(log_store_->next_slot() - 1)` | `LastLogTerm` | uint64 |

### Message Fields (event-specific)

| Implementation field | TLA+ field | Events |
|---|---|---|
| `req.get_src()` / `resp.get_src()` | `from` | all message events |
| `req.get_dst()` / destination | `to` | all message events |
| `req.get_term()` / `resp.get_term()` | `msgTerm` | all message events |
| `req.get_last_log_idx()` | `lastLogIdx` | vote/prevote requests |
| `req.get_last_log_term()` | `lastLogTerm` | vote/prevote requests |
| `resp.get_accepted()` | `accepted` | vote/prevote/AE responses |
| `resp.get_next_idx()` | `nextIdx` | AE responses |

## Section 2: Action-to-Code Mapping

### 1. Timeout (election timeout → pre-vote)

- **Spec action**: `Timeout`
- **Code location**: `handle_vote.cxx:48-197` (`request_prevote`)
- **Trigger point**: After line 132 (`pre_vote_.dead_++`), before sending requests
- **Trace event**: `"Timeout"`
- **Fields**: state snapshot only
- **Notes**: Capture state AFTER setting `hb_alive_ = false` (line 126) and `role_ = candidate` (line 128). This event fires once per pre-vote initiation, not per peer.

### 2. HandlePreVoteRequest

- **Spec action**: `HandlePreVoteRequest`
- **Code location**: `handle_vote.cxx:431-479` (`handle_prevote_req`)
- **Trigger point**: After decision (line 468: grant, or line 471-475: deny), before return
- **Trace event**: `"HandlePreVoteRequest"`
- **Fields**: state + `from` (req.get_src()), `msgTerm` (req.get_term()), `granted` (bool)
- **Notes**: Capture whether vote was granted or denied.

### 3. HandlePreVoteResponse

- **Spec action**: `HandlePreVoteResponse`
- **Code location**: `handle_vote.cxx:481-558` (`handle_prevote_resp`)
- **Trigger point**: After processing (line 504), before quorum check
- **Trace event**: `"HandlePreVoteResponse"`
- **Fields**: state + `from` (resp.get_src()), `msgTerm` (resp.get_term()), `accepted` (resp.get_accepted())
- **Notes**: Capture after tallying but before potential initiate_vote trigger.

### 4. InitiateVote

- **Spec action**: `InitiateVote`
- **Code location**: `handle_vote.cxx:199-314` (`initiate_vote` + `request_vote`)
- **Trigger point**: After `save_state()` at line 261 in `request_vote`
- **Trace event**: `"InitiateVote"`
- **Fields**: state snapshot only (term will reflect new term)
- **Notes**: This captures the combined initiate_vote → request_vote flow. State is captured AFTER save_state so persisted and in-memory state match.

### 5. HandleVoteRequest

- **Spec action**: `HandleVoteRequest`
- **Code location**: `handle_vote.cxx:316-388` (`handle_vote_req`)
- **Trigger point**: After decision (line 380: grant + save_state, or line 384: deny), before return
- **Trace event**: `"HandleVoteRequest"`
- **Fields**: state + `from` (req.get_src()), `msgTerm` (req.get_term()), `granted` (bool), `lastLogIdx`, `lastLogTerm`
- **Notes**: Capture after `save_state()` if vote was granted.

### 6. HandleVoteResponse

- **Spec action**: `HandleVoteResponse`
- **Code location**: `handle_vote.cxx:390-429` (`handle_vote_resp`)
- **Trigger point**: After vote tally (line 406-411), before become_leader check
- **Trace event**: `"HandleVoteResponse"`
- **Fields**: state + `from` (resp.get_src()), `msgTerm` (resp.get_term()), `accepted` (resp.get_accepted())
- **Notes**: State captured BEFORE potential become_leader. If become_leader fires, a separate BecomeLeader event is emitted.

### 7. BecomeLeader

- **Spec action**: `BecomeLeader`
- **Code location**: `raft_server.cxx:1122-1220` (`become_leader`)
- **Trigger point**: After config entry appended (line 1193-1195), before request_append_entries
- **Trace event**: `"BecomeLeader"`
- **Fields**: state snapshot (role = "leader", term, commitIndex, lastLogIndex updated)
- **Notes**: lastLogIndex reflects the newly appended config entry. precommitIndex = lastLogIndex.

### 8. ClientRequest

- **Spec action**: `ClientRequest`
- **Code location**: `handle_client_request.cxx:85-142` (`handle_cli_req`)
- **Trigger point**: After `try_update_precommit_index` (line 142), before response setup
- **Trace event**: `"ClientRequest"`
- **Fields**: state + `logIndex` (last_idx from line 124)
- **Notes**: Capture after all entries appended and pre-committed. precommitIndex should reflect new value.

### 9. AppendEntries (leader sends)

- **Spec action**: `AppendEntries`
- **Code location**: `handle_append_entries.cxx:466-666` (`create_append_entries_req` + `send_request`)
- **Trigger point**: After request created (line 640-643), before `send_req` (line 440)
- **Trace event**: `"AppendEntries"`
- **Fields**: state + `to` (peer ID), `prevLogIndex`, `prevLogTerm`, `numEntries`, `commitIdx`
- **Notes**: One event per peer per send. Empty entries = heartbeat.

### 10. HandleAppendEntries (follower receives)

- **Spec action**: `HandleAppendEntries`
- **Code location**: `handle_append_entries.cxx:668-1144` (`handle_append_entries`)
- **Trigger point**: After all processing (line 1094: commit), before response return
- **Trace event**: `"HandleAppendEntries"`
- **Fields**: state + `from` (req.get_src()), `msgTerm` (req.get_term()), `accepted` (bool), `numEntries` (req.log_entries().size())
- **Notes**: State reflects post-commit state. lastLogIndex may have changed due to append/overwrite.

### 11. HandleAppendEntriesResponse

- **Spec action**: `HandleAppendEntriesResponse`
- **Code location**: `handle_append_entries.cxx:1169-1508` (`handle_append_entries_resp`)
- **Trigger point**: After matchIndex update (line 1226) or nextIndex rewind (line 1338)
- **Trace event**: `"HandleAppendEntriesResponse"`
- **Fields**: state + `from` (resp.get_src()), `msgTerm` (resp.get_term()), `accepted` (resp.get_accepted()), `matchIndex` (new_matched_idx or 0)
- **Notes**: Weak validation — commitIndex may not be updated yet (happens in AdvanceCommitIndex).

### 12. AdvanceCommitIndex

- **Spec action**: `AdvanceCommitIndex`
- **Code location**: `handle_append_entries.cxx:1523-1608` (`get_expected_committed_log_idx`)
- **Trigger point**: After computing committed index, at the `commit()` call site (line 1304)
- **Trace event**: `"AdvanceCommitIndex"`
- **Fields**: state + `newCommitIndex` (committed_index from line 1296)
- **Notes**: Only emit when commitIndex actually advances. Called from multiple sites: handle_append_entries_resp (line 1304), request_append_entries (line 167), notify_log_append_completion (line 1630).

### 13. CommitEntry

- **Spec action**: `CommitEntry`
- **Code location**: `handle_commit.cxx:184-319` (`commit_in_bg_exec`)
- **Trigger point**: After `sm_commit_index_.compare_exchange_strong` (line 278)
- **Trace event**: `"CommitEntry"`
- **Fields**: state + `smCommitIndex` (index_to_commit), `entryType` ("app" or "conf")
- **Notes**: One event per committed entry. precommitIndex should be >= smCommitIndex (Bug Family 1 check).

### 14. ProposeConfigChange

- **Spec action**: `ProposeConfigChange`
- **Code location**: `handle_join_leave.cxx` (handle_add_srv_req, handle_rm_srv_req)
- **Trigger point**: After config entry stored, after `config_changing_ = true`
- **Trace event**: `"ProposeConfigChange"`
- **Fields**: state + `configType` ("add" or "remove"), `targetServer`
- **Notes**: Only emit for leader-initiated config changes.

### 15. AdjustQuorum

- **Spec action**: `AdjustQuorum`
- **Code location**: `handle_vote.cxx:105-123` or `handle_append_entries.cxx:195-243`
- **Trigger point**: After `ctx_->set_params(clone)` (line 122 or line 225)
- **Trace event**: `"AdjustQuorum"`
- **Fields**: state + `newQuorumSize` (1)
- **Notes**: Only fires for 2-node clusters when peer is unresponsive.

### 16. Crash

- **Spec action**: `Crash`
- **Code location**: N/A (external event)
- **Trigger point**: On server restart, before processing any messages
- **Trace event**: `"Crash"`
- **Fields**: state (post-recovery state from persisted storage)
- **Notes**: Emit on restart. State reflects recovered values from stable storage.

### 17. PersistState

- **Spec action**: `PersistState`
- **Code location**: `handle_vote.cxx:261` (`save_state` in request_vote), `raft_server.cxx:1580` (save_state in update_term)
- **Trigger point**: After `ctx_->state_mgr_->save_state(*state_)` returns
- **Trace event**: `"PersistState"`
- **Fields**: `persistedTerm`, `persistedVotedFor`
- **Notes**: Emit after every save_state call. Critical for Bug Family 2 crash window analysis.

## Section 3: Special Considerations

### 1. Concurrent Threads

nuraft has multiple background threads that can emit events concurrently:

| Thread | Events |
|---|---|
| Main Raft thread (lock_) | Timeout, HandlePreVote*, HandleVote*, HandleAE, HandleAEResp, BecomeLeader |
| Client request thread (cli_lock_) | ClientRequest |
| Commit background thread | CommitEntry |
| Per-peer heartbeat timers | AppendEntries |

**Recommendation**: Use a thread-safe trace writer with a global sequence counter to preserve total order. Use `std::mutex` to protect the trace file, or use a lock-free SPSC queue per thread with a merging consumer.

### 2. State Snapshot Timing

- **Pre-action** events (Timeout, InitiateVote): capture state BEFORE the action modifies it, then include "post-state" fields showing expected post-state.
- **Post-action** events (HandleVoteRequest, HandleAE, etc.): capture state AFTER the action completes.
- **For Bug Family 2**: PersistState must be emitted AFTER save_state() returns. InitiateVote should be emitted AFTER save_state (i.e., capture the combined initiate_vote + request_vote as one event).

### 3. Bootstrap State

nuraft initializes with:
- `term = 0` (or recovered from persistent state)
- `votedFor = -1` (mapped to `Nil`)
- Empty log (or recovered from log store)
- `role = follower`
- `commitIndex = sm_commit_index_ = state_machine_->last_commit_index()`

The trace's first event should reflect this initial state. If the node is recovering from a crash, the first event should be `"Crash"` with the recovered state.

### 4. Self-Vote in InitiateVote

The `InitiateVote` event combines `initiate_vote()` + `request_vote()`. The self-vote (votesGranted += 1) happens in `request_vote` at line 262. The trace should capture state AFTER the self-vote.

### 5. Message Correlation

Messages are sent and received asynchronously. The trace does NOT need to correlate send/receive pairs — the TLA+ message bag handles this. However, message events should include the message term (`msgTerm`) to distinguish stale messages.

### 6. Log Entry Types

When appending log entries, include the entry type in the trace:
- `"app"` for `log_val_type::app_log`
- `"conf"` for `log_val_type::conf`

This is needed to distinguish regular client requests from config changes in the spec.

### 7. Instrumentation Guard

Use a compile-time flag (`#ifdef NURAFT_TLA_TRACE`) to enable/disable instrumentation. Set the trace file path via environment variable `NURAFT_TRACE_FILE`.

```cpp
#ifdef NURAFT_TLA_TRACE
#include "tla_trace.h"
// Emit trace events
#endif
```
