# Hazelcast CP Raft — Instrumentation Guide

Guide for Phase 3 (validation) agent to adjust instrumentation when trace validation reveals issues.

## Trace Module

**File**: `harness/src/TlaTraceLogger.java`
**Installed at**: `artifact/.../raft/impl/TlaTraceLogger.java`

### Key Methods

| Method | Purpose |
|--------|---------|
| `TlaTraceLogger.init(filePath)` | Open trace file. Call once per test. |
| `TlaTraceLogger.shutdown()` | Flush and close. Call in test teardown. |
| `TlaTraceLogger.emit(event, node, state, extra)` | Emit node-only event |
| `TlaTraceLogger.emitMsg(event, node, from, to, state, extra)` | Emit message event |
| `TlaTraceLogger.mapId(endpoint)` | Map UUID endpoint to "s1", "s2", ... |

### State Capture

`stateJson(RaftState)` captures: `term`, `role`, `commitIndex`, `lastLogIndex`, `lastLogTerm`, `votedFor`.
- `votedFor` emits `"none"` (not JSON null) when null — TLC can't parse null.
- All fields read from `RaftState` getters and `RaftLog` accessors.

## Instrumented Files

All paths relative to `artifact/hazelcast/hazelcast/src/main/java/com/hazelcast/cp/internal/raft/impl/`.

| File | Event | Trigger Point |
|------|-------|---------------|
| `task/PreVoteTask.java:64` | `Timeout` | After `state.initPreCandidateState()` |
| `handler/PreVoteRequestHandlerTask.java` (5 points) | `HandlePreVoteRequest` | Before each `raftNode.send(PreVoteResponse)` |
| `handler/PreVoteResponseHandlerTask.java:73,77` | `HandlePreVoteResponse` | After `LeaderElectionTask.run()` (elected=true) or in else branch (elected=false) |
| `handler/VoteRequestHandlerTask.java` (7 points) | `HandleVoteRequest` | Before each `raftNode.send(VoteResponse)` |
| `handler/VoteResponseHandlerTask.java:68,86,88` | `HandleVoteResponse` | After `toFollower()` (demotion), after `toLeader()` (becameLeader=true), or else (becameLeader=false) |
| `task/ReplicateTask.java:99` | `ClientRequest` | After `log.appendEntries()`, guarded by `!(operation instanceof UpdateRaftGroupMembersCmd)` |
| `RaftNodeImpl.java:751` | `AppendEntries` | After `raftIntegration.send(request, follower)` |
| `handler/AppendRequestHandlerTask.java` (4 points) | `HandleAppendRequest` | Before each failure response send (3x) and after success response send (1x) |
| `handler/AppendSuccessResponseHandlerTask.java:80` | `HandleAppendSuccessResponse` | After `checkIfQueryAckNeeded()` |
| `handler/AppendFailureResponseHandlerTask.java` (2 points) | `HandleAppendFailureResponse` | After demotion `toFollower()` (before return) and at end of method |
| `RaftNodeImpl.java:1290` | `AdvanceCommitIndex` | After `commitEntries(quorumMatchIndex)` |
| `RaftNodeImpl.java:1338` | `RunQueries` | Before `queryState.reset()` |
| `RaftNodeImpl.java:1381` | `LeaderCheckLease` | After `toFollower(state.term())` in HeartbeatTask |
| `task/QueryTask.java:141` | `SubmitLinearizableRead` | After `queryState.addQuery()` |

## How to Add a New Field to an Event

1. Find the `TlaTraceLogger.emit*()` call for that event
2. Add the field to the `extra` string parameter, e.g.:
   ```java
   TlaTraceLogger.emit("EventName", node, state,
       "\"existingField\":" + value + ",\"newField\":" + newValue);
   ```

## How to Add a New Event Type

1. Copy the pattern from an existing instrumentation point
2. Insert `TlaTraceLogger.emit()` or `TlaTraceLogger.emitMsg()` at the trigger point
3. Add a corresponding `TraceEventName` action wrapper in `Trace.tla`
4. Add it to `TraceNext`

## How to Move a Capture Point

If post-state validation fails because state is captured at the wrong point:

1. Find the current `TlaTraceLogger.emit*()` call
2. Move it before/after the state-mutating operation as needed
3. Note: "after" captures post-state (most common), "before" captures pre-state

## Rebuild and Re-run

```bash
cd case-studies/hazelcast
bash harness/run.sh
```

Or manually:
```bash
cd artifact/hazelcast
# After editing source:
mvn -pl hazelcast test-compile -Dcheckstyle.skip=true -Dspotbugs.skip=true -Denforcer.skip=true -Dmaven.javadoc.skip=true -Dpmd.skip=true -DskipTests=true
export TLA_TRACE_DIR=../../traces
mvn -pl hazelcast test -Dtest=com.hazelcast.cp.internal.raft.impl.TlaTraceTest -DfailIfNoTests=false -Dcheckstyle.skip=true -Dspotbugs.skip=true -Denforcer.skip=true -Dmaven.javadoc.skip=true -Dpmd.skip=true -Dhazelcast.phone.home.enabled=false -Dhazelcast.test.use.network=false
```

## Known Issues for Phase 3

1. **Cross-node event ordering**: Events from different nodes interleave non-deterministically. The trace may show `HandleVoteRequest(s3)` before `HandlePreVoteResponse(s1)` because s3 processes the VoteRequest faster than s1's trace event is emitted. Trace.tla needs `SilentHandlePreVoteResponse` and `SilentHandleVoteResponse` silent actions.

2. **Capture levels**: All instrumentation points use full state capture. No weak/specialized capture levels needed since Hazelcast's single-threaded executor ensures all state is accessible.

3. **votedFor encoding**: Uses string `"none"` instead of JSON `null` because TLC's JSON deserializer doesn't support null values. Trace.tla has `VotedForMap(v)` helper to convert.
