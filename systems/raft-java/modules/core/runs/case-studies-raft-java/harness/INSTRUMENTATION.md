# raft-java Instrumentation Guide

Quick reference for the Phase 3 agent to adjust instrumentation.

## File Layout

After `apply.sh`, instrumented files are at:

| File | Location |
|------|----------|
| Trace module | `raft-java-core/src/main/java/com/github/wenweihu86/raft/TlaTrace.java` |
| Test scenarios | `raft-java-core/src/test/java/com/github/wenweihu86/raft/RaftTraceTest.java` |
| Instrumented sources | `RaftNode.java`, `RaftConsensusServiceImpl.java` (via patch) |

## Instrumentation Points

### RaftNode.java

| Event | Method | Location (after patch) | Capture |
|-------|--------|----------------------|---------|
| StartPreVote | `startPreVote()` | After `state = STATE_PRE_CANDIDATE` | Full |
| StartVote | `startVote()` | After `votedFor = localServer.getServerId()` | Full |
| BecomeLeader | `becomeLeader()` | After `state = STATE_LEADER` | Full |
| ClientRequest | `replicate()` | After `raftLog.append(entries)`, only for ENTRY_TYPE_DATA | Full |
| AppendEntries | `appendEntries(Peer)` | Inside lock, after building request | Full |
| HandleAppendEntriesResponse | `appendEntries(Peer)` | After processing response, before advanceCommitIndex | Full |
| HandlePreVoteResponse | `PreVoteResponseCallback.success()` | Before `startVote()` if quorum, else at end | Full |
| HandleRequestVoteResponse | `VoteResponseCallback.success()` | Before `becomeLeader()` if quorum, else at end | Full |
| AdvanceCommitIndex | `advanceCommitIndex()` | After `commitIndex = newCommitIndex` | Full |
| TakeSnapshot | `takeSnapshot()` | After snapshot reload, inside lock | Full |
| SendInstallSnapshot | `installSnapshot(Peer)` | After first chunk response succeeds, inside lock | Full |
| HandleInstallSnapshotResponse | `installSnapshot(Peer)` | After `peer.setNextIndex()`, inside lock | Full |

### RaftConsensusServiceImpl.java

| Event | Method | Location | Capture |
|-------|--------|----------|---------|
| HandlePreVoteRequest | `preVote()` | Before final return (grant path) | Full |
| HandleRequestVoteRequest | `requestVote()` | Before final return | Full |
| HandleAppendEntriesRequest | `appendEntries()` | Before each return (6 paths) | Full |
| HandleInstallSnapshotRequest | `installSnapshot()` | After isLast processing, inside lock | Full |

## How to Add a New Field to an Event

1. Open `TlaTrace.java`
2. Find the `stateJson()` method — it builds the state JSON fragment
3. Add the new field to the format string:
   ```java
   "\"newField\":%d"
   ```
4. Add the corresponding getter in the format args

## How to Add a New Event Type

1. Add a new `emitXxx()` method in `TlaTrace.java` (copy an existing one)
2. Add the `TlaTrace.emitXxx()` call at the appropriate point in the source
3. Add the corresponding `TraceXxx` action wrapper in `Trace.tla`
4. Add it to `TraceNext` in `Trace.tla`

## How to Move a Capture Point

If validation shows state is captured at the wrong time (before vs after):
1. Find the `TlaTrace.emitXxx()` call in the instrumented source
2. Move it before/after the state-changing line
3. Ensure it's still inside the lock (for thread safety)
4. Rebuild: `cd artifact/raft-java && mvn install -DskipTests -q`

## How to Rebuild and Re-run

```bash
# From case-studies/raft-java/
cd artifact/raft-java
mvn install -DskipTests -q         # Rebuild after source changes

# Run a specific test
mvn -pl raft-java-core test \
  -Dtest=com.github.wenweihu86.raft.RaftTraceTest#testBasicConsensus \
  -Draft.trace.file=/path/to/output.ndjson

# Or re-run everything
cd ../..
bash harness/run.sh
```

## Known Issues

### brpc-java Duplicate RPCs
brpc-java sometimes calls the same RPC handler twice for a single request.
`TlaTrace.emit()` deduplicates consecutive identical events (same JSON minus timestamp).
If new duplicates appear, check the `lastEventKey` dedup logic in `TlaTrace.java`.

### Event Ordering
Some events appear out of spec order because the implementation performs multiple
spec-level actions atomically (e.g., HandlePreVoteResponse → StartVote in one callback).
The instrumentation emits HandlePreVoteResponse BEFORE startVote() to match spec ordering.
Same pattern for HandleRequestVoteResponse → BecomeLeader, and
HandleAppendEntriesResponse → AdvanceCommitIndex.

### Partial Connectivity
In the 3-node test, one node sometimes fails to fully connect via brpc-java,
resulting in missing handler events for that node. The traces still cover the
complete election + replication protocol between the connected nodes.
If this is a problem, increase `electionTimeoutMilliseconds` or add a longer
startup delay before `node.init()`.

## Trace Format

Every trace line:
```json
{"tag":"trace","ts":"<ISO-8601>","event":{"name":"<Action>","nid":"<sN>","state":{...},"msg":{...}}}
```

- `tag`: always `"trace"` (required by Trace.tla)
- `ts`: real ISO-8601 timestamp
- `nid`: server ID (`"s1"`, `"s2"`, `"s3"`)
- `state.term`, `state.role`, `state.votedFor`, `state.commitIndex`, `state.lastLogIndex`, `state.lastLogTerm`
- `msg.from`, `msg.to`: only for message events
- `votedFor`: `""` for no vote, `"sN"` for voted
