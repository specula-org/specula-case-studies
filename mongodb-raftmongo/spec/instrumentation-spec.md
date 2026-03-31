# Instrumentation Spec: MongoDB RaftMongo

## Approach

MongoDB uses LOGV2 structured logging. We parse existing logs into NDJSON traces — **no C++ instrumentation needed**. See `case-studies/mongodb-shared-harness.md` for the shared pipeline.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "2024-01-15T10:30:00.000Z",
  "event": {
    "name": "<EventName>",
    "state": {
      "server": "s1",
      "currentTerm": 2,
      "state": "Leader",
      "commitPoint": {"term": 2, "index": 3},
      "lastWritten": {"term": 2, "index": 5},
      "lastApplied": {"term": 2, "index": 4},
      "lastDurable": {"term": 2, "index": 3}
    },
    "msg": {}
  }
}
```

### State Fields (captured at every event)

| TLA+ Variable | MongoDB Getter | Log Attribute |
|---------------|---------------|---------------|
| `currentTerm[i]` | `_topCoord->getTerm()` | Extracted from log context or `"term"` attr |
| `state[i]` | `_getMemberState()` | `"newState"` or mapped from role |
| `commitPoint[i]` | `getLastCommittedOpTime()` | `"_lastCommittedOpTimeAndWallTime"` |
| `lastWritten[i]` | `getMyLastWrittenOpTime()` | `"lastWrittenOpTime"` |
| `lastApplied[i]` | `getMyLastAppliedOpTime()` | `"lastAppliedOpTime"` |
| `lastDurable[i]` | `getMyLastDurableOpTime()` | `"lastDurableOpTime"` |

### Server Identity Mapping

MongoDB nodes are identified by hostname:port in logs. The log parser maps these to spec server IDs (`s1`, `s2`, `s3`) in order of first encounter. The `server` field in each trace event uses the mapped ID.

## Section 2: Action-to-Code Mapping

### StartElection

| Field | Value |
|-------|-------|
| **Spec action** | `StartElection(i)` |
| **Code location** | `replication_coordinator_impl_elect_v1.cpp:294-350` |
| **Trigger point** | After `_updateTerm(lk, newTerm)` and `voteForMyselfV1()` |
| **Log IDs** | `21444` ("Dry election run succeeded, running for election"), `4615652`/`4615660`/`4615661`/`4615662` (election start reasons) |
| **Trace event** | `"StartElection"` |
| **Fields** | `server`, `currentTerm` (new term), `state` ("Candidate") |
| **Notes** | The dry run completes before the real election starts. Use `21444` for the real election start. |

### VoteGranted (RequestVote)

| Field | Value |
|-------|-------|
| **Spec action** | `RequestVote(candidate, voter)` |
| **Code location** | `topology_coordinator.cpp:3788-3794` |
| **Trigger point** | After `_lastVote.setTerm(args.getTerm())` and `response->setVoteGranted(true)` |
| **Log ID** | `5972100` ("Voting yes in election") |
| **Trace event** | `"VoteGranted"` |
| **Fields** | `server` (voter), `candidate` (candidate server), `currentTerm`, `state` |
| **Notes** | Only granted votes are traced. Denials don't produce `5972100`. The `candidate` field must be mapped from the candidate's member index to spec server ID. |

### ElectionWon (WinElection)

| Field | Value |
|-------|-------|
| **Spec action** | `WinElection(i)` |
| **Code location** | `replication_coordinator_impl_elect_v1.cpp:462` |
| **Trigger point** | After `processWinElection` |
| **Log ID** | `21450` ("Election succeeded, assuming primary role") |
| **Trace event** | `"ElectionWon"` |
| **Fields** | `server`, `currentTerm`, `state` ("Leader") |
| **Notes** | At this point the node is in LeaderElect mode (not yet writable). `firstOpTimeOfMyTerm` = InfOpTime. |

### TransitionToPrimary (WritePrimaryNoOp)

| Field | Value |
|-------|-------|
| **Spec action** | `WritePrimaryNoOp(i)` |
| **Code location** | `replication_coordinator_impl.cpp:1521-1528` |
| **Trigger point** | After `_topCoord->completeTransitionToPrimary(firstOpTime)` |
| **Log ID** | `21331` ("Transition to primary complete; database writes are now permitted") |
| **Trace event** | `"TransitionToPrimary"` |
| **Fields** | `server`, `currentTerm`, `state` ("Leader"), `commitPoint`, `lastWritten`, `lastApplied` |
| **Notes** | This is the moment `firstOpTimeOfMyTerm` is set to the no-op's optime. Full state capture here is critical for verifying the commit point protocol. |

### ClientWrite

| Field | Value |
|-------|-------|
| **Spec action** | `ClientWrite(i)` |
| **Code location** | `replication_coordinator_impl.cpp:1603-1621` |
| **Trigger point** | After `setMyLastAppliedAndLastWrittenOpTimeAndWallTimeForward` |
| **Log ID** | No specific LOGV2 for individual writes. Use oplog cursor tailing or test-specific markers. |
| **Trace event** | `"ClientWrite"` |
| **Fields** | `server`, `currentTerm`, `lastWritten`, `lastApplied`, `commitPoint` |
| **Notes** | In test scenarios, use `db.collection.insert()` and capture the resulting optime from the oplog. The test harness should emit this event after each write operation. |

### AppendOplog

| Field | Value |
|-------|-------|
| **Spec action** | `AppendOplog(i, j)` |
| **Code location** | Oplog applier pipeline |
| **Trigger point** | After batch apply completes and `setMyLastWrittenOpTimeAndWallTimeForward` |
| **Log ID** | Use verbosity 3 replication logs or test-specific hooks |
| **Trace event** | `"AppendOplog"` |
| **Fields** | `server`, `lastWritten` (new top of oplog), `lastApplied`, `commitPoint` |
| **Notes** | Oplog entries arrive in batches. Each batch apply produces one trace event with the final state. The `j` (source server) is not captured — the Trace spec uses existential quantification over possible sources. |

### PersistOplog

| Field | Value |
|-------|-------|
| **Spec action** | `PersistOplog(i)` |
| **Code location** | `replication_coordinator_impl.cpp:1693-1708` |
| **Trigger point** | After `setMyLastDurableOpTimeAndWallTime` |
| **Log ID** | No specific LOGV2. This is a silent action in trace validation. |
| **Trace event** | `"PersistOplog"` (optional — usually silent) |
| **Fields** | `server`, `lastDurable` |
| **Notes** | Journal flushes are frequent and not individually logged. The Trace spec handles this via `SilentPersistOplog`. If explicit tracing is needed, add a verbosity-3 log point. |

### ApplyOplog

| Field | Value |
|-------|-------|
| **Spec action** | `ApplyOplog(i)` |
| **Code location** | Oplog applier batch completion |
| **Trigger point** | After batch apply updates `lastApplied` |
| **Log ID** | Use oplog applier batch completion logs |
| **Trace event** | `"ApplyOplog"` (optional — usually silent) |
| **Fields** | `server`, `lastApplied` |
| **Notes** | On followers, apply is already captured by `AppendOplog` (batch apply updates both lastWritten and lastApplied). Explicit `ApplyOplog` events are only needed if lastApplied and lastWritten update separately. |

### RollbackOplog

| Field | Value |
|-------|-------|
| **Spec action** | `RollbackOplog(i, j)` |
| **Code location** | `rollback_impl.cpp:1182-1248` |
| **Trigger point** | After finding common point and truncating oplog |
| **Log ID** | `21607` ("Rollback common point"), `21592` ("Rollback complete") |
| **Trace event** | `"RollbackOplog"` |
| **Fields** | `server`, `currentTerm`, `state` |
| **Notes** | Use `21607` for the rollback common point (shows what entries are truncated) and `21592` for completion. The `j` (sync source) is implicit. |

### UpdateTerm

| Field | Value |
|-------|-------|
| **Spec action** | `UpdateTermThroughHeartbeat(i, j)` |
| **Code location** | `replication_coordinator_impl.cpp:5564` |
| **Trigger point** | After `_termShadow.store(term)` |
| **Log ID** | `21827` ("Updating term") in topology_coordinator.cpp:3308 |
| **Trace event** | `"UpdateTerm"` |
| **Fields** | `server`, `currentTerm` (new term), `state` |
| **Notes** | Term updates from any source (heartbeat, vote request, etc.) all go through `_updateTerm`. The source (`j`) is not captured — Trace spec uses existential quantification. |

### Stepdown

| Field | Value |
|-------|-------|
| **Spec action** | `Stepdown(i)` |
| **Code location** | `replication_coordinator_impl.cpp:5573-5588` |
| **Trigger point** | After `_stepDownStart()` or `prepareForUnconditionalStepDown()` |
| **Log ID** | `21402` ("Stepping down from primary, because a new term has begun"), `21475` ("Stepping down from primary in response to heartbeat") |
| **Trace event** | `"Stepdown"` |
| **Fields** | `server`, `currentTerm`, `state` ("Follower") |
| **Notes** | Multiple code paths lead to stepdown. All produce LOGV2 events. |

### AdvanceCommitPoint

| Field | Value |
|-------|-------|
| **Spec action** | `AdvanceCommitPoint` |
| **Code location** | `topology_coordinator.cpp:3131-3172` |
| **Trigger point** | After `advanceLastCommittedOpTimeAndWallTime` returns true |
| **Log ID** | `21826` ("Updating _lastCommittedOpTimeAndWallTime") — verbosity 2, or `6795400` ("Advancing committed opTime to a new term") |
| **Trace event** | `"AdvanceCommitPoint"` |
| **Fields** | `server`, `commitPoint` (new commit point) |
| **Notes** | `21826` fires on every commit point update. `6795400` only fires on term changes. Use `21826` for comprehensive tracing (requires verbosity >= 2). |

### LearnCommitPointHeartbeat

| Field | Value |
|-------|-------|
| **Spec action** | `LearnCommitPointWithTermCheck(i, j)` |
| **Code location** | `replication_coordinator_impl_heartbeat.cpp:322-332` |
| **Trigger point** | After `_advanceCommitPoint(lk, replMetadata.getValue().getLastOpCommitted(), false)` |
| **Log ID** | `21826` (if commit point advances) — shared with AdvanceCommitPoint |
| **Trace event** | `"LearnCommitPointHeartbeat"` |
| **Fields** | `server`, `commitPoint` (new value) |
| **Notes** | The heartbeat commit point path uses `fromSyncSource = false`. Differentiate from sync source path by the call site. In log parsing, heartbeat-sourced commit point updates come from `_handleHeartbeatResponse`. |

### LearnCommitPointSyncSource

| Field | Value |
|-------|-------|
| **Spec action** | `LearnCommitPointFromSyncSourceNeverBeyondLastWritten(i, j)` |
| **Code location** | `data_replicator_external_state_impl.cpp:96-108` |
| **Trigger point** | After sync source metadata processing |
| **Log ID** | `21826` (if commit point advances) — shared |
| **Trace event** | `"LearnCommitPointSyncSource"` |
| **Fields** | `server`, `commitPoint` (new value, after clamping) |
| **Notes** | The sync source path uses `fromSyncSource = true`. Differentiation from heartbeat path requires checking the call stack or log context. |

### Crash

| Field | Value |
|-------|-------|
| **Spec action** | `Crash(i)` |
| **Code location** | N/A (external — kill signal or failpoint) |
| **Trigger point** | After node restart and recovery |
| **Log ID** | `501401` ("Incrementing the rollback ID after unclean shutdown") |
| **Trace event** | `"Crash"` |
| **Fields** | `server`, `currentTerm`, `state` ("Follower") |
| **Notes** | Crashes are triggered externally (kill -9, Docker stop). The trace event is emitted by the test harness after observing a restart. Recovery state is captured from the first post-restart log entries. |

## Section 3: Special Considerations

### Log Verbosity Requirements

To capture all trace events, MongoDB must run with increased replication log verbosity:
```
--setParameter logComponentVerbosity='{replication: {verbosity: 3}}'
```

Verbosity 3 is needed for:
- `21826` (commit point updates, verbosity 2)
- `21823`/`21824` (commit point rejection, verbosity 1)
- `5972100` (vote grant, verbosity 1)

### Differentiating Heartbeat vs Sync Source Commit Point

Both `LearnCommitPointHeartbeat` and `LearnCommitPointSyncSource` produce `21826` when the commit point advances. To differentiate:
1. Parse the surrounding log context — heartbeat events are preceded by heartbeat response logs (`_handleHeartbeatResponse`)
2. Sync source events are preceded by oplog fetcher/applier logs
3. If differentiation is impossible, merge into a single `"LearnCommitPoint"` event and let the Trace spec try both actions

### Bootstrap State

The trace's initial state may differ from the spec's `Init`:
- MongoDB starts with `currentTerm = 0` (matching spec)
- But after a restart, the term may be > 0
- The test harness should capture the initial state from the first log entry and use it to override `TraceInit`

### Client Write Tracing

MongoDB doesn't produce a LOGV2 event for each client write. The test harness must:
1. Perform the write via `mongosh` (`db.coll.insert(...)`)
2. Read the resulting oplog entry (`rs.printReplicationInfo()`)
3. Emit a synthetic `"ClientWrite"` trace event with the optime

### Concurrent Threads

MongoDB's replication uses a single-threaded executor for callbacks, but:
- Journal flushes happen on a separate thread (why `PersistOplog` is silent)
- Oplog application is pipelined (writer + applier threads)
- Heartbeats are scheduled asynchronously

The Trace spec handles this via silent actions. Events may interleave between threads, but the executor's mutex ensures state consistency at each LOGV2 emission point.

### Server ID Mapping

MongoDB logs use hostname:port. The parser maps these to spec IDs:
```python
server_map = {}  # Populated in order of first encounter
def map_server(host_port):
    if host_port not in server_map:
        server_map[host_port] = f"s{len(server_map) + 1}"
    return server_map[host_port]
```

## Log ID Summary

| Log ID | Event Name | Source File | Verbosity |
|--------|-----------|-------------|-----------|
| 4615652 | StartElection (timeout) | heartbeat.cpp:1370 | 0 |
| 4615660 | StartElection (priority) | heartbeat.cpp:1377 | 0 |
| 21444 | StartElection (real) | elect_v1.cpp:288 | 0 |
| 5972100 | VoteGranted | topology_coordinator.cpp:3792 | 1 |
| 21450 | ElectionWon | elect_v1.cpp:462 | 0 |
| 21331 | TransitionToPrimary | repl_coord_impl.cpp:1542 | 0 |
| 21402 | Stepdown (new term) | repl_coord_impl.cpp:5578 | 0 |
| 21475 | Stepdown (heartbeat) | heartbeat.cpp:498 | 0 |
| 21827 | UpdateTerm | topology_coordinator.cpp:3308 | 0 |
| 21826 | CommitPointAdvanced | topology_coordinator.cpp:3240 | 2 |
| 6795400 | CommitPointNewTerm | topology_coordinator.cpp:3233 | 0 |
| 21607 | RollbackCommonPoint | rollback_impl.cpp:1220 | 0 |
| 21592 | RollbackComplete | rollback_impl.cpp:334 | 0 |
| 501401 | CrashRecovery | repl_coord_impl.cpp:614 | 0 |
