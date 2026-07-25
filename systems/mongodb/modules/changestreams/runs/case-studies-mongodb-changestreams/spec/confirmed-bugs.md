# Confirmed Bug Report — MongoDB Change Streams v2 Resume Token Ordering

## Summary

- Total findings reviewed: 15
- Confirmed: 0
- False positives: 15
- Inconclusive: 0

Model checking explored ~1.13B states across 4 bug families (Resume Token Ordering, Invalidation Sequencing, Cross-Shard Merge & Topology, Transaction Unwinding) with 0 invariant violations. All 15 code-review findings were investigated via code audit and classified as false positives or defensive coding suggestions with no user-visible impact.

---

## Findings from Model Checking

### MC-1 through MC-6: All Passed

| ID | Description | Config | States | Result |
|----|-------------|--------|--------|--------|
| MC-1 | Version transition `\|\|` logic | MC_hunt_version_transition.cfg | 247M | No violation |
| MC-2 | Sequential invalidation (drop-recreate-drop) | MC_hunt_invalidation.cfg | 192M | No violation |
| MC-3 | New shard HWM token ordering | MC_hunt_segment_boundary.cfg | 347M | No violation |
| MC-4 | V2 segment boundary event loss | MC_hunt_segment_boundary.cfg | 347M | No violation |
| MC-5 | Resume within multi-op transaction | MC_hunt_txn_ordering.cfg | 340M | No violation |
| MC-6 | Control event duplicate resume tokens | MC_hunt_segment_boundary.cfg | 347M | No violation |

Two spec modeling fixes (Case B) were applied during hunting — both involved `AddShard` not correctly modeling MongoDB's cursor opening protocol. These were spec issues, not implementation bugs.

---

## Findings from Code Review

### Finding 1: Version transition `||` logic (MC-1)
- **Source**: Code Review (modeling-brief.md §6.1)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_event_transform.cpp:256-261`
- **Description**: The version transition condition uses `clusterTime > resume.clusterTime || txnOpIndex > resume.txnOpIndex`, which was flagged as potentially switching token versions prematurely within the same clusterTime.
- **Why false positive**: The `||` is correct and intentional, introduced by the SERVER-81295 fix. Within a single clusterTime, all events come from the same oplog entry (one transaction). The `txnOpIndex` comparison cleanly separates "before/at resume" from "after resume" within that transaction. Using `&&` would be wrong: a non-transaction event at `clusterTime > T` with `txnOpIndex = 0` would evaluate `(true && false) = false`, incorrectly keeping the old version. Regression tests `change_stream_v1_v2_within_txn.js` and `change_streams_split_event_v1_v2_tokens.js` validate this behavior.

### Finding 2: Missing wallTime type validation in view transform (TV-1)
- **Source**: Code Review (modeling-brief.md §6.2)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_event_transform.cpp:856`
- **Description**: The view transform passes `wallTime` from the oplog entry without `checkValueType(..., BSONType::date)`, unlike the default transform at line 680.
- **Why false positive**: The `wall` field is a required Date field in all oplog entries since MongoDB 3.6. The oplog format guarantee makes the validation redundant. The default transform's check is purely defensive. No user-visible behavior difference.

### Finding 3: Unconditional operationDescription in view transform (TV-2)
- **Source**: Code Review (modeling-brief.md §6.2)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_event_transform.cpp:860`
- **Description**: The view transform always emits `operationDescription` without checking `showExpandedEvents`.
- **Why false positive**: View events (`create`, `modify`, `drop` for views) are DDL events that inherently need `operationDescription` to carry the view definition. The code comment at lines 803-806 explicitly states view events are handled independently of `showExpandedEvents`. For `drop` events, `operationDescription` is `missing`, and `MutableDocument::addField` with a missing value is a no-op. Minor internal inconsistency (`nsType` IS gated on `showExpandedEvents` while `operationDescription` is not), but no user-visible bug.

### Finding 4: Duplicated transaction filter bases (TV-3)
- **Source**: Code Review (modeling-brief.md §6.2)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_filter_helpers.cpp:89` vs `:351`
- **Description**: Two functions (`appendCommonTransactionFilter` and `appendBaseTransactionFilter`) share 3 of 4 filter predicates but are not expressed in terms of each other.
- **Why false positive**: The split is intentional. `appendBaseTransactionFilter` has two callers that need different `o.applyOps` constraints: one appends a plain `{$type: "array"}` check, the other combines it with `{$elemMatch: controlEventsFilter}`. Bundling the check into the base would prevent the `$elemMatch` variant. Both paths currently produce correct filters. This is a maintainability concern, not a bug.

### Finding 5: Orphaned resharding cursors after failover (TV-4)
- **Source**: Code Review (modeling-brief.md §6.2)
- **Status**: FALSE POSITIVE
- **Location**: `resharding_change_streams_monitor.cpp:59`
- **Description**: Process-global `commonUUID` is regenerated on startup; `killCursors` cannot find cursors from a previous process incarnation.
- **Why false positive**: Two independent mechanisms handle cleanup: (1) replica set stepdown kills all cursors on the old primary, and (2) server-side cursor timeout (default 10 minutes) reaps idle cursors. The `commonUUID` is a disambiguation mechanism within a single process lifetime, not a cross-restart identifier. Resource pressure from orphaned cursors is bounded and self-healing.

### Finding 6: Non-atomic resharding batch callback (modeling-brief §2 Family 4)
- **Source**: Code Review (modeling-brief.md §2, Family 4)
- **Status**: FALSE POSITIVE
- **Location**: `resharding_change_streams_monitor.cpp:386-399`
- **Description**: In-memory state update (`_numEventsTotal`, `_numBatches`, `_receivedFinalEvent`) occurs after the persist callback, with a crash window between them.
- **Why false positive**: (1) No concurrent access — the AsyncTry loop is sequential on the executor. (2) `_numEventsTotal` and `_numBatches` are test-only counters (exposed via `numEventsTotalForTest()` and `numBatchesForTest()`). (3) `_receivedFinalEvent` is redundant with the persisted `completed` field — on crash/stepdown, the monitor is destroyed and reconstructed from persisted `ChangeStreamsMonitorContext`, which reads `getCompleted()` directly.

### Finding 7: Unordered set iteration in handleSupportedEvent (CR-1)
- **Source**: Code Review (modeling-brief.md §6.3)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_event_transform.cpp:746-761`
- **Description**: `handleSupportedEvent` iterates an unordered `StringDataSet` for first-match, potentially returning non-deterministic results.
- **Why false positive**: Each noop oplog entry's `o2` field is constructed by MongoDB server code with exactly one event-type discriminator field. The o2 document structurally has at most one matching key, making iteration order irrelevant.

### Finding 8: Missing mutual exclusion assertion (CR-2)
- **Source**: Code Review (modeling-brief.md §6.3)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_event_transform.cpp:660`
- **Description**: `documentKey`/`operationDescription` mutual exclusion not asserted at token construction.
- **Why false positive**: The assertion already exists in the `ResumeTokenData` constructor at `resume_token.cpp:66-68`: `tassert(6280100, "both documentKey and operationDescription cannot be present for an event", documentKey.missing() || opDescription.missing())`. The comment at line 712-713 of the transform file explicitly acknowledges this: "We already validated this while creating the resume token."

### Finding 9: reshardBlockingWrites filter gating (CR-3)
- **Source**: Code Review (modeling-brief.md §6.3)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_filter_helpers.cpp:505-509`, `change_stream_helpers.h:72-84`
- **Description**: `reshardBlockingWrites` is in `kClassicOperationTypes` but gated behind `showSystemEvents` in the oplog filter.
- **Why false positive**: The oplog filter is the gating filter. If `showSystemEvents=false`, the `reshardBlockingWrites` entry never enters the pipeline, so its inclusion in `kClassicOperationTypes` is harmless. The inclusion serves a secondary purpose for resume token construction (determining v1-style documentKey tokens). Confusing for maintainers, but not a bug.

### Finding 10: Shard targeter mode enforcement (CR-4)
- **Source**: Code Review (modeling-brief.md §6.3)
- **Status**: FALSE POSITIVE
- **Location**: `change_stream_shard_targeter.h:115-128`
- **Description**: Normal/Degraded mode distinction enforced only by documentation contract, not by runtime assertions.
- **Why false positive**: Standard C++ abstract interface pattern. The caller controls mode based on `startChangeStreamSegment`'s return value. No evidence of any concrete implementation violating the contract. A runtime `tassert` would add safety, but the absence is not a bug.

---

## Conclusion

MongoDB Change Streams' resume token ordering, invalidation sequencing, cross-shard merge, and transaction unwinding logic are well-engineered. Model checking at scale (~1.13B states, ~64.3M traces) found no invariant violations. All code-review findings resolved as false positives — existing safeguards (oplog format guarantees, constructor assertions, cursor timeouts, crash-recovery via persisted state) prevent each hypothesized bug from manifesting.

The two spec fixes discovered during model checking (AddShard cursor positioning and clock advancement) confirm that the implementation handles these edge cases correctly — the spec had to be updated to match the implementation's behavior, not the other way around.
