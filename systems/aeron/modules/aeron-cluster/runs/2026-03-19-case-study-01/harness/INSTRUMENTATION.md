# Aeron Cluster Trace Instrumentation Guide

## Overview

The trace harness instruments `Election.java` and `ConsensusModuleAgent.java` to emit NDJSON trace events during execution. Events are written via `TlaTrace.java`, a zero-dependency trace module.

## File Locations (after `apply.sh`)

### Trace Module
- `aeron-cluster/src/main/java/io/aeron/cluster/TlaTrace.java`

### Instrumented Files
- `aeron-cluster/src/main/java/io/aeron/cluster/Election.java`
- `aeron-cluster/src/main/java/io/aeron/cluster/ConsensusModuleAgent.java`

### Test Scenarios
- `aeron-cluster/src/test/java/io/aeron/cluster/TlaTraceElectionTest.java`

## Instrumentation Points

| Event | File | Method | Trigger |
|-------|------|--------|---------|
| EnterCanvass | Election.java | `init()` | After `state(CANVASS, ...)` |
| SendCanvassPosition | Election.java | `publishCanvassPosition()` | After `consensusPublisher.canvassPosition()` |
| HandleCanvassPosition | Election.java | `onCanvassPosition()` | After `updateMemberLogPosition()` |
| Nominate | Election.java | `nominate()` | After `state(CANDIDATE_BALLOT, ...)` |
| HandleRequestVote | Election.java | `onRequestVote()` | After each `placeVote()` call |
| HandleRequestVoteResponse | Election.java | `onVote()` | After recording vote in ClusterMember |
| BecomeLeader | Election.java | `candidateBallot()` | After leader transition |
| HandleNewLeadershipTerm | Election.java | `onNewLeadershipTerm()` | After state updates (line ~492) |
| ElectionReceiveCommitPosition | Election.java | `onCommitPosition()` | After `notifiedCommitPosition` update |
| FollowerReceiveCommitPosition | ConsensusModuleAgent.java | `onCommitPosition()` | After follower notifiedCommitPosition update |
| Timeout | ConsensusModuleAgent.java | `enterElection()` | At method entry |
| LeaderAdvanceCommitPosition | ConsensusModuleAgent.java | `updateLeaderPosition()` | After quorumPosition > commitPosition |

## How to Enable Tracing

Set the trace file path via environment variable or system property:

```bash
# Environment variable
TLA_TRACE_FILE=/path/to/trace.ndjson ./gradlew :aeron-cluster:test --tests ...

# System property
./gradlew :aeron-cluster:test --tests ... -DtlaTraceFile=/path/to/trace.ndjson
```

When neither is set, tracing is disabled (zero overhead).

## How to Modify Instrumentation

### Add a field to an existing event

In `TlaTrace.java`, add the field to the relevant `emit*` method's StringBuilder. For example, to add `mlogPosition` to `emitMsgEvent`:

```java
sb.append(",\"mlogPosition\":").append(mlogPosition);
```

Then update the call site in `Election.java` or `ConsensusModuleAgent.java`.

### Add a new event type

1. Choose the appropriate emit method in `TlaTrace.java` (`emitNodeEvent`, `emitMsgEvent`, `emitVoteEvent`, etc.) or create a new one if needed.
2. Insert a call at the trigger point in the source code.
3. Add a corresponding `TraceXxx` wrapper in `Trace.tla`.

### Move a capture point (before → after)

Move the `TlaTrace.emit*()` call to the new location. The field values may need adjustment — check what state variables are available at the new position.

### Rebuild and re-run after changes

```bash
cd case-studies/aeron
bash harness/run.sh
```

Or for faster iteration after manual edits:

```bash
cd artifact/aeron
./gradlew :aeron-cluster:compileJava :aeron-cluster:compileTestJava --no-daemon -q
TLA_TRACE_FILE=../../traces/test.ndjson \
  ./gradlew :aeron-cluster:test --tests "io.aeron.cluster.TlaTraceElectionTest.basicElection" --no-daemon -q
```

## Clean Up

To revert all instrumentation:

```bash
cd artifact/aeron
git checkout -- aeron-cluster/
```

## Server ID Mapping

Implementation member IDs (0, 1, 2) map to TLA+ names (s1, s2, s3).
The mapping is registered in `TlaTraceElectionTest.setUp()` via `TlaTrace.registerServers(3)`.
