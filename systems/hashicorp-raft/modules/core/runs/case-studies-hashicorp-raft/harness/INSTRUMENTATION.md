# Instrumentation Guide: hashicorp/raft

Guide for Phase 3 (validation) agents to adjust instrumentation when trace validation reveals issues.

## Architecture

The instrumentation is baked into the artifact source code at `artifact/raft/`. No patches are needed.

**Key files:**
- `artifact/raft/trace_logger.go` — `TraceLogger` interface, `TraceEvent`/`TraceState`/`TraceMsg` types, `getTraceState()`, `traceEvent()` helper
- `artifact/raft/raft.go` — Election and AppendEntries trace emit points
- `artifact/raft/replication.go` — Replication and heartbeat trace emit points
- `artifact/raft/api.go:148-152` — `traceLogger` and `traceVotedFor` fields on Raft struct
- `artifact/raft/config.go:229-231` — `TraceLogger` config option

**Trace module:**
- `harness/src/tracer.go` — `NDJSONTracer` implements `raft.TraceLogger`, writes NDJSON
- `harness/src/main.go` — Test scenarios and cluster setup

## Instrumentation Points

| Event | File:Line | Trigger Point |
|-------|-----------|---------------|
| `BecomeCandidate` | raft.go:2070 | After `persistVote()` for self in `electSelf()` |
| `HandleRequestVoteRequest` | raft.go:1646 | Deferred: after all state updates, before `rpc.Respond()` |
| `HandleRequestVoteResponse` | raft.go:380 | After processing vote response in `runCandidate()` |
| `BecomeLeader` | raft.go:505 | After `setState(Leader)` in `runLeader()` |
| `SendReplicateEntries` | replication.go:230 | Before `trans.AppendEntries()` in `replicateTo()` |
| `SendReplicateEntries` | replication.go:566 | Before pipeline send in `pipelineReplicate()` |
| `HandleReplicateResponse` | replication.go:251 | Stale term path in `replicateTo()` |
| `HandleReplicateResponse` | replication.go:283 | After success/failure processing in `replicateTo()` |
| `HandleReplicateResponse` | replication.go:608,625,638 | Pipeline response paths |
| `SendHeartbeat` | replication.go:439 | Before `trans.AppendEntries()` in `heartbeat()` |
| `HandleHeartbeatResponse` | replication.go:463 | After `setLastContact()` on successful heartbeat |
| `HandleAppendEntriesRequest` | raft.go:1470 | Deferred: after all state updates in `appendEntries()` |
| `AdvanceCommitIndex` | raft.go:802 | After `setCommitIndex()` in leader loop commitCh handler |
| `ProposeConfigChange` | raft.go:1255 | After config log entry appended in `processConfigurationLogEntry()` |

## Shadow Fields

**`traceVotedFor`** (api.go:152): Caches the votedFor value since there's no public getter.

Set at:
- raft.go:2069 — `r.traceVotedFor = r.localID` (self-vote in `electSelf()`)
- raft.go:1773 — `r.traceVotedFor = ServerID(req.ID)` (vote granted in `requestVote()`)
- raft.go:371, 1495, 1710 — `r.traceVotedFor = ""` (step down / term change)

## How to Add a New Field to an Event

1. Add the field to `TraceMsg` in `trace_logger.go` with a `json:"fieldName,omitempty"` tag
2. Set the field at the trace emit site (e.g., `r.traceEvent("EventName", &TraceMsg{NewField: value})`)
3. Access it in `Trace.tla` via `logline.event.msg.fieldName`

## How to Add a New Event Type

1. Choose a name matching a spec action (e.g., `"CheckLeaderLease"`)
2. Add `r.traceEvent("CheckLeaderLease", &TraceMsg{...})` at the code location
3. Add `CheckLeaderLeaseIfLogged` wrapper in `Trace.tla` following the pattern of existing wrappers
4. Add the wrapper to `TraceNext`

## How to Move a Capture Point

Some events use deferred trace emission (e.g., `HandleAppendEntriesRequest`, `HandleRequestVoteRequest`). The `defer` ensures the event is emitted after all state updates but before the response is sent.

To move from before to after (or vice versa):
1. Find the `r.traceEvent(...)` call
2. Move it to the new location, ensuring the state snapshot captures the correct post-state
3. For deferred events, the state is captured at defer execution time (function return)

## State Capture Levels

| Level | Events | Reason |
|-------|--------|--------|
| **Full** | BecomeCandidate, BecomeLeader, HandleRequestVoteRequest, HandleRequestVoteResponse, HandleAppendEntriesRequest, AdvanceCommitIndex, ProposeConfigChange | Main goroutine has full state access |
| **Weak** (term + role only) | SendReplicateEntries, SendHeartbeat, HandleReplicateResponse, HandleHeartbeatResponse | Replication/heartbeat goroutines — commitIndex may be stale |

## Known Concurrency Issues

### Pipeline commitIndex Race
The replication goroutine calls `setupAppendEntries()` which reads `r.getCommitIndex()`. Between this read and the trace event emission, the main goroutine may advance commitIndex. This causes `state.commitIndex` (fresh) to differ from `msg.commitIndex` (stale) in `SendReplicateEntries` events.

**Trace.tla fix**: `TraceReplicateEntries` uses `logline.event.msg.commitIndex` (the actual message value) instead of `commitIndex[i]` (the spec's current state).

### Pipeline nextIndex
In pipeline mode (`pipelineReplicate()`), the implementation updates `s.nextIndex` optimistically after each send. The spec only updates `nextIndex` after receiving a response. This means back-to-back `SendReplicateEntries` events may have different `prevLogIndex` values than the spec expects.

**Trace.tla fix**: `FillLogGap` handles the case where the spec's log is shorter than expected. Messages from the spec may carry more entries than the implementation's messages, but `HandleAppendEntriesRequestIfLogged` matches by source/dest/term/subtype (not by entries).

## How to Rebuild and Re-run

```bash
# From case-studies/hashicorp-raft/
bash harness/run.sh

# Or manually:
cd harness/src && go build -o harness . && cd ../..
harness/src/harness -scenario basic_election -out traces/basic_election.ndjson

# Validate a single trace:
cd spec
JSON="../traces/basic_election.ndjson" java -cp $TLA_JAR:$CM_JAR tlc2.TLC Trace.tla -config Trace.cfg -workers 1 -deadlock
```
