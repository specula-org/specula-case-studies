# Instrumentation Spec: MongoDB RangeDeletionsSecondaryNodes

## Approach

**Log parsing** (NOT C++ instrumentation). MongoDB's LOGV2 structured logs contain state transition events. Parse LOGV2 JSON log lines into NDJSON trace files.

See `case-studies/mongodb-shared-harness.md` for Docker compose templates, log parsing patterns, and harness structure.

---

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<ActionName>",
  "rd": <int>,            // Range deletion index (1-based), present for RD events
  "query": <int>,         // Query index (1-based), present for query events
  "trackerValid": [bool], // Optional: tracker validity array after this action
  "queryState": "<str>",  // Optional: query state after this action
  "lastAppliedSnapshotSize": <int>  // Optional: doc count in snapshot
}
```

### Init Config (First Line)

```json
{
  "event": "init",
  "nodeRole": "SECONDARY",
  "trackerShardV": [<int>, ...],
  "rdPreMigShardV": [<int>, ...],
  "queryTracker": [<int>, ...]
}
```

The init line captures the frozen variables that define the test scenario configuration.

### State Fields

| Trace field | TLA+ variable | Source |
|---|---|---|
| `nodeRole` | `nodeRole` | Replica set member state |
| `trackerShardV[i]` | `trackerShardV[i]` | `MetadataManager::_metadata[i]->metadata->getShardPlacementVersion()` |
| `trackerValid[i]` | `trackerValid[i]` | `MetadataManager::_metadata[i]->valid` |
| `queryState` | `queryState[q]` | Query execution state (RESTORE_START, SNAPSHOT_ADVANCED, etc.) |
| `lastAppliedSnapshotSize` | `Cardinality(lastAppliedSnapshot)` | Number of docs visible at current timestamp |

---

## Section 2: Action-to-Code Mapping

### SignalUpdate

| Field | Value |
|---|---|
| **Spec action** | `OpApplierSignalUpdate(rd)` |
| **Code location** | `range_deleter_service_op_observer.cpp:164-168` |
| **Trigger point** | After `processingFieldUpdatedToTrue` check fires, before returning |
| **LOGV2 candidates** | Custom: add LOGV2 at line 168 in `onUpdate()`, or detect via existing log ID near invalidation |
| **Fields** | `rd`: range deletion index; `trackerValid`: post-invalidation tracker validity array |
| **Notes** | The actual invalidation happens inside `invalidateRangePreservers()` (line 167). Capture state AFTER the call returns. The `trackerValid` post-state is critical for validating the early-break logic (Family 1). |

### SignalCommit

| Field | Value |
|---|---|
| **Spec action** | `OpApplierSignalCommit(rd)` |
| **Code location** | Oplog applier batch commit infrastructure |
| **Trigger point** | After individual op within batch reaches committed state |
| **LOGV2 candidates** | Oplog applier per-op commit logging (if available) |
| **Fields** | `rd`: range deletion index |
| **Notes** | May not have a distinct LOGV2 event. If not logged, this action can be handled as a silent action in the trace spec (SilentOpApplierSignalCommit). |

### DeleteUpdate

| Field | Value |
|---|---|
| **Spec action** | `OpApplierDeleteUpdate(rd)` |
| **Code location** | Oplog applier processing range delete op |
| **Trigger point** | After oplog applier thread starts processing the delete op |
| **LOGV2 candidates** | Oplog applier per-op logging |
| **Fields** | `rd`: range deletion index |
| **Notes** | Similar to SignalCommit — may not have distinct LOGV2. Use silent action if needed. |

### DeleteCommit

| Field | Value |
|---|---|
| **Spec action** | `OpApplierDeleteCommit(rd)` |
| **Code location** | Oplog applier batch commit infrastructure |
| **Trigger point** | After individual delete op within batch reaches committed state |
| **LOGV2 candidates** | Same as SignalCommit |
| **Fields** | `rd`: range deletion index |
| **Notes** | May be handled as silent action (SilentOpApplierDeleteCommit). |

### BatchCommitted

| Field | Value |
|---|---|
| **Spec action** | `BatchCommitted(rd)` |
| **Code location** | Oplog batch apply completion |
| **Trigger point** | After all ops in the batch are committed and applied timestamp advances |
| **LOGV2 candidates** | Log ID for oplog batch completion (grep for "applied" or "batch" in oplog applier) |
| **Fields** | `rd`: range deletion index; `lastAppliedSnapshotSize`: doc count after deletion |
| **Notes** | This is the key visibility event. After this point, the deleted docs are invisible to new snapshot reads. |

### QueryAdvanceSnapshot

| Field | Value |
|---|---|
| **Spec action** | `QueryAdvanceSnapshot(q)` |
| **Code location** | `shard_role.cpp:1973-1979` |
| **Trigger point** | At the yield/restore point where the query advances its storage snapshot |
| **LOGV2 candidates** | Custom: add LOGV2 before the `checkOrphanRangePreserverIsStillValid` call |
| **Fields** | `query`: query index |
| **Notes** | The snapshot advance happens at `acquireLocalCollectionOrView()` (line 1979). Capture BEFORE the kill check. |

### QueryKilled

| Field | Value |
|---|---|
| **Spec action** | `QueryKilled(q)` |
| **Code location** | `shard_role.cpp:1965` |
| **Trigger point** | After `uasserted(ErrorCodes::QueryPlanKilled, ...)` is thrown |
| **LOGV2 candidates** | Log ID `10016300` — "Read has been terminated due to orphan range cleanup" |
| **Fields** | `query`: query index; `queryState`: "KILLED" |
| **Notes** | This log is gated behind `enableQueryKilledByRangeDeletionLog` (line 1953). Ensure this parameter is enabled in the test scenario. Counter: `killedDueToRangeDeletionCounter` (line 1964). |

### QueryProceed

| Field | Value |
|---|---|
| **Spec action** | `QueryProceed(q)` |
| **Code location** | `shard_role.cpp:1973` (after passing kill check) |
| **Trigger point** | After `checkOrphanRangePreserverIsStillValid` returns without throwing |
| **LOGV2 candidates** | Custom: add LOGV2 after the kill check or at query completion |
| **Fields** | `query`: query index; `queryState`: "DONE_OK" |
| **Notes** | No existing LOGV2 for the "proceed" case. Must be captured either via custom logging at the restore point or at query completion. |

### StepUp

| Field | Value |
|---|---|
| **Spec action** | `StepUp` |
| **Code location** | `range_deleter_service.cpp:127-133` |
| **Trigger point** | After `onStepUpBegin` is called |
| **LOGV2 candidates** | Standard replica set step-up logging; also Log ID `11079600` — "Range deleter service is now up" (for step-up completion) |
| **Fields** | (none — implicit from event type) |
| **Notes** | Can be detected from replica set state change logs (member state PRIMARY transition). |

### RecoverTask

| Field | Value |
|---|---|
| **Spec action** | `RecoverTask(rd)` |
| **Code location** | `range_deleter_service.cpp:220-231` |
| **Trigger point** | After each `registerTask()` call within the recovery loop (line 226-229) |
| **LOGV2 candidates** | Log ID `6834800` — "Resubmitting range deletion tasks"; Log ID `7536600` — "Registering range deletion task" |
| **Fields** | `rd`: range deletion index |
| **Notes** | `6834800` fires once at recovery start. `7536600` fires per task (line 370-375). Use `7536600` with filter for recovery context (during step-up). Log ID `6834802` signals recovery completion. |

---

## Section 3: Special Considerations

### 1. Init Configuration Capture

The init line must be synthesized by the test harness, NOT captured from logs. It contains:
- `trackerShardV`: Extract from `MetadataManager::_metadata` at test start (use `db.adminCommand({getShardVersion: "<ns>"})` or mongosh)
- `rdPreMigShardV`: Extract from `config.rangeDeletions` collection on the shard (`db.getSiblingDB("config").rangeDeletions.find()`)
- `queryTracker`: Which metadata tracker index the query uses (infer from timing: latest tracker at query start)

### 2. LOGV2 Gaps

Several spec actions lack direct LOGV2 events:
- **SignalCommit, DeleteUpdate, DeleteCommit**: Individual op state transitions within a batch may not be logged. The trace spec handles these via silent actions (`SilentOpApplierSignalCommit`, `SilentOpApplierDeleteUpdate`, `SilentOpApplierDeleteCommit`).
- **QueryProceed**: No existing log for the "query passed kill check" case. Options:
  - Add custom LOGV2 at `shard_role.cpp:1973`
  - Infer from query completion logs
  - Use query profiler output (`db.setProfilingLevel(2)`)

### 3. Metadata Tracker Indexing

The `_metadata` list is internal to `MetadataManager`. There's no direct LOGV2 exposure. Options for capturing tracker state:
- **Preferred**: Use `MetadataManager::dumpState()` at key points (requires adding LOGV2)
- **Alternative**: Infer from sharding metadata refresh logs and version transitions
- **Test harness**: Inject known metadata versions via `moveChunk` operations with controlled timing

### 4. Feature Flag Configuration

The `gTerminateSecondaryReadsUponRangeDeletion` feature flag and `terminateSecondaryReadsOnOrphanCleanup` runtime parameter must be explicitly configured in the test scenario. The default is enabled since v8.2.

```javascript
// Enable (default for >= 8.2)
db.adminCommand({setParameter: 1, terminateSecondaryReadsOnOrphanCleanup: true})

// Disable (for Family 3 testing)
db.adminCommand({setParameter: 1, terminateSecondaryReadsOnOrphanCleanup: false})
```

### 5. Recovery Scenario Setup

To test Family 2 (recovery without re-invalidation):
1. Start sharded cluster with replica set shard
2. Trigger a moveChunk to create a range deletion task
3. Ensure the secondary has NOT applied the processing=true oplog entry (use `replSetFreeze` or `configureFailPoint`)
4. Start a long-running query on the secondary
5. Trigger `replSetStepUp` on the secondary
6. Observe recovery behavior (Log ID `6834800`, `7536600`)
7. Check if the query is killed or proceeds

### 6. Docker Compose Template

Use the sharding cluster template from `case-studies/mongodb-shared-harness.md`:
- 1 config server RS
- 2 shard RSs (each with 3 members)
- 1 mongos
- Verbose logging: `--setParameter logComponentVerbosity='{sharding: {rangeDeleter: 3}}'`

### 7. Log ID Reference

| Log ID | Message | Spec Action |
|---|---|---|
| `6834800` | "Resubmitting range deletion tasks" | RecoverTask (start) |
| `6834802` | "Finished resubmitting range deletion tasks" | RecoverTask (end) |
| `7536600` | "Registering range deletion task" | RecoverTask (per-task) |
| `10016300` | "Read has been terminated due to orphan range cleanup" | QueryKilled |
| `11079600` | "Range deleter service is now up" | StepUp (completion) |
| `11366700` | "Collection UUID mismatch detected..." | CSR invalidation skip |
