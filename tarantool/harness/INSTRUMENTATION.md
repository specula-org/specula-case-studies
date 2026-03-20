# Tarantool Raft Trace Instrumentation Guide

Guide for the Phase 3 (validation) agent to adjust instrumentation.

## Architecture

- **Trace module**: `src/lib/raft/tla_trace.h` + `tla_trace.c` (copied by apply.sh)
- **Instrumentation**: `src/lib/raft/raft.c` (patched by `patches/instrumentation.patch`)
- **Test scenarios**: `test/unit/raft_trace_test.c`
- **Build flag**: `-DRAFT_TLA_TRACE=ON` enables instrumentation at compile time
- **Runtime activation**: `RAFT_TRACE_FILE=/path/to/trace.ndjson` env var

## Instrumentation Points (after apply)

| Event | File:Line (approx) | Function | Capture Level |
|-------|---------------------|----------|---------------|
| `election_timeout` | raft.c:1011 | `raft_sm_election_update_cb` | Full |
| `receive_message` | raft.c:660 | `raft_process_msg` (trace_and_return label) | Full + msg fields |
| `receive_heartbeat` | raft.c:706 | `raft_process_heartbeat` | Full |
| `wal_write_term_only` | raft.c:808 | `raft_worker_handle_io` (after raft_write, req.vote==0 && volatile_vote!=0) | Full |
| `wal_write_term_and_vote` | raft.c:806 | `raft_worker_handle_io` (after raft_write, req.vote!=0) | Full |
| `wal_write_revoke_vote` | raft.c:778 | `raft_worker_handle_io` (after raft_revoke_vote) | Full |
| `wal_write_term_no_vote` | raft.c:810 | `raft_worker_handle_io` (after raft_write, volatile_vote==0) | Full |
| `complete_wal_write` | raft.c:747 | `raft_worker_handle_io` (end_dump, after transitions) | Full |
| `broadcast_state` | raft.c:835 | `raft_worker_handle_broadcast` | Full |
| `promote` | raft.c:1250 | `raft_promote` | Full |
| `leader_resign` | raft.c:1259 | `raft_resign` | Full |
| `crash` | (test harness) | `tla_trace_crash()` called from test code | Node ID only |

## How to Add a New Field to an Event

1. Edit `tla_trace.c`: find the `trace_state_snprintf()` function
2. Add the new field to the format string (e.g., `"\"newField\":%d,"`)
3. Add the corresponding value from `raft->field_name`
4. Rebuild: `cmake --build build --target raft_trace.test`

## How to Add a New Event Type

1. Add declaration in `tla_trace.h`:
   ```c
   void tla_trace_new_event(const struct raft *raft);
   ```
2. Add implementation in `tla_trace.c`:
   ```c
   void tla_trace_new_event(const struct raft *raft) {
       trace_emit_node_event("new_event", raft);
   }
   ```
3. Add `TLA_TRACE(tla_trace_new_event, raft);` at the instrumentation point in `raft.c`
4. Update the patch: `cd artifact/tarantool && git diff src/lib/raft/raft.c > ../../harness/patches/instrumentation.patch`

## How to Move a Capture Point

The `TLA_TRACE(...)` calls in `raft.c` can be moved up or down within the function to capture pre-state vs post-state. The macro expands to a no-op when `RAFT_TLA_TRACE` is not defined, so it's safe to move freely.

After moving, regenerate the patch:
```bash
cd artifact/tarantool
git diff src/lib/raft/raft.c > ../../harness/patches/instrumentation.patch
```

## How to Rebuild and Re-run After Changes

```bash
# If you modified tla_trace.c or tla_trace.h:
cp harness/src/tla_trace.* artifact/tarantool/src/lib/raft/

# If you modified raft.c instrumentation:
# (apply.sh resets first, so just re-run it)
bash harness/apply.sh

# Rebuild and collect traces:
cmake --build artifact/tarantool/build --target raft_trace.test -j$(nproc)
RAFT_TRACE_FILE=traces/trace.ndjson artifact/tarantool/build/test/unit/raft_trace.test
```

## State Fields in Trace Events

Every event includes these fields from `raft` struct:
- `state`: "follower" / "candidate" / "leader"
- `volatileTerm`: `raft->volatile_term`
- `volatileVote`: `raft->volatile_vote` (0 = Nil)
- `persistedTerm`: `raft->term`
- `persistedVote`: `raft->vote` (0 = Nil)
- `leader`: `raft->leader` (0 = Nil)
- `isWriteInProgress`: `raft->is_write_in_progress`
- `leaderWitnessMap`: bitmap serialized as JSON array of set bit positions

## Server ID Mapping

Tarantool uses integer instance IDs (1, 2, 3, ...) which map directly to TLA+ `Server = {1, 2, 3}`. No mapping needed — the `node` field in traces contains the raw instance ID.

## Single-Threaded Model

Tarantool Raft runs in a single cooperative fiber per node. No concurrent access to raft state. Events within one node are strictly ordered. No thread-safety concerns for tracing.
