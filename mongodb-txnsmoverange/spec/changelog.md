# TxnsMoveRange Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] RespondStatus: added chunk ownership check (`ranges[ns][k] # self`) — shard must verify it owns the requested chunk, faithful to collection_sharding_runtime.cpp placement version check. Added `k` parameter.
- [fix] Init: refactored into InitBase + Init to allow TraceInit to use unconstrained rCachedRanges (models stale router cache from prior migrations not in the trace)
- [fix] TraceInit: uses InitBase with `rCachedRanges \in [NameSpaces -> [Keys -> Shards]]` instead of `rCachedRanges = ranges` — allows validating traces that start from post-migration state
- [fix] MapKey: mapped k3, k4 explicitly to k2 (real system has 4 keys, spec abstracts to 2)
- Validated: basic_txn (51 states, depth 7), migration_lifecycle (40 states, depth 4), txn_during_migration (47 states, depth 7)

## Round 1 - Model Checking
- No violations. 239K states, 80K distinct, depth 21, 1 second. All 5 invariants pass.

## Bug Hunting
- [fix-inv] NoPrematureCSRelease: replaced tautological invariant with `coordinatorDoc = DocCommitted => ranges reflect migration` (Case B: was always TRUE)
- [fix-inv] RecoveryPreservesDecision: replaced tautological invariant with version consistency check after recovery (Case B: was always TRUE)
- [fix-spec] RespondStatus: removed createdDatabases exemption from collection-level chunk migration checks — database_sharding_runtime.cpp:112-114 exemption only applies to movePrimary, not chunk migration (Case B: spec incorrectly merged database-level and collection-level checks)
- [bug] AtMostOnceExecution (Family 4): ShardRespondAfterExec + RouterRetryOnStale causes double execution — confirms known-fixed SERVER-81508

## Result
Converged in 1 round. Bug hunting: 1 known-fixed bug confirmed (SERVER-81508). No new bugs found across 305M+ states (2-txn BFS) + 2B simulation states + all family-specific configs.
