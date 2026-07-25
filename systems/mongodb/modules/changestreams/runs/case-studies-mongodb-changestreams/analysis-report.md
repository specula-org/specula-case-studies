# Analysis Report: MongoDB Change Streams v2 Resume Token Ordering

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Total bug-fix commits analyzed | 35 |
| Total GitHub/JIRA issues collected | 48 |
| Total issues deeply read (full diffs/discussions) | 28 |
| Total confirmed bugs | 25 |
| Total excluded (false positive / feature / test) | 24 |
| Core files deeply read (full file) | 30+ |
| Total production source files | 95 |
| Total lines of code analyzed | ~40,000 |

---

## Phase 1: Structural Map

### Codebase Overview

MongoDB Change Streams spans 119 files (~40K LOC) across three main locations:
- `src/mongo/db/pipeline/` — Core pipeline stages and utilities (71 files)
- `src/mongo/db/` — Storage and configuration (25 files)
- `src/mongo/db/s/resharding/` — Resharding integration (9 files)

### Core Architecture

**Event Pipeline (per shard)**:
1. `OplogMatch` — filter oplog entries by namespace/operation
2. `UnwindTransaction` — expand multi-op transaction entries
3. `Transform` — convert oplog entries to change stream events with resume tokens
4. `CheckInvalidate` — detect/generate invalidation events
5. `CheckResumability` — verify resume token is valid, swallow pre-resume events
6. `InjectControlEvents` — inject v2 control events for shard targeting
7. `AddPreImage` / `AddPostImage` — image lookups
8. `HandleTopologyChange[V2]` — **split point**: everything above runs on shards

**Cross-Shard Merge (mongos)**:
9. `EnsureResumeTokenPresent` — verify resume token exists in merged stream
10. Classic operation type filter (when `showExpandedEvents=false`)

### Resume Token Structure

Fields in KeyString encoding order (determines total ordering):
```
clusterTime (Timestamp) > version (int) > tokenType (0=HWM, 128=Event) >
txnOpIndex (int) > fromInvalidate (bool) > uuid (UUID|null) >
eventIdentifier (Value) > fragmentNum (int, optional)
```

Events are sorted by `{"_id._data": 1}` — lexicographic on the hex-encoded KeyString.

### V1 vs V2 Token Differences

| Feature | V0 | V1 | V2 (default) |
|---------|----|----|------|
| tokenType field | No | Yes | Yes |
| fromInvalidate field | No | Yes | Yes |
| Missing UUID encoding | Omitted | Omitted | Explicit null |
| eventIdentifier | Optional | Optional | Required for events |
| fragmentNum | No | No | Yes (for split events) |

---

## Phase 2: Bug Archaeology

### Group 1: Resume Token Ordering / Comparison (8 commits, 10 tickets)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-81295 | V2 resume from V1 token ignores txnOpIndex; HWM v1 blocks splitting | HIGH | 6.0.12, 7.0.4 |
| SERVER-34314 | Resume within multi-op transaction fails without txnOpIndex | HIGH | 3.6.5 |
| SERVER-38975 | HWM tokens from shards without collection omit UUID | HIGH | 4.0.7 |
| SERVER-34090 | Resume fails when documentKey lacks shard key (post-sharding) | HIGH | 3.7.4 |
| SERVER-47810 | postBatchResumeToken earlier than user-specified startAt | HIGH | 4.4.0-rc8 |
| SERVER-44801 | AsyncResultsMerger returns sort-key format not ResumeToken format | HIGH | 4.3.3 |
| SERVER-66017 | operationDescription missing from v2 rename token (P1 blocker) | CRITICAL | 6.0.0-rc4 |
| SERVER-113140 | Resume token not reported when batchSize=0 | HIGH | 8.3.0-rc0 |
| SERVER-34399 | Invalid resume token crashes server | CRITICAL | 3.6.5 |
| SERVER-97071 | Resume token format unstable across server versions | MEDIUM | 8.2.0-rc0 |

### Group 2: Invalidation Event Sequencing (7 tickets)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-120644 | Sequential invalidations: second invalidation swallowed | HIGH | 8.3.0-rc0 |
| SERVER-58442 | _startAfterInvalidate never cleared after first invalidation | HIGH | 5.1.0-rc0 |
| SERVER-34789 | Invalidate token accepted with resumeAfter (should require startAfter) | MEDIUM | 4.0.1 |
| SERVER-41196 | mongos invariant failure crash with startAfter invalidate token | HIGH | 4.2.0-rc3 |
| SERVER-57792 | $match filtering invalidate → spurious "token not found" | HIGH | 5.1.0-rc0 |
| SERVER-54937 | Duplicate invalidation logic between CloseCursor and CheckInvalidate | MEDIUM | 5.1.0-rc0 |
| SERVER-110732 | checkInvalidate stage incorrectly in all-cluster pipelines | HIGH | 8.3.0-rc0 |

### Group 3: Cross-Shard Merge / Topology (8 tickets)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-110575 | V2 segment boundary: event consumed past end, not rolled back → event loss | HIGH | 8.3.0-rc0 |
| SERVER-119376 | Follow-up: improved V2 segment transition robustness | HIGH | 8.3.0-rc0 |
| SERVER-42723 | New shard with new database silently ignored by whole-cluster streams | HIGH | 4.3.1 |
| SERVER-42232 | Adding new shard invalidates ALL preceding resume tokens | HIGH | 4.0.11 |
| SERVER-65497 | Topology handler assumes input document immutability | HIGH | 5.1.0-rc0 |
| SERVER-44733 | ChangeStreamFatalError inconsistent on mongos vs mongod | HIGH | 3.6.17 |
| SERVER-106550 | Incorrect PBRT for non-empty batches | HIGH | 8.2.0-rc0 |
| SERVER-59424 | kNewShardDetected event leaked to non-merging streams | MEDIUM | 5.1.0-rc0 |

### Group 4: Resharding + Change Streams (4 tickets)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-113247 | Resharding coordinator didn't bump vector clock → wrong shard targeting | HIGH | 8.3.0-rc0 |
| SERVER-102106 | Resume token not updated on empty batches during resharding | HIGH | 8.2.0-rc0 |
| SERVER-111901 | V2 targeting fails when config.placementHistory not initialized | HIGH | 8.3.0-rc0 |
| SERVER-102201 | Prepared transactions visible before startAtOperationTime double-counted | MEDIUM | 8.2.0-rc0 |

### Group 5: Oplog Rewrite / Filter Correctness (7 tickets)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-59426 | Collation mixing during change stream rewrites | HIGH | 5.1.0-rc0 |
| SERVER-59840 | Pipeline optimization ran with temporary collator | HIGH | 5.1.0-rc0 |
| SERVER-62003 | fullDocument null-equality rewrite missed deletes and non-CRUD | MEDIUM | 5.1.0-rc0 |
| SERVER-62081 | Multiple rewrite helpers wrong for $eq:null, $exists:false, $ne:null | HIGH | 5.2.0-rc0 |
| SERVER-67715 | Unescaped regex metacharacters in namespace filter | MEDIUM | 5.3.0 |
| SERVER-90297 | Empty field $match caused assertion in rewrite | MEDIUM | 8.1.0-rc0 |
| SERVER-63958 | Incomplete documentKey predicate rewrite | MEDIUM | 5.1.0-rc0 |

### Group 6: Transaction / applyOps Handling (4 tickets)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-39674 | Oplog filter didn't match prepared transaction commits | HIGH | 4.1.8 |
| SERVER-39675 | Prepared txn commit ops not matched to prepare ops | HIGH | 4.1.8 |
| SERVER-50769 | Empty applyOps entry caused assertion failure | MEDIUM | 5.0.0-rc0 |
| SERVER-79274 | Race: FCV uninitialized between successive checks in unwind | HIGH | 6.0.10 |

### Group 7: Other (7 tickets)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-111406 | Top-level $v field misinterpreted as oplog version marker | MEDIUM | 8.3.0-rc0 |
| SERVER-112036 | Overly permissive $v:1 check in event generation | MEDIUM | 8.3.0-rc0 |
| SERVER-63860 | documentKey cache needed for 5.0→6.0 upgrade | HIGH | 6.0.0-rc0 |
| SERVER-92239 | Change stream killed during rollback instead of resumable error | HIGH | 7.0.21 |
| SERVER-78650 | $nor oplog rewrite crashes on empty array | HIGH | 6.0.10 |
| SERVER-89489 | Resume token incorrectly serialized for query stats | MEDIUM | 8.1.0-rc0 |
| SERVER-74716 | splitEvent token accepted without splitEvent stage | MEDIUM | 7.0.0-rc0 |

### Bug Hotspot Analysis

| File | Bug-fix commits | Critical/High |
|------|----------------|---------------|
| change_stream_event_transform.cpp | 9 | 5 |
| change_stream_rewrite_helpers.cpp | 7 | 4 |
| resume_token.cpp | 4 | 3 |
| resharding_change_streams_monitor.cpp | 4 | 2 |
| document_source_change_stream_check_invalidate.cpp | 3 | 3 |
| document_source_change_stream_unwind_transaction.cpp | 3 | 2 |
| document_source_change_stream_handle_topology_change*.cpp | 3 | 3 |

---

## Phase 3: Deep Analysis Findings

### Finding DA-1: Resume Token Version Transition `||` Logic

**File**: `change_stream_event_transform.cpp:259`
```cpp
auto version = (clusterTime > _resumeToken.clusterTime || txnOpIndex > _resumeToken.txnOpIndex)
    ? _expCtx->getChangeStreamTokenVersion()
    : _resumeToken.version;
```

The `||` (OR) means the version switches to the new default as soon as EITHER clusterTime advances OR txnOpIndex advances. The dangerous case: `clusterTime == _resumeToken.clusterTime && txnOpIndex > _resumeToken.txnOpIndex`. Here the version switches within the same clusterTime — there could be events at the same clusterTime with txnOpIndex values between the resume point and the current event that were generated with the old version. A mixed-version token sequence at the same clusterTime could break ordering.

**Classification**: Model-checkable (MC-1)

### Finding DA-2: Nondeterministic First-Match in handleSupportedEvent

**File**: `change_stream_event_transform.cpp:746-761`

`_supportedEvents` is a `StringDataSet` (hash-based). If an oplog entry's `o2` field contains multiple recognized field names, the iteration order determines which event type is returned. Nondeterministic across restarts (hash seed may differ).

**Classification**: Code-review-only (CR-1). Low practical risk (o2 should have exactly one event-type field).

### Finding DA-3: Control Events with Duplicate Resume Tokens

**File**: `document_source_change_stream_inject_control_events.h:71-78`

The `kInjectControlEvent` action clones an event and injects it as a control event with the **same resume token** as the original. If a client sees the control event and resumes from its token, it resumes from the same position as the original event.

**Classification**: Model-checkable (MC-6). The control event should be filtered before reaching the client, but this depends on pipeline stage ordering.

### Finding DA-4: Missing wallTime Type Validation in View Transform

**File**: `change_stream_event_transform.cpp:856-857`

The view transformation path copies `wallTime` without type validation. The default path validates it as `BSONType::date` at line 680. A corrupt view oplog entry with non-date wallTime would be silently propagated.

**Classification**: Test-verifiable (TV-1).

### Finding DA-5: View Transform Always Emits operationDescription

**File**: `change_stream_event_transform.cpp:860`

View events always emit `operationDescription` regardless of `showExpandedEvents`, while the default path gates this field on that flag. Inconsistent output shapes between view and non-view events.

**Classification**: Test-verifiable (TV-2).

### Finding DA-6: Duplicated Transaction Filter Base Functions

**File**: `change_stream_filter_helpers.cpp:89-96` (anonymous namespace) vs `:351-355` (namespace)

Two functions produce similar transaction base filters but diverge: `appendCommonTransactionFilter` includes `o.applyOps: {$type: "array"}` in the base; `appendBaseTransactionFilter` does not (added separately). If one is updated without the other, filters could silently diverge.

**Classification**: Test-verifiable (TV-3).

### Finding DA-7: reshardBlockingWrites Filter Inconsistency

**File**: `change_stream_filter_helpers.cpp:509` vs `change_stream_helpers.h:82`

`reshardBlockingWrites` is in `kClassicOperationTypes` (accepted by the end-of-pipeline filter) but gated behind `showSystemEvents` in the oplog filter. If the oplog filter is bypassed or misconfigured, these events would reach the client without `showSystemEvents`.

**Classification**: Code-review-only (CR-3).

### Finding DA-8: Pipeline Ordering Dependency Between CheckInvalidate and CheckResumability

**File**: `change_stream_pipeline_helpers.cpp:189-195`

Comment states: "The resume stage must come after the check invalidate stage." If reordered, an invalidation could be swallowed as pre-resume. Currently correct by construction, but fragile to pipeline optimization changes.

**Classification**: Model-checkable (implicit in Family 2 modeling).

### Finding DA-9: Shard Targeter Normal/Degraded Mode Enforced by Contract Only

**File**: `change_stream_shard_targeter.h:115-128`

In Degraded mode, `handleEvent()` cannot open/close cursors. This is enforced only by documentation, not by the interface. A buggy implementation could violate this.

**Classification**: Code-review-only (CR-4).

### Finding DA-10: Deferred Cursor Management Race Window

**File**: `change_stream_reader_context.h:63-96`

Opens are synchronous-enough ("before next event read") but closes are eventually-consistent ("ultimately closed"). A window exists where both old and new cursors are open, potentially receiving duplicate events.

**Classification**: Model-checkable (implicit in Family 3 segment lifecycle modeling).

### Finding DA-11: Non-Atomic Resume Token Update in Resharding Monitor

**File**: `resharding_change_streams_monitor.cpp:386-399`

The batch callback persists the resume token to disk, then updates in-memory state. Between persist and in-memory update, concurrent reads see stale in-memory state but current persisted state.

**Classification**: Test-verifiable (TV-4). Not a correctness issue (failover recovery uses persisted state).

### Finding DA-12: Orphaned Cursors After Resharding Monitor Failover

**File**: `resharding_change_streams_monitor.cpp:59`

`commonUUID = UUID::gen()` is regenerated per process. After failover, the new primary cannot identify cursors from the old primary for cleanup. Cursors persist until idle timeout.

**Classification**: Test-verifiable (TV-4).

### Finding DA-13: endOfTransaction Events Not Matched by Config Server Filter

**File**: `change_stream_filter_helpers.cpp:451-477`

The config server transaction filter does NOT include `endOfTransaction` matching (only data shard filter does). This is consistent because end-of-transaction markers are shard-local, but represents an implicit assumption.

**Classification**: Code-review-only. Correct by design.

### Finding DA-14: Config Server V2 Pipeline Missing Timeseries Filter

**File**: `change_stream_pipeline_helpers.cpp:108-136`

The config server pipeline does not include `buildNotViewlessTimeSeriesFilter`. Assumes config server oplog has no timeseries entries. Correct for current architecture but an implicit assumption.

**Classification**: Code-review-only.

---

## Developer Signals (TODO/FIXME/HACK)

| Location | Ticket | Content |
|----------|--------|---------|
| `change_stream_event_transform.cpp:82` | SERVER-112325 | Remove kNewShardDetectedOpType once guaranteed no more in oplog |
| `document_source_change_stream_check_topology_change.h:56` | SERVER-112325 | Remove CheckTopologyChange stage once migrateChunkToNewShard removed |
| `document_source_change_stream.cpp:135,163,189,217` | SERVER-105554 | Regex → exact match optimization blocked by collation concerns |
| `document_source_change_stream_oplog_match.cpp:127` | SERVER-81846 | Enable Boolean Expression Simplifier in change streams |
| `resume_token.cpp:94` | SERVER-96418 | Make ResumeTokenData an IDL type |
| `change_stream_event_transform.h:169` | SERVER-112709 | Split test into QO and QE parts |
| `document_source_change_stream_transform.h:122` | SERVER-105521 | shared_ptr → unique_ptr for transformer |
| `resharding_change_streams_monitor.cpp:311` | SERVER-107180 | Remove rawData FCV guard when 9.0 is last LTS |
| `resharding_change_streams_monitor.cpp:362` | SERVER-101189 | Make getMore wait longer for events |

---

## Bug Family Summary

| Family | Historical Bugs | New Findings | TLA+ Suitability | Priority |
|--------|----------------|--------------|-------------------|----------|
| 1: Resume Token Ordering | 10 (1 P1) | 1 (MC-1) | Excellent | HIGH |
| 2: Invalidation Sequencing | 7 | 0 | Excellent | HIGH |
| 3: Cross-Shard Merge | 8 | 2 (MC-6, DA-10) | Excellent | HIGH |
| 4: Resharding Coordination | 4 | 2 (DA-11, DA-12) | Good | MEDIUM |
| 5: Transaction Unwinding | 5 | 1 (MC-5) | Good | MEDIUM |
| 6: Oplog Filter Correctness | 7 | 2 (DA-6, DA-7) | Poor (unit test) | LOW |
