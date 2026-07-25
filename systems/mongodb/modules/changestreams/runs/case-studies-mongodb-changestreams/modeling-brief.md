# Modeling Brief: MongoDB Change Streams v2 Resume Token Ordering

## 1. System Overview

- **System**: MongoDB Change Streams — distributed event streaming over sharded MongoDB clusters
- **Language**: C++, ~40K LOC across 119 files (95 production + 24 test)
- **Protocol**: Per-shard oplog tailing with cross-shard merge at mongos, ordered by KeyString-encoded resume tokens
- **Key architectural choices**:
  - Resume token ordering is reduced to **lexicographic string comparison** on hex-encoded KeyStrings (`resume_token.cpp:134-190`)
  - Token field encoding order: `clusterTime > version > tokenType > txnOpIndex > fromInvalidate > UUID > eventIdentifier > fragmentNum`
  - V2 tokens (default since 6.0) encode missing UUID as **explicit null** for deterministic ordering (`resume_token.cpp:170-172`)
  - Invalidation events carry `fromInvalidate=true`, sorting AFTER triggering events at the same clusterTime
  - Pipeline split: stages before `HandleTopologyChange` run on shards; stages after run on mongos (`change_stream_pipeline_helpers.cpp:223-236`)
  - V2 topology change handler uses **segment-based fetching** with degraded/normal modes (`change_stream_shard_targeter.h:48-128`)
- **Concurrency model**: Single-threaded pipeline per cursor; cross-shard merge via AsyncResultsMerger on mongos; resharding monitor uses AsyncTry loop on executor

## 2. Bug Families

### Family 1: Resume Token Ordering & Version Transition (HIGH)

**Mechanism**: Resume tokens must provide a total order across shards and survive version transitions, but the multi-field KeyString encoding creates edge cases where tokens compare incorrectly or become incompatible.

**Evidence**:
- Historical: SERVER-81295 — V2 resume from V1 token ignores `txnOpIndex` within same-clusterTime transaction; HWM v1 token blocks large-event splitting (requires v2)
- Historical: SERVER-34314 — Resume within multi-op transaction failed because `txnOpIndex` was not in token comparison
- Historical: SERVER-38975 — HWM tokens from shards lacking the collection omitted UUID, breaking cross-shard merge ordering
- Historical: SERVER-34090 — Post-sharding resume failed because documentKey lacked shard key fields
- Historical: SERVER-47810 — postBatchResumeToken earlier than user-specified resume point on mongos
- Historical: SERVER-44801 — AsyncResultsMerger returned sort-key-format instead of ResumeToken-format
- Historical: SERVER-66017 (P1 blocker) — Rename events omitted `operationDescription` from v2 token when `showExpandedEvents=false`, causing non-deterministic tokens
- Historical: SERVER-113140 — Resume token not reported when `batchSize=0`
- Code analysis: `change_stream_event_transform.cpp:259` — Version transition uses `||` (OR) for `clusterTime > resume.clusterTime || txnOpIndex > resume.txnOpIndex`; could switch versions prematurely within same clusterTime

**Affected code paths**:
- `resume_token.cpp:134-190` — KeyString encoding order
- `change_stream_event_transform.cpp:245-265` — `makeResumeToken()` and version transition
- `change_stream_event_transform.cpp:58-83` — eventIdentifier construction (v1 vs v2 divergence)

**Suggested modeling approach**:
- Variables: `resumeToken[Shard -> TokenData]`, `clusterTime[Shard -> Nat]`, `tokenVersion[Shard -> {1,2}]`
- Actions: `GenerateEvent` (per shard, increments clusterTime or txnOpIndex), `MergeEvents` (mongos picks min-token across shards), `ResumeFromToken` (each shard replays from token)
- Model the v1→v2 version transition as a per-shard state change that can happen mid-stream
- Include `txnOpIndex` as a secondary ordering field within same clusterTime

**Priority**: High
**Rationale**: 10 historical bugs (1 P1 blocker), active code churn (v1→v2 transition), directly targets the core ordering invariant.

---

### Family 2: Invalidation Event Sequencing State Machine (HIGH)

**Mechanism**: Invalidation events (drop, rename, resharding) must be delivered AFTER all prior events on all shards, and the `startAfterInvalidate` state machine must correctly suppress duplicate invalidations while allowing genuine new ones.

**Evidence**:
- Historical: SERVER-120644 (Mar 2026) — Multiple sequential invalidating events: resuming from first invalidate swallowed genuine second invalidation. Fix introduced 3-way classification: rethrow/generate/swallow
- Historical: SERVER-58442 — `_startAfterInvalidate` flag never cleared after first invalidation observed; subsequent invalidations silently suppressed
- Historical: SERVER-34789 — Invalidate token accepted with `resumeAfter` (should require `startAfter`)
- Historical: SERVER-41196 — mongos invariant failure crash with `startAfter` invalidate token
- Historical: SERVER-57792 — `$match` filtering out invalidate events caused spurious "resume token not found"
- Historical: SERVER-54937 — Duplicated invalidation logic between CloseCursor and CheckInvalidate
- Code analysis: `change_stream_pipeline_helpers.cpp:189-195` — CheckInvalidate must come BEFORE CheckResumability; ordering dependency is fragile

**Affected code paths**:
- `document_source_change_stream_check_invalidate.cpp` — `_startAfterInvalidate` state
- `document_source_change_stream_ensure_resume_token_present.cpp` — Resume token verification
- `change_stream_invalidation_info.h/cpp` — Error propagation with resume token
- `change_stream_start_after_invalidate_info.h/cpp` — Resume-after-invalidate handling

**Suggested modeling approach**:
- Variables: `streamState \in {Active, Invalidated}`, `startAfterInvalidate \in BOOLEAN`, `invalidateToken`
- Actions: `DropCollection`, `RenameCollection` (generate invalidation at current clusterTime), `DeliverInvalidation` (send to client after all prior events), `ResumeAfterInvalidate` (client resumes with `startAfter`)
- Model the 3-way classification: {rethrow, generate, swallow} for sequential invalidations
- Include cross-shard ordering: invalidation must wait for all shards to advance past the invalidation timestamp

**Priority**: High
**Rationale**: 7 historical bugs, most recent (SERVER-120644) in March 2026. The state machine has been patched 4+ times, each fix revealing a new edge case. Classic TLA+ state machine verification target.

---

### Family 3: Cross-Shard Event Merging & Topology Change (HIGH)

**Mechanism**: Mongos merges sorted event streams from multiple shards. Topology changes (shard add/remove, resharding) require opening/closing cursors mid-stream without losing or duplicating events. The V2 segment-based approach introduced new boundary-handling bugs.

**Evidence**:
- Historical: SERVER-110575 — V2 segment boundary: event consumed past segment end but not rolled back, causing event loss. Fix added `undoGetNextAndSetHighWaterMark()`
- Historical: SERVER-119376 — Follow-up improving V2 segment transition robustness
- Historical: SERVER-42723 — New shard with new database silently ignored by whole-cluster change streams
- Historical: SERVER-42232 — Adding new shard invalidated ALL preceding resume tokens
- Historical: SERVER-65497 — Topology handler assumed input document immutability; prior stages could mutate it
- Historical: SERVER-44733 — `ChangeStreamFatalError` not used consistently on mongos vs mongod, causing driver infinite retry loops
- Historical: SERVER-106550 — Incorrect postBatchResumeToken for non-empty batches (PBRT represents oplog position, not batch position)
- Code analysis: `change_stream_shard_targeter.h:115-128` — Normal vs Degraded mode enforced only by contract, not assertions
- Code analysis: `change_stream_reader_context.h:63-96` — Deferred cursor management creates window for duplicate events

**Affected code paths**:
- `document_source_change_stream_handle_topology_change_v2.cpp` — V2 segment-based merge
- `document_source_change_stream_inject_control_events.cpp` — Control event injection for shard targeting
- `change_stream_shard_targeter.h` — Abstract shard targeting interface
- `change_stream_reader_context.h` — Cursor management interface
- `change_stream_topology_helpers.cpp` — New-shard cursor creation

**Suggested modeling approach**:
- Variables: `shardCursors \in SUBSET Shard`, `segmentEnd[Shard -> Timestamp \cup {None}]`, `mode \in {Normal, Degraded}`
- Actions: `AddShard` (open cursor on new shard with startAfter HWM), `RemoveShard` (close cursor), `SegmentTransition` (switch from degraded to normal), `MergeNext` (pick min-token event from active cursors), `UndoGetNext` (rollback consumed event at segment boundary)
- Model the V2 segment lifecycle: Normal → Degraded (on topology change) → Normal (after segment end)
- Include HWM token propagation: shards without events must still advance their HWM

**Priority**: High
**Rationale**: 8 historical bugs, V2 is actively being stabilized (3 fixes in 2025-2026). The segment-based approach is a novel design not covered by existing formal models. Event loss at segment boundaries (SERVER-110575) is a critical safety violation.

---

### Family 4: Resharding + Change Stream Coordination (MEDIUM)

**Mechanism**: Resharding moves data between shards while change streams are active. Resume tokens must remain valid across the resharding boundary, and placement history must be consistent for shard targeting.

**Evidence**:
- Historical: SERVER-113247 — Resharding coordinator did not bump vector clock after commit notification; metadata persisted with wrong timestamp, causing cursors on wrong shard
- Historical: SERVER-102106 — Resume token not updated on empty batches during resharding monitoring
- Historical: SERVER-111901 — V2 targeting failed when `config.placementHistory` not lazily initialized
- Historical: SERVER-102201 — Prepared transactions visible before `startAtOperationTime` double-counted
- Code analysis: `resharding_change_streams_monitor.cpp:386-399` — Non-atomic in-memory state update in batch callback; race window between persist and in-memory update
- Code analysis: `resharding_change_streams_monitor.cpp:59` — Process-global UUID regenerated on startup; orphaned cursors from old primary not cleaned up

**Affected code paths**:
- `resharding_change_streams_monitor.cpp` — Batch processing and resume token persistence
- `change_stream_shard_targeter.h` — Placement history lookups
- `change_stream_topology_helpers.cpp` — Resume token replacement for new shards

**Suggested modeling approach**:
- Variables: `placementHistory[Collection -> Seq(ShardPlacement)]`, `reshardingPhase \in {None, Cloning, Catchup, Committed}`
- Actions: `StartResharding`, `CommitResharding` (update placement, bump vector clock), `ResumeAfterResharding` (target correct shard based on placement history)
- Model the ordering constraint: commit notification timestamp < placement history timestamp

**Priority**: Medium
**Rationale**: 4 historical bugs, all in 2025-2026. Resharding is less frequent than normal operations, reducing real-world impact. The vector clock ordering constraint (SERVER-113247) is a clean TLA+ target.

---

### Family 5: Transaction Unwinding & Event Atomicity (MEDIUM)

**Mechanism**: Multi-statement transactions produce a single oplog entry (applyOps) that must be unwound into individual events, each with a unique `txnOpIndex`. Prepared transactions add a two-phase commit that further complicates event visibility.

**Evidence**:
- Historical: SERVER-34314 — Resume within transaction failed without `txnOpIndex` in token
- Historical: SERVER-39674, SERVER-39675 — Prepared transaction commit/prepare ops invisible to change streams (two separate fixes needed)
- Historical: SERVER-50769 — Empty applyOps entry caused assertion failure
- Historical: SERVER-79274 — Race: FCV uninitialized between successive checks in unwind stage
- Code analysis: `document_source_change_stream_unwind_transaction.cpp:86-129` — Unwind filter applies operation filter + namespace filter; v2 control events bypass namespace filter via OR
- Code analysis: `change_stream_event_transform.cpp:259` — `txnOpIndex` comparison in version transition uses `||` not `&&`

**Affected code paths**:
- `document_source_change_stream_unwind_transaction.cpp` — Transaction unwinding filter
- `change_stream_event_transform.cpp:245-265` — `makeResumeToken()` with txnOpIndex
- `document_source_change_stream_oplog_match.cpp` — Transaction oplog filter

**Suggested modeling approach**:
- Variables: `pendingTxn[Shard -> Seq(Op)]`, `txnState \in {None, Prepared, Committed}`
- Actions: `BeginTransaction`, `PrepareTransaction`, `CommitTransaction` (make ops visible), `UnwindTransaction` (emit individual events with incrementing txnOpIndex)
- Model the two-phase commit: prepared txn operations are invisible until commit, but the commit timestamp determines ordering

**Priority**: Medium
**Rationale**: 5 historical bugs. The prepared transaction interaction is complex but well-understood after 3 fixes. TLA+ can verify that txnOpIndex provides correct ordering within a transaction.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Resume token as abstract ordering key | Family 1: core invariant, 10 bugs | Model token as tuple `(clusterTime, tokenType, txnOpIndex, fromInvalidate, uuid, eventId)` with lexicographic comparison |
| Per-shard event generation | Family 1, 3: independent clocks | Each shard generates events with local clusterTime; mongos merges by min-token |
| Cross-shard merge at mongos | Family 3: 8 bugs in merge logic | `MergeNext` action picks min-token from active shard cursors |
| Invalidation state machine | Family 2: 7 bugs, 4+ patches | Model {Active, Invalidated} states with 3-way classification for sequential invalidations |
| Topology changes (shard add/remove) | Family 3: V2 segment boundaries | `AddShard`/`RemoveShard` actions with segment lifecycle (Normal/Degraded) |
| HWM token propagation | Family 1, 3: HWM ordering critical | Shards without events emit HWM tokens; HWM sorts before event tokens at same clusterTime |
| Resume-from-token | Family 1, 2: resume correctness | `ResumeFromToken` action: each shard replays from the given token position |
| Transaction unwinding | Family 5: txnOpIndex ordering | Model multi-op transactions as atomic commit with per-op `txnOpIndex` |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Pre-image/post-image lookup | Storage concern, not ordering. No ordering bugs in this area. |
| Oplog rewrite/filter optimization | Family 5 (filters): 7 bugs but all are predicate-logic errors, not protocol ordering. Better tested by unit tests. |
| Large event splitting | Fragment tokens are a simple extension of the base token with `fragmentNum`. Deterministic, no reported bugs. |
| View definition events | Synthetic events from system.views DML. No ordering interaction with normal events. |
| Collation handling | Implementation detail of filter pushdown. No impact on token ordering. |
| Resharding monitor batch processing | Family 4 is medium priority; monitor is an internal component with simpler invariants. |
| Pipeline optimization | Stage reordering optimization is a compiler concern, not protocol logic. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Per-shard clocks | `clusterTime[Shard -> Nat]` | Model independent shard timestamps | Family 1, 3 |
| Resume token tuple | `token = <<clusterTime, tokenType, txnOpIndex, fromInvalidate, uuid>>` | Abstract ordering key | Family 1 |
| HWM tokens | `hwmToken[Shard -> Token]` | Track high-water-mark per shard | Family 1, 3 |
| Invalidation state | `streamState`, `startAfterInvalidate`, `invalidateClusterTime` | 3-way invalidation classification | Family 2 |
| Shard cursor set | `activeCursors \in SUBSET Shard` | Track which shards have open cursors | Family 3 |
| Segment lifecycle | `segmentEnd[Shard -> Timestamp \cup None]`, `mode \in {Normal, Degraded}` | V2 topology change segments | Family 3 |
| Transaction state | `pendingTxn[Shard -> Seq(Op)]`, `txnCommitted[Shard -> BOOLEAN]` | Multi-op transaction atomicity | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| TotalOrder | Safety | For any two events e1, e2 delivered to client: e1.token < e2.token iff e1 delivered before e2 | Family 1, 3 |
| ResumeConsistency | Safety | Resuming from token T produces the same subsequent events regardless of which mongos handles the resume | Family 1, 2 |
| InvalidationCompleteness | Safety | An invalidation event for collection C is delivered only after ALL prior events on C from ALL shards | Family 2, 3 |
| NoGapOnResume | Safety | Resuming from token T never skips an event that was visible before the resume | Family 1, 3 |
| NoEventLossAtSegmentBoundary | Safety | When V2 topology handler transitions between segments, no event is consumed and lost | Family 3 |
| HWMMonotonicity | Safety | A shard's HWM token is monotonically non-decreasing | Family 1 |
| InvalidationIdempotency | Safety | Resuming after an invalidation with `startAfter` delivers exactly one subsequent invalidation (if any), not duplicates | Family 2 |
| TxnOrderPreservation | Safety | Events from the same transaction are delivered in txnOpIndex order | Family 5 |
| CrossShardMergeProgress | Liveness | If all shards have events past token T, mongos eventually delivers an event past T | Family 3 |
| InvalidationDelivery | Liveness | If a collection is dropped, the invalidation event is eventually delivered to all active streams on that collection | Family 2 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Version transition `\|\|` logic at `change_stream_event_transform.cpp:259` may switch token version prematurely within same clusterTime | TotalOrder (tokens at same clusterTime with mixed versions may compare incorrectly) | 1 |
| MC-2 | Sequential invalidation: drop-recreate-drop sequence where second invalidation has same clusterTime as first | InvalidationIdempotency (second invalidation swallowed or duplicated) | 2 |
| MC-3 | New shard added during active stream: HWM token from new shard with no events vs existing events on other shards | NoGapOnResume (resume from pre-add token may skip events on new shard) | 3 |
| MC-4 | V2 segment boundary: event at exact segment end timestamp consumed but segment transitions | NoEventLossAtSegmentBoundary (event consumed by degraded-mode fetch but not delivered) | 3 |
| MC-5 | Resume within multi-op transaction: resume token has txnOpIndex=2, but shard replays from clusterTime which includes all ops in txn | TxnOrderPreservation (ops 0-1 re-delivered after resume) | 5 |
| MC-6 | Control events with duplicate resume tokens (`kInjectControlEvent` action) may confuse resume logic | NoGapOnResume (resume after control event re-delivers original event) | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | View transform missing `wallTime` type validation (`change_stream_event_transform.cpp:856`) | Feed malformed oplog entry with non-date wallTime through view transformer |
| TV-2 | View transform always emits `operationDescription` without `showExpandedEvents` guard (`change_stream_event_transform.cpp:860`) | Open DB-level stream without expanded events, trigger view create + collection create, compare output shapes |
| TV-3 | Duplicated transaction filter bases (`change_stream_filter_helpers.cpp:89` vs `:351`) | Diff the two filter outputs and assert equivalence; add regression test |
| TV-4 | Orphaned resharding cursors after failover (`resharding_change_streams_monitor.cpp:59`) | Simulate failover during active resharding monitor, verify cursors cleaned up |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `handleSupportedEvent` iterates unordered set for first-match (`change_stream_event_transform.cpp:746-761`) | Add assertion that o2 field has exactly one recognized event name |
| CR-2 | `documentKey`/`operationDescription` mutual exclusion not asserted at token construction (`change_stream_event_transform.cpp:660`) | Add tassert; currently enforced only in ResumeTokenData constructor |
| CR-3 | `reshardBlockingWrites` in `kClassicOperationTypes` but gated behind `showSystemEvents` in oplog filter | Verify intent; add comment or move to correct set |
| CR-4 | Shard targeter Normal/Degraded mode enforced by contract only (`change_stream_shard_targeter.h:115-128`) | Add mode state variable with assertions |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-changestreams/analysis-report.md`
- **Key source files**:
  - `src/mongo/db/pipeline/resume_token.h/cpp` (580 lines) — Token encoding/decoding/comparison
  - `src/mongo/db/pipeline/change_stream_event_transform.cpp` (889 lines) — Event transformation + token generation
  - `src/mongo/db/pipeline/document_source_change_stream_check_invalidate.cpp` (104 lines) — Invalidation state machine
  - `src/mongo/db/pipeline/document_source_change_stream_handle_topology_change_v2.cpp` (103 lines) — V2 segment-based merge
  - `src/mongo/db/pipeline/change_stream_filter_helpers.cpp` (538 lines) — Oplog filter construction
  - `src/mongo/db/pipeline/change_stream_pipeline_helpers.cpp` (252 lines) — Pipeline stage ordering
  - `src/mongo/db/s/resharding/resharding_change_streams_monitor.cpp` (507 lines) — Resharding integration
- **Key GitHub/JIRA tickets**: SERVER-81295 (v1/v2 transition), SERVER-120644 (sequential invalidations), SERVER-110575 (segment boundary event loss), SERVER-113247 (resharding vector clock), SERVER-66017 (P1 non-deterministic tokens)
- **MongoDB Change Streams spec**: https://github.com/mongodb/specifications/tree/master/source/change-streams
