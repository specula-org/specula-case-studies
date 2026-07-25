# sofa-jraft Instrumentation Guide

## Overview

This harness instruments the real sofa-jraft source code to emit TLA+ trace events
as NDJSON to `traces/*.ndjson` files, suitable for trace-validation with TLC and
`spec/Trace.tla`.

## Files

```
harness/
  apply.sh          — copies instrumented files into the artifact tree
  run.sh            — full pipeline: apply → build → test → collect traces
  INSTRUMENTATION.md — this file
  src/
    TlaTrace.java              — trace emission library (new file)
    NodeImpl.java              — instrumented (7 event sites)
    FSMCallerImpl.java         — instrumented (1 event site)
    Replicator.java            — instrumented (1 event site)
    TlaTraceScenario1Test.java — normal election + replication test
    TlaTraceScenario2Test.java — leader crash + re-election test
```

## Quick Start

```bash
cd harness
./run.sh           # produces traces/scenario1.ndjson and traces/scenario2.ndjson
```

To apply instrumentation only (skip build and tests):

```bash
./apply.sh
```

## Instrumentation Points

### TlaTrace.java (new file)

Package `com.alipay.sofa.jraft.core`. Thread-safe trace writer with:
- `reset(traceFile)` — opens a fresh NDJSON file (used at scenario start)
- `registerPeers(String...)` — pre-registers PeerId→s1/s2/s3 mapping
- `emitXxx(...)` — one method per TLA+ event (16 total)
- `emitCrash(...)` — also marks the node in `pendingRestarts`
- `consumeRestartPending(peerId)` — returns true+clears if node was crashed

### NodeImpl.java

| Location | Event emitted |
|---|---|
| `electSelf()` — after `setTermAndVotedFor` | `ElectionTimeout` |
| `handleRequestVoteRequest()` — higher-term path, after stepDown | `PersistTermEmptyVote` |
| `handleRequestVoteRequest()` — deny path, before `break` | `HandleRequestVoteRequestDeny` |
| `handleRequestVoteRequest()` — higher-term grant, after `setVotedFor` | `PersistActualVote` |
| `handleRequestVoteRequest()` — same-term grant, after `setVotedFor` | `HandleRequestVoteRequestGrantSameTerm` |
| `handleRequestVoteRequest()` — before return on grant+higherTerm | `SendVoteGranted` |
| `handleRequestVoteResponse()` — after `voteCtx.grant()`, before finally | `HandleRequestVoteResponse` |
| `executeApplyingTasks()` — after `appendEntries`, if entries non-empty | `ClientRequest` |
| `FollowerStableClosure.run()` — after `sendResponse` | `HandleAppendEntriesRequest` |
| `stepDown()` — at end, if was Leader before stepDown | `StepDown` |
| `initMetaStorage()` — after `votedId` loaded, if `consumeRestartPending` | `RestartFromPersisted` |

**Key design decisions:**

- `tlaWasHigherTerm` boolean tracks the two-phase vote path in `handleRequestVoteRequest()`.
- `tlaWasLeader` boolean captures pre-stepdown role at the top of `stepDown()`.
- `FollowerStableClosure` stores `tlaPrevLogIndex` and `tlaEntriesCount` from the
  request object at construction time, since the callback fires asynchronously after
  the log is stable.
- `RestartFromPersisted` is only emitted when `consumeRestartPending()` returns true —
  i.e., only after an explicit `Crash` event (not on fresh startup).
- `getMetaStorage()` package-private accessor added for test harness use.

### FSMCallerImpl.java

| Location | Event emitted |
|---|---|
| `setLastApplied()` — after `notifyLastAppliedIndexUpdated`, if lastIndex > 0 | `ApplyCommittedEntries` |

### Replicator.java

| Location | Event emitted |
|---|---|
| `onInstallSnapshotReturned()` — after `r.setState(State.Replicate)` | `HandleInstallSnapshotResponseNormal` |

## NDJSON Format

Every line is a flat JSON object with mandatory fields:

```json
{"tag":"trace","ts":<ms>,"event":"<EventName>","node":"<sN>", ...state-fields...}
```

- `"tag":"trace"` — required by Trace.tla for line filtering
- `"node"` — `"s1"`, `"s2"`, or `"s3"` (mapped from Java PeerId strings)
- State fields vary by event (see TlaTrace.java emit methods)

## TLA+ Constants

```
Server = {s1, s2, s3}
Nil = nil
Leader = Leader
Candidate = Candidate
Follower = Follower
```

## Test Scenarios

### Scenario 1: Normal Election + Replication

`TlaTraceScenario1Test` starts a 3-node cluster (election_timeout=300ms), waits for
leader election, applies 5 client tasks, waits for FSM convergence.

Expected events: ~35+
- ElectionTimeout × 1 (first candidate)
- PersistTermEmptyVote/PersistActualVote/SendVoteGranted × 2 followers
- HandleRequestVoteResponse × 2 (candidate tallying votes)
- ClientRequest × 5
- HandleAppendEntriesRequest × 10 (2 followers × 5 tasks)
- ApplyCommittedEntries × 15 (3 nodes × 5 batches)

### Scenario 2: Leader Crash + Re-election

`TlaTraceScenario2Test` starts a 3-node cluster (election_timeout=500ms):
1. Initial election (like scenario 1)
2. 3 client tasks
3. Explicit `TlaTrace.emitCrash()` + leader `cluster.stop()`
4. New election on remaining 2 nodes
5. 3 more client tasks
6. Restart old leader → `RestartFromPersisted` event
7. FSM convergence

Expected events: ~50+

## Running TLC Validation (Phase 3)

After generating traces, run TLC on spec/Trace.tla:

```bash
tlc2 -config spec/Trace.cfg spec/Trace.tla -trace traces/scenario1.ndjson
```

The spec invariant `TraceMatched` requires each trace event to match a corresponding
TLA+ action. `TypeOK`, `ElectionSafety`, `LogMatching`, `PersistMonotone`, and
`CommitMonotone` are checked as invariants.
