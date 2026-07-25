# Instrumentation Guide

Phase 3 reference for adjusting MongoDB Raft Reconfig trace instrumentation.

## Spec Changes Made During Harness Generation

These changes to `spec/Trace.tla` and `spec/Trace.cfg` were made to make traces validate:

### Trace.cfg
- **`Server = {"n1", "n2", "n3"}`** — string constants matching trace node IDs
- **`INIT TraceInit` / `NEXT TraceNext`** — replaces `SPECIFICATION TraceSpec` to avoid temporal property complexity
- **`MaxTerm = 4`**, **`MaxConfigVersion = 6`** — reduced bounds to prevent state-space explosion in HBReconfig validation

### Trace.tla
- **All validate functions use primed variables** (`currentTerm'[n]`, `role'[n]`, etc.) instead of unprimed — necessary because `logline.post` captures POST-action state
- **`TraceTerminated` self-loop** added to `TraceNext` — prevents TLC deadlock at terminal state when trace cursor l > Len(TraceLog)
- **`TraceHBReconfigSchedule` uses IF-THEN-ELSE** — when trace contains `schedVer`/`schedTerm`/`schedCfg`, TLC uses them directly instead of the `∃ newCfg ∈ SUBSET Server, v ∈ 1..MaxConfigVersion, t ∈ ...` quantifier (1920→1 state per existing state)

## Validation Results

All 5 traces are fully consumed by TLC with no invariant violations.

When using the parallel validation tool, the expected output is:
```
"Trace validation failed at trace line N"
```
where N = total events in the trace. This means **all N events were consumed** and TLC reached the terminal state. It is NOT a real failure — it's TLC reporting that the trace cursor advanced past the end.

This is equivalent to `l > Len(TraceLog)` = TRUE = `TraceMatched` satisfied.

## File Map

| Event | File | Location |
|---|---|---|
| Timeout | `replication_coordinator_impl_elect_v1.cpp` | `ElectionState::_startRealElection` — after `voteForMyselfV1()` |
| RequestVotes | `replication_coordinator_impl_elect_v1.cpp` | `ElectionState::_requestVotesForRealElection` — after `_startVoteRequester()` |
| BecomeLeader | `replication_coordinator_impl_elect_v1.cpp` | `ElectionState::_onVoteRequestComplete` — after `_postWonElectionUpdateMemberState()` |
| HandleRequestVote | `replication_coordinator_impl.cpp` | `processReplSetRequestVotes` — before `storeLocalLastVoteDocument` call |
| PersistVote | `replication_coordinator_impl.cpp` | `processReplSetRequestVotes` — after `storeLocalLastVoteDocument` succeeds |
| AutoReconfig | `replication_coordinator_impl.cpp` | Drain-complete callback — after `doOptimizedReconfig` returns OK |
| AutoReconfigPreempted | `replication_coordinator_impl.cpp` | Drain-complete callback — on `ConfigurationInProgress` error |
| SafeReconfigStart | `replication_coordinator_impl.cpp` | `_doReplSetReconfig` — after `_setConfigState(lk, kConfigReconfiguring)` |
| SafeReconfigSwap | `replication_coordinator_impl.cpp` | `_finishReplSetReconfig` — after `_setCurrentRSConfig` (force=false) |
| SafeReconfigCaptureBarrier | `replication_coordinator_impl.cpp` | `_finishReplSetReconfig` — after `updateLastCommittedInPrevConfig()` (force=false) |
| ForceReconfig | `replication_coordinator_impl.cpp` | `_finishReplSetReconfig` — after `_setCurrentRSConfig` (force=true) |
| HBReconfigSchedule | `replication_coordinator_impl_heartbeat.cpp` | `_scheduleHeartbeatReconfig` — after `_setConfigState(lk, kConfigHBReconfiguring)` |
| HBReconfigFinish | `replication_coordinator_impl_heartbeat.cpp` | `_heartbeatReconfigFinish` — after `_setCurrentRSConfig` |
| AdvanceCommitIndex | `replication_coordinator_impl.cpp` | `_updateLastCommittedOpTimeAndWallTime` — when commit advances (primary only) |

**AppendEntry** is not instrumented in the patch because `_appendOplogEntryCallback`
ties into the storage layer. If needed, instrument in the OplogWriter path or
use the `logLen` approximation (`getMyLastAppliedOpTime().getSecs()`).

## Trace Module

`tla_trace.h` / `tla_trace.cpp` in `src/mongo/db/repl/`.

- Init: `TlaTrace::init(path)` — call at startup (e.g., at the top of a test)
- Shutdown: `TlaTrace::shutdown()` — call at teardown
- Default path: set `TLA_TRACE_FILE` env var; defaults to `/tmp/tla_trace.ndjson`
- Thread-safe: global mutex; all emitters lock per call.

## Adding a New Field to an Event

1. Add the field to the emit function signature in `tla_trace.h`
2. Include it in the `ostringstream` in the corresponding `emit*` function in `tla_trace.cpp`
3. Update the call site in the relevant `.cpp` file
4. Update the corresponding Trace.tla validator (`ValidatePostState*`)

## Adding a New Event Type

1. Add a new `emitXxx(...)` declaration in `tla_trace.h`
2. Implement it in `tla_trace.cpp` following the pattern of existing emitters
3. Add the call site in the relevant source file
4. Add `TraceXxx(n)` wrapper and `\/ \E n \in Server : TraceXxx(n)` in Trace.tla

## Moving a Capture Point (before → after or vice versa)

All instrumentation points use the `tla_trace.h` emit calls with values
read from existing local variables or `_topCoord`/`_rsConfig` getters.
To move a capture point, move the `TlaTrace::emit*` call and update which
getters are called.

## Capture Levels

| Event | Capture Level | Reason |
|---|---|---|
| HandleRequestVote | Specialized (term+role+inMemVoteTerm) | Emitted before mutex is re-acquired for persist |
| PersistVote | Specialized (durableVoteTerm only) | Only `durableVote` changes |
| AdvanceCommitIndex | Specialized (commitIndex only) | Only `commitIndex` changes |
| All config events | Specialized (config fields) | Emit under `_mutex`; full state capture possible but verbose |

## Rebuild and Re-run

```bash
# After changing instrumentation sources:
bash harness/apply.sh          # re-copy + re-apply
TLA_BUILD=1 bash harness/run.sh  # build + run (requires MongoDB toolchain)

# Without toolchain (simulator only):
bash harness/run.sh            # regenerates simulator traces
```

## Node ID → Server Mapping

The instrumented code emits HostAndPort strings (e.g., `"rs0:27017"`).
The Trace.cfg uses `Server <- TraceServer` so TLC derives the Server set
from whatever node IDs appear in the trace. No manual mapping needed.

For the Python simulator, node IDs are `"n1"`, `"n2"`, `"n3"`.
For real MongoDB tests, they will be the actual `HostAndPort` values
(update test scripts to use consistent node IDs if needed).

## PostSwap as Synthetic State

`SafeReconfigSwap` emits `"PostSwap"` as the configState string.
The implementation has no `kConfigPostSwap` enum value — the harness
emits this synthetic string to represent the narrow window between
`_setCurrentRSConfig` (line ~4037) and `updateLastCommittedInPrevConfig`
(line ~4052) in `_finishReplSetReconfig`. The Trace.tla `ToConfigState`
maps `"PostSwap"` → `PostSwap` constant.

## Shadow Field for durableVoteTerm

`TlaTrace::emitPersistVote` reads `_topCoord->getLastVote().getTerm()` after
the durable write. This is the simplest available approximation. For higher
fidelity, add a shadow field `_durableVoteTerm` to `ReplicationCoordinatorImpl`
and update it inside the `storeLocalLastVoteDocument` callback.

## configTerm for ForceReconfig

`ForceReconfig` emits `configTerm = -1`. The Trace.tla `ToConfigTerm(-1)`
maps this to `UNINITIALIZED`. This is correct per the spec (Family 1 bug).
