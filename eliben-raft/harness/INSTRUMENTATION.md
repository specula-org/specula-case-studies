# Instrumentation Guide: eliben/raft

Quick reference for adjusting trace instrumentation in Phase 3 (validation).

## Architecture

- **Trace module**: `tla_trace.go` (copied into `artifact/raft/part3/raft/`)
- **Instrumentation**: `patches/instrumentation.patch` (applied to `raft.go` and `testharness.go`)
- **Test scenarios**: `tla_trace_test.go` (copied into `artifact/raft/part3/raft/`)

## Instrumentation Points

After applying the patch (`harness/apply.sh`), trace emit calls are at:

| Event | File | Location | Capture Level |
|-------|------|----------|---------------|
| Timeout | raft.go:startElection | After `cm.votedFor = cm.id` | Weak (term, role) |
| HandleRequestVoteRequest | raft.go:RequestVote | After `cm.persistToStorage()` | Full + votedFor |
| HandleRequestVoteResponse | raft.go:startElection goroutine | 3 exit points (becomeFollower, quorum, fallthrough) | Weak (async goroutine) |
| BecomeLeader | raft.go:startLeader | After nextIndex/matchIndex init | Full (commitIndex, lastLogIndex) |
| ClientRequest | raft.go:Submit | After `cm.persistToStorage()` | Full (commitIndex, lastLogIndex) |
| AppendEntries | raft.go:leaderSendAEs | After args construction, before RPC | from/to only (via traceEmitRaw) |
| HandleAppendEntriesRequest | raft.go:AppendEntries | After `cm.persistToStorage()` | Full + votedFor |
| HandleAppendEntriesResponse | raft.go:leaderSendAEs | 4 exit points (higher term, success+commit, success, failure) | Weak (async goroutine) |
| AdvanceCommitIndex | raft.go:leaderSendAEs | When `cm.commitIndex != savedCommitIndex` | commitIndex only |
| Crash | testharness.go:CrashPeer | Before `Shutdown()` | node only (via traceEmitRaw) |

## How to Add a New Field to an Event

1. Find the `cm.traceEvent(...)` call for the event in `raft.go`
2. Add the field to the `map[string]any{...}` argument:
   ```go
   cm.traceEvent("EventName", map[string]any{
       "existingField": value,
       "newField":      newValue,  // add here
   })
   ```
3. Rebuild: `cd artifact/raft/part3/raft && go test -run TestTraceBasicConsensus -count=1 .`

## How to Add a New Event Type

1. Add a `cm.traceEvent("NewEventName", map[string]any{...})` call at the trigger point in `raft.go`
2. The `traceEvent` method automatically includes: event, node, term, role, ts
3. Add extra fields as needed in the map
4. For events outside the CM (e.g., test harness), use `traceEmitRaw(map[string]any{...})` directly

## How to Move a Capture Point

1. Find the current `cm.traceEvent(...)` call
2. Move it to the new location (before/after a specific operation)
3. Ensure `cm.mu` is held at the new location (check surrounding Lock/Unlock)
4. For goroutine contexts, verify the lock is held and state is consistent

## Index Mapping

The implementation uses 0-indexed Go slices; TLA+ uses 1-indexed sequences:

| Field | Trace Value | Code Expression |
|-------|-------------|-----------------|
| commitIndex | `cm.commitIndex + 1` | Code -1 → TLA+ 0 |
| lastLogIndex | `len(cm.log)` | Matches TLA+ Len(log[i]) directly |

## Rebuild and Re-run

```bash
cd case-studies/eliben-raft
bash harness/run.sh     # Full: apply + build + test + collect
# Or manually:
bash harness/apply.sh   # Apply instrumentation
cd artifact/raft/part3/raft
RAFT_TRACE_DIR=../../../../traces go test -run TestTrace -count=1 -v .
```

## Lock Ordering

`cm.mu` → `traceMu` (always). Never acquire `cm.mu` while holding `traceMu`.
All `cm.traceEvent()` calls must be inside `cm.mu.Lock()` sections.
The `traceEmitRaw()` function only acquires `traceMu` (for external callers like testharness).
