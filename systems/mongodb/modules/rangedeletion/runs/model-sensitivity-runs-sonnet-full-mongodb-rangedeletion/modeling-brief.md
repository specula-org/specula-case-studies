# Modeling Brief: MongoDB Sharding — Range Deletion

## 1. System Overview

**System**: MongoDB sharding range deletion subsystem (`src/mongo/db/s/`)
**Language**: C++
**Core LOC**: ~2,800 (range deletion) + ~1,800 (migration coordinator) + ~1,800 (migration source manager)

**Category**: **A — Distributed / Message-Passing**
*Justification*: The range deletion protocol is a multi-node state machine spanning donor shard, recipient shard, and config server. Its correctness depends on the ordering of durable writes across two separate persistent document stores (`config.migrationCoordinators` and `config.rangeDeletions`), crash-recovery behavior, and RPCs between shards. The dominant failure modes are crash windows between multi-step durable writes and message-delivery gaps on the abort/commit path — canonical Category A patterns.

**What it implements**: After a chunk migration, documents that were on the donor (or partially cloned to a recipient that aborted) must be deleted asynchronously. The `RangeDeleterService` manages in-memory task scheduling; persistent state is stored in `config.rangeDeletions` documents (one per shard per migration). The migration coordinator orchestrates decision delivery and controls the `pending` flag that gates deletion.

**Key architectural choices**:
- Two separate document stores (migration coordinator + range deletion task) are not written atomically.
- The `pending: true` flag gates deletion; removal of this flag (via `$unset`) is observed through an op-observer, which registers the task with `RangeDeleterService`.
- Recovery on step-up explicitly skips `pending: true` tasks; they must be reactivated by the migration coordinator recovery path.
- `forgetMigration` uses `WriteConcernOptions{1}` (w:1, not majority).

**Concurrency model**: MongoDB's executor-per-service model. The range deleter runs on a single-threaded executor. Recovery runs on the `_executor` thread. Op-observer callbacks run on the committing thread (holding collection lock). The service uses a `Mutex` for all in-memory task map access.

---

## 2. Bug Families

### Family 1: Non-Atomic Coordinator + Range Deletion Task Initialization

**Mechanism**: `startMigration` writes two independent durable documents — first the migration coordinator doc, then the range deletion task — without a multi-document transaction. A crash between the two writes leaves the coordinator without a corresponding range deletion task. Recovery's commit path silently skips donor range deletion when the task is absent.

**Evidence**:
- Code: `migration_coordinator.cpp:147–170` — `insertMigrationCoordinatorDoc` at line 150, then `createAndPersistRangeDeletionTask` at line 158–169; no transaction spans them.
- Code: `migration_coordinator.cpp:285–294` — `_commitMigrationOnDonorAndRecipient` falls through to `return Future<void>::makeReady()` when `_donorRangeDeletionTask` is null after a disk lookup. This is the silent-skip path.
- Design note: `README_migrations.md` states the range deletion task is persisted "at the beginning of the migration, before the donor sends the request to begin cloning" — the README describes the intent as atomic with migration start, but the implementation is a sequential two-write sequence.

**Affected code paths**:
- `MigrationCoordinator::startMigration` (coordinator doc insert → task insert)
- `MigrationCoordinator::_commitMigrationOnDonorAndRecipient` (early return at line 294)
- `resumeMigrationCoordinationsOnStepUp` → `completeMigration` (the recovery call path that hits the early return)

**Suggested modeling approach**:
- Variables: `coordDoc ∈ {absent, present-no-decision, committed, aborted}`, `donorTask ∈ {absent, pending, ready, processing}`
- Actions: split `startMigration` into `WriteCoordinatorDoc` and `WriteRangeDeletionTask` as two separate TLA+ actions with a crash action between them
- Granularity: model crash as a silent-stop action that leaves persisted state intact; on recovery, model the lookup returning absent when the task doc was never written

**Priority**: **High**
**Rationale**: Direct safety violation — committed migration + missing donor range deletion task = orphans that persist indefinitely. No compensating mechanism in the recovery path. The crash window is always open during normal migration start.

---

### Family 2: Pending-Flag Activation Gaps (Stuck Pending Tasks)

**Mechanism**: Range deletion tasks start as `pending: true` and must be explicitly activated by the migration coordinator delivering the commit/abort decision. The recovery scan on step-up explicitly skips `pending: true` tasks (by design). Two code paths can prevent activation: (a) the abort path's `ShardNotFound` handling does not cover `markAsReadyRangeDeletionTaskOnRecipient`, allowing the exception to propagate and block delivery indefinitely; (b) `forgetMigration` uses w:1, so the coordinator document can survive a stepdown and trigger re-execution with no range deletion task present.

**Evidence**:
- Code: `migration_coordinator.cpp:352–386` — `advanceTransactionOnRecipient` is wrapped in a `ShardNotFound` try/catch (lines 352–375), but `markAsReadyRangeDeletionTaskOnRecipient` at line 382 is **outside** the try block. The catch block's log message at line 368–374 reads "and/or marking range deletion task on recipient as ready for processing" — the developer's intent was to cover both calls, but the code does not.
- Code: `range_deleter_service.cpp:241–254` — recovery scan filter explicitly uses `$ne: true` for both `processing` and `pending` fields; `pending: true` documents are never touched by this scan.
- Code: `migration_coordinator.cpp:396–401` — `forgetMigration` passes `WriteConcernOptions{1, ...}` (w:1); on stepdown before replication, the coordinator document survives and recovery re-runs `_commitMigrationOnDonorAndRecipient`, which finds the range deletion task already deleted and hits the early return at line 294.
- Design signal: `range_deleter_service.h` class marker `MONGO_MOD_NEEDS_REPLACEMENT` — the developers acknowledge the pending/ready lifecycle is incomplete.

**Affected code paths**:
- `MigrationCoordinator::_abortMigrationOnDonorAndRecipient` (lines 326–387)
- `MigrationCoordinator::forgetMigration` (w:1 at line 400)
- `RangeDeleterService::_launchRangeDeletionRecoveryTask` (lines 241–254 exclusion of pending tasks)
- `resumeMigrationCoordinationsOnStepUp` retry loop (hits ShardNotFound, retries, fails permanently if shard is gone)

**Suggested modeling approach**:
- Variables: `recipientTask ∈ {absent, pending, ready}`, `donorCoordinator ∈ {absent, present, committed, aborted}`, `recipientShard ∈ {alive, removed}`
- Actions: `ActivateRecipientTask` (can fail with ShardNotFound); `ForgetMigration` with w:1 (non-durable); `StepDown` before `forgetMigration` replicates
- Invariant to check: `□(aborted ∧ recipientTaskExists → ◇recipientTask = ready)` — is the liveness of recipient task activation guaranteed?

**Priority**: **High**
**Rationale**: The code/intent mismatch in the abort path (ShardNotFound catch scope) is a clear protocol gap. A shard that is temporarily removed from the cluster can leave `pending: true` recipient tasks stranded indefinitely, creating persistent orphans on the recipient. Confirmed by a specific code path where the exception propagates uncaught.

---

### Family 3: Overlapping Range Deletion TOCTOU Gap

**Mechanism**: `getOverlappingRangeDeletionsFuture` takes a point-in-time snapshot of in-memory range deletion tasks. Any task registered *after* the snapshot is taken is invisible to the caller. A new migration to the same range that starts and registers its deletion task after the snapshot can proceed concurrently with the old deletion, violating the serial ordering guarantee.

**Evidence**:
- Code: `range_deleter_service.h:153–158` — explicit `NB:` warning: "in case an overlapping range deletion task is registered AFTER invoking this method, it will not be taken into account."
- Code: `range_deleter_service.h:157` — method marked `MONGO_MOD_NEEDS_REPLACEMENT`.
- Code: `range_deleter_service.cpp:506–528` — implementation takes a lock, collects in-memory tasks, returns; no mechanism to catch subsequently-registered tasks.
- Design signal: `RangeDeleterService`, `MigrationCoordinator`, `MigrationSourceManager`, `deleteRangeDeletionTaskLocally`, `deleteRangeDeletionTaskOnRecipient` are all marked `MONGO_MOD_NEEDS_REPLACEMENT`.

**Affected code paths**:
- `CollectionShardingRuntime` → `getOverlappingRangeDeletionsFuture` (called before migration starts cloning)
- `RangeDeleterService::registerTask` ordering chain (lines 392–427: waits on overlapping in-memory tasks)

**Suggested modeling approach**:
- Variables: `deletionTasks[shard][range]` as a set (can have multiple), `migrationPhase ∈ {cloning, committed}`
- Actions: `GetOverlapSnapshot` (returns current tasks), `RegisterNewTask` (can happen concurrently after snapshot), `DeleteRange` (proceeds without checking post-snapshot tasks)
- Invariant: `□(¬(twoTasksForSameRange ∧ bothProcessing))` — no two range deletions for overlapping ranges proceed simultaneously

**Priority**: **Medium**
**Rationale**: Acknowledged known gap with a `MONGO_MOD_NEEDS_REPLACEMENT` marker; the window requires specific timing (new task registration between snapshot and migration start). The `registrationTime`-based ordering in `registerTask` closes the window for tasks known at registration time, but not for post-snapshot tasks. Good TLA+ target to determine if the window is exploitable in practice.

---

### Family 4: Recovery Scan Non-Atomicity (Two-Pass Miss)

**Mechanism**: The step-up recovery scan performs two separate `DBDirectClient::find` calls. Pass 1 scans for `processing == true` tasks; Pass 2 scans for `processing != true AND pending != true` tasks. A task for which `markRangeDeletionTaskAsProcessing` is called between Pass 1 and Pass 2 is missed by both passes — not yet `processing` during Pass 1, and excluded (now `processing = true`) during Pass 2.

**Evidence**:
- Code: `range_deleter_service.cpp:220–254` — two separate `client.find(...)` calls; both run under a `ScopedRangeDeleterLock(MODE_S)` and `AutoGetCollection(MODE_S)`, but `markRangeDeletionTaskAsProcessing` (`range_deletion_util.cpp:274–296`) uses `PersistentTaskStore::update` which acquires collection lock in MODE_X; MODE_X and MODE_S conflict, meaning this race cannot occur *during* the two-pass scan if both are under the same `AutoGetCollection(MODE_S)` lock scope.
- **Refinement**: the two `client.find()` calls share the same `AutoGetCollection collRangeDeletionLock(opCtx, ..., MODE_S)` scope (line 214). This means `markRangeDeletionTaskAsProcessing` (which needs MODE_X) cannot interleave between the two scans in the same step-up term. However, a task that completed Pass 1's deletion run and called `markRangeDeletionTaskAsProcessing` before the recovery scan began could appear in neither scan if the service stepped down and the task's `processing` flag was set *after* Pass 1 completed.
- **Net assessment**: the two-pass gap is partially protected by the shared `AutoGetCollection` lock. However, it remains a theoretical concern for overlapping terms and for tasks whose `processing` flag update races with the lock-free interval between the `AutoGetCollection` scope end and the next scan's lock acquisition.

**Affected code paths**:
- `RangeDeleterService::_launchRangeDeletionRecoveryTask` (lines 200–261)
- `markRangeDeletionTaskAsProcessing` in `range_deletion_util.cpp` (lines 274–296)

**Priority**: **Low**
**Rationale**: Partially mitigated by shared lock; the race window is narrow. Better characterized as a spec-coverage target than a confirmed bug. A task missed in one term will be correctly recovered in the next step-up, so worst-case impact is one-term delay in orphan cleanup.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Two-step persistent write in `startMigration` | Family 1 — crash window causes permanent orphan skip | Split `startMigration` into `WriteCoordDoc` and `WriteRangeDeletionTask` actions; add `Crash` action between them |
| Coordinator document state (absent / present / committed / aborted) | Family 1 & 2 — decision delivery drives task activation; w:1 `forgetMigration` can replay it | Model coordinator as a durable variable with independent persistence step |
| Range deletion task document state (absent / pending / ready / processing) | All families — the pending/ready/processing state machine is the core protocol | Model as a separate persistent variable per (shard, range) pair |
| `forgetMigration` w:1 write | Family 2 — coordinator survives stepdown, recovery re-runs with missing task | Model as a non-durable write that can be rolled back on stepdown |
| Abort path `markAsReadyRangeDeletionTaskOnRecipient` failure | Family 2 — ShardNotFound propagates uncaught, recipient task stuck | Model as a `DeliverAbortToRecipient` action that can fail non-atomically |
| Recovery scan on step-up | All families — recovery must correctly re-register surviving tasks | Model `Recovery` action that reads persistent state and registers in-memory tasks, with the `pending=true` exclusion |
| Crash action | Family 1 & 2 — crash windows between sequential writes | Model `Crash` as atomic step that discards in-memory state, retains durable state |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| `deleteRangeInBatches` internal batch loop | Too low-level; correctness of the deletion loop is not in question — only whether it runs at all |
| Orphan count (`numOrphanDocs`) tracking | Best-effort metric; acknowledged to be imprecise; not a safety property |
| Query drain (`getOngoingQueriesCompletionFuture`) | Liveness concern within a term; does not affect whether deletion eventually happens |
| Recovery scan two-pass atomicity (Family 4) | Partially protected by shared lock; a missed task is recovered in the next term; low TLA+ value |
| `int8_t` overflow in `RangeDeletionRecoveryTracker` | Implementation-level overflow; not a protocol correctness issue |
| Session migration | Orthogonal subsystem; does not interact with range deletion protocol |
| Write concern details of internal operations (other than `forgetMigration` w:1) | Most writes use `defaultMajorityWriteConcernDoNotUse()`; the w:1 exception in `forgetMigration` is the only relevant deviation |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Split `startMigration` writes | `coordDocWritten`, `donorTaskWritten` | Capture crash window between two writes | Family 1 |
| Non-durable `forgetMigration` | `coordDocDurable` (bool) | Allow coordinator doc to survive stepdown/rollback | Family 1, 2 |
| Recipient shard liveness | `recipientShardAlive` (bool) | Model `ShardNotFound` failure on `markAsReadyRangeDeletionTaskOnRecipient` | Family 2 |
| Pending-flag state | `task.state ∈ {absent, pending, ready, processing}` | Track pending/ready/processing lifecycle per (shard, range) | All |
| Explicit `Recovery` action | `inMemoryTasks` rebuilt from persistent state | Model the recovery scan and its `pending=true` exclusion | Family 2 |
| Overlapping task snapshot | `overlapSnapshot : set of tasks` taken at a point in time | Model TOCTOU gap when new tasks are registered post-snapshot | Family 3 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `OrphanEventualCleanup` | Liveness | After a committed migration, the donor range deletion task is eventually activated and executed | Family 1 |
| `AbortedMigrationRecipientCleanup` | Liveness | After an aborted migration, the recipient range deletion task is eventually activated and executed | Family 2 |
| `NoPermanentPendingTask` | Liveness | No `pending: true` task remains in `pending` state indefinitely if its migration coordinator has reached a decision | Family 1, 2 |
| `NoOrphanedDocAfterForget` | Safety | After `forgetMigration` is durable (majority), the donor's range has either been deleted or is actively scheduled for deletion | Family 1 |
| `NoSimultaneousOverlappingDeletions` | Safety | No two range deletion tasks for overlapping ranges execute concurrently | Family 3 |
| `RecoveryCompleteness` | Safety | After step-up recovery, every non-pending range deletion task on disk has a corresponding in-memory registration | Family 4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Can a crash between `insertMigrationCoordinatorDoc` and `createAndPersistRangeDeletionTask` in `startMigration` cause a committed migration's donor range to never be deleted? | `OrphanEventualCleanup` — the recovery path returns `makeReady()` without scheduling deletion | Family 1 |
| MC2 | If `markAsReadyRangeDeletionTaskOnRecipient` throws `ShardNotFound` (outside the abort path's try/catch), can the recipient's range deletion task remain `pending: true` permanently even after the shard rejoins? | `AbortedMigrationRecipientCleanup` — the recipient task is never activated without a second coordinator delivery | Family 2 |
| MC3 | Can a new range deletion task for a range be registered *after* `getOverlappingRangeDeletionsFuture` returns its snapshot, allowing two deletions of the same range to proceed simultaneously? | `NoSimultaneousOverlappingDeletions` — the ordering chain misses the post-snapshot task | Family 3 |
| MC4 | After `forgetMigration` is rolled back on stepdown (w:1 write not replicated), does the recovery path correctly handle the case where the coordinator doc reappears but the range deletion task is already gone? | `NoOrphanedDocAfterForget` — recovery re-runs with no task, returns `makeReady()`, orphans persist | Family 1, 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | Verify that `markAsReadyRangeDeletionTaskOnRecipient` correctly propagates `ShardNotFound` and that the retry loop eventually unblocks when the shard rejoins | Integration test: temporarily remove recipient shard during abort, observe retry loop, re-add shard, verify task activated |
| TV2 | Verify that a `forgetMigration` w:1 write followed by stepdown causes correct idempotent re-execution on the new primary | Failover test: inject primary stepdown after `forgetMigration`, verify new primary completes migration cleanup correctly |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `_abortMigrationOnDonorAndRecipient` lines 365–375: catch block log message says "and/or marking range deletion task on recipient as ready for processing" but only wraps `advanceTransactionOnRecipient`; `markAsReadyRangeDeletionTaskOnRecipient` at line 382 is outside the try — code/intent mismatch | Extend try/catch at lines 352–375 to also wrap `markAsReadyRangeDeletionTaskOnRecipient`, or add a separate catch |
| CR2 | `forgetMigration` uses `WriteConcernOptions{1, ...}` (w:1) while all other coordinator document writes use majority — inconsistent write concern policy | Change to majority write concern, or explicitly document why w:1 is safe here |
| CR3 | `_completeTask` in `ready_range_deletions_processor.cpp` removes the task from `_rangeDeletionTasks` and fulfills the completion future BEFORE `removePersistentTask` removes the on-disk document — in-memory state says "complete" while disk state still shows the task | Reorder: remove persistent task first, then fulfill in-memory completion future (or make both atomic under service lock) |
| CR4 | `SERVER-114753` TODO: "Put all interactions with this on-disk state behind public functions in this module" — the `rangeDeletionTask` IDL struct fields are directly read/written by multiple callers | Enforce encapsulation as noted in the TODO before the MONGO_MOD_NEEDS_REPLACEMENT refactor |

---

## 7. Reference Pointers

**Key source files** (all in `src/mongo/db/s/`):
- `migration_coordinator.cpp:147–401` — startMigration (two-write init), commit/abort paths, forgetMigration
- `range_deleter_service.cpp:120–262` — step-up/step-down lifecycle, recovery scan (two-pass)
- `ready_range_deletions_processor.cpp:290–400` — batch deletion loop, completeTask before removePersistentTask
- `range_deleter_service.h:153–158` — `getOverlappingRangeDeletionsFuture` TOCTOU NB comment
- `range_deletion_task.idl` — on-disk document schema (pending, processing, whenToClean fields)
- `range_deletion_util.cpp:274–296` — `markRangeDeletionTaskAsProcessing`
- `range_deletion_util.cpp:147–170` — `createAndPersistRangeDeletionTask`

**Design documentation**:
- `src/mongo/db/s/README_migrations.md` — migration protocol overview and range deletion lifecycle description

**Relevant SERVER tickets** (from code comments):
- `SERVER-103046` — backward-compat shim for `preMigrationShardVersion` field (TODO: remove on 9.0 LTS)
- `SERVER-103838` — schema backward-incompatibility of `transfersFirstCollectionChunkToRecipient` field
- `SERVER-92531` — "Use existing clean-up infrastructure when aborting in early stages" (constructor exception path)
- `SERVER-71444` (×5) — "Fix to be interruptible or document exception" in migration source manager lock acquisitions
- `SERVER-114753` — "Put all interactions with this on-disk state behind public functions in this module"
