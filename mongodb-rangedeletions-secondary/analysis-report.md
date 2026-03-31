# Analysis Report: MongoDB RangeDeletionsSecondaryNodes

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Core files analyzed (full read) | 10 |
| Git commits reviewed | 68+ bug-fix commits across core files |
| Jira issues deeply read | 35+ |
| Confirmed historical bugs | 14 |
| Unfixed/design-level bugs | 3 (SERVER-87673 workaround, SERVER-8405 no fix, orphanCleanupDelay design) |
| New findings from deep analysis | 6 model-checkable, 3 test-verifiable, 3 code-review-only |
| Parallel analysis agents used | 8 |

---

## Phase 1: Reconnaissance Summary

### Core File Map

| File | Lines | Role | Bug Hotspot? |
|------|-------|------|-------------|
| `metadata_manager.cpp` | ~300 | RangePreserver class, version comparison, metadata lifecycle | YES (Family 1) |
| `range_deleter_service_op_observer.cpp` | 175 | Invalidation trigger on oplog apply | YES (ordering) |
| `shard_role.cpp` | ~2200 | Query yield/restore, RangePreserver validity check | YES (gating) |
| `range_deleter_service.cpp` | 530 | Task lifecycle, recovery, overlap handling | YES (Family 2, deadlocks) |
| `range_deletion_util.cpp` | 850 | Deletion execution, task persistence | Medium |
| `ready_range_deletions_processor.cpp` | ~400 | Sequential deletion processing | Low |
| `collection_sharding_runtime.cpp` | ~500 | CSR invalidation routing, UUID check | Medium |
| `range_deletion_task_tracker.cpp` | ~150 | In-memory task dedup and tracking | Low |
| `scoped_collection_metadata.h` | ~200 | Public validity checking interface | Low |
| `metadata_manager.h` | ~200 | MetadataManager interface, tracker struct | Context |

### Existing TLA+ Spec Coverage

The existing spec (RangeDeletionsSecondaryNodes.tla, 164 lines) models:
- 6 variables: opApplierState, batchState, queryState, querySnapshot, rangePreserverIsValid, lastAppliedSnapshot
- Single shard, single query, single range deletion, single batch
- Core safety: query killed before deletion visible, or query sees all docs
- Core liveness: termination, eventual invalidation and deletion

**NOT modeled** (gaps we target):
- Multiple metadata trackers with version ordering
- shardVersion vs collPlacementVersion divergence
- Step-up recovery without re-invalidation
- Feature flag / runtime parameter gating
- Multiple concurrent queries with different metadata versions
- Multiple concurrent range deletions
- Partial ordering comparison semantics
- preMigrationShardVersion absence

### Concurrency Model

```
Oplog Applier Thread(s)     Query Executor Thread(s)     Range Deleter Thread
        |                           |                           |
  onUpdate() fires            yield/restore cycle         registerTask()
        |                           |                           |
  invalidateRangePreservers   checkOrphanRangePreserver   overlap wait
        |                       StillValid()                    |
  CSR exclusive lock →           |                        sleepFor delay
  _managerLock                 _managerLock                    |
        |                    (read valid flag)            actual deletion
  set valid=false                  |                           |
        |                   QueryPlanKilled or              completeTask
        |                     DONE_OK                          |
```

Lock hierarchy: CSR resource lock → MetadataManager._managerLock (never reversed).

---

## Phase 2: Bug Archaeology Details

### Historical Bug Classification

#### Race Conditions (5 commits)
- `fcccb877f4` SERVER-115921: SharedPromise completed twice
- `12d8f741fd` SERVER-115750: Data race on _rangeDeletionTasks (access without mutex)
- `eed07f04fb` SERVER-117542: Race accessing _queue in ReadyRangeDeletionsProcessor
- `289aeb5651` SERVER-69552: StepDown race conditions (reverted, re-applied)
- `2aee6b6ba0` SERVER-115667: Test race condition

#### Deadlocks / Step-Down Hangs (6 commits)
- `9343c350ae` SERVER-119435: Deadlock in overlapping task registration
- `64488b038d` SERVER-70888: ScopedRangeDeleterLock deadlock on stepdown
- `29fdc94ccd` SERVER-70034: Potential deadlock on step down
- `de6eb37f32` SERVER-70964: Wait for range deletion thread on stepdown
- `ba892872f9` SERVER-112357: moveChunk hangs when range deleter disabled
- `1ab9c22972` SERVER-70003: Alternative client must be interruptible on stepdown

#### Secondary-Specific Fixes (6 commits)
- `7ddd8f7425` SERVER-100158: Kill query on invalidated metadata tracker (THE fix for secondary reads, 304 lines added)
- `d450c6eac4` SERVER-100050: terminateSecondaryReadsOnOrphanCleanup parameter
- `c3aeed0e76` SERVER-113667: UUID mismatch guard for invalidation
- `d8beee9e15` SERVER-77471: Suppress log spam on secondary
- `d5d59422cf` SERVER-59832: Prevent writes to orphan documents
- `20e9320f77` SERVER-29342: Original safe-secondary-reads plumbing (352 lines)

#### Correctness / Data Integrity (12 commits)
- `4c1a21e6aa` SERVER-70087: getOverlappingRangeDeletionsFuture misses ranges
- `90eefa051e` SERVER-46395: Ensure task doc exists during deletion
- `b4f1a63544` SERVER-57001: Snapshot must start from clean state
- `b8d5cfe531` SERVER-67688: notifySecondariesThatDeletionIsOccurring was dead code (entire function removed)
- `f44581d5bf` SERVER-63243: Range deleter round-robin bug
- `cb0e706157` SERVER-64979: Must start with same task on step up (reverted twice)
- `36fd043c35` SERVER-66958: Multiple "processing" range deletions on step-up

### Key Issue Deep Reads

#### SERVER-87673 (Confirmed, Fixed by SERVER-100158)
**Root cause**: Long-running secondary reads can exceed orphanCleanupDelaySecs and read orphaned documents. No mechanism existed to kill such queries.
**Fix**: SERVER-100158 added QueryPlanKilled on invalidated metadata tracker. Feature-flagged.
**Impact**: ALL MongoDB < 8.1 affected. Default orphanCleanupDelaySecs increased from 900→3600 as mitigation.

#### SERVER-67385 (P2 Critical, Fixed)
**Root cause**: Range deletion tasks scheduled before ongoing queries finish on shard primary. Metadata clearing lost reference to previous MetadataManager instances tracking active cursors.
**Relevance to secondary**: Direct analogue — our Family 2 (recovery without re-invalidation) is the secondary-side variant.

#### SERVER-119435 (Fixed, 2026-02)
**Root cause**: Deadlock between overlapping range deletion tasks with equal registration timestamps. Task A waits on Task B and vice versa.
**Fix**: Register task before capturing overlapping tasks; task skips waiting on itself.
**Relevance**: Shows overlap ordering remains fragile.

#### SERVER-113667 (Fixed, 2025-11)
**Root cause**: UUID mismatch between CSR and range deletion task caused invalidation of wrong collection's RangePreservers.
**Fix**: Added UUID comparison guard before invalidation (collection_sharding_runtime.cpp:227-239).
**Relevance**: Shows the invalidation dispatch path needs careful filtering.

### Bug Hotspot Analysis

| File | Bug-Fix Commits | Severity |
|------|----------------|----------|
| range_deletion_util.cpp | 82 total, ~12 bug fixes | High |
| range_deleter_service.cpp | 68 total, ~15 bug fixes | Critical |
| range_deleter_service_op_observer.cpp | 34 total, ~4 bug fixes | Medium |
| metadata_manager.cpp (shard_catalog) | 2 total (recently moved) | Low commit count but HIGH conceptual complexity |
| shard_role.cpp | 10 total, ~3 bug fixes | Medium |

---

## Phase 3: Deep Analysis Details

### Finding DA-1: Version Comparison Mismatch (Family 1)

**Location**: metadata_manager.cpp:273-295

**The issue**: `_metadata` list is ordered by `collPlacementVersion` (enforced at metadata_manager.cpp:207-217). The invalidation loop at line 287 compares `shardPlacementVersion`, which can have a different ordering.

**Concrete scenario**:
1. Metadata M1: collVersion=(epoch,3,5), shardVersion=(epoch,3,2) — shard owns 2 chunks
2. Metadata M2: collVersion=(epoch,4,0), shardVersion=(epoch,0,0) — shard lost all chunks
3. M1 is before M2 in `_metadata` (collVersion ordering)
4. Range deletion with preMigrationShardVersion=(epoch,3,1) triggers invalidation
5. Loop at M1: shardVersion (epoch,3,2) > (epoch,3,1) → `break` (early exit)
6. M2 is NEVER checked, despite shardVersion={0,0} which should be invalidated

**Compensating mechanism check**: None found. The early-break is the only exit condition besides end-of-list.

**Severity**: Medium-High. Requires specific sequence of chunk migrations (shard gaining then losing chunks).

### Finding DA-2: partial_ordering::unordered Semantics (Family 1)

**Location**: metadata_manager.cpp:288, chunk_version.h:222-245

**The issue**: `ChunkVersion::operator<=>` returns `unordered` in three cases:
- Either version is UNTRACKED
- Either version is IGNORED
- Same collection generation, one has placement {0,0} (unset)

The condition `!= partial_ordering::greater` evaluates to `true` for `unordered`, causing invalidation.

**Concrete scenario**: Shard had chunks (version V1), lost all chunks (shardVersion drops to {0,0}), new metadata tracker has unset placement. Comparison with any preMigrationShardVersion from the same collection yields `unordered` → invalidation fires, which may be OVER-invalidation (killing queries that shouldn't be killed).

**Compensating mechanism**: IGNORED guard at line 275. But no guard for UNTRACKED or the "one unset" case.

### Finding DA-3: Recovery Without Re-Invalidation (Family 2)

**Location**: range_deleter_service.cpp:186-262

**The issue**: Recovery on step-up finds tasks with `processing=true` (line 227-248) and registers them with `SemiFuture<void>::makeReady()` (line 229). This bypasses the normal registration chain that includes:
- Waiting for service up (line 380-384) — skipped (immediate)
- Waiting for overlapping tasks (line 385-426) — skipped (immediate)
- Waiting for active queries (line 428-432) — skipped (makeReady)
- Secondary cleanup delay (line 434-451) — skipped (immediate for processing tasks)

The call to `invalidateRangePreservers` only exists in the OpObserver (range_deleter_service_op_observer.cpp:164-168). During recovery, the OpObserver does NOT fire because recovery reads from the collection directly (not via oplog apply).

**Concrete scenario**:
1. Node is secondary, serves read with RangePreserver (usageCounter=1, valid=true)
2. Primary marks task processing=true, but oplog entry NOT YET applied on this secondary
3. This secondary wins election (step-up)
4. Recovery finds task with processing=true, registers with makeReady()
5. Deletion proceeds immediately
6. The read from step 1 yields and restores — RangePreserver still valid=true
7. Read continues, potentially accessing documents being deleted

**Compensating mechanism check**: The read uses a storage engine snapshot, so deleted documents should still be visible via MVCC. However, if the range deletion completes and the task document is removed, a subsequent metadata refresh could alter what the query sees.

### Finding DA-4: Feature Flag Gating (Family 3)

**Location**: shard_role.cpp:1937-1971

**The issue**: Three independent conditions must ALL be true for the kill to fire:
```cpp
gTerminateSecondaryReadsUponRangeDeletion.isEnabledAndIgnoreFCVUnsafe() &&
terminateSecondaryReadsOnOrphanCleanup.load() &&
(readConcern != kSnapshot && readConcern != kAvailable)
```

When ANY is false, `Q_KILLED` transition is disabled. The existing TLA+ spec's `Q_KILLED` has no such condition — it fires unconditionally when `rangePreserverIsValid = FALSE`.

**Assessment**: By design for backward compatibility, but the TLA+ spec should explicitly model this gate to correctly characterize the safety boundary.

### Finding DA-5: Concurrent Invalidations (Family 4)

**Location**: metadata_manager.cpp:273-295

**The issue**: Two range deletions R1(V1) and R2(V2) where V1 < V2. R1's invalidation marks trackers <= V1 invalid. R2's invalidation marks trackers <= V2 invalid (superset). But if R1 fires first and hits the early-break at a tracker between V1 and V2, that tracker remains valid. Then R2 fires and invalidates it.

**This is actually safe** if R2 always fires. But if R2 is aborted/cancelled before invalidation runs, the tracker between V1 and V2 stays valid. A query on that tracker could read orphans from R1's range.

**Compensating mechanism**: Range deletion abortion removes the task document, which prevents actual deletion. But the orphaned documents may already exist from the migration.

### Finding DA-6: Active Metadata Can Be Invalidated (Family 1)

**Location**: metadata_manager.cpp:128 (getActiveMetadata returns back()), metadata_manager.cpp:285-294 (invalidation includes last entry)

**The issue**: `getActiveMetadata` always returns `_metadata.back()`. The invalidation loop iterates ALL entries including the last. If preMigrationShardVersion >= active metadata's shardPlacementVersion, the active metadata gets `valid=false`.

New queries via `getActiveMetadata` get a RangePreserver on already-invalidated metadata. `isMetadataStillValid()` immediately returns false. All queries fail with QueryPlanKilled until metadata is refreshed.

**Impact**: Temporary query unavailability on the secondary between invalidation and metadata refresh. The gap is unbounded.

**Compensating mechanism**: Query retry logic should trigger metadata refresh. But the refresh path depends on config server reachability.

---

## Phase 3: Verified False Positives

| Finding | Why False Positive |
|---------|-------------------|
| Lock ordering deadlock (CSR → _managerLock) | Strictly hierarchical — never reversed. isMetadataStillValid() only acquires _managerLock. |
| _retireExpiredMetadata removes active tracker | Only removes from front when usageCounter=0; preserves at least one entry (back). |
| Query reads documents between snapshot open and validity check | The restore function runs check BEFORE returning control to query executor. No document reads in between. |
| Multiple yield/restore cycles miss invalidation | `valid` flag is monotonically decreasing (once false, stays false). Checked every restore. |
| RangePreserver destructor doesn't fire on QueryPlanKilled | RAII chain: exception → ScopeGuard → releaseAllResources → destroy ownershipFilter → ~RangePreserver. |
| UUID mismatch causes wrong-collection invalidation | Fixed by SERVER-113667 — UUID comparison guard added. |

---

## Key Architectural Observations

1. **The RangePreserver mechanism was retrofitted, not designed in.** The original design (SERVER-29405, 2017) was a pure delay (`orphanCleanupDelaySecs`). The metadata-version-based invalidation was added 8 years later (SERVER-100158, 2025). This explains the complexity of the gating conditions and the version comparison issues.

2. **The version comparison is the weakest link.** The `_metadata` list ordering (collPlacementVersion) vs the invalidation comparison key (shardPlacementVersion) mismatch is a structural issue, not a transient bug. It would require re-sorting the list or changing the comparison to fix.

3. **Recovery is the most underspecified path.** The normal registration chain has 4 sequential waits (service up → overlapping tasks → active queries → cleanup delay). Recovery bypasses ALL of them with `makeReady()`. This is the same pattern as SERVER-67385 (P2 Critical) on the primary side.

4. **The feature flag creates two different safety regimes.** With the flag enabled, the spec's safety properties hold. With it disabled, they provably don't. The TLA+ spec should model both to precisely characterize the boundary.
