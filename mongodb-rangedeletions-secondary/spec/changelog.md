# Changelog — MongoDB RangeDeletionsSecondaryNodes

## Round 1 - Trace Validation
- [pass] basic_kill.ndjson: 13 states, 11 distinct, depth 9. All events consumed, invariants hold.

## Round 1 - Model Checking
- [pass] MC.cfg: 18521 states, 7822 distinct, depth 9. All structural invariants hold (TypeOK, StepUpBound, BatchRequiresBothCommitted, RecoveryOnlyOnPrimary).

## Bug Hunting
- [bug] Family 1 — Early-break in invalidation loop skips trackers with non-monotonic shardVersion. QueryShouldReadAllDocs violated, 8-state counterexample. trackerShardV=<<0,2,0>>, preMigShardV=1 → tracker 3 never checked. (metadata_manager.cpp:273-294)
- [bug] Family 2 — Recovery after step-up skips RangePreserver invalidation. InvalidationBeforeVisibility violated, 4-state counterexample. StepUp → RecoverTask → BatchCommitted with no invalidation. (range_deleter_service.cpp:220-231)
- [known] Family 3 — Feature flag disabled allows query bypass. QueryShouldReadAllDocs violated, 8 states. Confirms SERVER-87673, fixed in 8.2+.
- [bug] Family 4 — Concurrent variant of Family 1. InvalidationBeforeVisibility violated, 6 states. Same early-break root cause with 2 queries + 2 range deletions.

## Result
Converged in 1 round. Bug hunting: 2 new bugs found + 1 known confirmed.
