# Changelog: MongoDB Change Streams Spec Validation

## Round 1 - Trace Validation
- [fix] Trace.cfg: Shard constant must be string-valued (not model values) to match JSON trace data — used CONSTANT DEFINITION override `Shard <- TraceShardConst` with `TraceShardConst == {"s1", "s2", "s3"}` (Trace: all)
- [fix] TraceInit: activeCursors must be TraceShard (shards in trace), not Shard (all shards). Shard s3 had lowest HWM blocking merge. Inlined Init with `activeCursors = TraceShard` (Trace: basic_insert.ndjson)
- All 3 traces pass: basic_insert (15 states), invalidation (9 states), resume (9 states)

## Round 1 - Model Checking
- No invariant violations found
- BFS exhaustive: 56M states, 20.3M distinct, depth 20, 6 min (MaxClusterTime=3, MaxEvents=2, MaxTopoChanges=0)
- Simulation: 632M states, 33.8M traces, no violations (MaxClusterTime=4, MaxEvents=3, all features enabled)
- All 6 invariants pass: TotalOrder, CursorPositionsValid, ActiveCursorsSubset, StreamStateConsistency, TokenVersionsValid, DeliveredEventsHaveTokens

## Bug Hunting - Spec Fixes
- [fix-spec] AddShard: refToken must use resumeToken when isResuming and deliveredEvents is empty (Case B — NoGapOnResume violated in MC_hunt_segment_boundary.cfg, 19-state counterexample). After resume, deliveredEvents is cleared, so AddShard fell back to NoToken, positioning cursor at beginning of shard.
- [fix-spec] AddShard: must advance new shard's clock to at least refToken's clusterTime (Case B — TotalOrder violated in MC_hunt_segment_boundary.cfg, 21-state counterexample). Models MongoDB's atClusterTime constraint (change_stream_reader_context.h:59). Without this, newly added shard generates events at stale timestamps, breaking merge ordering.
- Post-fix verification: 756M states, 40M traces simulation — no violations. All traces still pass.

## Bug Hunting Results
- MC_hunt_version_transition.cfg: 247M states, 14.7M traces — no violations (TotalOrder, NoGapOnResume)
- MC_hunt_invalidation.cfg: 192M states, 14.3M traces — no violations (InvalidationCompleteness, InvalidationIdempotency)
- MC_hunt_segment_boundary.cfg: 347M states, 19M traces — no violations after fix (TotalOrder, NoEventLossAtSegmentBoundary, NoGapOnResume)
- MC_hunt_txn_ordering.cfg: 340M states, 16.3M traces — no violations (TxnOrderPreservation, TotalOrder, NoGapOnResume)

## Result
Converged in 1 round. 2 spec fixes during bug hunting (both Case B). 0 real bugs found across 4 hunting configs (~1.1B total states, ~64M traces).
