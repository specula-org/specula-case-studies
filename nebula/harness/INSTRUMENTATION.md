# Nebula Raft Trace Instrumentation Guide

Guide for the Phase 3 (validation) agent to adjust instrumentation.

## Architecture

- **Trace module**: `src/kvstore/raftex/trace_logger.h` / `trace_logger.cpp`
- **Compile flag**: `-DNEBULA_ENABLE_TRACE` (via CMake `WITH_NEBULA_TRACE=ON`)
- **Env var**: `NEBULA_TRACE_FILE` overrides `--nebula_trace_file` flag
- **Thread safety**: `TraceWriter` uses a mutex; all emit calls are safe from any thread

## Instrumentation Points

All instrumentation is guarded by `NEBULA_TRACE_IF_ENABLED({...})` — zero overhead when disabled.

| Event | File | Location | Capture Level |
|-------|------|----------|---------------|
| Restart | RaftPart.cpp:~448 | After `startTimeMs_` set in `start()` | Full |
| Timeout | RaftPart.cpp:~1152 | Before `return role_ == Role::CANDIDATE` in `needToStartElection()` | Weak (term, role) |
| SendPreVote | RaftPart.cpp:~1192 | After `hosts = followers()` in `prepareElectionRequest()` | Full |
| SendRequestVote | RaftPart.cpp:~1192 | Same location, distinguished by `isPreVote` flag | Full |
| HandlePreVoteRequest | RaftPart.cpp:~1606 | After `kNumGrantVotes` in `processAskForVoteRequest()` (grant path only) | Full + msg |
| HandleRequestVoteRequest | RaftPart.cpp:~1606 | Same location, distinguished by `is_pre_vote` | Full + msg |
| BecomeLeader | RaftPart.cpp:~1397 | Before `inElection_ = false` in `handleElectionResponses()` | Full |
| ClientRequest | RaftPart.cpp:~903 | After `lastId = wal_->lastLogId()` in `appendLogsInternal()` | Full |
| HandleAppendEntriesResponse | RaftPart.cpp:~1083 | After `committedLogTerm_ = lastCommitTerm` in `processAppendLogResponses()` | Full |
| HandleAppendEntriesRequest | RaftPart.cpp:~1826 | After second `lastMsgRecvDur_.reset()` in `processAppendLogRequest()` | Full + msg |
| HandleHeartbeatRequest | RaftPart.cpp:~1949 | After "return ok after verifyLeader" in `processHeartbeatRequest()` | Full + msg |
| HandleHeartbeatResponse | RaftPart.cpp:~2113 | After "Heartbeat is accepted by quorum" in `sendHeartbeat()` callback | Weak |
| SendHeartbeat | RaftPart.cpp:~2078 | After "Send heartbeat to" in `sendHeartbeat()` lambda | Weak + msg |
| AppendEntries | Host.cpp:~400 | After "Sending appendLog:" in `sendAppendLogRequest()` | Weak + msg |
| StartSnapshot | Host.cpp:~355 | After `sendingSnapshot_ = true` in `startSendSnapshot()` | Weak + msg |
| CompleteSnapshot | Host.cpp:~372 | After `sendingSnapshot_ = false` in snapshot callback | Weak + msg |
| Crash | TraceTest.cpp | Emitted by test harness before `killOneCopy()` | nid only |

## How to Add a New Field to an Event

1. Add the field to `TraceState` struct in `trace_logger.h`
2. Set it in the capture block (the `__ts.field = value;` lines)
3. The field will appear in the JSON state object automatically via `emit()`

## How to Add a New Event Type

1. Copy an existing `NEBULA_TRACE_IF_ENABLED({...})` block
2. Change the event name string: `TraceEvent("NewEventName")`
3. Adjust the state capture level (Full vs Weak)
4. Add msg fields if the event involves a message

## How to Move a Capture Point

If trace validation shows state captured too early/late:

1. Find the `NEBULA_TRACE_IF_ENABLED` block in the instrumented source
2. Move it to the new location (before/after the state update)
3. Ensure the raft lock is held when capturing full state

## How to Rebuild and Re-run

```bash
cd case-studies/nebula

# Re-apply instrumentation (reverts + re-applies)
bash harness/apply.sh

# Rebuild just the test
cd artifact/nebula/build
make -j$(nproc) trace_test

# Re-run one scenario
./bin/test/trace_test --gtest_filter="TraceTest.BasicConsensus" \
    --nebula_trace_enabled=true \
    --nebula_trace_file="../../traces/basic_consensus.ndjson"
```

## Server ID Mapping

Server IDs are mapped at runtime via `TraceServerMap::registerPeer()`. The mapping is:
- First `start()` call registers self → "s1"
- Peers are registered in order of first encounter → "s2", "s3", ...
- All hosts within a partition share the same map (singleton)

The mapping is initialized in the `Restart` event instrumentation inside `RaftPart::start()`.

## Known Limitations

1. **Vote reject paths not traced**: Only the grant path in `processAskForVoteRequest()` emits events. Reject paths (term too low, log stale, already voted) are handled by Trace.tla silent actions.
2. **AppendEntries from Host**: The `AppendEntries` event is emitted from `Host::sendAppendLogRequest()`, which runs on an IO thread. State capture is weak (term + role from the request).
3. **Heartbeat callback**: `HandleHeartbeatResponse` only fires on quorum success, not individual responses. This is a simplification.
4. **Noop log in sendHeartbeat**: The empty log appended at `sendHeartbeat:2044-2048` is NOT separately traced. Use `SilentClientRequest` in Trace.tla.
