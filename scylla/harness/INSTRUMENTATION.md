# ScyllaDB Raft Instrumentation Guide

Guide for the Phase 3 (validation) agent to adjust trace instrumentation.

## Architecture

- **Trace module**: `harness/src/tla_trace.hh` — header-only, copied to `raft/tla_trace.hh` at apply time
- **Instrumentation**: Python script `harness/apply_instrumentation.py` inserts `#ifdef SCYLLA_TLA_TRACE_ENABLED` blocks into `raft/fsm.cc` and `raft/fsm.hh`
- **Test scenarios**: `harness/src/trace_test.cc` — Boost.Test using `fsm_debug` class
- **Activation**: Set env var `SCYLLA_TLA_TRACE=<path>` at runtime

## Instrumentation Points

| Action | File | Anchor (after apply) | Capture Level |
|--------|------|---------------------|---------------|
| ClientRequest | fsm.cc:~113 | After `_sm_events.signal()` in add_entry | Full |
| BecomeLeader | fsm.cc:~203 | After `logger.trace("fsm::become_leader()...")` | Full |
| Timeout | fsm.cc:~319 | Before `if (votes.tally_votes() == ...)` in become_candidate | Full |
| MaybeCommit | fsm.cc:~479 | After `_commit_idx = new_commit_idx` (2nd occurrence) | Full |
| HandleAppendEntriesRequest | fsm.cc:~705 | After accepted `send_to(from, append_reply{...})` | Full |
| HandleAppendEntriesResponse | fsm.cc:~818 | After `replicate_to(*opt_progress, false)` | Full |
| HandleRequestVoteRequest (grant) | fsm.cc:~873 | After `send_to(from, vote_reply{...true...})` | Full |
| HandleRequestVoteRequest (deny) | fsm.cc:~892 | After `send_to(from, vote_reply{...false...})` | Full |
| HandleRequestVoteResponse (won) | fsm.cc:~925 | After `"won vote"` log | Full |
| HandleRequestVoteResponse (lost) | fsm.cc:~938 | After `become_follower(server_id{})` (5th occ.) | Full |
| AppendEntries | fsm.cc:~989 | Before `send_to(progress.id, std::move(req))` | Full + msg |
| SendInstallSnapshot | fsm.cc:~1036 | After `send_to(progress.id, install_snapshot{...})` | Full + msg |
| HandleInstallSnapshot/TakeLocalSnapshot | fsm.cc:~1125 | Before `return true` in apply_snapshot | Full |
| BroadcastReadQuorum | fsm.cc:~1185 | After `send_to(p.id, read_quorum{...})` | Full |
| HandleReadQuorumResponse | fsm.cc:~1220 | After `"new commit read"` log | Full |
| Crash | fsm.cc:~1267 | After `become_follower({})` in stop() | Full |
| UpdateTerm | fsm.hh:~559 | After `update_current_term(msg.current_term)` in step() | Weak |
| HandleReadQuorumRequest | fsm.hh:~627 | After `send_to(from, read_quorum_reply{...})` in step(follower) | Full |

## How to Add a Field to an Event

1. Edit `harness/src/tla_trace.hh` — add a parameter to the relevant `emit_*()` function
2. Inside the function, append the field to the JSON output:
   ```cpp
   out += ",\"fieldName\":";
   append_num(out, value);  // or append_str for strings
   ```
3. Update the call site in `apply_instrumentation.py` (find the insertion for that action)
4. Re-apply: `bash harness/apply.sh`

## How to Add a New Event

1. Add a new `emit_*()` function in `harness/src/tla_trace.hh`:
   ```cpp
   inline void emit_new_action(uint64_t nid_low, int64_t term, ...) {
       auto nid = ServerMap::instance().lookup(nid_low);
       auto out = begin_event("NewAction", nid);
       out += ",";
       append_state(out, term, role, commitIdx, lastLogIdx, lastLogTerm);
       finish_event(out);
   }
   ```
2. Add a new insertion in `apply_instrumentation.py`:
   ```python
   ('unique_anchor_string', 1, "after", """
   #ifdef SCYLLA_TLA_TRACE_ENABLED
       if (tla_trace::enabled())
           tla_trace::emit_new_action(TLA_NID(_my_id), ...);
   #endif"""),
   ```
3. Add a matching `TraceNewAction` wrapper in `spec/Trace.tla`
4. Re-apply and rebuild

## How to Move a Capture Point

The `apply_instrumentation.py` script uses unique source-code strings as anchors. To move a capture point:

1. Find the insertion in `FSM_CC_INSERTIONS` or `FSM_HH_INSERTIONS`
2. Change the anchor string and/or `"before"`/`"after"` position
3. Adjust the `occurrence` number if the anchor appears multiple times
4. Re-apply: `bash harness/apply.sh`

## How to Rebuild and Re-run

```bash
# Re-apply instrumentation (reverts and re-instruments)
bash harness/apply.sh

# Rebuild (from build dir)
cmake --build artifact/scylla/build/trace --target trace_test -- -j$(nproc)

# Re-run a single scenario
SCYLLA_TLA_TRACE=traces/basic_consensus.ndjson \
  artifact/scylla/build/trace/test/raft/trace_test --run_test=test_trace_basic_consensus

# Or run everything
bash harness/run.sh
```

## Server ID Mapping

ScyllaDB uses UUID-based `server_id`. The trace module maps `UUID.get_least_significant_bits()` to `"s1"`, `"s2"`, `"s3"` in order of first registration. The test scenarios pre-register servers with deterministic UUIDs:
- `UUID(0, 1)` → `"s1"`
- `UUID(0, 2)` → `"s2"`
- `UUID(0, 3)` → `"s3"`

## State Capture

All state snapshots use post-state (captured AFTER the action completes):
- `currentTerm`: `_current_term` (uint64)
- `role`: derived from `_state` variant (`is_leader()` / `is_candidate()` / `is_follower()`)
- `commitIndex`: `_commit_idx` (uint64)
- `lastLogIndex`: `_log.last_idx()` (uint64)
- `lastLogTerm`: `_log.last_term()` (uint64)

Macro `TLA_ROLE_STR()` returns `"Leader"`, `"Candidate"`, or `"Follower"`.

## PreVote Filtering

PreVote is NOT modeled in the spec. The instrumentation guards with `!is_prevote` / `!request.is_prevote` to skip prevote events. Only real elections and real votes are traced.

## Compile Flag

All trace code is guarded by `#ifdef SCYLLA_TLA_TRACE_ENABLED`. The CMakeLists.txt patch adds `target_compile_definitions(raft PUBLIC SCYLLA_TLA_TRACE_ENABLED)`. To disable tracing at compile time, remove this line.
