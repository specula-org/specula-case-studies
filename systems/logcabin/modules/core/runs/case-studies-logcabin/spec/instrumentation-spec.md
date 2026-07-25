# Instrumentation Spec: logcabin/logcabin

Action-to-code mapping for trace harness generation. Each entry specifies where to instrument the source code to produce NDJSON trace events compatible with `Trace.tla`.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "event": "<spec action name>",
  "node": "<server ID string>",
  "timestamp": <nanoseconds>,
  "state": {
    "currentTerm": <uint64>,
    "role": "follower" | "candidate" | "leader",
    "commitIndex": <uint64>,
    "lastLogIndex": <uint64>,
    "lastLogTerm": <uint64>
  },
  ... event-specific fields ...
}
```

### State Fields

| Implementation field | TLA+ variable | Accessor |
|---------------------|---------------|----------|
| `currentTerm` | `currentTerm[i]` | `consensus.currentTerm` |
| `state` | `state[i]` | `consensus.state` (enum: FOLLOWER/CANDIDATE/LEADER) |
| `commitIndex` | `commitIndex[i]` | `consensus.commitIndex` |
| `log->getLastLogIndex()` | `LastLogIndex(i)` | `consensus.log->getLastLogIndex()` |
| `getLastLogTerm()` | `LastLogTerm(i)` | `consensus.getLastLogTerm()` |
| `lastSnapshotIndex` | `lastSnapshotIndex[i]` | `consensus.lastSnapshotIndex` |
| `votedFor` | `votedFor[i]` | `consensus.votedFor` |
| `leaderId` | `leaderId[i]` | `consensus.leaderId` |

### Message Fields (event-specific)

| Implementation field | TLA+ field | Notes |
|---------------------|------------|-------|
| `request.server_id()` | `msource` | Sender's server ID |
| `request.term()` | `mterm` | Message term |
| `request.prev_log_index()` | `mprevLogIndex` | AppendEntries only |
| `request.prev_log_term()` | `mprevLogTerm` | AppendEntries only |
| `request.commit_index()` | `mcommitIndex` | AppendEntries only |
| `response.success()` | `msuccess` | AppendEntries response |
| `response.granted()` | `mvoteGranted` | RequestVote response |

---

## Section 2: Action-to-Code Mapping

### 1. Timeout (startNewElection)

| Field | Value |
|-------|-------|
| **Spec action** | `Timeout` |
| **Code location** | `Server/RaftConsensus.cc:2858-2904` |
| **Trigger point** | After `++currentTerm` and `state = State::CANDIDATE` (line 2888-2890) |
| **Trace event name** | `Timeout` |
| **Fields** | Standard state snapshot |
| **Notes** | Capture state AFTER term increment and state change. Self-vote is already recorded at this point. |

### 2. BecomeLeader

| Field | Value |
|-------|-------|
| **Spec action** | `BecomeLeader` |
| **Code location** | `Server/RaftConsensus.cc:2493-2528` |
| **Trigger point** | After `state = State::LEADER` (line 2500) and NOOP append (line 2524) |
| **Trace event name** | `BecomeLeader` |
| **Fields** | Standard state snapshot |
| **Notes** | Emit after the NOOP entry is appended so lastLogIndex reflects it. |

### 3. ClientRequest

| Field | Value |
|-------|-------|
| **Spec action** | `ClientRequest` |
| **Code location** | `Server/RaftConsensus.cc` (via `replicateEntry`, called from `replicate`) |
| **Trigger point** | After `append({&entry})` completes for a DATA entry |
| **Trace event name** | `ClientRequest` |
| **Fields** | Standard state snapshot |
| **Notes** | Only emit for DATA entries, not for internal NOOP or CONFIG entries. |

### 4. AppendEntries (leader sends)

| Field | Value |
|-------|-------|
| **Spec action** | `AppendEntries` |
| **Code location** | `Server/RaftConsensus.cc:2249-2295` (appendEntries, before callRPC) |
| **Trigger point** | After building request, before `peer.callRPC()` (line 2290) |
| **Trace event name** | `AppendEntries` |
| **Fields** | `from`: serverId, `to`: peer.serverId, `prevLogIndex`: request.prev_log_index(), `numEntries`: numEntries, standard state |
| **Notes** | Emit from leader context. The lock is held at this point. |

### 5. SendInstallSnapshot (leader sends)

| Field | Value |
|-------|-------|
| **Spec action** | `SendInstallSnapshot` |
| **Code location** | `Server/RaftConsensus.cc:2387-2440` (installSnapshot, before callRPC) |
| **Trigger point** | After building request, before `peer.callRPC()` (line 2435) |
| **Trace event name** | `InstallSnapshot` |
| **Fields** | `from`: serverId, `to`: peer.serverId, `lastSnapshotIndex`: request.last_snapshot_index(), standard state |
| **Notes** | Only emit for the first chunk (byte_offset == 0) or when done==true. |

### 6. HandleRequestVote (follower/candidate receives)

| Field | Value |
|-------|-------|
| **Spec action** | `HandleRequestVoteRequest` |
| **Code location** | `Server/RaftConsensus.cc:1526-1582` (handleRequestVote) |
| **Trigger point** | After all state changes, before returning (line 1580) |
| **Trace event name** | `HandleRequestVote` |
| **Fields** | `from`: request.server_id(), `granted`: response.granted(), standard state |
| **Notes** | State snapshot captures post-stepDown state (term may have changed). |

### 7. HandleRequestVoteResponse (candidate receives)

| Field | Value |
|-------|-------|
| **Spec action** | `HandleRequestVoteResponse` |
| **Code location** | `Server/RaftConsensus.cc:2796-2819` (requestVote, response processing) |
| **Trigger point** | After processing response, before return (line 2819) |
| **Trace event name** | `HandleRequestVoteResponse` |
| **Fields** | `from`: peer.serverId, `granted`: response.granted(), standard state |
| **Notes** | May trigger BecomeLeader — if so, emit BOTH events in sequence. Guard: skip emit if `currentTerm != request.term()` (stale, line 2793). |

### 8. HandleAppendEntries (follower receives)

| Field | Value |
|-------|-------|
| **Spec action** | `HandleAppendEntriesRequest` |
| **Code location** | `Server/RaftConsensus.cc:1263-1427` (handleAppendEntries) |
| **Trigger point** | After all state changes, before returning (line 1427) |
| **Trace event name** | `HandleAppendEntries` |
| **Fields** | `from`: request.server_id(), `success`: response.success(), `lastLogIndex`: response.last_log_index(), standard state |
| **Notes** | State snapshot includes post-truncation/append log state and updated commitIndex. Reset of withholdVotesUntil happens at line 1426. |

### 9. HandleAppendEntriesResponse (leader receives)

| Field | Value |
|-------|-------|
| **Spec action** | `HandleAppendEntriesResponse` |
| **Code location** | `Server/RaftConsensus.cc:2296-2380` (appendEntries, response processing) |
| **Trigger point** | After processing response (matchIndex/nextIndex updated), before return |
| **Trace event name** | `HandleAppendEntriesResponse` |
| **Fields** | `from`: peer.serverId, `success`: response.success(), `matchIndex`: peer.matchIndex, standard state |
| **Notes** | Guard: skip if `currentTerm != request.term()` (stale, line 2307). May call advanceCommitIndex internally — commitIndex may change. |

### 10. HandleInstallSnapshot (follower receives)

| Field | Value |
|-------|-------|
| **Spec action** | `HandleInstallSnapshotRequest` |
| **Code location** | `Server/RaftConsensus.cc:1430-1525` (handleInstallSnapshot) |
| **Trigger point** | After readSnapshot completes (line 1520), before return |
| **Trace event name** | `HandleInstallSnapshot` |
| **Fields** | `from`: request.server_id(), `lastSnapshotIndex`: lastSnapshotIndex, standard state |
| **Notes** | Only emit when `done == true` (final chunk). For multi-chunk transfers, intermediate chunks don't change spec state. |

### 11. HandleInstallSnapshotResponse (leader receives)

| Field | Value |
|-------|-------|
| **Spec action** | `HandleInstallSnapshotResponse` |
| **Code location** | `Server/RaftConsensus.cc:2451-2490` (installSnapshot, response processing) |
| **Trigger point** | After updating peer.matchIndex/nextIndex, before return |
| **Trace event name** | `HandleInstallSnapshotResponse` |
| **Fields** | `from`: peer.serverId, `matchIndex`: peer.matchIndex, standard state |
| **Notes** | Guard: skip if `currentTerm != request.term()` (stale). Only emit when snapshot transfer is complete (all bytes sent). |

### 12. AdvanceCommitIndex

| Field | Value |
|-------|-------|
| **Spec action** | `AdvanceCommitIndex` |
| **Code location** | `Server/RaftConsensus.cc:2174-2223` (advanceCommitIndex) |
| **Trigger point** | After `commitIndex = newCommitIndex` (line 2196) |
| **Trace event name** | `AdvanceCommitIndex` |
| **Fields** | `newCommitIndex`: commitIndex, standard state |
| **Notes** | This is called from leaderDiskThreadMain (line 2048) and appendEntries (line 2337). Both call sites hold the mutex. Only emit if commitIndex actually changed. |

### 13. LeaderDiskSync

| Field | Value |
|-------|-------|
| **Spec action** | `LeaderDiskSync` |
| **Code location** | `Server/RaftConsensus.cc:2025-2054` (leaderDiskThreadMain) |
| **Trigger point** | After `localServer->lastSyncedIndex = sync->lastIndex` (line 2047) |
| **Trace event name** | `LeaderDiskSync` |
| **Fields** | `lastSyncedIndex`: localServer->lastSyncedIndex, standard state |
| **Notes** | Only emits when `state == LEADER && currentTerm == term` (line 2046). The disk thread holds the mutex at this point. |

### 14. TakeSnapshot

| Field | Value |
|-------|-------|
| **Spec action** | `TakeSnapshot` |
| **Code location** | `Server/RaftConsensus.cc:1814-1862` (snapshotDone) |
| **Trigger point** | After `lastSnapshotIndex = lastIncludedIndex` (line 1839) |
| **Trace event name** | `TakeSnapshot` |
| **Fields** | `lastSnapshotIndex`: lastSnapshotIndex, `lastSnapshotTerm`: lastSnapshotTerm, standard state |
| **Notes** | Emit from snapshotDone, not beginSnapshot — the snapshot is only complete when snapshotDone runs. |

### 15. Crash

| Field | Value |
|-------|-------|
| **Spec action** | `Crash` |
| **Code location** | N/A (external event) |
| **Trigger point** | Emitted by test harness when a server is killed |
| **Trace event name** | `Crash` |
| **Fields** | `node`: server ID |
| **Notes** | No state snapshot — the server is dead. The test harness emits this, not the server itself. |

### 16. ProposeConfigChange

| Field | Value |
|-------|-------|
| **Spec action** | `ProposeConfigChange` |
| **Code location** | `Server/RaftConsensus.cc:1688-1700` (setConfiguration, Cold,new entry) |
| **Trigger point** | After transitional config entry is appended |
| **Trace event name** | `ProposeConfigChange` |
| **Fields** | `newServers`: [list of new server IDs], standard state |
| **Notes** | Emit when the TRANSITIONAL configuration entry is created, not when staging servers are added. |

### 17. StepDownCheck

| Field | Value |
|-------|-------|
| **Spec action** | `StepDownCheck` |
| **Code location** | `Server/RaftConsensus.cc:2123-2169` (stepDownThreadMain) |
| **Trigger point** | After epoch check result is determined (line 2140 for pass, 2161 for step-down) |
| **Trace event name** | `StepDownCheck` |
| **Fields** | `currentEpoch`: currentEpoch, `quorumAcked`: bool, standard state |
| **Notes** | Emit on every check cycle, whether stepping down or not. |

---

## Section 3: Special Considerations

### 3.1 Thread Interleaving

LogCabin uses multiple threads protected by a single mutex (`consensus.mutex`). All trace events should be emitted while holding the mutex, so they are naturally serialized. The relevant threads:

- **Main thread**: handles incoming RPCs (handleRequestVote, handleAppendEntries, handleInstallSnapshot)
- **Peer threads**: execute requestVote, appendEntries, installSnapshot (release lock during RPC)
- **Leader disk thread**: leaderDiskThreadMain (release lock during disk sync)
- **Timer thread**: timerThreadMain (calls startNewElection)
- **Step-down thread**: stepDownThreadMain (epoch checks)

### 3.2 Lock Release Windows

Several functions release the mutex during I/O:
- `peer.callRPC()` — releases lock during RPC call
- `leaderDiskThreadMain` — releases lock during `sync->wait()`

Events must be emitted AFTER re-acquiring the lock and verifying the term hasn't changed. The stale-check pattern (`currentTerm != request.term()`) must suppress event emission.

### 3.3 Atomic Persistence

LogCabin persists `currentTerm` and `votedFor` atomically via `updateLogMetadata()` (RaftConsensus.cc:2955-2962). This is a single metadata write, NOT a two-step persist like hashicorp/raft. The trace does not need separate persist events.

### 3.4 Leader Disk Thread Events

The leader disk thread's sync completion (LeaderDiskSync event) may trigger AdvanceCommitIndex internally (line 2048). The instrumentation should emit LeaderDiskSync FIRST, then AdvanceCommitIndex if commitIndex changes. This ordering matches the code's execution order.

### 3.5 InstallSnapshot Multi-Chunk

The implementation sends snapshots in chunks. Only the final chunk (`done == true`) triggers a spec-level state change. Emit HandleInstallSnapshot only on the final chunk. Intermediate chunks should be silent.

### 3.6 Server ID Mapping

LogCabin uses `uint64_t` server IDs. The trace should emit these as strings for TLA+ compatibility: `"s1"`, `"s2"`, `"s3"`, etc. The mapping from numeric ID to string ID should be configured in the test harness.

### 3.7 Configuration Change Events

The `setConfiguration` function is synchronous and holds the mutex across multiple phases (staging, catch-up, replicate). Only emit `ProposeConfigChange` when the TRANSITIONAL entry is appended (line 1700). The catch-up phase and final STABLE commit are handled by AppendEntries and AdvanceCommitIndex events respectively.

### 3.8 Bootstrap State

LogCabin servers start with `currentTerm=0`, `votedFor=0`, empty log, and `state=FOLLOWER`. The first configuration entry (if any) is appended during `init()`. If the test starts with a pre-existing cluster, the trace must include the initial configuration setup or TraceInit must be adjusted accordingly.
