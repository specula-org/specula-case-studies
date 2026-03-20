# Instrumentation Guide: nuraft

Quick reference for the Phase 3 (validation) agent to adjust trace instrumentation.

## Architecture

- **Trace module**: `src/tla_trace.hxx` — header-only, thread-safe NDJSON emitter
- **Compile guard**: `#ifdef NURAFT_TLA_TRACE` wraps all trace calls
- **Env var**: `NURAFT_TRACE_FILE=/path/to/trace.ndjson` activates tracing
- **Server IDs**: Integer IDs (1,2,3) mapped to strings ("s1","s2","s3") via `tla_trace::server_name()`

## Instrumentation Points

| Event | File | Location | Capture Level |
|-------|------|----------|---------------|
| Timeout | handle_vote.cxx | After `pre_vote_.dead_++` in `request_prevote()` | Full |
| HandlePreVoteRequest | handle_vote.cxx | Before `return resp` in `handle_prevote_req()` | Full |
| HandlePreVoteResponse | handle_vote.cxx | After accept/deny block in `handle_prevote_resp()` | Full |
| InitiateVote | handle_vote.cxx | After `votes_responded_ += 1` in `request_vote()` | Full |
| HandleVoteRequest | handle_vote.cxx | Before `return resp` in `handle_vote_req()` | Full |
| HandleVoteResponse | handle_vote.cxx | After election_completed check in `handle_vote_resp()` | Full |
| PersistState | handle_vote.cxx + raft_server.cxx | After `save_state()` calls | Full |
| BecomeLeader | raft_server.cxx | After `config_changing_ = true` in `become_leader()` | Full |
| ClientRequest | handle_client_request.cxx | After `try_update_precommit_index()` | Full |
| AppendEntries | handle_append_entries.cxx | After `set_last_sent_idx()` in `create_append_entries_req()` | Weak (local copies) |
| HandleAppendEntries | handle_append_entries.cxx | Before rejection return + before success return | Full |
| HandleAppendEntriesResponse | handle_append_entries.cxx | After lock scope with `new_matched_idx` | Full |
| AdvanceCommitIndex | handle_append_entries.cxx | After `commit(committed_index)` | Full |
| CommitEntry | handle_commit.cxx | Inside CAS success block in `commit_in_bg_exec()` | Full |

## How to Add a New Field

In the target source file, find the `#ifdef NURAFT_TLA_TRACE` block and add a chained call:

```cpp
tla_trace::EventBuilder("EventName", TLA_TRACE_NID)
    .state(TLA_TRACE_STATE_ARGS)
    .field_int("newField", (int64_t)value)    // integer
    .field_str("newField", "value")            // string
    .field_bool("newField", true)              // boolean
    .emit();
```

## How to Add a New Event

1. Copy an existing `#ifdef NURAFT_TLA_TRACE ... #endif` block
2. Change the event name string
3. Adjust fields as needed
4. Add corresponding `TraceXxx` wrapper in `Trace.tla`

## How to Move a Capture Point

Move the entire `#ifdef ... #endif` block to the desired location. Ensure:
- The `state` fields (term, role, commitIndex, etc.) reflect post-action values at the new position
- The event still fires under the correct lock/thread context

## State Fields Reference

The `TLA_TRACE_STATE_ARGS` macro expands to:
```cpp
state_->get_term(),              // term
static_cast<int>(role_.load()),  // role (1=follower, 2=candidate, 3=leader)
quick_commit_index_.load(),      // commitIndex
sm_commit_index_.load(),         // smCommitIndex
precommit_index_.load(),         // precommitIndex
log_store_->next_slot() - 1,     // lastLogIndex
term_for_log(log_store_->next_slot() - 1) // lastLogTerm
```

## Rebuild and Re-run

```bash
cd case-studies/nuraft/artifact/nuraft/build
make -j$(nproc) trace_test
NURAFT_TRACE_FILE=../../traces/basic_consensus.ndjson ./tests/trace_test
```

Or from scratch:
```bash
cd case-studies/nuraft && bash harness/run.sh
```

## Notes

- All trace calls run under the raft_server's main lock (`lock_`) except:
  - `ClientRequest`: under `cli_lock_`
  - `CommitEntry`: under `commit_lock_`
  - `AppendEntries`: uses local copies from a lock scope
- The trace writer is thread-safe (mutex-protected singleton)
- `votedFor = -1` in nuraft maps to `Nil` in the TLA+ spec
