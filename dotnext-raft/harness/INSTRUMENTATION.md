# dotNext Raft Instrumentation Guide

Guide for Phase 3 (validation) agent to adjust instrumentation when trace validation reveals issues.

## Architecture

- **Trace module**: `harness/src/TlaTrace.cs` → copied to `Tracing/TlaTrace.cs` in the DotNext.Net.Cluster project
- **Instrumentation**: `harness/patches/instrumentation.patch` → applied to 3 source files
- **Test scenarios**: `harness/src/TlaTraceTests.cs` → copied to test project

## Instrumentation Points

After applying `harness/apply.sh`, the instrumentation is at:

| Event | File | Location | Capture Level |
|-------|------|----------|--------------|
| Timeout | RaftCluster.cs:~1101 | After `IncrementTermAsync` + `StartVoting` | Full |
| RequestVote | CandidateState.cs:~49 | In `StartVoting`, before `voters.Add()` | Weak |
| HandleRequestVote | RaftCluster.cs:~852 | At `exit:` label, before `return result` | Full |
| HandleRequestVoteResponse | CandidateState.cs:~113 | After switch block in `EndVoting` loop | Weak |
| HandleRequestVoteResponse (higher term) | CandidateState.cs:~93 | Before `MoveToFollowerState` early return | Weak |
| BecomeLeader | RaftCluster.cs:~1164 | After `AppendNoOpEntry` + `StartLeading` | Full |
| AppendEntries | LeaderState.cs:~57 | In `ForkHeartbeats`, before `SpawnReplicationAsync` | Weak |
| HandleAppendEntries | RaftCluster.cs:~668 | Inside `TransitionSuppressionScope`, after config processing | Full |
| HandleAppendEntriesResponse | LeaderState.cs:~192 | In `DoHeartbeats` switch `default:` case | Weak |
| HandleAppendEntriesResponse (higher term) | LeaderState.cs:~174 | Before `MoveToFollowerState` | Weak |
| AdvanceCommitIndex | LeaderState.cs:~182 | After `CommitAsync` in `DoHeartbeats` | Commit |

## How to Add a New Field to an Event

1. Find the `TlaTrace.Emit*` call at the instrumentation point
2. Add the field to the `new Dictionary<string, object> { ... }` for `msg`, or modify the state parameters
3. Example — adding `matchIndex` to HandleAppendEntriesResponse:
   ```csharp
   new Dictionary<string, object> { ["from"] = _hrFrom, ["term"] = result.Term,
       ["success"] = result.Value, ["matchIndex"] = someValue }
   ```

## How to Add a New Event Type

1. Identify the code location for the new event
2. Add a `TlaTrace.Emit*` call using the appropriate level:
   - `EmitFull` — when you have full access to term, role, votedFor, commitIndex, lastLogIndex, lastLogTerm
   - `EmitWeak` — when you only have term + role (async/concurrent contexts)
   - `EmitCommit` — when you have term + role + commitIndex
3. Use underscore-prefixed local variables to avoid naming conflicts: `var _nid = ...`
4. Wrap in `if (Tracing.TlaTrace.IsEnabled) { ... }` for zero overhead when tracing is off

## How to Move a Capture Point

If validation shows the state snapshot is taken at the wrong moment (before vs after):

1. Find the current `TlaTrace.Emit*` call in the source
2. Move it to the correct position (before/after the state-changing operation)
3. Regenerate the patch: `cd artifact/dotNext && git diff > ../../harness/patches/instrumentation.patch`
4. Revert: `git -C artifact/dotNext checkout -- .`

## How to Rebuild and Re-run

```bash
cd case-studies/dotnext-raft
bash harness/run.sh
```

Or step by step:
```bash
bash harness/apply.sh                           # apply instrumentation
cd artifact/dotNext
dotnet build src/DotNext.Tests -c Release       # build
TRACE_OUTPUT_DIR=../../traces dotnet test \
  src/DotNext.Tests -c Release \
  --filter "FullyQualifiedName~TlaTraceTests"   # run tests
git checkout -- .                                # revert
```

## Capture Levels Explained

- **Full**: All spec state variables. Used when trace capture happens inside `transitionLock` or after an atomic state update. Fields: term, role, votedFor, commitIndex, lastLogIndex, lastLogTerm.
- **Weak**: Only term + role. Used in async contexts (CandidateState, LeaderState) where other state may be concurrently modified. The Phase 3 spec should use `ValidatePostStateWeak`.
- **Commit**: term + role + commitIndex. Used for AdvanceCommitIndex where only the commit advancement matters.

## Server ID Mapping

Implementation endpoints (`http://localhost:PORT`) are mapped to TLA+ names (`s1`, `s2`, `s3`) via static registration in `TlaTraceTests.cs`. The mapping is deterministic: `9561→s1`, `9562→s2`, `9563→s3`.

To change the mapping, modify the `TlaTrace.RegisterServer()` calls at the top of each test method.

## Known Limitations

1. **votedFor**: Only accurately captured in `Timeout` events (where it equals self). Other events emit `""` for votedFor since `IPersistentState` doesn't expose the voted-for member directly.
2. **HandleAppendEntries rejection**: Only success cases are traced. Log mismatch rejections (rare in healthy clusters) are not yet instrumented.
3. **matchIndex**: Set to 0 in HandleAppendEntriesResponse events — the implementation doesn't expose per-member matchIndex directly from the response processing path.
4. **prevLogTerm**: Set to 0 in AppendEntries events (computed asynchronously in the actual replicator, not available in the sync `ForkHeartbeats` context).
