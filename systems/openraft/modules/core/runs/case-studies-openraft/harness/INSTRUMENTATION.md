# Instrumentation Guide: openraft

Quick reference for Phase 3 (trace validation) agent to adjust instrumentation.

## Architecture

- **Approach**: Feature-gated instrumentation (`tla-trace` cargo feature)
- **Trace module**: `openraft/src/tla_trace.rs` — global NDJSON writer with Mutex
- **Activation**: Call `openraft::tla_trace::init(path)` in test setup
- **Node ID mapping**: openraft uses 0-based u64; TLA+ uses 1-based. Mapping: `tla_id = impl_id + 1`

## Instrumentation Points

| Action | File | Location | Capture |
|--------|------|----------|---------|
| Elect | engine_impl.rs:~215 | After `update_vote()` self-vote | Strong |
| HandleVoteRequest | engine_impl.rs:~285 | After `update_vote()` for requester | Weak + source |
| HandleVoteResponse | engine_impl.rs:~318,~355 | After grant path / reject path | Weak + source |
| EstablishLeader | engine_impl.rs:~676 | After blank log appended | Strong |
| HandleAppendEntries | engine_impl.rs:~371 | After `append_entries()` | Weak + source |
| HandleInstallSnapshot | engine_impl.rs:~427 | After `install_full_snapshot()` | Weak + source |
| LeaderStepDown | engine_impl.rs:~483 | After `update_internal_server_state()`, only if was Leader | Weak |
| ClientRequest | leader_handler/mod.rs:~100 | After entries appended (Normal payloads only) | Strong |
| SendHeartbeat | leader_handler/mod.rs:~112 | After BroadcastHeartbeat command | Term |
| ReplicateEntries | replication_handler/mod.rs:~365 | In `initiate_replication()` loop, Logs/LogsSince | Term + target |
| SendInstallSnapshot | replication_handler/mod.rs:~365 | In `initiate_replication()` loop, Snapshot | Term + target |
| HandleAppendEntriesResponse | replication_handler/mod.rs:~198,~247 | After `update_matching` / `update_conflicting` | Weak + source |
| AdvanceCommitIndex | replication_handler/mod.rs:~219 | Inside `update_local_committed` success | Strong |
| PurgeLog | log_handler/mod.rs:~49 | After `purge_log()` + PurgeLog command | Term |
| TriggerSnapshot | snapshot_handler/mod.rs:~43 | After `set_building_snapshot(true)` | Term |

## Capture Levels

- **Strong**: `term, state, commitIndex, lastLogIndex, lastLogTerm`
- **Weak**: `term, state` (for async/message-handling paths)
- **Term**: `term` only (for lightweight events)
- **+ source**: adds `"source"` field (message sender node ID)
- **+ target**: adds `"target"` field (replication target node ID)

## How to Add a New Field

1. Edit the relevant `*_post()` function in `tla_trace.rs` (e.g., `strong_post`, `weak_post`)
2. Access state via `RaftState<C>` methods (see existing patterns)
3. Add the field to the JSON object

## How to Add a New Event

1. Choose the capture level (strong/weak/term)
2. Add a `#[cfg(feature = "tla-trace")]` block at the trigger point
3. Call the appropriate `crate::tla_trace::emit_*()` function
4. Add the event name string to match `Trace.tla`

## How to Move a Capture Point

1. Remove the `#[cfg(feature = "tla-trace")]` block from the old location
2. Add it at the new location, ensuring state has been updated (before/after matters)
3. Check borrow rules: emit calls need `&self.config.id` and `&*self.state` (or `self.state` in handlers)

## Rebuild and Re-run

```bash
# Quick rebuild after editing source files directly in artifact:
cd artifact/openraft
cargo check -p openraft --features "tla-trace,type-alias"

# Full cycle (reset + apply + build + run):
cd case-studies/openraft
bash harness/run.sh

# Run just the test (after apply):
cd artifact/openraft
TLA_TRACE_FILE=../../traces/basic_consensus.ndjson \
  cargo test -p tests --test tla_trace -- tla_trace_basic_consensus --nocapture --test-threads=1
```

## Known Limitations

- **No HandleVoteRequest events** in basic_consensus trace: `new_cluster()` bootstraps node 0 alone, so initial election has no vote requests from other nodes.
- **ProposeConfigChange / CommitConfigChange** not observed in basic traces: membership changes happen during cluster setup but the replication_handler `append_membership` is not yet instrumented.
- **Crash / Restart** require explicit test scenarios with node shutdown/recovery.
- **LeaseExpire** is implicit in the implementation — omitted from instrumentation (spec uses SilentLeaseExpire).
