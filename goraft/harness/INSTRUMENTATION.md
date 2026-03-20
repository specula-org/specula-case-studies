# Instrumentation Guide: goraft/raft

Quick reference for the Phase 3 (validation) agent to adjust instrumentation.

## Overview

The instrumentation adds trace emission calls to `server.go` and `peer.go` via a git patch.
The trace module (`tla_trace.go`) and test scenarios (`tla_trace_test.go`) are separate files
copied into the artifact directory.

## File Locations (after apply.sh)

| File | Purpose |
|------|---------|
| `artifact/raft/tla_trace.go` | Trace emission module (emit helpers, state capture) |
| `artifact/raft/tla_trace_test.go` | Test scenarios that generate traces |
| `artifact/raft/server.go` | Main instrumentation points (patched) |
| `artifact/raft/peer.go` | Peer heartbeat/replication instrumentation (patched) |

## Instrumentation Points

### server.go

| Event | Location | Trigger |
|-------|----------|---------|
| Timeout | `followerLoop()` ~line 712 | After `setState(Candidate)` |
| RequestVote | `candidateLoop()` ~line 750 | After `votedFor = s.name` |
| BecomeLeader | `candidateLoop()` ~line 776 | After `setState(Leader)` |
| HandleRequestVoteResponse | `candidateLoop()` ~line 790 | After `processVoteResponse()` |
| HandleRequestVoteRequest | `processRequestVoteRequest()` | defer at function entry (named returns) |
| HandleAppendEntriesRequest | `processAppendEntriesRequest()` | defer at function entry (named returns) |
| HandleAppendEntriesResponse | `processAppendEntriesResponse()` | After syncedPeer update |
| AdvanceCommitIndex | `processAppendEntriesResponse()` | After `setCommitIndex()` |
| ClientRequest / AppendNOP | `processCommand()` | After `appendEntry()`, checks command type |
| HandleSnapshotRequest | `processSnapshotRequest()` | After `setState(Snapshotting)` |
| HandleSnapshotRecoveryRequest | `processSnapshotRecoveryRequest()` | After `log.compact()` |

### peer.go

| Event | Location | Trigger |
|-------|----------|---------|
| Replicate | `flush()` | Before `sendAppendEntriesRequest()` when `len(entries) > 0` |
| SendHeartbeat | `flush()` | Before `sendAppendEntriesRequest()` when `len(entries) == 0` |
| SendSnapshotRequest | `flush()` | Before `sendSnapshotRequest()` |
| SendSnapshotRecoveryRequest | `sendSnapshotRecoveryRequest()` | Before sending recovery request |

## State Capture Levels

| Level | Used by | Fields |
|-------|---------|--------|
| Full (`captureState`) | Event loop actions | term, role, commitIndex, lastLogIndex, lastLogTerm |
| Weak (`captureWeakState`) | Peer goroutine actions | term, role only (no lock held) |
| Pre (`capturePre`) | All actions | term, role before mutation |

## How to Add a New Field to an Event

1. Edit `tla_trace.go`: add the field to `TraceState` struct
2. Edit `captureState()` to populate the new field
3. Rebuild: `cd artifact/raft && go build ./...`

## How to Add a New Event Type

1. In `tla_trace.go`: add a new `emitXxx(s *server, ...)` function following existing patterns
2. In `server.go` or `peer.go`: insert the emit call at the desired trigger point
3. Update `harness/patches/instrumentation.patch`: `cd artifact/raft && git diff server.go peer.go > ../../harness/patches/instrumentation.patch`

## How to Move a Capture Point

If validation reveals the trace captures state at the wrong moment (e.g., before vs after a mutation):

1. Find the emit call in `server.go` or `peer.go`
2. Move it to the correct position (before/after the state mutation)
3. If moving pre-state capture: ensure `capturePre(s)` is called before the mutation
4. Regenerate the patch

## Rebuild and Re-run After Changes

```bash
# From case-studies/goraft/
cd artifact/raft
go build ./...
TRACE_DIR=$PWD/../../traces go test -v -run TestTLATrace -timeout 120s ./...

# Or re-run the full pipeline:
cd ../..
bash harness/run.sh
```

## Known Quirks

- **Named return values**: `processRequestVoteRequest` and `processAppendEntriesRequest` use
  named return values + `defer` for trace emission. All return paths automatically trigger the trace.
- **NOPCommand type check**: `processCommand` checks both `NOPCommand` (value) and `*NOPCommand` (pointer)
  because the Go type system requires both.
- **Weak state for peer events**: Replicate/SendHeartbeat capture state without the server mutex
  (matching the implementation's own racy reads — Bug Family 5).
- **No Crash event**: The test scenarios use `Stop()` to simulate failures. A true Crash event
  would require `Stop()` + `Start()` with trace emission on restart.
