# RedisRaft Trace Instrumentation Guide

Quick reference for adjusting instrumentation during Phase 3 (trace validation).

## Architecture

- **Trace module**: `harness/src/tla_trace.h` + `harness/src/tla_trace.c`
- **Instrumentation patch**: `harness/patches/instrumentation.patch` (applied to `deps/raft/src/raft_server.c`)
- **Test scenarios**: `harness/src/test_trace.c`
- **Build flag**: `-DREDISRAFT_ENABLE_TRACE` (zero-cost when disabled)
- **Output control**: `RAFT_TRACE_FILE` env var → NDJSON file path

## Instrumentation Points

After `apply.sh`, the trace calls are at these locations in `deps/raft/src/raft_server.c`:

| # | Event | Function | Trigger Point | Capture Level |
|---|-------|----------|---------------|---------------|
| 1 | `Timeout` | `raft_become_candidate()` | After term increment + self-vote | Full |
| 2 | `BecomeLeader` | `raft_become_leader()` | After noop append + state transition | Full |
| 3 | `HandleRequestVoteRequest` | `raft_recv_requestvote()` | After response built (non-prevote only) | Full + msg |
| 4 | `HandleRequestVoteResponse` | `raft_recv_requestvote_response()` | BEFORE majority check/become_leader | Weak + msg |
| 5 | `ClientRequest` | `raft_recv_entry()` | After `raft_append_entry()` (NORMAL type) | Full |
| 6 | `ProposeAddServer` | `raft_recv_entry()` | After append (ADD_NODE type) | Full + target |
| 7 | `ProposeRemoveServer` | `raft_recv_entry()` | After append (REMOVE_NODE type) | Full + target |
| 8 | `HandleAppendEntriesRequest` | `raft_recv_appendentries()` | After all log updates + commit advance | Full + msg |
| 9 | `HandleAppendEntriesResponse` | `raft_recv_appendentries_response()` | After matchIndex update | Weak + msg |
| 10 | `AdvanceCommitIndex` | `raft_update_commit_idx()` | After `raft_set_commit_idx()` | Commit |
| 11 | `TakeSnapshot` | `raft_end_snapshot()` | After snapshot_in_progress=0 | Full + snapshot |
| 12 | `HandleInstallSnapshotRequest` | `raft_begin_load_snapshot()` | After log reset + node cleanup | Weak + msg |
| 13 | `EndLoadSnapshot` | `raft_end_load_snapshot()` | After snapshot metadata finalized | Full + snapshot |

## Capture Levels

- **Full**: term, role, commitIndex, lastLogIndex, lastLogTerm, votedFor
- **Weak**: term, role only (for async paths or where log state is transitional)
- **Commit**: term, role, commitIndex

## How to Add a New Field to an Event

1. Add the field to the JSON output in `tla_trace.c` (modify the relevant `tla_trace_event_*` function)
2. Add the corresponding field access in `Trace.tla` (e.g., `logline.event.state.newField`)
3. Rebuild: `bash harness/run.sh`

## How to Add a New Event Type

1. Add a new emit function in `tla_trace.h` / `tla_trace.c` (or reuse an existing one)
2. Add the `#ifdef REDISRAFT_ENABLE_TRACE` block in `raft_server.c` at the trigger point
3. Add `<Event>IfLogged` wrapper in `Trace.tla`
4. Add the wrapper to `TraceNext`
5. Regenerate the patch: `cd artifact/redisraft && git diff deps/raft/src/raft_server.c > ../../harness/patches/instrumentation.patch`

## How to Move a Capture Point

For before→after (or vice versa), move the `#ifdef REDISRAFT_ENABLE_TRACE` block in `raft_server.c`. Key considerations:

- **HandleRequestVoteResponse**: MUST be emitted BEFORE the majority check and potential `raft_become_leader()` call, so the trace ordering matches the spec's action decomposition
- **HandleAppendEntriesRequest**: emit AFTER all log updates and commit index advancement
- **AdvanceCommitIndex**: emit inside the `if (ety->term == me->current_term)` block, after `raft_set_commit_idx()`

## How to Rebuild After Changes

```bash
cd case-studies/redisraft
# If you modified raft_server.c directly:
cd artifact/redisraft && git diff deps/raft/src/raft_server.c > ../../harness/patches/instrumentation.patch && cd ../..
# Full rebuild + trace collection:
bash harness/run.sh
```

## Server ID Mapping

Implementation uses `raft_node_id_t` (integers: 1, 2, 3). The trace module maps to TLA+ IDs (`"s1"`, `"s2"`, `"s3"`) via `tla_trace_register_server()`. The Trace.tla `ServerMap` then maps strings to TLC model values using `ToString()`.

## Known Trace.tla Adjustments Made

- `ServerMap`: maps JSON strings `"s1"` → TLC model values `s1` using `ToString()`
- `SilentTimeout`: guarded against re-firing when RV messages are already in the bag
- `SilentAppendEntry`: skips when next event is `ClientRequest` (which does the append itself)
- `AdvanceCommitIndexIfLogged`: idempotent (accepts already-advanced commitIndex)
- `HandleRequestVoteResponse` trace emit: placed BEFORE majority check in the C code
