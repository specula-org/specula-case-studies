# Ra Instrumentation Guide

Guide for the Phase 3 (validation) agent to adjust instrumentation.

## Overview

Instrumentation adds `tla_trace:ret/2,3` and `tla_trace:emit/4` calls inside
`ra_server.erl` and `ra_server_proc.erl`. Each call emits one NDJSON line to the
trace file when `tla_trace:init/1` has been called.

## Files

| File | Role |
|------|------|
| `src/tla_trace.erl` | Trace emission module (copied from harness/src/) |
| `src/ra_server.erl` | Instrumented Raft state machine (~40 trace calls) |
| `src/ra_server_proc.erl` | Instrumented effect handler (1 trace call for `replicate_entries`) |
| `src/ra.hrl` | Added `from` field to `#pre_vote_result{}` and `#request_vote_result{}` |
| `test/tla_trace_SUITE.erl` | Common Test suite generating traces (copied from harness/src/) |

## Instrumentation Points

### Election Actions

| Event | Location | Capture Level |
|-------|----------|---------------|
| `call_for_election_pre_vote` | `ra_server.erl` in `call_for_election(pre_vote, ...)` | Weak |
| `handle_pre_vote_request` | `ra_server.erl` in `process_pre_vote/3` (7 return points) | Weak |
| `handle_pre_vote_response` | `ra_server.erl` in `handle_pre_vote(#pre_vote_result{...})` | Weak |
| `win_pre_vote` | `ra_server.erl` in `handle_pre_vote` quorum branch | Weak |
| `handle_request_vote_request` | `ra_server.erl` in `handle_follower(#request_vote_rpc{...})` | Weak |
| `handle_request_vote_response` | `ra_server.erl` in `handle_candidate(#request_vote_result{...})` | Weak |
| `become_leader` | `ra_server.erl` in `handle_candidate` quorum branch | Weak |

### Replication Actions

| Event | Location | Capture Level |
|-------|----------|---------------|
| `client_request` | `ra_server.erl` in `handle_leader({command, ...})` | Weak |
| `replicate_entries` | `ra_server_proc.erl` in `handle_effect({send_rpc, ...})` | Weak |
| `handle_append_entries_request` | `ra_server.erl` in `handle_follower(#append_entries_rpc{...})` | Full |
| `handle_append_entries_response` | `ra_server.erl` in `handle_leader({PeerId, #append_entries_reply{...}})` | Weak |
| `advance_commit_index` | `ra_server.erl` in `increment_commit_index/1` | Weak |
| `apply_entries` | `ra_server.erl` in `evaluate_quorum/2` (leader path only) | Weak |

### Query & Heartbeat Actions

| Event | Location | Capture Level |
|-------|----------|---------------|
| `consistent_query` | `ra_server.erl` in `handle_leader({consistent_query, ...})` | Weak |
| `handle_heartbeat_request` | `ra_server.erl` in `handle_follower(#heartbeat_rpc{...})` | Weak |
| `handle_heartbeat_response` | `ra_server.erl` in `handle_leader({PeerId, #heartbeat_reply{...}})` | Weak |

### Snapshot & Step-Down Actions

| Event | Location | Capture Level |
|-------|----------|---------------|
| `handle_install_snapshot_request` | `ra_server.erl` in `handle_follower(#install_snapshot_rpc{...})` | Weak |
| `handle_install_snapshot_response` | `ra_server.erl` in `handle_leader({PeerId, #install_snapshot_result{...}})` | Weak |
| `candidate_step_down` | `ra_server.erl` in `handle_candidate(#append_entries_rpc{...})` etc. | Weak |
| `leader_step_down` | `ra_server.erl` in `handle_leader(#append_entries_rpc{term > CurTerm})` etc. | Weak |
| `propose_config_change` | `ra_server.erl` in `append_cluster_change/5` | Weak + new_config |

## Known Ordering Constraint

**Follower `apply_entries` is NOT traced.** The follower's `evaluate_commit_index_follower`
runs INSIDE `handle_follower(#append_entries_rpc{...})`, so `apply_entries` would be
emitted mid-function BEFORE the enclosing `handle_append_entries_request` trace
(emitted at handler return via `tla_trace:ret`). Since the TLA+ spec requires
`handle_append_entries_request` first (to advance `commitIndex`), this ordering
mismatch causes deadlock. The fix: `Trace.tla` uses `SilentApplyEntries` for
follower-side applies. Leader `apply_entries` IS traced (emitted in
`evaluate_quorum`, which runs outside handler returns).

## How to Add a New Field to an Event

1. Find the `tla_trace:ret` or `tla_trace:emit` call at the instrumentation point
2. Add the field to the `Extra` map:
   ```erlang
   %% Before:
   tla_trace:ret(<<"event_name">>, #{from => LeaderId}, ...)
   %% After:
   tla_trace:ret(<<"event_name">>, #{from => LeaderId, new_field => Value}, ...)
   ```
3. The field will appear in the NDJSON output as a top-level key
4. For state fields, modify `do_emit` in `tla_trace.erl`

## How to Add a New Event

1. Find the code location in `ra_server.erl` where the action happens
2. Add a `tla_trace:ret/2` or `tla_trace:ret/3` call wrapping the return tuple:
   ```erlang
   tla_trace:ret(<<"new_event_name">>, #{from => Source},
                 {NextState, State, Effects})
   ```
3. Or use `tla_trace:emit/4` for mid-function events:
   ```erlang
   tla_trace:emit(<<"new_event_name">>, FsmStateAtom, StateMap, #{...})
   ```
4. **Beware ordering**: `tla_trace:emit` fires immediately, `tla_trace:ret` fires
   at return. If the spec requires action A before action B, ensure A's trace
   is emitted before B's. Mid-function emits precede return-point emits.

## How to Move a Capture Point

Move the `tla_trace:ret/emit` call to the new position. Ensure:
- The `State` map at the new position has the fields you need
- The FSM state atom (first element of return tuple) is correct
- `from`/`to` fields are in scope

## Rebuild and Re-run

```bash
cd case-studies/ra
bash harness/run.sh             # Apply + build + run + collect traces
```

Or manually:
```bash
cd artifact/ra
rebar3 compile                  # system rebar3 (OTP 25+)
export TLA_TRACE_DIR="../../traces"
rebar3 ct --suite tla_trace_SUITE --readable true
```

## Validated Traces

| Trace | Lines | TLC States | Description |
|-------|-------|------------|-------------|
| basic_consensus | 71 | 20,709 | 3-node cluster, election, 2 writes, replication |
| leader_step_down | 64 | 17,055 | Election, write, trigger re-election, write through new leader |
| consistent_query | 79 | 27,351 | Election, writes, 3 consistent reads via heartbeat |
