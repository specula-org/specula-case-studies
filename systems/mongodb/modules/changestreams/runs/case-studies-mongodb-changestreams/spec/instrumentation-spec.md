# Instrumentation Spec: MongoDB Change Streams

Action-to-code mapping for trace collection. Traces are collected from MongoDB structured logs and `mongosh`/`pymongo` test harness output.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<ISO timestamp>",
  "event": {
    "name": "<action name>",
    "shard": "<shard identifier>",
    "opType": "<operation type string>",
    "state": { <post-action state snapshot> },
    "token": { <resume token fields> }
  }
}
```

### State Fields

| Impl Field | TLA+ Variable | Captured At |
|---|---|---|
| `clusterTime` (oplog `ts` field) | `shardClock[s]` | Every shard event |
| `numEvents` (count of events on shard cursor) | `Len(shardEvents[s])` | Every shard event |
| `deliveredCount` (count of events delivered to client) | `Len(deliveredEvents)` | Every merge/delivery event |
| `streamState` (`"Active"`, `"Invalidated"`, `"Closed"`) | `streamState` | Invalidation events |
| `tokenVersion` (1 or 2) | `shardTokenVersion[s]` | Version transition events |
| `activeCursors` (list of shard IDs) | `activeCursors` | Topology change events |
| `topoMode` (`"Normal"`, `"Degraded"`) | `topoMode` | Topology change events |
| `txnOpIndex` (index within transaction) | Event's `txnOpIndex` field | Transaction events |

### Resume Token Fields

| Impl Field | TLA+ Token Position | Notes |
|---|---|---|
| `clusterTime` | `token[1]` | Oplog timestamp |
| `version` | `token[2]` | 1 or 2 |
| `tokenType` | `token[3]` | 0=HWM, 128=Event |
| `txnOpIndex` | `token[4]` | 0 for non-txn ops |
| `fromInvalidate` | `token[5]` | 0=false, 1=true |

## Section 2: Action-to-Code Mapping

### 2.1 GenerateEvent

- **Spec action**: `GenerateEvent(s, opType)`
- **Code location**: `change_stream_event_transform.cpp:321-744` (`applyTransformation`)
- **Trigger point**: After `makeResumeToken()` at line 660-661, when the event document is fully constructed
- **Trace event name**: `"GenerateEvent"`
- **Fields**: `shard`, `opType`, `state.clusterTime`, `state.numEvents`, `token.clusterTime`, `token.version`, `token.tokenType`, `token.txnOpIndex`
- **Notes**: This is the per-shard pipeline stage. Each shard runs the transform independently. The opType is extracted from the oplog entry at lines 363-644.

### 2.2 AdvanceShardClock

- **Spec action**: `AdvanceShardClock(s)`
- **Code location**: Not directly instrumented — inferred from clusterTime gaps between events
- **Trigger point**: N/A (implicit between events)
- **Trace event name**: `"AdvanceShardClock"`
- **Fields**: `shard`, `state.clusterTime`
- **Notes**: Shard clock advances are implicit in MongoDB. The trace harness should emit this event when the test script advances the cluster time (e.g., by inserting documents with forced timestamps or using `sleep` commands). Alternatively, use `SilentAdvanceShardClock` in the trace spec to handle implicit advances.

### 2.3 SwitchTokenVersion

- **Spec action**: `SwitchTokenVersion(s)`
- **Code location**: `change_stream_event_transform.cpp:259-261` (version transition in `makeResumeToken`)
- **Trigger point**: When the version determination changes from V1 to V2 (first event where the condition flips)
- **Trace event name**: `"SwitchTokenVersion"`
- **Fields**: `shard`, `state.tokenVersion`
- **Notes**: This is detected by comparing consecutive event tokens' version fields. The harness should emit this when a change stream opened with a V1 resume token first produces a V2 token. In practice, this requires starting with a V1 token (from an older MongoDB version or explicit construction).

### 2.4 GenerateInvalidatingEvent

- **Spec action**: `GenerateInvalidatingEvent(s, opType)`
- **Code location**: `change_stream_event_transform.cpp:453-579` (command op handling in `applyTransformation`)
- **Trigger point**: After transform produces a drop/rename event
- **Trace event name**: `"GenerateInvalidatingEvent"`
- **Fields**: `shard`, `opType` (`"drop"` or `"rename"`), `state.clusterTime`, `token.*`
- **Notes**: The invalidating event is a normal event from the shard's perspective. The `drop` case is at line 455, `rename` at line 461. The `collectionAlive` state transition happens externally (the collection no longer exists after the drop DDL completes).

### 2.5 MergeNextNormal

- **Spec action**: `MergeNextNormal`
- **Code location**: `document_source_change_stream_handle_topology_change_v2.cpp` (V2 stage, `kFetchingNormalGettingChangeEvent` state)
- **Trigger point**: After mongos delivers a non-invalidating event to the client in normal mode
- **Trace event name**: `"MergeNextNormal"`
- **Fields**: `state.deliveredCount`, `state.topoMode` (should be `"Normal"`), event's `token.*`, `opType`
- **Notes**: This is observed at the mongos level. In the test harness, this corresponds to each `change_stream.next()` call that returns a non-invalidating document. The shard ID of the source event should be included if available from the `_id._data` field.

### 2.6 MergeNextDegraded

- **Spec action**: `MergeNextDegraded`
- **Code location**: `document_source_change_stream_handle_topology_change_v2.cpp` (V2 stage, `kFetchingDegradedGettingChangeEvent` state)
- **Trigger point**: After mongos delivers an event within a degraded-mode segment
- **Trace event name**: `"MergeNextDegraded"`
- **Fields**: `state.deliveredCount`, `state.topoMode` (should be `"Degraded"`), `state.segmentEnd`, event's `token.*`
- **Notes**: Degraded mode is entered after a topology change. The harness must track whether the V2 reader is in degraded or normal mode. This may require inspecting MongoDB server logs for V2 segment lifecycle events.

### 2.7 MergeNextInvalidating

- **Spec action**: `MergeNextInvalidating`
- **Code location**: Composition of merge + `document_source_change_stream_check_invalidate.cpp`
- **Trigger point**: When mongos encounters and delivers an invalidating event (drop/rename) through merge
- **Trace event name**: `"MergeNextInvalidating"`
- **Fields**: `state.deliveredCount`, `opType` (`"drop"` or `"rename"`), `token.*`
- **Notes**: This is a composite action in the spec. In the trace, it appears as a single `change_stream.next()` that returns a drop/rename event. The CheckInvalidate stage fires internally — the trace sees the combined effect.

### 2.8 DeliverInvalidation

- **Spec action**: `DeliverInvalidation`
- **Code location**: `document_source_change_stream_check_invalidate.cpp` (generates synthetic invalidation)
- **Trigger point**: When `change_stream.next()` returns an `"invalidate"` event
- **Trace event name**: `"DeliverInvalidation"`
- **Fields**: `state.streamState` (should transition to `"Invalidated"`), `state.deliveredCount`, `token.*` (should have `fromInvalidate=1`)
- **Notes**: The synthetic invalidation event is generated by CheckInvalidate, not by the shard. The token includes `fromInvalidate=true` which makes it sort after the triggering event. After this, the next `change_stream.next()` call will throw `ChangeStreamInvalidated`.

### 2.9 UndoGetNextAtSegmentBoundary

- **Spec action**: `UndoGetNextAtSegmentBoundary`
- **Code location**: `document_source_change_stream_handle_topology_change_v2.cpp` (test lines 2253-2257)
- **Trigger point**: When V2 stage rolls back an event at segment boundary
- **Trace event name**: `"UndoGetNextAtSegmentBoundary"`
- **Fields**: `state.topoMode`, `state.segmentEnd`, undone event's `token.*`
- **Notes**: This is an internal mongos event not directly visible to the client. Requires MongoDB server log instrumentation or the V2 stage to emit a log entry when `undoGetNextAndSetHighWaterMark()` is called. SERVER-110575 is the fix that introduced this mechanism.

### 2.10 AddShard

- **Spec action**: `AddShard(newShard)`
- **Code location**: `change_stream_topology_helpers.cpp:87-97` (`createUpdatedCommandForNewShard`)
- **Trigger point**: After `openCursorsOnDataShards()` completes for the new shard
- **Trace event name**: `"AddShard"`
- **Fields**: `shard` (the new shard), `state.activeCursors`
- **Notes**: In the test harness, this corresponds to `sh.addShard()` command. The trace event should be emitted after the change stream pipeline detects the new shard and opens a cursor on it.

### 2.11 RemoveShard

- **Spec action**: `RemoveShard(s)`
- **Code location**: `change_stream_reader_context.h:80` (`closeCursorsOnDataShards`)
- **Trigger point**: After `closeCursorsOnDataShards()` for the removed shard
- **Trace event name**: `"RemoveShard"`
- **Fields**: `shard` (the removed shard), `state.activeCursors`, `state.topoMode`, `state.segmentEnd`
- **Notes**: In the test harness, this corresponds to `removeShard` admin command. The trace event captures the transition to degraded mode with the segment end timestamp.

### 2.12 StartNewSegment

- **Spec action**: `StartNewSegment`
- **Code location**: `document_source_change_stream_handle_topology_change_v2.cpp` (state transition `kFetchingStartingChangeStreamSegment → kFetchingNormalGettingChangeEvent`)
- **Trigger point**: After the V2 stage completes segment transition
- **Trace event name**: `"StartNewSegment"`
- **Fields**: `state.topoMode` (should be `"Normal"`), `state.segmentEnd` (should be Nil)
- **Notes**: Internal mongos event. Requires MongoDB server log instrumentation.

### 2.13 BeginTransaction

- **Spec action**: `BeginTransaction(s)`
- **Code location**: Test harness — `session.startTransaction()`
- **Trigger point**: After transaction started on a shard
- **Trace event name**: `"BeginTransaction"`
- **Fields**: `shard`, `state.clusterTime`
- **Notes**: Transaction boundaries are controlled by the test harness. The shard assignment depends on which shard owns the target document's chunk.

### 2.14 AddTxnOperation

- **Spec action**: `AddTxnOperation(s, opType)`
- **Code location**: Test harness — individual CRUD operations within a transaction
- **Trigger point**: After each operation within the transaction
- **Trace event name**: `"AddTxnOperation"`
- **Fields**: `shard`, `opType`, `state.txnOpCount` (number of ops so far)
- **Notes**: These operations are not visible to the change stream until the transaction commits. The txnOpIndex is assigned during unwind at `document_source_change_stream_unwind_transaction.cpp:83-129`.

### 2.15 CommitTransaction

- **Spec action**: `CommitTransaction(s)`
- **Code location**: Test harness — `session.commitTransaction()`
- **Trigger point**: After commit completes (all ops become visible in oplog as applyOps)
- **Trace event name**: `"CommitTransaction"`
- **Fields**: `shard`, `state.clusterTime` (commit timestamp), `state.numOps`
- **Notes**: The commit timestamp becomes the clusterTime for all events from this transaction. Each operation gets a unique txnOpIndex (0-based) assigned during unwind.

### 2.16 RecreateCollection

- **Spec action**: `RecreateCollection`
- **Code location**: Test harness — `db.createCollection()` after drop
- **Trigger point**: After collection recreation completes
- **Trace event name**: `"RecreateCollection"`
- **Fields**: `state.collectionAlive` (should be `true`)
- **Notes**: Used for testing the drop-recreate-drop sequence (MC-2, Family 2).

### 2.17 InitiateResume

- **Spec action**: `InitiateResume`
- **Code location**: Test harness — `db.watch([], {resumeAfter: <token>})`
- **Trigger point**: After new change stream opened with resume token
- **Trace event name**: `"InitiateResume"`
- **Fields**: `token.*` (the resume token being used)
- **Notes**: The test captures the resume token from a previously received event, then opens a new change stream with `resumeAfter`.

### 2.18 InitiateResumeAfterInvalidate

- **Spec action**: `InitiateResumeAfterInvalidate`
- **Code location**: Test harness — `db.watch([], {startAfter: <invalidateToken>})`
- **Trigger point**: After new change stream opened with startAfter and invalidation token
- **Trace event name**: `"InitiateResumeAfterInvalidate"`
- **Fields**: `token.*` (the invalidation token), `state.streamState` (should be `"Active"` after resume)
- **Notes**: Only valid with `startAfter`, not `resumeAfter`. The token must have `fromInvalidate=true`. This tests the 3-way classification state machine (Family 2).

## Section 3: Special Considerations

### 3.1 Trace Collection Architecture

MongoDB change streams are consumed through `mongosh` or `pymongo`. The trace harness is a **test script** (not C++ instrumentation) that:

1. Sets up a sharded cluster (Docker: `mongo:latest` = 8.2.6)
2. Opens a change stream via `db.collection.watch()`
3. Performs operations (inserts, drops, transactions, topology changes)
4. Iterates the change stream cursor, emitting NDJSON trace events
5. Each `change_stream.next()` produces a trace event with the event's resume token and operation type

### 3.2 Internal vs External Events

| Event Type | Visibility | Collection Method |
|---|---|---|
| GenerateEvent | Visible via `change_stream.next()` | Test harness |
| MergeNextNormal/Degraded | Visible via `change_stream.next()` | Test harness |
| DeliverInvalidation | Visible via `change_stream.next()` | Test harness |
| UndoGetNextAtSegmentBoundary | Internal (mongos V2 stage) | MongoDB server logs |
| StartNewSegment | Internal (mongos V2 stage) | MongoDB server logs |
| AddShard/RemoveShard | Triggered by admin commands | Test harness + server logs |

For internal events (UndoGetNext, StartNewSegment), use MongoDB's structured JSON logging (`--logComponentVerbosity '{command: 2}'`) to capture V2 stage lifecycle events. Alternatively, use `SilentAdvanceShardClock` and `SilentMergeNext` in the trace spec to handle gaps.

### 3.3 Shard Identification

Events from `change_stream.next()` do not directly expose which shard produced them. The shard can be inferred from:
- The `_id._data` resume token (contains UUID which maps to a specific shard)
- The `ns` field (database + collection, combined with chunk ownership from `sh.status()`)
- For test harnesses with direct shard access, query each shard's oplog directly

### 3.4 Token Version Detection

The resume token version is embedded in the hex-encoded KeyString (`_id._data`). To extract it:
1. Decode the hex string to bytes
2. Convert KeyString to BSON
3. The second field is the version number (1 or 2)

In `pymongo`, use `bson.decode()` on the raw token bytes. In `mongosh`, the version can be extracted via the internal `ResumeToken` class if available, or by comparing token behavior (V1 tokens lack the `operationType` in eventIdentifier).

### 3.5 Bootstrap State Differences

The trace spec's `TraceInit` uses the base spec's `Init`, which starts with:
- All shard clocks at 1
- Empty event sequences
- All shards have active cursors
- Stream in Active state

If the test starts with a pre-existing collection and pre-positioned change stream, the initial state may differ. Use `SilentAdvanceShardClock` to align shard clocks, and adjust `TraceInit` if needed.

### 3.6 Concurrency

MongoDB change streams are single-threaded per cursor on mongos. Cross-shard merging happens within the AsyncResultsMerger, which is single-threaded. Events from different shards interleave at the merge point but are serialized in token order. The trace captures this serialized output, so no concurrency interleaving needs to be handled in the trace spec.
