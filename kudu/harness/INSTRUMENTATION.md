# Kudu Raft Trace Instrumentation Guide

Quick reference for the Phase 3 (validation) agent to adjust instrumentation.

## Files Modified

After running `harness/apply.sh`, these files are modified:

| File | Changes |
|------|---------|
| `src/kudu/consensus/tla_trace.h` | Trace module header (copied) |
| `src/kudu/consensus/tla_trace.cc` | Trace module implementation (copied) |
| `src/kudu/consensus/CMakeLists.txt` | Added `tla_trace.cc` to CONSENSUS_SRCS |
| `src/kudu/consensus/raft_consensus.cc` | 8 trace emit points |
| `src/kudu/consensus/consensus_peers.cc` | 1 trace emit point (SendEntries/SendHeartbeat) |
| `src/kudu/consensus/consensus_queue.cc` | 1 trace emit point (HandleAppendEntriesResponse) |
| `src/kudu/consensus/leader_election.cc` | 1 trace emit point (HandleRequestVoteResponse) |
| `src/kudu/consensus/leader_election.h` | Added `trace_commit_index_` field |
| `src/kudu/consensus/tla_trace_test.cc` | Test scenario (copied) |

## Instrumentation Points

Search for `TLA+ trace:` comments in the instrumented source to find each point.

### raft_consensus.cc

| Event | Location | State Level | Trigger |
|-------|----------|-------------|---------|
| BecomeCandidate | `StartElection()`, after `SetVotedForCurrentTermUnlocked` | Full | Real election start |
| PreVote | `StartElection()`, same location (mode=PRE_ELECTION) | Full | Pre-election start |
| HandleRequestVoteResponse (self) | `StartElection()`, after `counter.RegisterVote` | Full | Self-vote |
| BecomeLeader | `BecomeLeaderUnlocked()`, after `leader_is_ready_=true` | Full | Election won |
| StepDown | `StepDown()`, after `HandleTermAdvanceUnlocked` | Full | Leader steps down |
| AdvanceCommitIndex | `NotifyCommitIndex()`, after `AdvanceCommittedIndex` | Full | Leader commit advance |
| HandleAppendEntriesRequest | `UpdateReplica()`, after `FillConsensusResponseOKUnlocked` | Full | Follower accepts entries |
| HandleRequestVoteRequest | Each `RequestVoteRespond*()` method (5 locations) | Full | Vote granted/denied |

### consensus_peers.cc

| Event | Location | State Level | Trigger |
|-------|----------|-------------|---------|
| SendEntries / SendHeartbeat | `SendNextRequest()`, before `controller_.Reset()` | Weak (term+role) | Leader sends to peer |

### consensus_queue.cc

| Event | Location | State Level | Trigger |
|-------|----------|-------------|---------|
| HandleAppendEntriesResponse | `ResponseFromPeer()`, after VLOG | Weak (term+role) | Leader processes response |

### leader_election.cc

| Event | Location | State Level | Trigger |
|-------|----------|-------------|---------|
| HandleRequestVoteResponse | `VoteResponseRpcCallback()`, before `CheckForDecision` | Full (reconstructed from election state) | Remote vote received |

## How to Add a New Field to an Event

1. Open the trace emit point (search for `TLA+ trace: <EventName>`)
2. Add a new `.MsgStr()`, `.MsgInt()`, or `.MsgBool()` call to the `TraceEvent` builder
3. Rebuild: `cd artifact/incubator-kudu/build && make -j$(nproc) tla_trace_test`

Example — adding `numEntries` to HandleAppendEntriesRequest:
```cpp
tla_trace::TraceEvent("HandleAppendEntriesRequest")
    .Node(tla_trace::Nid(peer_uuid()))
    .State(ts)
    .MsgStr("from", tla_trace::Nid(request->caller_uuid()))
    .MsgInt("numEntries", request->ops_size())  // <-- add this
    .Emit();
```

## How to Add a New Event Type

1. Find the code location where the action occurs
2. Copy the pattern from an existing trace emit block
3. Use `tla_trace::TraceEvent("NewEventName")` with appropriate `.Node()`, `.State()`, `.Msg*()` calls
4. Add corresponding handler in `spec/Trace.tla`

## How to Move a Capture Point

If state needs to be captured BEFORE an action instead of AFTER (or vice versa), move the trace emit block to the desired location. Ensure you're still inside the correct lock scope.

State accessors available under `lock_`:
- `CurrentTermUnlocked()` — current term
- `cmeta_->active_role()` — LEADER/FOLLOWER enum
- `HasVotedCurrentTermUnlocked()` / `GetVotedForCurrentTermUnlocked()` — vote
- `pending_->GetCommittedIndex()` — commit index
- `queue_->GetLastOpIdInLog()` — last log OpId (index + term)

## How to Rebuild and Re-run

```bash
cd case-studies/kudu
# Re-apply instrumentation (resets changes first)
bash harness/apply.sh
# Copy test file
cp harness/src/tla_trace_test.cc artifact/incubator-kudu/src/kudu/consensus/tla_trace_test.cc
# Rebuild
cd artifact/incubator-kudu/build
make -j$(nproc) tla_trace_test
# Run with trace
cd ../../..
KUDU_TRACE_FILE=$(pwd)/traces/test.ndjson \
  artifact/incubator-kudu/build/bin/tla_trace_test --gtest_filter=TlaTraceTest.BasicElectionAndReplication
```

## Server ID Mapping

UUIDs are dynamically mapped to `s1`, `s2`, `s3` in registration order. The mapping is initialized in the test's `BuildAndStartCluster()` method. The `tla_trace::Nid(uuid)` function auto-registers unknown UUIDs.

## Environment Variable

Set `KUDU_TRACE_FILE=/path/to/trace.ndjson` to enable tracing. If unset, no trace is emitted (zero overhead).
