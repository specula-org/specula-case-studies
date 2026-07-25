# Instrumentation Spec: rabbitmq/ra

Action-to-code mapping for trace harness generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "event": "<event_name>",
  "node": "<server_id>",
  "from": "<source_server_id>",       // message events only
  "to": "<dest_server_id>",           // send events only
  "post_state": {
    "current_term": 0,
    "state": "follower",
    "commit_index": 0,
    "last_log_index": 0,
    "last_applied": 0,
    "voted_for": null,
    "query_index": 0,
    "cluster_change_permitted": false,
    "membership": "voter"
  },
  "msg": { ... },                     // message fields, event-specific
  "new_config": [...],                // config change events only
  "ts": 1234567890                    // monotonic timestamp (ns)
}
```

### State Fields Mapping

| Implementation field | TLA+ variable | Getter |
|---------------------|---------------|--------|
| `State#ra_server_state.current_term` | `currentTerm[i]` | `maps:get(current_term, State)` |
| FSM state atom | `state[i]` | Return value tag: `{follower, ...}`, `{leader, ...}` |
| `State#ra_server_state.commit_index` | `commitIndex[i]` | `maps:get(commit_index, State)` |
| `ra_log:last_index_term(Log)` | `LastLogIndex(i)` | `element(1, ra_log:last_index_term(maps:get(log, State)))` |
| `State#ra_server_state.last_applied` | `lastApplied[i]` | `maps:get(last_applied, State)` |
| `State#ra_server_state.voted_for` | `votedFor[i]` | `maps:get(voted_for, State, undefined)` |
| `State#ra_server_state.query_index` | `queryIndex[i]` | `maps:get(query_index, State)` |
| `State#ra_server_state.cluster_change_permitted` | `clusterChangePermitted[i]` | `maps:get(cluster_change_permitted, State)` |
| `State#ra_server_state.membership` | `membership[i]` | `maps:get(membership, State, voter)` |

### Message Fields Mapping

| Implementation field | TLA+ field | Notes |
|---------------------|-----------|-------|
| `#pre_vote_rpc.term` | `mterm` | |
| `#pre_vote_rpc.token` | `mtoken` | Erlang reference; serialize as integer hash |
| `#pre_vote_rpc.last_log_index` | `mlastLogIndex` | |
| `#pre_vote_rpc.last_log_term` | `mlastLogTerm` | |
| `#request_vote_rpc.term` | `mterm` | |
| `#request_vote_rpc.candidate_id` | `msource` | |
| `#append_entries_rpc.term` | `mterm` | |
| `#append_entries_rpc.prev_log_index` | `mprevLogIndex` | |
| `#append_entries_rpc.prev_log_term` | `mprevLogTerm` | |
| `#append_entries_rpc.leader_commit` | `mcommitIndex` | |
| `#append_entries_rpc.entries` | `mentries` | Serialize as length only |
| `#heartbeat_rpc.query_index` | `mqueryIndex` | |
| `#install_snapshot_rpc.meta.index` | `msnapshotIndex` | |
| `#install_snapshot_rpc.meta.term` | `msnapshotTerm` | |

## 2. Action-to-Code Mapping

### Election Actions

#### `call_for_election_pre_vote`
- **Code location**: `ra_server.erl:2860-2880` (`call_for_election(pre_vote, ...)`)
- **Trigger point**: After `call_for_election/2` returns for pre_vote
- **Fields**: Standard post_state
- **Notes**: Capture `pre_vote_token` as integer for token correlation. Pre-vote does NOT increment term.

#### `handle_pre_vote_request`
- **Code location**: `ra_server.erl:2882-2937` (`process_pre_vote`)
- **Trigger point**: After `process_pre_vote/3` returns
- **Fields**: Standard post_state + `from` (sender)
- **Notes**: Called from multiple FSM states (follower, candidate, pre_vote). Capture the calling FSM state.

#### `handle_pre_vote_response`
- **Code location**: `ra_server.erl:1206-1237` (`handle_pre_vote(#pre_vote_result{...})`)
- **Trigger point**: After handler returns
- **Fields**: Standard post_state + `from` (voter)
- **Notes**: Only fires in `pre_vote` state. Token matching happens inside handler.

#### `win_pre_vote`
- **Code location**: `ra_server.erl:1163-1170` (quorum reached in handle_pre_vote)
- **Trigger point**: When `required_quorum(Nodes) == NewVotes` triggers `call_for_election(candidate, ...)`
- **Fields**: Standard post_state
- **Notes**: This is the transition from pre_vote to candidate. Emitted just before `call_for_election(candidate)`. Post_state will show `candidate` with incremented term.

#### `handle_request_vote_request`
- **Code location**: `ra_server.erl:1448-1494` (`handle_follower(#request_vote_rpc{...})`)
- **Trigger point**: After handler returns
- **Fields**: Standard post_state + `from` (candidate)
- **Notes**: Non-voters silently ignore (line 1448-1452); still emit event for trace.

#### `handle_request_vote_response`
- **Code location**: `ra_server.erl:1028-1065` (`handle_candidate(#request_vote_result{...})`)
- **Trigger point**: After handler returns
- **Fields**: Standard post_state + `from` (voter)
- **Notes**: Only fires in `candidate` state.

#### `become_leader`
- **Code location**: `ra_server.erl:1037-1045` (quorum reached → `initialise_peers`)
- **Trigger point**: After `initialise_peers` returns and noop appended
- **Fields**: Standard post_state
- **Notes**: Post_state shows `leader` state. The noop entry is part of this event.

### Log Replication Actions

#### `client_request`
- **Code location**: `ra_server.erl:739-795` (`handle_leader({command, ...})`)
- **Trigger point**: After entry appended to log
- **Fields**: Standard post_state
- **Notes**: Multiple code paths (pipeline vs non-pipeline). Instrument the common `append` call.

#### `replicate_entries`
- **Code location**: `ra_server_proc.erl` (effect execution for `{send_rpc, ...}`)
- **Trigger point**: When AppendEntries RPC is sent
- **Fields**: `node` (leader), `to` (follower)
- **Notes**: Sent as an effect, not directly in `ra_server.erl`. Instrument at the effect execution point in `ra_server_proc.erl`.

#### `handle_append_entries_request`
- **Code location**: `ra_server.erl:1247-1405` (`handle_follower(#append_entries_rpc{...})`)
- **Trigger point**: After handler returns (full state available)
- **Fields**: Standard post_state (strong validation) + `from` (leader)
- **Notes**: This is the most important action for Family 1 bugs. Capture full post_state including commit_index and last_log_index.

#### `handle_append_entries_response`
- **Code location**: `ra_server.erl` (leader handles `#append_entries_reply`)
- **Trigger point**: After handler returns
- **Fields**: Standard post_state (weak) + `from` (follower)
- **Notes**: matchIndex/nextIndex updates happen here.

#### `advance_commit_index`
- **Code location**: `ra_server.erl:3598-3607` (`increment_commit_index`)
- **Trigger point**: After `increment_commit_index` returns with new commit_index
- **Fields**: Standard post_state
- **Notes**: Only fires when commit_index actually advances. Guard: `PotentialNewCommitIndex > CommitIndex`.

#### `apply_entries`
- **Code location**: `ra_server.erl:2212-2246` (`evaluate_commit_index_follower`) or leader apply path
- **Trigger point**: After `apply_to` returns
- **Fields**: Standard post_state (weak)
- **Notes**: Both leader and follower paths. Instrument the common `apply_to` call.

### Consistent Query Actions

#### `consistent_query`
- **Code location**: `ra_server.erl:846-869` (`handle_leader({consistent_query, ...})`)
- **Trigger point**: After heartbeat RPCs generated
- **Fields**: Standard post_state + `query_index`
- **Notes**: Only fires when `cluster_change_permitted = true`.

#### `handle_heartbeat_request`
- **Code location**: `ra_server.erl` (follower handles `#heartbeat_rpc`)
- **Trigger point**: After handler returns
- **Fields**: Standard post_state (weak) + `from` (leader)
- **Notes**: Heartbeat is separate from AppendEntries in Ra.

#### `handle_heartbeat_response`
- **Code location**: `ra_server.erl:3747-3782` (`heartbeat_rpc_quorum`)
- **Trigger point**: After `heartbeat_rpc_quorum` returns
- **Fields**: Standard post_state (weak) + `from` (follower)
- **Notes**: This is where query quorum is checked and queries released.

### Snapshot Actions

#### `handle_install_snapshot_request`
- **Code location**: `ra_server.erl:1503-1573` (`handle_follower(#install_snapshot_rpc{...})`)
- **Trigger point**: After handler returns
- **Fields**: Standard post_state (weak) + `from` (leader)
- **Notes**: Simplified in spec (atomic install). In impl, multi-phase chunking.

#### `handle_install_snapshot_response`
- **Code location**: `ra_server.erl` (leader handles `#install_snapshot_result`)
- **Trigger point**: After handler returns
- **Fields**: Standard post_state (weak) + `from` (follower)

### State Transition Actions

#### `candidate_step_down`
- **Code location**: `ra_server.erl:1066-1090` (candidate receives AER with term >= current)
- **Trigger point**: After state transition to follower
- **Fields**: Standard post_state (weak) + `from` (new leader)
- **Notes**: The AER itself is re-processed; only the step-down is this event.

#### `leader_step_down`
- **Code location**: `ra_server.erl:800-840` (leader receives higher-term message)
- **Trigger point**: After state transition to follower
- **Fields**: Standard post_state (weak) + `from` (message source)
- **Notes**: Query state is reset on step-down.

### Membership Change Actions

#### `propose_config_change`
- **Code location**: `ra_server.erl:3538-3562` (`append_cluster_change`)
- **Trigger point**: After cluster change appended to log
- **Fields**: Standard post_state + `new_config` (list of server IDs)
- **Notes**: `cluster_change_permitted` set to false after this.

## 3. Special Considerations

### Erlang-Specific Instrumentation

1. **Effects-based architecture**: `ra_server.erl` is a pure state machine returning `{NextState, State, Effects}`. Most send operations happen in `ra_server_proc.erl` when effects are executed. For send events (like `replicate_entries`), instrument at the effect execution point, not in `ra_server.erl`.

2. **gen_statem process**: Each Ra server is a single `gen_statem` process. All message handling is sequential — no concurrent threads. This simplifies trace ordering: events for a single server are always in order.

3. **Server ID format**: Ra uses `{Name, Node}` tuples as server IDs. Map these to short string IDs ("s1", "s2", ...) in order of first encounter.

4. **Term/VotedFor atomicity**: `ra_log_meta` persists term and voted_for atomically via DETS batch. No crash window between them (unlike some other Raft implementations).

5. **Pre-vote token**: Erlang `reference()` — serialize as integer hash or monotonic counter for trace JSON.

### Bootstrap State

Ra servers start with:
- `current_term = 0`
- `voted_for = undefined`
- `state = recover` (transitions to `recovered` then `follower`)
- `commit_index = 0`
- `last_applied = 0`
- Empty log

The trace spec's `TraceInit` uses the base spec's `Init` which matches these defaults. If the implementation starts with a bootstrap log entry, adjust `TraceInit` accordingly.

### Concurrent Events

Since Ra is single-process-per-server, events within a server are strictly ordered. Cross-server events may interleave. The trace harness should use a global monotonic timestamp (e.g., `erlang:monotonic_time(nanosecond)`) to establish total order.

### Heartbeat vs AppendEntries

Ra uses a **separate** `heartbeat_rpc` type (not an empty AppendEntries). The heartbeat carries `query_index` and `term` but no entries, prevLogIndex, or commitIndex. This is critical for Family 3 (consistent query) bugs — do not merge heartbeat and AER instrumentation.

### Log Entry Serialization

For trace validation, log entries need only `{index, term, type}`. The actual value/command payload is not needed for spec validation. Serialize entries as:
```json
{"index": 1, "term": 1, "type": "value"}
```

### Config Change Events

When a config change is appended (`append_cluster_change`), capture the new cluster membership as a list of server IDs in the `new_config` field. The spec maps this to a set.
