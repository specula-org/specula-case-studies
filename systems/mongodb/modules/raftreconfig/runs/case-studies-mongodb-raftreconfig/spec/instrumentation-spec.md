# Instrumentation Spec: MongoRaftReconfig

Action-to-code mapping for trace collection. Traces are collected by parsing MongoDB's LOGV2 structured logs into NDJSON events.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<ISO8601 timestamp>",
  "event": {
    "name": "<action name>",
    "node": "<server id>",
    "state": {
      "currentTerm": <int>,
      "state": "<PRIMARY|SECONDARY|REMOVED>",
      "configVersion": <int>,
      "configTerm": <int>,
      "drainMode": <bool>,
      "logLength": <int>
    },
    // Optional fields per event type:
    "sender": "<server id>",
    "receiver": "<server id>",
    "member": "<server id>",
    "config": ["<server id>", ...],
    "newlyAdded": <bool>
  }
}
```

### State Fields

| Trace field | Implementation getter | TLA+ variable |
|---|---|---|
| `currentTerm` | `_topCoord->getTerm()` | `currentTerm[i]` |
| `state` | `_memberState.toString()` | `state[i]` |
| `configVersion` | `_rsConfig.getConfigVersion()` | `configVersion[i]` |
| `configTerm` | `_rsConfig.getConfigTerm()` | `configTerm[i]` |
| `drainMode` | `_applierState == ApplierState::Draining` | `drainMode[i]` |
| `logLength` | `_lastAppliedOpTime.getTimestamp()` (proxy) | `Len(log[i])` |

### Server ID Mapping

Map MongoDB `host:port` to TLA+ server IDs (`s1`, `s2`, `s3`) by order of first encounter in the replica set config. Consistent mapping across all events is critical.

## Section 2: Action-to-Code Mapping

### WinElection

| Field | Value |
|---|---|
| **Spec action** | `WinElection(i)` |
| **Code location** | `replication_coordinator_impl.cpp:~2020` (`_topCoord->processWinElection`) |
| **Trigger point** | After election win, before drain mode entry |
| **Event name** | `WinElection` |
| **LOGV2 ID** | `21359` ("election succeeded") |
| **Fields** | `node`, `state` (post-state: currentTerm, state=PRIMARY, drainMode=TRUE) |
| **Notes** | State snapshot AFTER term increment. `drainMode` is TRUE. |

### CompleteDrain

| Field | Value |
|---|---|
| **Spec action** | `CompleteDrain(i)` |
| **Code location** | `replication_coordinator_impl.cpp:1495` (after `doOptimizedReconfig`) |
| **Trigger point** | After `signalDrainComplete` + config term bump |
| **Event name** | `CompleteDrain` |
| **LOGV2 ID** | `21331` ("transition to primary complete") |
| **Fields** | `node`, `state` (post-state: configVersion, configTerm bumped, drainMode=FALSE) |
| **Notes** | `configTerm` should equal `currentTerm` after this event (unless force config). |

### Reconfig

| Field | Value |
|---|---|
| **Spec action** | `Reconfig(i)` |
| **Code location** | `replication_coordinator_impl.cpp:3997` (after `_setCurrentRSConfig`) |
| **Trigger point** | After config installation (post `_finishReplSetReconfig`) |
| **Event name** | `Reconfig` |
| **LOGV2 ID** | `21392` ("replSetReconfig config object") |
| **Fields** | `node`, `state`, `config` (new member list) |
| **Notes** | Capture new config's member hostnames for config set validation. |

### ForceReconfig

| Field | Value |
|---|---|
| **Spec action** | `ForceReconfig(i)` |
| **Code location** | `replication_coordinator_impl.cpp:3997` (after `_setCurrentRSConfig`, force path) |
| **Trigger point** | After force config installation |
| **Event name** | `ForceReconfig` |
| **LOGV2 ID** | `21392` (same log line — distinguish by `configTerm == -1`) |
| **Fields** | `node`, `state` (configTerm will be -1), `config` |
| **Notes** | Distinguish from `Reconfig` by checking `configTerm == -1` in parsed event. |

### SendConfig

| Field | Value |
|---|---|
| **Spec action** | `SendConfig(sender, receiver)` |
| **Code location** | `replication_coordinator_impl_heartbeat.cpp:1052` (after `_setCurrentRSConfig` in heartbeat path) |
| **Trigger point** | After heartbeat reconfig finishes |
| **Event name** | `SendConfig` |
| **LOGV2 ID** | `21392` (config installed via heartbeat — source node in log context) |
| **Fields** | `sender`, `receiver`, `state` (receiver's post-state) |
| **Notes** | Sender is the node whose config was propagated (from heartbeat response). Receiver is the local node installing the config. Parse from heartbeat response context. |

### ClientRequest

| Field | Value |
|---|---|
| **Spec action** | `ClientRequest(i)` |
| **Code location** | Oplog insert path |
| **Trigger point** | After oplog entry written |
| **Event name** | `ClientRequest` |
| **LOGV2 ID** | Custom or test-harness injected |
| **Fields** | `node`, `state` (currentTerm) |
| **Notes** | In test scenarios, use `db.coll.insert()` commands. Track via oplog entry count change. |

### CommitEntry

| Field | Value |
|---|---|
| **Spec action** | `CommitEntry(i)` |
| **Code location** | `topology_coordinator.cpp` (commit point advance) |
| **Trigger point** | After `lastCommittedOpTime` advance |
| **Event name** | `CommitEntry` |
| **LOGV2 ID** | `21331` or custom tracking of commit point advance |
| **Fields** | `node`, `state`, commit index |
| **Notes** | May need to track commit point advances via `setMyLastAppliedOpTimeAndWallTime` log entries. |

### GetEntry

| Field | Value |
|---|---|
| **Spec action** | `GetEntry(receiver, sender)` |
| **Code location** | Oplog fetcher / replication path |
| **Trigger point** | After applying replicated oplog entry |
| **Event name** | `GetEntry` |
| **LOGV2 ID** | `21075` ("applied op") or batch application logs |
| **Fields** | `node` (receiver), `sender` (sync source), `state` |
| **Notes** | Track via batch application. `sender` is the sync source. |

### RollbackEntries

| Field | Value |
|---|---|
| **Spec action** | `RollbackEntries(i, j)` |
| **Code location** | `rollback_impl.cpp` |
| **Trigger point** | After rollback completes |
| **Event name** | `RollbackEntries` |
| **LOGV2 ID** | `21595` ("rollback finished") |
| **Fields** | `node`, `source` (sync source), `state` |
| **Notes** | Rollback truncates log entries. Track new log length post-rollback. |

### UpdateTerms

| Field | Value |
|---|---|
| **Spec action** | `UpdateTermsOnNodes(i, j)` |
| **Code location** | `topology_coordinator.cpp` (term update paths) |
| **Trigger point** | After term update from heartbeat/vote response |
| **Event name** | `UpdateTerms` |
| **LOGV2 ID** | `21340` ("term updated") |
| **Fields** | `node`, `peer` (remote node), `state` |
| **Notes** | This event is implicit in many interactions. Only emit when term actually changes. |

### ShutDown

| Field | Value |
|---|---|
| **Spec action** | `ShutDown(i)` |
| **Code location** | Test harness (stop container / kill process) |
| **Trigger point** | After node shutdown |
| **Event name** | `ShutDown` |
| **LOGV2 ID** | N/A (external event from test harness) |
| **Fields** | `node` |
| **Notes** | Injected by test harness, not from MongoDB logs. |

### RemoveNewlyAdded

| Field | Value |
|---|---|
| **Spec action** | `RemoveNewlyAdded(i, j)` |
| **Code location** | `replication_coordinator_impl.cpp:4188` (after `doReplSetReconfig` in `_reconfigToRemoveNewlyAddedField`) |
| **Trigger point** | After newlyAdded removal reconfig completes |
| **Event name** | `RemoveNewlyAdded` |
| **LOGV2 ID** | `21392` (config change — detect by checking member's newlyAdded field removed) |
| **Fields** | `node` (primary), `member` (the node whose newlyAdded was removed), `state` |
| **Notes** | Distinguish from regular reconfig by checking diff: member lost newlyAdded field. |

## Section 3: Special Considerations

### Log-Based Instrumentation (No Recompilation)

MongoDB's LOGV2 structured JSON logs contain sufficient state transition information. The instrumentation approach is:

1. **Enable verbose replication logging**: `--setParameter logComponentVerbosity='{replication: {verbosity: 3}}'`
2. **Parse LOGV2 JSON lines**: Each log line has an `id` field matching LOGV2 IDs above.
3. **Extract state from `attr` field**: The `attr` object contains the state data.
4. **Emit NDJSON**: One event per relevant log line.

### Distinguishing Force vs. Normal Reconfig

Both use LOGV2 ID `21392`. Distinguish by:
- `configTerm == -1` → `ForceReconfig`
- `configTerm > 0` → `Reconfig` (safe) or `SendConfig` (heartbeat propagation)
- Context: if event is from `_heartbeatReconfigFinish` → `SendConfig`
- Else if primary initiated → `Reconfig` or `ForceReconfig`

### Server ID Mapping

MongoDB logs use `host:port` identifiers. The log parser must:
1. Extract the replica set config from the first config-related log event.
2. Assign `s1`, `s2`, `s3` etc. by order of member index in the config.
3. Use consistent mapping across all events.

### Bootstrap State

- Initial config comes from `replSetInitiate` (one-time).
- All nodes start as `SECONDARY` (Follower in spec).
- Initial term is typically 0 or 1 depending on election.
- Trace.tla's `TraceInit` should match the cluster's initial state.

### Concurrent Events

- Heartbeats are asynchronous — events from different nodes may interleave freely.
- Elections and reconfigs are serialized on each node by `_mutex` and `_rsConfigState`.
- Silent actions handle the gap between logged events (e.g., config propagation that happens between other logged events).

### Drain Mode Detection

MongoDB does not log drain mode entry/exit directly. Detect via:
- **Entry**: LOGV2 `21359` ("election succeeded") — node enters drain mode.
- **Exit**: LOGV2 `21331` ("transition to primary complete") — drain mode ends.
- Between these two events, `drainMode = TRUE`.

### Docker Compose Template

Use the replica set template from `case-studies/mongodb-shared-harness.md`:
- 3-node RS (or 5-node for reconfig tests)
- `--setParameter enableTestCommands=1`
- `--setParameter logComponentVerbosity='{replication: {verbosity: 3}}'`

### Test Scenarios

Key scenarios to trace:

1. **Basic reconfig**: Add/remove a node via `rs.reconfig()`.
2. **Force reconfig**: `rs.reconfig({...}, {force: true})` on a secondary during partition.
3. **Election + drain**: Trigger stepdown, observe election + drain mode + config term bump.
4. **Force reconfig during drain**: Partition + force reconfig while a node is in drain mode.
5. **newlyAdded addition**: Add a new node, observe it starts as newlyAdded, then auto-promoted.
6. **Heartbeat config propagation**: Reconfig on primary, observe secondaries receive via heartbeat.
