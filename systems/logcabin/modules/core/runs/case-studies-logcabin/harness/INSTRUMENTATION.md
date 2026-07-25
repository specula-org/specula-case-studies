# LogCabin Trace Instrumentation Guide

Quick reference for the Phase 3 (validation) agent to adjust instrumentation.

## Architecture

- **Trace module**: `Server/tla_trace.h` (header) + `Server/tla_trace.cc` (impl)
- **Instrumentation**: `Server/RaftConsensus.cc` — emit calls guarded by `#ifdef LOGCABIN_TLA_TRACE`
- **Test scenarios**: `Server/RaftTraceTest.cc`
- **Activation**: Set `LOGCABIN_TRACE_FILE=path.ndjson` environment variable
- **Build flag**: `CXXFLAGS='-DLOGCABIN_TLA_TRACE'`

## Instrumentation Points

| # | Event | File:Location | Capture Level | Notes |
|---|-------|--------------|---------------|-------|
| 1 | Timeout | RaftConsensus.cc:startNewElection, after updateLogMetadata | Full | After term increment + state change |
| 2 | BecomeLeader | RaftConsensus.cc:becomeLeader, after interruptAll | Full | After NOOP append, lastLogIndex includes it |
| 3 | ClientRequest | RaftConsensus.cc:replicateEntry, after append | Full | Only for DATA entries |
| 4 | AppendEntries | RaftConsensus.cc:appendEntries, before callRPC | Full | Leader sends to peer |
| 5 | HandleAppendEntriesResponse | RaftConsensus.cc:appendEntries, after matchIndex update | Full | Success and failure paths |
| 6 | InstallSnapshot | RaftConsensus.cc:installSnapshot, before callRPC | Full | Only first chunk (byte_offset==0) |
| 7 | HandleInstallSnapshotResponse | RaftConsensus.cc:installSnapshot, after snapshot complete | Full | Only when transfer complete |
| 8 | HandleRequestVote | RaftConsensus.cc:handleRequestVote, after response set | Full | Before return |
| 9 | HandleRequestVoteResponse | RaftConsensus.cc:requestVote, after peer.haveVote_ set | Full | BEFORE potential becomeLeader() call |
| 10 | HandleAppendEntries | RaftConsensus.cc:handleAppendEntries, at end | Full | After all state changes |
| 11 | HandleInstallSnapshot | RaftConsensus.cc:handleInstallSnapshot, after readSnapshot | Full | Only when done==true |
| 12 | AdvanceCommitIndex | RaftConsensus.cc:advanceCommitIndex, after commitIndex update | Commit | Only when commitIndex actually changes |
| 13 | LeaderDiskSync | RaftConsensus.cc:leaderDiskThreadMain, after lastSyncedIndex | Full | Only when state==LEADER && term matches |
| 14 | TakeSnapshot | RaftConsensus.cc:snapshotDone, after lastSnapshotTerm set | Full | |
| 15 | Crash | Test harness emits directly | None | No state snapshot |

### Not Yet Instrumented (available as Silent actions in Trace.tla)

- **StepDownCheck**: Complex loop in stepDownThreadMain with epoch checks. Not traced because the step-down thread doesn't run in test mode (`startThreads=false`).
- **ProposeConfigChange**: Embedded in setConfiguration's complex flow with catch-up waiting. Traced only via the config entry appearing in AppendEntries.

## How to Add a New Field to an Event

1. Find the `TlaTrace::Event(...)` call in `RaftConsensus.cc`
2. Chain `.field("fieldName", value)` before `.emit()`
3. Example:
   ```cpp
   TlaTrace::Event("HandleAppendEntries", serverId)
       .state(TLA_STATE())
       .field("from", TlaTrace::nid(request.server_id()))
       .field("success", response.success())
       .field("newField", someValue)   // ← add here
       .emit();
   ```

## How to Add a New Event Type

1. Find the appropriate code location in `RaftConsensus.cc`
2. Add an `#ifdef LOGCABIN_TLA_TRACE` block:
   ```cpp
   #ifdef LOGCABIN_TLA_TRACE
       if (TlaTrace::isEnabled()) {
           TlaTrace::Event("NewEventName", serverId)
               .state(TLA_STATE())
               .emit();
       }
   #endif
   ```
3. Add corresponding `TraceNewEventName` wrapper in `Trace.tla`

## How to Move a Capture Point

The `TLA_STATE()` macro captures `currentTerm, role, commitIndex, lastLogIndex, lastLogTerm` from the calling context. To move from before→after (or vice versa):

1. Move the entire `#ifdef LOGCABIN_TLA_TRACE ... #endif` block
2. Ensure the new location still holds the mutex (all current points do)
3. Verify the state fields are correct at the new location

## How to Rebuild and Re-run

```bash
cd case-studies/logcabin
bash harness/apply.sh    # re-apply instrumentation (resets artifact first)
cd artifact/logcabin
scons -j$(nproc) CXXFLAGS='-DLOGCABIN_TLA_TRACE'
LOGCABIN_TRACE_FILE=../../traces/test.ndjson \
    ./build/test/test --gtest_filter='RaftTraceTest.basic_consensus'
```

Or run everything at once:
```bash
cd case-studies/logcabin && bash harness/run.sh
```

## Test-Emitted Events

Some events are emitted from `RaftTraceTest.cc` rather than from instrumented `RaftConsensus.cc` code. This is because the response processing for RPC-based methods (`requestVote`, `appendEntries`) is embedded inside the RPC call flow, which requires real network connections.

**Test-emitted in basic_consensus**: HandleRequestVoteResponse (x2), AppendEntries (x2), HandleAppendEntriesResponse (x2), LeaderDiskSync (x1)

**Instrumented-code-emitted**: Timeout, HandleRequestVote (x2), BecomeLeader, HandleAppendEntries (x2), AdvanceCommitIndex

The test-emitted events capture **real state** from the consensus object — only the trigger point is in test code rather than inside the handler method. When real peer threads are enabled (multi-process tests), the instrumented code paths fire naturally.

## Threading Model

All trace events are emitted while holding `consensus.mutex`, so they are naturally serialized. The trace module has its own mutex for file I/O, making it safe for the rare case of concurrent emitters.

## Server ID Mapping

Implementation uses `uint64_t` server IDs (1, 2, 3). Mapped to TLA+ names ("s1", "s2", "s3") via `TlaTrace::registerServer()` at test setup. The mapping is used by `TlaTrace::nid()` at emit time.
