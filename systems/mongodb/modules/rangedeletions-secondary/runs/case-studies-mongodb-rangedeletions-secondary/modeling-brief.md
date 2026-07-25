# Modeling Brief: MongoDB RangeDeletionsSecondaryNodes — Range Preserver

## 1. System Overview

- **System**: MongoDB Sharding — Range deletion on secondary nodes with query protection via RangePreserver
- **Language**: C++, ~2500 LOC core logic across 6 files
- **Protocol**: MVCC-based range preservation — secondary queries hold metadata references (RangePreservers) that block orphan cleanup; invalidation via oplog-replicated signals kills stale queries before orphans become visible
- **Key architectural choices**:
  - RangePreserver is a reference-counted wrapper around `CollectionMetadataTracker` (metadata_manager.cpp:71-115). `usageCounter` prevents metadata retirement while queries are active.
  - Invalidation is triggered by the `processing=true` update to `config.rangeDeletions`, replicated via oplog to secondaries (range_deleter_service_op_observer.cpp:164-168).
  - Version comparison uses `std::partial_ordering` on `ChunkVersion`, where `unordered` (incomparable) versions are treated as "invalidate" (metadata_manager.cpp:288).
  - Kill mechanism is gated behind feature flag `gTerminateSecondaryReadsUponRangeDeletion` AND runtime parameter `terminateSecondaryReadsOnOrphanCleanup` (shard_role.cpp:1943-1951).
  - `_metadata` list is sorted by `collPlacementVersion` but invalidation compares by `shardPlacementVersion` — these can have different orderings (metadata_manager.cpp:203-217 vs 287).
- **Concurrency model**: Multi-threaded — oplog applier threads, query executor threads, range deleter service thread, all synchronized via per-MetadataManager mutex + CSR resource lock hierarchy.

## 2. Bug Families

### Family 1: Version Comparison Mismatch in Invalidation (HIGH)

**Mechanism**: The invalidation loop iterates `_metadata` (sorted by collPlacementVersion) but compares by shardPlacementVersion. These orderings diverge when a shard gains/loses chunks. The early-break optimization (metadata_manager.cpp:291) can skip trackers that should have been invalidated.

**Evidence**:
- Code analysis: `_metadata` insertion guarded by `collPlacementVersion` comparison (metadata_manager.cpp:203-217), but invalidation uses `shardPlacementVersion` (metadata_manager.cpp:287). When a shard loses all chunks, shardPlacementVersion drops to `{0,0}` while collPlacementVersion increases.
- Code analysis: `partial_ordering::unordered` from `ChunkVersion::operator<=>` (chunk_version.h:222-245) is treated as "not greater" → invalidation fires. This silently invalidates metadata with incomparable versions.
- Historical: SERVER-113667 added UUID mismatch guard (collection_sharding_runtime.cpp:227-239) to prevent cross-collection invalidation — shows this path is error-prone.

**Affected code paths**:
- `MetadataManager::invalidateRangePreserversOlderThanShardVersion()` (metadata_manager.cpp:273-295)
- `CollectionShardingRuntime::invalidateRangePreserversOlderThanShardVersion()` (collection_sharding_runtime.cpp:221-242)

**Suggested modeling approach**:
- Variables: `metadataVersions [MetadataTracker -> <collVersion, shardVersion>]`, `metadataValid [MetadataTracker -> BOOLEAN]`
- Actions: Model `InvalidateRangePreservers(preMigShardVersion)` with the real comparison logic — iterate in collVersion order, compare shardVersion, break on "greater"
- Granularity: One action per invalidation call, but model 2-3 metadata trackers to expose ordering divergence
- Key: Model a scenario where shard loses chunks (shardVersion drops to 0) then regains them

**Priority**: High
**Rationale**: The version ordering mismatch is a structural issue in the invariation logic. The interaction between partial_ordering semantics and the early-break optimization creates a concrete scenario where trackers are skipped. Model checking can enumerate the version space to find violating interleavings.

---

### Family 2: Recovery Without Re-Invalidation After Step-Up (HIGH)

**Mechanism**: When a secondary becomes primary, recovery re-registers range deletion tasks with `processing=true` but does NOT re-run `invalidateRangePreservers`. If the stepping-up node had not yet applied the oplog entry that triggered invalidation, in-flight queries with valid RangePreservers can read orphaned documents while they're being deleted.

**Evidence**:
- Code analysis: Recovery at range_deleter_service.cpp:186-262 calls `registerTask` with `SemiFuture<void>::makeReady()` (line 229), bypassing the query drain wait.
- Code analysis: `invalidateRangePreservers` is only called from `RangeDeleterServiceOpObserver::onUpdate` (range_deleter_service_op_observer.cpp:164-168) — NOT from recovery.
- Historical: SERVER-67385 (P2 Critical) — "Range deletion tasks wrongly scheduled before ongoing queries finish on shard primary" — same class of bug on primary side.
- Historical: 6 reverted commits on step-up/step-down lifecycle (SERVER-69552, SERVER-64979, SERVER-77513) — the lifecycle is the most error-prone area.

**Affected code paths**:
- `RangeDeleterService::_launchRangeDeletionRecoveryTask()` (range_deleter_service.cpp:186-262)
- `RangeDeleterService::registerTask()` (range_deleter_service.cpp:361-489)

**Suggested modeling approach**:
- Variables: `nodeRole [Node -> {PRIMARY, SECONDARY}]`, `recoveryPending [Node -> BOOLEAN]`
- Actions: `StepUp` (transitions secondary→primary, triggers recovery), `RecoverTask` (registers task without invalidation), `StepDown` (clears service)
- Key: Model a query on the secondary that holds a valid RangePreserver, then the node steps up, recovery starts deletion, query restores and proceeds

**Priority**: High
**Rationale**: Direct analogue of SERVER-67385 (confirmed P2 Critical). The recovery path explicitly skips query drain. Model checking can verify whether in-flight queries with stale RangePreservers can coexist with active range deletion.

---

### Family 3: Feature Flag Gating Disables Safety (MEDIUM)

**Mechanism**: The query kill check at shard_role.cpp:1937-1971 is gated behind a feature flag AND a runtime parameter AND read concern exclusions. When any gate is disabled, queries proceed with invalidated RangePreservers and can read orphaned/deleted documents. The existing TLA+ spec assumes the kill always fires.

**Evidence**:
- Code analysis: Three independent gates at shard_role.cpp:1943-1955 — feature flag, runtime parameter, read concern check. ANY being false bypasses the kill.
- Historical: SERVER-100050 (2025) added `terminateSecondaryReadsOnOrphanCleanup` parameter — runtime-toggleable.
- Historical: SERVER-87673 — "Queries on secondaries exceeding orphanCleanupDelaySecs may miss donated documents" — this was the bug that drove the feature flag, confirming the property DOES NOT hold without it.
- Code analysis: For MongoDB < 8.1, the feature flag is disabled and the property `QueryShouldReadAllDocs` does NOT hold.

**Affected code paths**:
- `checkOrphanRangePreserverIsStillValid` lambda (shard_role.cpp:1937-1971)

**Suggested modeling approach**:
- Variables: `featureEnabled \in BOOLEAN`, `orphanCleanupDelay \in Nat`
- Actions: When `featureEnabled = FALSE`, `Q_KILLED` action is disabled (query always proceeds)
- Key: Verify that `QueryShouldReadAllDocs` is violated when `featureEnabled = FALSE` (confirms the known bug pattern) and holds when `featureEnabled = TRUE`

**Priority**: Medium
**Rationale**: The feature flag is enabled by default since v8.2, but runtime parameter can be toggled. Model checking with the flag as a variable validates the safety boundary precisely.

---

### Family 4: Multiple Concurrent Queries and Range Deletions (MEDIUM)

**Mechanism**: The existing TLA+ spec models ONE query and ONE range deletion. In production, multiple queries hold RangePreservers on different metadata tracker versions, and multiple range deletions with different `preMigrationShardVersion` values can interleave. The version-based invalidation may invalidate too many or too few trackers.

**Evidence**:
- Code analysis: `_metadata` can have multiple entries with active RangePreservers (metadata_manager.cpp:239-261 shows multiple trackers coexist).
- Code analysis: `invalidateRangePreserversOlderThanShardVersion(V)` invalidates ALL trackers <= V, not just the one for the specific range deletion (metadata_manager.cpp:285-294).
- Historical: SERVER-63243 — "Range deleter must not clean up orphan ranges in round-robin fashion" — concurrent range deletion ordering was a confirmed bug.
- Historical: SERVER-119435 — "Fix deadlock with range deletion task registration" — concurrent overlapping tasks with equal registration times caused deadlock.

**Affected code paths**:
- `MetadataManager::invalidateRangePreserversOlderThanShardVersion()` (metadata_manager.cpp:273-295)
- `MetadataManager::getActiveMetadata()` (metadata_manager.cpp:124-158)
- `RangeDeleterService::registerTask()` overlap handling (range_deleter_service.cpp:385-426)

**Suggested modeling approach**:
- Variables: Extend DOCS to multiple ranges, model 2+ queries and 2+ range deletions
- Actions: `Q_ADVANCE_SNAPSHOT(q)` for each query, `OP_UPDATED(rd)` for each range deletion
- Key: Two range deletions with V1 < V2 — does V1's invalidation incorrectly kill a query that only overlaps V2's range?

**Priority**: Medium
**Rationale**: The existing spec's single-query/single-deletion assumption hides cross-invalidation bugs. Even 2 queries + 2 deletions would be a significant extension.

---

### Family 5: Oplog Batch Atomicity and Ordering (LOW)

**Mechanism**: On secondaries, the `processing=true` signal and the actual range deletion can arrive in the same oplog batch, executing concurrently. The existing spec correctly models this worst case. However, it does not model the case where they arrive in DIFFERENT batches with arbitrary interleaving of queries.

**Evidence**:
- Existing TLA+ spec comments (lines 28-35): "If both operations run on different batches we can make sure that the invalidation of the Range Preserver will precede the actual Range Deletion operation."
- Code analysis: Oplog apply parallelism — different collections can be applied in parallel (ready_range_deletions_processor.cpp:332-336 comments about ordering).
- Historical: SERVER-68660 — "Register range deletion tasks with ongoing queries future after the oplog entry is committed" — timing of registration vs oplog commit was a real bug.

**Affected code paths**:
- `RangeDeleterServiceOpObserver::onUpdate()` (range_deleter_service_op_observer.cpp:139-175)
- Oplog batch application infrastructure

**Suggested modeling approach**:
- Variables: `batchId [OpEntry -> Nat]`, model entries in same or different batches
- Actions: `BATCH_COMMITTED(b)` advances visibility only for entries in batch b
- Key: Verify that cross-batch ordering (signal in batch N, deletion in batch N+1) is always safe

**Priority**: Low
**Rationale**: The existing spec already handles the worst case (same batch). Cross-batch is stated to be safe by design. Low priority for new bugs but good for completeness.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Multiple metadata trackers with version ordering | Family 1: version comparison mismatch | Model `_metadata` as a sequence of `<collVersion, shardVersion, valid, usageCount>` tuples |
| shardVersion vs collVersion divergence | Family 1: early-break bug with non-monotonic shard versions | Add scenario where shard loses chunks (shardVersion drops to 0) |
| Step-up/recovery without re-invalidation | Family 2: recovery skips invalidateRangePreservers | Add `StepUp` action that re-registers tasks but doesn't invalidate |
| Feature flag gating | Family 3: safety property conditional on configuration | Add `featureEnabled` boolean that gates Q_KILLED |
| Multiple concurrent queries | Family 4: cross-invalidation between queries/deletions | Model 2 queries with different metadata tracker references |
| Multiple concurrent range deletions | Family 4: interleaving of invalidations with different versions | Model 2 range deletions with different preMigrationShardVersions |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Actual document deletion mechanics | The batch deletion loop (range_deletion_util.cpp:335-437) is an implementation detail; the spec cares about visibility, not deletion batching |
| Persistent task document lifecycle | The `config.rangeDeletions` CRUD operations are managed by the service layer; the protocol concern is invalidation timing |
| Network/replication transport | Oplog delivery is modeled abstractly as batch application |
| Lock hierarchy details | The mutex ordering (CSR → _managerLock) is a code-level concern; TLA+ models logical state, not lock contention |
| Copy-paste / code quality issues | No protocol safety implications |
| Read concern snapshot/available exemptions | These are by design (snapshot reads are pinned, available reads accept orphans) |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Metadata version tracking | `metadataTrackers: Seq([collV: Nat, shardV: Nat, valid: BOOLEAN, usageCount: Nat])` | Model version comparison and early-break logic | Family 1 |
| Node role transitions | `nodeRole: {PRIMARY, SECONDARY}`, `recoveryPending: BOOLEAN` | Model step-up recovery without re-invalidation | Family 2 |
| Feature flag | `featureEnabled: BOOLEAN` | Gate the query kill action | Family 3 |
| Multiple queries | `queryState: [Query -> State]`, `queryTracker: [Query -> TrackerIdx]` | Each query references a specific metadata tracker | Family 4 |
| Multiple range deletions | `rangeDeletions: [RD -> <range, preMigShardVersion, processing>]` | Concurrent invalidations with different versions | Family 1, 4 |
| Shard version drop | (scenario via initial state) | Shard with shardVersion={0,0} after losing chunks | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| QueryShouldReadAllDocs | Safety | If query reaches DONE_OK, it saw all documents (existing) | Baseline |
| InvalidationBeforeVisibility | Safety | If a document is removed from lastAppliedSnapshot, all trackers with version <= preMigrationShardVersion are invalid (existing, strengthened) | Family 1 |
| NoStaleQueryAfterRecovery | Safety | After step-up recovery starts deletion, no query with a pre-invalidation RangePreserver can reach DONE_OK | Family 2 |
| FeatureGatedSafety | Safety | When featureEnabled=TRUE, QueryShouldReadAllDocs holds; when FALSE, it may not | Family 3 |
| CrossInvalidationSafety | Safety | An invalidation for range R1 does not incorrectly kill a query that only overlaps range R2 | Family 4 |
| VersionMonotonicity | Safety | For all adjacent trackers Ti, Ti+1 in _metadata: Ti.shardVersion <= Ti+1.shardVersion (expected to FAIL, confirming Family 1) | Family 1 |
| Termination | Liveness | All queries and range deletions eventually complete (existing) | Baseline |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | shardVersion non-monotonicity causes early-break to skip tracker invalidation | InvalidationBeforeVisibility, QueryShouldReadAllDocs | 1 |
| MC-2 | partial_ordering::unordered treated as "invalidate" — over-invalidation when shard version is {0,0} | CrossInvalidationSafety | 1 |
| MC-3 | Recovery after step-up registers task without re-invalidating RangePreservers | NoStaleQueryAfterRecovery | 2 |
| MC-4 | Feature flag disabled allows query to proceed with invalidated RangePreserver | FeatureGatedSafety (expected violation) | 3 |
| MC-5 | Two range deletions with V1 < V2 — V1's invalidation kills query that only overlaps V2's range | CrossInvalidationSafety | 4 |
| MC-6 | Query obtains RangePreserver on active metadata that was already invalidated | QueryShouldReadAllDocs (depends on whether new query can still read) | 1, 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | orphanCleanupDelaySecs=0 with feature flag disabled — query reads orphans | Docker compose: disable flag, set delay=0, run long query during moveChunk |
| TV-2 | Step-up during active range deletion with in-flight secondary reads | Replica set test: read on secondary, trigger stepUp, verify query outcome |
| TV-3 | UUID mismatch between CSR and range deletion task silently skips invalidation | Unit test: mock CSR with different UUID, verify log warning and no invalidation |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `_retireExpiredMetadata` nullifies metadata in the middle of the list, creating gaps in the invalidation loop iteration | Verify no new query can attach to a nullified tracker |
| CR-2 | `isMetadataStillValid()` comment says "answer is unstable — it might change immediately after returning" | Verify all callers handle the TOCTOU correctly |
| CR-3 | SERVER-121826 (background shard filtering cleanup) was committed and reverted in 3 days | Monitor for re-introduction; may affect metadata tracker lifetime |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-rangedeletions-secondary/analysis-report.md`
- **Existing TLA+ spec**: `artifact/mongo-src/src/mongo/tla_plus/Sharding/RangeDeletionsSecondaryNodes/RangeDeletionsSecondaryNodes.tla`
- **Primary-side bug report**: `case-studies/mongodb-rangedeletion/spec/bug-report.md` (Bug 1: migrationId filter, Bug 2: recovery priority)
- **Shared harness doc**: `case-studies/mongodb-shared-harness.md`
- **Key source files**:
  - `metadata_manager.cpp` (RangePreserver, invalidation, version comparison — 300 lines)
  - `range_deleter_service_op_observer.cpp` (invalidation trigger — 175 lines)
  - `shard_role.cpp` (query restore, kill check — lines 1937-1990)
  - `range_deleter_service.cpp` (recovery, registration — 530 lines)
  - `collection_sharding_runtime.cpp` (CSR invalidation routing — lines 221-242)
- **GitHub/Jira issues**: SERVER-87673, SERVER-100158, SERVER-67385, SERVER-113667, SERVER-119435, SERVER-67688
- **Key commits**: `7ddd8f7425` (SERVER-100158, kill query on invalidation), `c3aeed0e76` (SERVER-113667, UUID mismatch guard), `fcccb877f4` (SERVER-115921, race fix)
