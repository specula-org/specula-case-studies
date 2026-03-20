# Instrumentation Guide: tikv/raft-rs

Guide for Phase 3 (trace validation) agent to adjust instrumentation.

## Architecture

- **Trace module**: `artifact/raft-rs/src/tla_trace.rs` (copied from `harness/src/tla_trace.rs`)
- **Instrumentation**: `artifact/raft-rs/src/raft.rs` (patched by `harness/src/patch_raft.py`)
- **Test scenarios**: `artifact/raft-rs/harness/tests/tla_trace_test.rs` (copied from `harness/src/tla_trace_test.rs`)
- **Environment variable**: `RAFT_TRACE_FILE=<path>` enables tracing

## Instrumentation Points

After `apply.sh`, the following trace calls exist in `raft.rs`:

| # | Event | Location | Trigger | Post-state Level |
|---|-------|----------|---------|------------------|
| 1 | `Timeout` | `step()` MsgHup handler | After `self.hup(false)` | Weak (term, role) |
| 2 | ~~`BecomeLeader`~~ | ~~`become_leader()`~~ | **REMOVED** — fires inside `poll()` before `HandleRequestVoteResponse`. Spec handles BecomeLeader within HandleRequestVoteResponse action. | — |
| 3 | `HandleRequestPreVoteRequest` | `step()` vote handler, grant branch | After vote response sent + vote recorded | Weak |
| 4 | `HandleRequestPreVoteRequest` | `step()` vote handler, reject branch | After rejection sent | Weak |
| 5 | `HandleRequestPreVoteResponse` | `step_candidate()` | After `poll()` + `maybe_commit_by_vote()` | Weak |
| 6 | `HandleRequestVoteRequest` | `step()` vote handler, grant/reject | Same structure as PreVote | Weak |
| 7 | `HandleRequestVoteResponse` | `step_candidate()` | After `poll()` + `maybe_commit_by_vote()` | Weak |
| 8 | `ClientRequest` | `step_leader()` MsgPropose | After `bcast_append()` | Full |
| 9 | `HandleAppendEntriesRequest` | `handle_append_entries()` | After response sent (main path only) | Full |
| 10a | `HandleAppendEntriesResponse` | `handle_append_response()` reject | Before `return` in reject branch | Weak |
| 10b | `HandleAppendEntriesResponse` | `handle_append_response()` accept | After `maybe_commit` block | Weak |
| 11 | `SendHeartbeat` | `send_heartbeat()` on RaftCore | After `self.send(m, msgs)` | Full |
| 12 | `HandleHeartbeatRequest` | `handle_heartbeat()` | After response sent | Commit (term+role+commit) |
| 13 | `HandleHeartbeatResponse` | `handle_heartbeat_response()` | After `send_append` block (before read_only) | Weak |
| 14 | `TransferLeadership` | `handle_transfer_leader()` | After `lead_transferee` set | Full |
| 15 | `HandleTimeoutNowRequest` | `step_follower()` MsgTimeoutNow | After `self.hup(true)` | Weak |
| 16 | `CheckQuorum` | `step_leader()` MsgCheckQuorum | After potential step-down | Weak |
| 17 | `PersistEntries` | `on_persist_entries()` | After `maybe_persist()` succeeds | Full |
| 18 | `AdvanceCommitIndex` | `maybe_commit()` | When returning true | Commit |

## How to Adjust Instrumentation

### Add a new field to an event

In `harness/src/patch_raft.py`, find the patch for that event. Modify the `format!()` string to add the field:

```python
# Before:
'tla_trace_event!("EventName", self, &format!(r#","from":{}"#, m.from));\n'
# After (adding "accepted" field):
'tla_trace_event!("EventName", self, &format!(r#","from":{},"accepted":{}"#, m.from, accepted));\n'
```

### Add a new event type

1. Add a new patch entry in `patch_raft.py` with a unique find/replace pattern
2. Use `tla_trace_event!("NewEvent", self)` for state-only events
3. Use `tla_trace_event!("NewEvent", self, &format!(r#","key":{}"#, val))` for events with extra fields

### Move a capture point (before → after or vice versa)

Find the patch entry in `patch_raft.py` and adjust the pattern to target a different insertion point. The `tla_trace_event!` macro captures state at the call site.

### Rebuild and re-run

```bash
cd case-studies/tikv
bash harness/run.sh          # Full pipeline: apply + build + test + collect
# or individually:
bash harness/apply.sh        # Just apply instrumentation
cd artifact/raft-rs && cargo test -p harness --test tla_trace_test -- --nocapture
```

## NDJSON Format

```json
{"tag":"trace","event":"Timeout","node":1,"state":{"term":0,"role":"PreCandidate","commit":0,"lastLogIndex":0,"lastLogTerm":0,"persisted":0,"votedFor":0,"leaderId":0},"ts":1773858114641268463}
```

- `tag`: always `"trace"`
- `event`: matches Trace.tla action names exactly
- `node`: raft-rs u64 node ID (1, 2, 3...)
- `state`: post-state snapshot
- `ts`: nanosecond epoch timestamp
- Additional fields (`from`, `to`, `target`, `granted`, `accepted`) are event-specific

## Known Spec Issues Found During Validation

The trace harness revealed several conflicting primed-variable assignments in `base.tla`:

1. **BecomePreCandidate/BecomeCandidate**: had UNCHANGED clauses for `messages`, `votesGranted`, `preVotesGranted` that conflicted with callers (Timeout, HandleRequestPreVoteResponse, HandleTimeoutNowRequest) which also set these variables. **Fixed** during Phase 2.5.

2. **HandleRequestVoteRequest**: had double assignment to `votedFor'` (first cleared during step-down, then set during vote grant). **Fixed** during Phase 2.5.

3. **BecomeLeader called from HandleRequestVoteResponse**: BecomeLeader had UNCHANGED for variables that HandleRequestVoteResponse also sets. **Partially fixed** (removed BecomeLeader event, fixed UNCHANGED for preVotesGranted). More variable conflicts likely remain.

4. **HandleRequestPreVoteResponse**: UNCHANGED configVars conflicts with BecomeCandidate setting pendingConfIndex. **Fixed** during Phase 2.5.

5. **Remaining**: trace validation reaches line 9/45 of basic_consensus trace. Further spec fixes needed in Phase 3 for HandleAppendEntriesRequest, PersistEntries, AdvanceCommitIndex, and other actions.

## Test Scenarios

| Scenario | Exercises | Trace Lines |
|----------|-----------|-------------|
| `tla_basic_consensus` | Election (pre-vote) + log replication + heartbeat | ~45 |
| `tla_prevote_election` | Pre-vote election cycle + proposal | ~28 |
| `tla_leader_transfer` | Election + transfer + new election | ~43 |

All scenarios use `pre_vote=true` to match the spec's Timeout action (which always routes Followers through PreVote).
