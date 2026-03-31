# Bug Report — MongoDB RangeDeletionsSecondaryNodes

## Summary

- Bug families tested: 4 (+ 1 known/expected)
- Bugs found: 2 new, 1 known confirmed
- Configs run: MC_hunt_version_mismatch.cfg, MC_hunt_recovery.cfg, MC_hunt_feature_flag.cfg, MC_hunt_concurrent.cfg

---

## Bug 1: Early-Break in Invalidation Loop Skips Trackers with Non-Monotonic ShardVersion

- **Bug Family**: Family 1 — Version Comparison Mismatch
- **Severity**: High
- **Invariant violated**: QueryShouldReadAllDocs
- **Config**: MC_hunt_version_mismatch.cfg
- **Counterexample**: 8 states (output: `spec/output/MC_hunt_version_mismatch_bfs.out`)

### Trace Summary

1. **Init**: 3 metadata trackers with `trackerShardV = <<0, 2, 0>>` (non-monotonic). Range deletion rd1 has `preMigShardV = 1`. Query q1 holds tracker 3 (shardV=0).
2. **OpApplierSignalUpdate(rd1)**: Invalidation loop runs with preMigV=1:
   - Tracker 1 (shardV=0): `CompareVersion(0, 1) = "unordered"` → not greater → **invalidated**
   - Tracker 2 (shardV=2): `CompareVersion(2, 1) = "greater"` → **BREAK** (loop exits)
   - Tracker 3 (shardV=0): **NEVER CHECKED** (skipped by early-break)
   - Result: `trackerValid = <<FALSE, TRUE, TRUE>>` — tracker 3 stays valid
3. **Signal commits, delete updates/commits, batch commits**: Normal progression. Docs removed from `lastAppliedSnapshot` (now empty).
4. **QueryAdvanceSnapshot(q1)**: Query takes snapshot of empty `lastAppliedSnapshot`.
5. **QueryProceed(q1)**: Query's tracker (3) is still valid, so query proceeds to DONE_OK. But its snapshot is missing all docs, and its tracker's shardVersion (0) is NOT greater than preMigShardV (1).

### Root Cause

`MetadataManager::invalidateRangePreserversOlderThanShardVersion()` iterates `_metadata` sorted by **collPlacementVersion** but compares by **shardPlacementVersion** with an early-break optimization. The `_metadata` list is sorted by collPlacementVersion (new entries appended with strictly increasing collPlacementVersion, lines 203-217). However, shardPlacementVersion can be non-monotonic: when a shard loses all chunks, `getShardPlacementVersion()` returns `{epoch, timestamp, 0, 0}` (chunk_manager.cpp:929-937), even though collPlacementVersion increased.

The early-break at `metadata_manager.cpp:291` (`else { break; }`) assumes shardPlacementVersions are monotonic with the iteration order. When they're not (e.g., shardV goes 0→2→0), the break exits at the first "greater" entry, leaving later entries with lower shardVersions unchecked.

### Affected Code

- `metadata_manager.cpp:273-294`: `invalidateRangePreserversOlderThanShardVersion()` — the early-break loop
- `metadata_manager.cpp:288-291`: The comparison `(placementVersion <=> shardVersion) != std::partial_ordering::greater` with `else { break; }`
- `metadata_manager.cpp:203-217`: `_metadata` sorted by collPlacementVersion (insertion guard)
- `chunk_version.h:222-245`: `ChunkVersion::operator<=>` — `!isSet()` returns `unordered`

### Recommendation

Remove the early-break optimization (line 291: `else { break; }`). Replace with a continue: always iterate the entire `_metadata` list. The performance cost is negligible — `_metadata` is typically small (2-5 entries). Alternatively, sort the comparison by shardPlacementVersion rather than relying on collPlacementVersion order.

---

## Bug 2: Recovery After Step-Up Skips RangePreserver Invalidation

- **Bug Family**: Family 2 — Recovery Without Re-Invalidation
- **Severity**: High
- **Invariant violated**: InvalidationBeforeVisibility
- **Config**: MC_hunt_recovery.cfg
- **Counterexample**: 4 states (output: `spec/output/MC_hunt_recovery_bfs.out`)

### Trace Summary

1. **Init**: Secondary node with `trackerShardV = <<0, 0>>`, `rdPreMigShardV = 1`, query q1 holds tracker 2. All trackers valid.
2. **StepUp**: Secondary transitions to primary (`nodeRole = "PRIMARY"`). No invalidation occurs — StepUp only changes the role.
3. **RecoverTask(rd1)**: Recovery re-registers the range deletion task. `signalState` and `deleteState` jump directly to "COMMITTED" (recovery uses `SemiFuture::makeReady()`, bypassing normal oplog application). `rdRecovered = TRUE`. **Critically: `trackerValid` remains `<<TRUE, TRUE>>`** — no invalidation was called.
4. **BatchCommitted(rd1)**: Batch commits, all docs removed from `lastAppliedSnapshot` (now empty). Both trackers still valid despite their shardVersions (0) being not-greater-than preMigShardV (1).

At this point, the invariant `InvalidationBeforeVisibility` is violated: batch is committed, but trackers with shardV not-greater-than preMigShardV are still valid. Any in-flight query holding these trackers can proceed to DONE_OK and read orphaned documents.

### Root Cause

`RangeDeleterService::_launchRangeDeletionRecoveryTask()` (range_deleter_service.cpp:220-231) calls `registerTask()` with `SemiFuture<void>::makeReady()` (line 229), which bypasses the query drain wait. More critically, `invalidateRangePreservers` is only called from `RangeDeleterServiceOpObserver::onUpdate()` (range_deleter_service_op_observer.cpp:164-168) when the `processing=true` field is **set** — not when the task is already marked `processing=true` in the database. During recovery, the task already has `processing=true`, so no oplog UPDATE fires, and `invalidateRangePreservers` is never called.

This is the direct secondary-side analogue of **SERVER-67385** (P2 Critical) — "Range deletion tasks wrongly scheduled before ongoing queries finish on shard primary."

### Affected Code

- `range_deleter_service.cpp:220-231`: `_launchRangeDeletionRecoveryTask()` — recovery path, no invalidation call
- `range_deleter_service.cpp:229`: `SemiFuture<void>::makeReady()` — bypasses query drain
- `range_deleter_service_op_observer.cpp:164-168`: `onUpdate()` — the only path that calls invalidation
- `range_deleter_service.cpp:127-133`: `onStepUpBegin()` — step-up entry point

### Recommendation

Add a call to `invalidateRangePreserversOlderThanShardVersion()` in the recovery path (`_launchRangeDeletionRecoveryTask`), after `registerTask()` completes. Each recovered task should trigger invalidation with its `preMigrationShardVersion`, matching the behavior of the normal oplog application path.

---

## Known/Expected Violations

### Family 3: Feature Flag Disabled Allows Query Bypass (KNOWN — SERVER-87673)

- **Config**: MC_hunt_feature_flag.cfg
- **Invariant violated**: QueryShouldReadAllDocs
- **Counterexample**: 8 states (output: `spec/output/MC_hunt_feature_flag_bfs.out`)
- **Description**: With `FeatureEnabled = FALSE` (gating `gTerminateSecondaryReadsUponRangeDeletion`), the query kill check at `shard_role.cpp:1943-1965` is bypassed. Even though the tracker is correctly invalidated, QueryProceed fires (instead of QueryKilled) because the feature flag check short-circuits. This confirms the known bug pattern that motivated SERVER-87673 and SERVER-100158. The fix is already deployed: the feature flag is enabled by default since MongoDB 8.2.
- **Status**: Known issue, already fixed in production for 8.2+.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 4 (Concurrent) | MC_hunt_concurrent.cfg | 2.67M generated, 1.06M distinct | InvalidationBeforeVisibility violated (6 states) — same root cause as Bug 1 (early-break), just with 2 queries + 2 RDs. No independent concurrent bug beyond the Family 1 root cause. |
| Family 5 (Oplog Batch) | N/A | Not tested | Existing spec already models worst case (same batch). No separate hunting config — the normal flow covers this. |

---

## Model Checking Statistics

| Config | Mode | States Generated | Distinct States | Depth | Time | Result |
|--------|------|-----------------|-----------------|-------|------|--------|
| MC.cfg (convergence) | BFS | 18,521 | 7,822 | 9 | <1s | Pass (structural) |
| MC_hunt_version_mismatch.cfg | BFS | 37,659 | 20,702 | 8 | <1s | **Bug 1 found** |
| MC_hunt_recovery.cfg | BFS | 1,936 | 1,108 | 6 | <1s | **Bug 2 found** |
| MC_hunt_feature_flag.cfg | BFS | 2,408 | 1,152 | 8 | <1s | Known violation |
| MC_hunt_concurrent.cfg | BFS | 2,671,104 | 1,060,972 | 6 | 3s | Bug 1 variant |
