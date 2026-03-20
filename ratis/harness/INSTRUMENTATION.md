# Ratis Trace Instrumentation Guide

Guide for the Phase 3 agent to adjust instrumentation when trace validation reveals issues.

## Architecture

- **TlaTrace.java** — Trace emission module at `ratis-server/src/main/java/org/apache/ratis/server/TlaTrace.java`
  - Thread-safe, synchronized writes
  - Auto-init from `RATIS_TLA_TRACE` env var, or explicit `TlaTrace.init(path)`
  - `emit(event, div)` captures full state from `RaftServer.Division`
  - `emitWeak(event, nodeId, term, role)` for limited-access contexts
  - Maps ratis INVALID_LOG_INDEX (-1) → 0 for spec compatibility

- **Instrumentation patch** — `harness/patches/instrumentation.patch`
  - Modifies 3 source files: LeaderElection.java, RaftServerImpl.java, LogAppenderDefault.java

## Instrumentation Points (after apply.sh)

### LeaderElection.java (`impl/`)
| Event | Location | Capture level |
|-------|----------|---------------|
| Timeout | `askForVotes()` after `initElection(Phase.ELECTION)` | Weak (term + role) |
| PreVote | `askForVotes()` after `initElection(Phase.PRE_VOTE)` | Weak |
| HandleRequestVoteResponseHigherTerm | `askForVotes()` switch: `DISCOVERED_A_NEW_TERM` | Weak |

### RaftServerImpl.java (`impl/`)
| Event | Location | Capture level |
|-------|----------|---------------|
| HandleRequestVoteResponse | `changeToLeader()` after `state.becomeLeader()` | Full |
| HandleRequestVoteRequest | `requestVote()` inside sync block, after building reply | Full + src, voteGranted, phase |
| ClientRequest | `appendTransaction()` after `state.appendLog(context)` | Full |
| HandleAppendEntriesRequest (NOT_LEADER) | `appendEntriesAsync()` when leader not recognized | Full + src, result |
| HandleAppendEntriesRequest (INCONSISTENCY) | `appendEntriesAsync()` when prev-log mismatch | Full + src, result |
| HandleAppendEntriesRequest (SUCCESS) | `appendEntriesAsync()` in thenApply handler | Full + src, result |
| AdvanceCommitIndex | `appendEntriesAsync()` in thenApply when commitIndex updated | Full |

### LogAppenderDefault.java (`leader/`)
| Event | Location | Capture level |
|-------|----------|---------------|
| AppendEntries | `sendAppendEntriesWithRetries()` before `getServerRpc().appendEntries()` | Full + dst |
| Heartbeat | Same location, when entries are empty | Full + dst |
| HandleAppendEntriesResponse | `handleReply()` after switch + `onAppendEntriesReply` | Full + src, result, matchIndex, nextIndex |

## How to Add a New Field to an Event

1. Find the emit call (grep for the event name in the patched source)
2. Add the field to the `extraJson` string parameter:
   ```java
   TlaTrace.emit("EventName", this, "\"newField\":" + value);
   ```
3. For string values, add escaped quotes: `"\"field\":\"" + strValue + "\""`

## How to Add a New Event

Copy the pattern from an existing event. For full-state events:
```java
TlaTrace.emit("NewEventName", this);  // or (this, extraJson)
```
For weak events (from LeaderElection or contexts without server reference):
```java
TlaTrace.emitWeak("NewEventName", nodeId, term, "ROLE");
```

## How to Move a Capture Point

If state needs to be captured BEFORE an operation (instead of AFTER), move the `TlaTrace.emit()` call above the operation. Conversely, move it below for post-state. Re-run `harness/run.sh` after changes.

## How to Rebuild and Re-run

```bash
cd case-studies/ratis
# Full rebuild + test
bash harness/run.sh

# Or manual steps:
bash harness/apply.sh
cd artifact/ratis
mvn install -DskipTests -pl ratis-server -q
RATIS_TLA_TRACE_DIR=../../traces mvn test -pl ratis-server -Dtest=TlaTraceTest#testBasicConsensus -DfailIfNoTests=false
```

## Known Issues for Phase 3

1. **No-op on leader election**: The spec appends a no-op entry when becoming leader, but `changeToLeader()` is traced before the no-op. `TraceHandleRequestVoteResponse` uses `ValidatePostStateWeak` to work around this.

2. **LastLogIndex primed evaluation bug**: TLC has a scoping issue with `LastLogIndex(s)'` when `s` is bound to `logline.node`. The fix in Trace.tla inlines the expression: `(Len(log'[s]) + snapshotIndex'[s])`.

3. **Server constant type**: Trace.cfg uses `Server <- TraceServer` to derive server IDs as strings from the trace, rather than model values.

4. **Silent actions needed**: The trace doesn't capture all spec state transitions (e.g., heartbeat processing on followers). Silent actions in Trace.tla (SilentFlushLog, SilentAdvanceCommitIndex, etc.) and potentially new silent HandleAppendEntriesRequest actions are needed for full trace consumption.

5. **FlushLog not traced**: The SegmentedRaftLogWorker doesn't have a server reference. FlushLog events rely on SilentFlushLog in Trace.tla.

6. **Heartbeat vs AppendEntries handling**: The trace distinguishes Heartbeat (empty entries) and AppendEntries, but the spec may need additional silent actions for heartbeat response processing on followers.

## Not Yet Instrumented

These events from the instrumentation spec are not yet implemented:
- ProposeConfigChange, CommitJointConfig (config changes)
- ClientRead, ExtendLease (reads)
- TakeSnapshot, SendInstallSnapshot, HandleInstallSnapshotRequest/Response (snapshots)
- CheckLeadership, ExpireLeaderValidity (leadership management)
- Crash (requires test harness support)

Add these following the same pattern if needed for specific bug-family investigation.
