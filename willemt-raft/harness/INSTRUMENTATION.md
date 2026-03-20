# Instrumentation Guide — willemt/raft

Quick reference for Phase 3 (validation) agent to adjust instrumentation.

## Architecture

willemt/raft is a callback-based C library. Instrumentation is:
1. **Trace module** (`tla_trace.h` / `tla_trace.c`) — NDJSON emission functions
2. **Patch** (`patches/instrumentation.patch`) — adds trace calls to `raft_server.c`
3. **Test harness** (`test_trace.c`) — drives a 3-node cluster, generates traces

All trace calls are guarded by `#ifdef RAFT_ENABLE_TRACE` and a runtime `tla_trace_enabled()` check via the `TLA_TRACE(cond, expr)` macro.

## Instrumentation Points

After `apply.sh`, these trace calls exist in `artifact/raft/src/raft_server.c`:

| Event | Function | Location | Capture |
|-------|----------|----------|---------|
| Timeout | `raft_election_start` | After `raft_become_candidate` returns | Full post-state |
| HandleRequestVoteRequest | `raft_recv_requestvote` | Before `return e` at `done:` label | Full post-state + msg |
| HandleRequestVoteResponse | `raft_recv_requestvote_response` | Before `return 0` (step-down + final) | Full post-state + msg |
| ClientRequest | `raft_recv_entry` | After `raft_append_entry` succeeds | Full post-state + value |
| SendAppendEntries | `raft_send_appendentries` | After `send_appendentries` callback | No post-state |
| SendInstallSnapshot | `raft_send_appendentries` | After `send_snapshot` callback (snapshot path) | No post-state |
| HandleAppendEntriesRequest | `raft_recv_appendentries` | Before `return e` at `out:` label | Full post-state + msg |
| HandleAppendEntriesResponse | `raft_recv_appendentries_response` | Before each `return 0` (6 sites) | Full post-state + msg |
| TakeSnapshot | `raft_end_snapshot` | Before each `return 0` (2 sites) | Full post-state |
| Crash | `test_trace.c` (test harness) | Before stopping server | Node ID only |
| Recover | `test_trace.c` (test harness) | After server restart | Full post-state |
| HandleInstallSnapshot | `test_trace.c` (test harness) | After `raft_end_load_snapshot` | Full post-state |

## How To: Add a Field to an Event

1. Edit the corresponding `tla_emit_*` function in `harness/src/tla_trace.c`
2. Add the new field to the `fprintf` call (JSON format)
3. Rebuild: `bash harness/run.sh`

Example — adding `votedFor` to post-state:
```c
// In write_post():
fprintf(fp, "\"post\":{\"term\":%ld,\"state\":\"%s\","
            "\"commitIndex\":%ld,\"lastLogIndex\":%ld,"
            "\"lastLogTerm\":%ld,\"votedFor\":%d}",
        ...,
        raft_get_voted_for(raft));
```

## How To: Add a New Event Type

1. Add a new emit function in `tla_trace.h` / `tla_trace.c`
2. Add a `TLA_TRACE(...)` call at the desired location in the patch
3. Add corresponding `Trace*` action wrapper in `Trace.tla`
4. Rebuild: `bash harness/run.sh`

## How To: Move a Capture Point

The `TLA_TRACE(cond, expr)` macro can be moved within a function. Common moves:
- **Before → After**: Move the macro line after the state-changing operation
- **After → Before**: Move it before (captures pre-state instead of post-state)

After moving, regenerate the patch:
```bash
cd artifact/raft
diff -u /dev/null src/raft_server.c  # inspect changes
# Or just re-run the harness and validate
```

## How To: Rebuild and Re-run

```bash
cd case-studies/willemt-raft
bash harness/run.sh                    # Full rebuild + trace collection
```

To validate a trace:
```bash
cd spec
java -DJSON=../traces/basic_consensus.ndjson \
     -cp $SPECULA/lib/tla2tools.jar:$SPECULA/lib/CommunityModules-deps.jar \
     tlc2.TLC -deadlock -config Trace.cfg -workers 1 Trace.tla
```

## Key Details

- **Node ID mapping**: Integer node IDs (1,2,3) → "s1","s2","s3" via `fprintf("s%d", id)`
- **State mapping**: `RAFT_STATE_FOLLOWER(1)` → "follower", `CANDIDATE(2)` → "candidate", `LEADER(3)` → "leader"
- **Timestamps**: `clock_gettime(CLOCK_MONOTONIC)` nanoseconds
- **Value**: All ClientRequest events emit `"v1"` — adjust in the `tla_emit_client_request` call in `raft_recv_entry`
- **Thread safety**: Not needed — willemt/raft is single-threaded
- **Trace.cfg**: Uses `Server = {"s1", "s2", "s3"}` (string constants, not model values)
