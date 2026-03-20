# RethinkDB Raft Trace Instrumentation Guide

Guide for the Phase 3 (validation) agent to adjust instrumentation when trace validation reveals issues.

## Architecture

- **Trace header**: `harness/src/raft_trace.hpp` — singleton writer + emit helper functions
- **Instrumented files**: Applied via `harness/patches/instrumentation.patch`
  - `src/clustering/generic/raft_core.tcc` — 18 emit calls across 13 spec actions
  - `src/unittest/clustering_utils_raft.cc` — trace init/shutdown + crash events
  - `src/unittest/clustering_raft.cc` — trace-specific test scenarios
- **Guard macro**: `RETHINKDB_TLA_TRACE` — all instrumentation is behind this ifdef
- **Env var**: `RAFT_TRACE_FILE=path.ndjson` — set to enable trace output

## Instrumentation Points

After applying the patch, emit calls are at these locations in `raft_core.tcc`:

| Event | Spec Action | Location (after patch) | Capture Level |
|-------|-------------|----------------------|---------------|
| `timeout` | `Timeout(s)` | `candidate_run_election()`, after `update_term` | Full |
| `request_vote_send` | `RequestVote(s, t)` | `candidate_run_election()`, before `send_rpc` | Send (no state) |
| `request_vote_recv` | `HandleRequestVoteRequest(s, m)` | `on_request_vote_rpc()`, 5 return paths | Full |
| `request_vote_response` | `HandleRequestVoteResponse(s, m)` | `candidate_run_election()`, after reply processing | Full |
| `virtual_heartbeat_start` | `StartVirtualHeartbeat(leader, follower)` | `on_connected_members_change()`, after sender set | Send |
| `virtual_heartbeat_stop` | `StopVirtualHeartbeat(leader, follower)` | `on_connected_members_change()`, before sender clear | Send |
| `client_request` | `ClientRequest(s, v)` | `propose_change()`, after `leader_append_log_entry` | Full |
| `append_entries_send` | `AppendEntries(s, t)` | `leader_send_updates()`, before `send_rpc` | Send |
| `append_entries_recv` | `HandleAppendEntriesRequest(s, m)` | `on_append_entries_rpc()`, 3 return paths | Full |
| `append_entries_response` | `HandleAppendEntriesResponse(s, m)` | `leader_send_updates()`, after reply processing | Full |
| `complete_step_down` | `CompleteStepDown(s)` | `candidate_or_leader_note_term()` coroutine, after `update_term` | Full |
| `propose_config_change` | `ProposeConfigChange(s, newVoters)` | `propose_config_change()`, after `leader_append_log_entry` | Full |
| `continue_reconfiguration` | `LeaderContinueReconfiguration(s)` | `leader_continue_reconfiguration()`, after `leader_append_log_entry` | Full |
| `step_down_config_change` | `LeaderStepDownAfterConfigChange(s)` | `leader_continue_reconfiguration()`, before `note_term` | Bare (node only) |
| `install_snapshot_send` | `SendInstallSnapshot(s, t)` | `leader_send_updates()`, before install_snapshot `send_rpc` | Send |
| `install_snapshot_recv` | `HandleInstallSnapshotRequest(s, m)` | `on_install_snapshot_rpc()`, 3 return paths | Full |
| `install_snapshot_response` | `HandleInstallSnapshotResponse(s, m)` | `leader_send_updates()`, after IS reply processing | Full |
| `crash` | `Crash(s)` | `clustering_utils_raft.cc`, `set_live(dead)` | Bare (node only) |

### Not Traced (Silent in Spec)

- **TakeSnapshot**: Happens inside `update_commit_index()` as a side effect of commit advance. Cannot be traced separately because the snapshot fires BEFORE the parent action's trace event. Handled by `SilentTakeSnapshot` in `Trace.tla`.

## State Fields

Every event with full state includes (via `RAFT_TRACE_STATE_ARGS` macro):

| Field | Source | Description |
|-------|--------|-------------|
| `currentTerm` | `ps().current_term` | Current term |
| `role` | `RAFT_TRACE_ROLE` macro | "follower", "candidate", "leader" |
| `commitIndex` | `ps().commit_index` | Highest committed entry index |
| `lastLogIndex` | `ps().log.get_latest_index()` | Absolute last log index |
| `lastLogTerm` | `ps().log.get_entry_term(latest)` | Term of last log entry |
| `votedFor` | `ps().voted_for` | Mapped to "s1"/"nil" etc. |
| `snapshotIndex` | `ps().log.prev_index` | Snapshot boundary index |
| `snapshotTerm` | `ps().log.prev_term` | Term at snapshot boundary |

## How to Add a Field to an Event

1. Find the emit call in `raft_core.tcc` (search for the event name string)
2. Add the field to the `_extra` char buffer using `snprintf`:
   ```cpp
   snprintf(_extra, sizeof(_extra),
       ",\"my_field\":%" PRIu64, some_value);
   ```
3. The `_extra` string is appended inside the JSON object, so always start with a comma

## How to Add a New Event

1. Choose the emit helper:
   - `raft_trace_emit_node()` — node event with full state (10 args + extra)
   - `raft_trace_emit_recv()` — recv event with node + from + state (12 args + extra)
   - `raft_trace_emit_send()` — send event (from + to, no state)
   - `raft_trace_emit_bare()` — minimal (node only)

2. Add the emit call wrapped in `#ifdef RETHINKDB_TLA_TRACE`:
   ```cpp
   #ifdef RETHINKDB_TLA_TRACE
   raft_trace_emit_node("my_event", this_member_id, RAFT_TRACE_STATE_ARGS);
   #endif
   ```

3. Add a corresponding `TraceMyEvent` wrapper in `Trace.tla`

## How to Rebuild and Re-run

```bash
cd case-studies/rethinkdb

# 1. Apply instrumentation
bash harness/apply.sh

# 2. Rebuild (incremental — only recompiles changed files)
cd artifact/rethinkdb
CXXFLAGS="-DRETHINKDB_TLA_TRACE" make -j$(nproc) DEBUG=1 ALLOW_WARNINGS=1

# 3. Run a single test scenario
RAFT_TRACE_FILE=../../traces/basic_3node.ndjson \
  build/debug/rethinkdb-unittest --gtest_filter='ClusteringRaft.TraceBasic3'

# 4. Validate
cd ../../spec
java -DJSON=../traces/basic_3node.ndjson \
  -cp ../../../lib/tla2tools.jar:../../../lib/CommunityModules-deps.jar \
  tlc2.TLC -config Trace.cfg -deadlock Trace
```

## Server ID Mapping

- Implementation uses UUIDs (`raft_member_id_t`)
- Trace module assigns `s1`, `s2`, `s3`, ... in registration order
- Registration happens in `dummy_raft_cluster_t::add_member()`
- **Note**: Members are registered in `std::set<raft_member_id_t>` iteration order (UUID sort), not creation order. So `member_ids[0]` may not be `s1`.
- The `Trace.cfg` must have `Server = {"s1", "s2", "s3"}`

## Known Issues for Phase 3

- **Snapshot ordering**: `TakeSnapshot` fires inside `update_commit_index` (atomically with commit advance). Handled by `SilentTakeSnapshot` in Trace.tla, but with full-trace lookahead (`\E futureIdx \in traceIdx..Len(TraceLog)`). On traces with install_snapshot events, TLC may explore branches where SilentTakeSnapshot doesn't fire before TraceSendInstallSnapshot, leading to wrong message content. The `TraceSendInstallSnapshot` guard (`snapshotIndex[s] = ll.lastIncludedIndex`) prevents invariant violations but may cause deadlock on that branch.
- **Value field**: `client_request` always uses `"v1"` — `Trace.cfg` needs `Value = {"v1"}`.
- **Stale events after crash**: AE response events may appear after crash events due to concurrent coroutine cleanup. Handled by `TraceDiscardStaleAEResponse` and `TraceDiscardStaleAESend`.

## Validated Traces

| Trace | Events | Status | Notes |
|-------|--------|--------|-------|
| `basic_3node` | 92 | PASS | 3-node cluster, 10 writes, all invariants pass |
| `failover_3node` | 141 | Phase 3 | 3-node with crash/rejoin, needs snapshot ordering fix |
