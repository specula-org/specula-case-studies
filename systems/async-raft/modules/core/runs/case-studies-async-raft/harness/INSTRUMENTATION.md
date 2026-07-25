# Instrumentation Guide: async-raft

Guide for the Phase 3 (validation) agent to adjust instrumentation.

## Architecture

- **Trace module**: `async-raft/src/tla_trace.rs` — thread-safe NDJSON emitter
- **Instrumentation**: Source code patches in `patches/instrumentation.patch`
- **Test scenario**: `async-raft/tests/tla_trace_scenario.rs`
- **Activation**: Set `TLA_TRACE_FILE=/path/to/output.ndjson` env var

## Instrumentation Points

After `apply.sh`, these are the instrumented locations:

| Event | File | Location | Capture Level |
|-------|------|----------|---------------|
| Timeout | `core/mod.rs` (CandidateState::run) | After `self.core.current_term += 1` and `self.core.voted_for = Some(self.core.id)` | Full |
| HandleRequestVoteRequest | `core/vote.rs` (handle_vote_request) | Before each `return Ok(VoteResponse{...})` | Full |
| HandleRequestVoteResponse | `core/vote.rs` (handle_vote_response) | At function entry, before processing | Weak (term+role) |
| BecomeLeader | `core/mod.rs` (LeaderState::run) | After setting up leader state, before `commit_initial_leader_entry` | Weak |
| ClientRequest | `core/client.rs` (append_payload_to_log) | After `self.core.last_log_index = entry.index` | Full |
| SendReplicateEntries | `replication/mod.rs` (send_append_entries) | Before `self.network.append_entries(...)`, when entries non-empty | Weak |
| SendHeartbeat | `replication/mod.rs` (send_append_entries) | Before `self.network.append_entries(...)`, when entries empty | Weak |
| HandleAppendEntriesRequest | `core/append_entries.rs` (handle_append_entries_request) | Before each `return Ok(AppendEntriesResponse{...})` | Full |
| HandleAppendEntriesResponse | `core/replication.rs` (handle_update_match_index) | After non-voter check, before match_index update | Weak |
| AdvanceCommitIndex | `core/replication.rs` (handle_update_match_index) | After `self.core.commit_index = std::cmp::min(commit_index_c0, commit_index_c1)` | Commit (term+role+commitIndex) |

## How to Add a New Field to an Event

1. In `tla_trace.rs`, modify `RaftState::to_json()` (or `RaftStateWeak`/`RaftStateCommit`) to include the new field
2. At the instrumentation point, populate the new field from the RaftCore struct
3. Rebuild: `cd artifact/async-raft && cargo test -p async-raft --test tla_trace_scenario --no-run`

## How to Add a New Event Type

1. Find the code location for the new action (check `instrumentation-spec.md`)
2. Add `use crate::tla_trace;` if not already present in the file
3. Insert a trace emit block:
   ```rust
   if tla_trace::is_active() {
       let state = tla_trace::RaftState { /* ... */ };
       tla_trace::emit_full("NewEventName", self.id, &state, None);
   }
   ```
4. For message events, add a `msg_json` string with the relevant fields

## How to Move a Capture Point

Simply move the `if tla_trace::is_active() { ... }` block to the desired location. The state snapshot captures whatever is in the RaftCore fields at that point.

- **Before action**: Place emit before the state change
- **After action**: Place emit after the state change (current pattern for most events)

## How to Rebuild and Re-run

```bash
cd case-studies/async-raft
bash harness/apply.sh
cd artifact/async-raft
TLA_TRACE_FILE=/absolute/path/to/trace.ndjson \
  cargo test -p async-raft --test tla_trace_scenario -- basic_consensus --nocapture
```

## Server ID Mapping

Static mapping at test setup time: `0 → "s1"`, `1 → "s2"`, `2 → "s3"`. Defined in the test scenario's `server_map` HashMap.

## Not Yet Instrumented

These actions from `instrumentation-spec.md` are not yet traced:
- ClientReadRequest, ClientReadConfirm, ClientReadComplete (Bug Family 1, 6)
- HandleInstallSnapshotRequest, SendInstallSnapshot, HandleInstallSnapshotResponse (Bug Family 4)
- TakeSnapshot
- ChangeMembership, FinalizeJointConsensus (Bug Family 5)

To add these, follow the "How to Add a New Event Type" pattern above.
