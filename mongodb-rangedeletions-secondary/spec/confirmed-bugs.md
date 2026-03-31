# Confirmed Bug Report — mongodb-rangedeletions-secondary

## Summary
- Total findings reviewed: 8 (2 new bugs, 1 known bug, 2 variants/duplicates, 3 defensive items)
- Reproduced: 2
- Confirmed (code audit, reproduction failed): 0
- False positives: 0
- Inconclusive: 0
- Known/historical (no reproduction needed): 1

## Bug 1: Early-Break in Invalidation Loop Skips Trackers with Non-Monotonic ShardVersion

- **Source**: MC (8-state counterexample) + Code Review (Family 1)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `metadata_manager.cpp:273-295` — `invalidateRangePreserversOlderThanShardVersion()`
- **MC Output**: `spec/output/MC_hunt_version_mismatch_bfs.out`

### Description

The `invalidateRangePreserversOlderThanShardVersion()` function iterates the `_metadata` list (sorted by collPlacementVersion in insertion order) but compares entries by `shardPlacementVersion` with an early-break optimization at line 291 (`else { break; }`). The code comment at lines 282-284 states: "The _metadata is sorted from the oldest to the newest versions. The 'for' loop can be exited if the current metadataTracker is newer."

This assumption is wrong: `shardPlacementVersion` is NOT monotonic with respect to `collPlacementVersion` ordering. When a shard loses all chunks, `RoutingTableHistory::_getVersion()` (chunk_manager.cpp:929-937) returns `{epoch, timestamp, 0, 0}`, while `collPlacementVersion` continues increasing monotonically. After chunk migrations back-and-forth, `_metadata` can have entries with shardPlacementVersion: high → {0,0} → high' → {0,0}.

The MC counterexample demonstrates this with `trackerShardV = <<0, 2, 0>>` and `preMigShardV = 1`:
- Tracker 1 (shardV=0): `unordered != greater` → **invalidated** ✓
- Tracker 2 (shardV=2): `2 > 1` → `greater` → **BREAK**
- Tracker 3 (shardV=0): **never checked** — stays valid despite shardV < preMigShardV

### Trigger Scenario

1. Shard collection on shard0, create multiple chunks
2. Move all chunks to shard1 (shard0 shardV → {0,0})
3. Move chunks back to shard0 (shardV increases)
4. Move all chunks to shard1 again (shardV → {0,0} again)
5. Move a chunk to shard0, start a query on secondary (acquires RangePreserver)
6. Move that chunk away (triggers invalidation with preMigShardV)
7. Early-break skips the query's tracker → query reads orphaned docs

### Reproduction Test

**File**: `repro/test_bug1_early_break.py`

Sets up a sharding cluster (2-node RS shard0, 1-node shard1), creates non-monotonic shardPlacementVersion via migration cycles, holds a query on the secondary using `setYieldAllLocksHang` failpoint, triggers invalidation via chunk migration, and releases the query.

**Result**: PASS (bug triggered). Query completed with `QUERY_OK:count=100` — NOT killed despite:
- `featureFlagTerminateSecondaryReadsUponRangeDeletion = true`
- `terminateSecondaryReadsOnOrphanCleanup = true`
- `orphanCleanupDelaySecs = 0`

The query read 100 orphaned documents that should have been protected by RangePreserver invalidation.

### Developer Evidence

- The code comment at line 282-284 explicitly states the monotonicity assumption
- Existing unit tests (`collection_sharding_runtime_test.cpp:635-678`) only test monotonic shard versions; no test exercises non-monotonic shardV
- `ChunkVersion::operator<=>` (chunk_version.h:222-245) explicitly deletes `<`, `>`, `<=`, `>=` operators to prevent bugs from `unordered` results — confirming the developers are aware of partial ordering dangers, but the invalidation loop still uses `<=>` unsafely with early-break
- SERVER-113667 added UUID mismatch guard to the same invalidation path — shows this path is known to be error-prone

### Recommendation

Remove the early-break optimization at line 291. Replace with a continue — always iterate the entire `_metadata` list. The list is typically 2-5 entries; the performance cost is negligible. Alternatively, compare by `collPlacementVersion` (which IS monotonic) rather than `shardPlacementVersion`.

---

## Bug 2: Recovery After Step-Up Skips RangePreserver Invalidation

- **Source**: MC (4-state counterexample) + Code Review (Family 2)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `range_deleter_service.cpp:184-260` — `_launchRangeDeletionRecoveryTask()`
- **MC Output**: `spec/output/MC_hunt_recovery_bfs.out`

### Description

When a secondary steps up to primary, `_launchRangeDeletionRecoveryTask()` re-registers range deletion tasks from `config.rangeDeletions` that already have `processing=true`. This recovery path:

1. **Bypasses invalidation**: `invalidateRangePreservers()` is only called from `RangeDeleterServiceOpObserver::onUpdate()` (range_deleter_service_op_observer.cpp:164-168) when the `processing` field is **SET** to true. During recovery, the task already has `processing=true` in the database — no UPDATE fires, so `onUpdate()` is never triggered.

2. **Bypasses query drain**: Recovery calls `registerTask(rdt, SemiFuture<void>::makeReady())` (line 224-227), where `makeReady()` resolves immediately instead of waiting for active queries to complete.

This is the direct secondary-side analogue of **SERVER-67385** (P2 Critical): "Range deletion tasks wrongly scheduled before ongoing queries finish on shard primary."

### Trigger Scenario

1. Set up a 2-node RS shard (shard0a primary, shard0b secondary)
2. Move chunk from shard0 to shard1, creating range deletion task with `processing=true`
3. Suspend range deletion (failpoint)
4. Start a long-running query on shard0b (secondary) — acquires RangePreserver
5. Step down shard0a → shard0b becomes primary
6. Recovery runs `_launchRangeDeletionRecoveryTask()` — re-registers task WITHOUT invalidation
7. Release query → completes successfully reading orphaned documents

### Reproduction Test

**File**: `repro/test_bug2_recovery_no_invalidation.py`

Sets up a sharding cluster, creates a range deletion task on shard0, holds a query on the secondary with `setYieldAllLocksHang`, forces step-down to trigger recovery, and releases the query.

**Result**: PASS (bug triggered). Query completed with `QUERY_OK:count=100` — NOT killed after step-up. Logs confirm:
- `"Resubmitting range deletion tasks"` (recovery executed)
- `"Finished resubmitting range deletion tasks"`
- **Zero** `invalidateRangePreservers` or `"Terminating secondary read"` messages

The query held a RangePreserver from the secondary phase, survived recovery, and read 100 orphaned documents.

### Developer Evidence

- SERVER-67385 (P2 Critical) is the same class of bug on the primary side — developers consider this severity level
- 6 reverted commits on step-up/step-down lifecycle (SERVER-69552, SERVER-64979, SERVER-77513) — the lifecycle is the most error-prone area
- No tests cover recovery + invalidation interaction
- No code comments in `_launchRangeDeletionRecoveryTask` acknowledge the missing invalidation

### Recommendation

Add a call to `invalidateRangePreserversOlderThanShardVersion()` in the recovery path. After `registerTask()` for each recovered task, call `invalidateRangePreservers()` with the task's `preMigrationShardVersion`, matching the behavior of the normal oplog application path in `onUpdate()`.

---

## Known/Historical Findings (No Reproduction Needed)

### Family 3: Feature Flag Disabled Allows Query Bypass (SERVER-87673)

- **Source**: MC (8-state counterexample) + Code Review
- **Status**: KNOWN — SERVER-87673, SERVER-100158
- **Severity**: Medium (fixed in 8.2+)
- **Location**: `shard_role.cpp:1937-1971` — `checkOrphanRangePreserverIsStillValid` lambda
- **Description**: With `gTerminateSecondaryReadsUponRangeDeletion = false`, the query kill check is bypassed. Even though the RangePreserver is correctly invalidated, `QueryProceed` fires instead of `QueryKilled`. The feature flag is enabled by default since MongoDB 8.2.
- **MC Config**: `MC_hunt_feature_flag.cfg` — 8-state counterexample confirms the known pattern.

---

## Filtered Out (Not Bugs)

| Finding | Reason for Exclusion |
|---------|---------------------|
| Family 4 (Concurrent) | Same root cause as Bug 1 (early-break). MC found violation with same invariant. |
| Family 5 (Oplog Batch) | Low priority, existing spec covers worst case by design |
| CR-1 (_retireExpiredMetadata gaps) | Defensive concern — `_retireExpiredMetadata` only nullifies metadata in entries with usageCount=0, which means no query holds them |
| CR-2 (isMetadataStillValid TOCTOU) | By design — the comment explicitly states the answer is unstable, and callers handle this correctly |
| CR-3 (SERVER-121826 revert) | Monitoring item, not a current bug |

---

## Reproduction Environment

- MongoDB 8.2.6 (`mongo:latest` Docker image)
- Cluster: 1 configsvr (1-node RS), 2 shards (shard0: 2-node RS, shard1: 1-node RS), 1 mongos
- `enableTestCommands=1`, `orphanCleanupDelaySecs=0`
- `featureFlagTerminateSecondaryReadsUponRangeDeletion=true` (default)
- `terminateSecondaryReadsOnOrphanCleanup=true` (default)
- Docker Compose: `repro/docker-compose.yml`
- Failpoints used: `setYieldAllLocksHang` (pause query at yield), `suspendRangeDeletion` (pause deletion)
