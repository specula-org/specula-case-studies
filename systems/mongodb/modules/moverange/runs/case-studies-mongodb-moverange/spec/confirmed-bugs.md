# Confirmed Bug Report — mongodb-moverange

## Summary
- Total findings reviewed: 15 (9 MC-verifiable, 5 test-verifiable, 4 code-review-only, 2 MC convergence)
- Reproduced: 1
- Confirmed (code audit, reproduction failed): 2
- False positives: 5
- Historical (existing JIRA tickets, no reproduction needed): 12+
- Code quality / not bugs: 4

## Bug 1: Commit Path Missing ShardNotFound Catch — Infinite Recovery Retry

- **Source**: Code Review (MC-3 from modeling brief)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `migration_coordinator.cpp:252-255`

### Description

The commit path in `_commitMigrationOnDonorAndRecipient` calls `advanceTransactionOnRecipient` at line 252 **without** a try-catch for `ShardNotFound`. The abort path at line 361-365 **does** catch `ShardNotFound` and swallows it. This asymmetry was introduced deliberately in SERVER-46202 (Sep 2020) when the ShardRegistry was refactored — the abort path tolerates a missing recipient because the migration is being cancelled, but the commit path was left unprotected because a missing recipient during commit was considered a serious error that "should be handled by recovery."

The problem: **recovery also hits the same unhandled exception.** The recovery path goes through `refreshFilteringMetadataUntilSuccess` → `_recoverMigrationCoordinations` → `completeMigration` → `_commitMigrationOnDonorAndRecipient`. `refreshFilteringMetadataUntilSuccess` retries **all** `DBException` subclasses in an infinite loop (only exits on step-down or shutdown). So if the recipient shard is removed, recovery retries forever.

### Trigger Scenario

1. Migration shard0→shard1 commits on config server
2. Step-down on shard0 before commit side-effects complete (coordinator doc persists)
3. Shard1 removed from cluster (admin removes shard, or shard decommissioned)
4. Shard0 becomes primary → recovery runs
5. Recovery calls `advanceTransactionOnRecipient` → ShardNotFound → retry → infinite loop

### Developer Intent Evidence

- The ShardNotFound catch was added to the abort path in commit `5a1953c4ae4` (Kevin Pulo, SERVER-46202, Sep 2020)
- The commit path was deliberately left unprotected
- In SERVER-50890 (Jan 2021, Marcos Grillo), the abort-path catch was expanded to also cover `markAsReadyRangeDeletionTaskOnRecipient`, confirming the team relied on this catch
- No TODO/FIXME comments near line 252; no ticket tracking this gap

### Reproduction Test

**File**: `repro/test_bug1_commit_shardnotfound.py`

**What it does**:
1. Sets up 2-shard cluster via Docker (configsvr + shard0 + shard1 + mongos)
2. Creates sharded collection, starts moveChunk shard0→shard1
3. Uses `hangBeforeMakingCommitDecisionDurable` failpoint to pause after config commit
4. Steps down shard0, disables failpoint, removes shard1 from config.shards, stops shard1
5. Waits for shard0 step-up and monitors recovery behavior

**Reproduction Result**: **BUG TRIGGERED**

Observable evidence:
- **Coordinator doc persists indefinitely** (decision=NONE, never cleaned up)
- **24,000+ recovery retry attempts** in 30 seconds (log id 23937: "Retrying task after failed attempt", context: MigrationRecovery)
- Recovery thread stuck in `refreshFilteringMetadataUntilSuccess` with `ReadThroughCacheTimeMonotonicityViolation` error (the metadata became inconsistent after shard removal)
- The migration is **permanently hung** — requires manual deletion of the coordinator doc from `config.migrationCoordinators` to resolve

The proximate error (`ReadThroughCacheTimeMonotonicityViolation`) differs from the predicted `ShardNotFound` at `advanceTransactionOnRecipient` — the recovery gets stuck at the metadata refresh stage before even reaching the specific missing catch. This confirms that **the entire commit recovery path** does not handle recipient shard removal, not just the single function call.

### Recommendation

Add a `ShardNotFound` catch around `advanceTransactionOnRecipient` in the commit path (line 252), matching the abort path (line 365). Also consider catching `ShardNotFound` for `retrieveNumOrphansFromShard` (line 265) and `deleteRangeDeletionTaskOnRecipient` (line 278), which have the same vulnerability. The general fix: the commit path should gracefully handle a missing recipient shard, since the migration has already committed on the config server — the recipient-side cleanup becomes best-effort.

---

## Bug 2: Post-Commit Refresh Failure Missing Recovery Scheduling

- **Source**: Code Review (MC-8 from modeling brief)
- **Status**: CONFIRMED (code audit + git blame), REPRODUCTION FAILED
- **Severity**: Medium
- **Location**: `migration_source_manager.cpp:742-743`

### Description

After a successful config server commit, the post-migration metadata refresh at lines 708-711 can fail with any `DBException`. The catch block at line 723 dismisses the scoped guard and calls `_cleanup(false)` at line 743 **without** scheduling `asyncRecoverMigrationUntilSuccessOrStepDown`. The commit failure path at line 695 **does** schedule recovery.

This is a confirmed oversight, not a design decision. Git blame shows the two paths started identical (SERVER-47982, Jun 2020), then the commit failure path was progressively strengthened (SERVER-62282 added retry-until-success, SERVER-63161 made it async), while the refresh path's recovery was silently dropped (SERVER-61759 removed the "best-effort recover" call without replacement). No comments, tickets, or discussions explain the asymmetry.

### Impact

When the metadata refresh fails on a stable primary (without step-down):
1. The coordinator doc persists on disk without a decision field
2. No recovery is scheduled (unlike the commit failure path)
3. Range deletion is not triggered on the donor shard
4. Orphaned documents persist on the donor until the next failover triggers step-up recovery
5. On a highly stable primary that rarely steps down, this could persist for days or weeks

### Trigger Scenario

1. Migration commits successfully on config server
2. Post-commit metadata refresh fails (network glitch, ConflictingOperationInProgress, etc.)
3. `_cleanup(false)` runs — critical section released, but coordinator doc persists
4. Node stays primary — no recovery scheduled, orphans not cleaned up
5. Only a subsequent step-down or restart triggers recovery

### Developer Intent Evidence

- SERVER-47982 (Marcos Grillo, Jun 2020): Both paths had identical `onShardVersionMismatchNoExcept` ("Best-effort recover")
- SERVER-62282 (Antonio Fuschetto, Jan 2022): Upgraded commit failure path to `recoverMigrationUntilSuccess`, **did not touch** refresh failure path
- SERVER-63161 (Antonio Fuschetto, Feb 2022): Made recovery async, again **did not touch** refresh failure path
- SERVER-61759 (Kaloian Manassiev, Dec 2021): Removed refresh path's `onShardVersionMismatchNoExcept` and "Best-effort recover" comment entirely, leaving no recovery
- No failpoint exists to test the refresh failure path (`hangBeforePostMigrationCommitRefresh` only pauses, doesn't fail)

### Reproduction Test

**File**: `repro/test_bug2_refresh_missing_recovery.py`

**What it does**:
1. Sets up 2-shard cluster, starts moveChunk with `hangBeforePostMigrationCommitRefresh` failpoint
2. Pauses config server container to cause metadata refresh failure
3. Releases failpoint, waits for refresh failure
4. Checks if coordinator doc persists without recovery

**Reproduction Result**: **REPRODUCTION FAILED**

The metadata refresh blocks indefinitely waiting for the config server (internal retry loops with no timeout), rather than failing with an exception. Pausing the config server for 90 seconds was insufficient — the refresh waited and succeeded after the config server was unpaused. External error injection via `failCommand` also did not work (the internal commands used by the refresh path differ from the external command names).

The bug is real and clearly evidenced by the code asymmetry and git history, but the refresh path is extremely resilient to external failure injection, making black-box reproduction impractical. An internal failpoint specifically targeting the metadata refresh failure would be needed.

### Recommendation

Add `asyncRecoverMigrationUntilSuccessOrStepDown` call at line 743 (inside the refresh failure catch block), matching the commit failure path at line 695. This is a 3-line fix that aligns the two error paths.

---

## Bug 3: Non-Idempotent $inc on Orphan Count

- **Source**: Code Review (TV-3 from modeling brief)
- **Status**: CONFIRMED (code audit), REPRODUCTION FAILED
- **Severity**: Low (bookkeeping only, not safety)
- **Location**: `range_deletion_util.cpp:549`

### Description

`persistUpdatedNumOrphans` uses `$inc` to update the `numOrphanDocs` field on the range deletion task document. `$inc` is not idempotent — if recovery re-executes the commit path, the orphan count gets incremented again.

The vulnerable window in `_commitMigrationOnDonorAndRecipient`:
- Line 265: `retrieveNumOrphansFromShard` — gets count N from recipient
- Line 269: `persistUpdatedNumOrphans` — `$inc` by N on donor (count = N)
- Line 278: `deleteRangeDeletionTaskOnRecipient` — deletes task on recipient

If step-down occurs between lines 269 and 278 (after `$inc` but before recipient task deletion), recovery re-runs:
- `retrieveNumOrphansFromShard` — gets N again (task still exists on recipient)
- `persistUpdatedNumOrphans` — `$inc` by N again (count = 2N)

### Impact

The orphan count in the range deletion task document is inflated. This affects `BalancerStatsRegistry` statistics but does **not** affect data integrity or migration correctness. The actual range deletion process iterates over documents and deletes them regardless of the count — the count is bookkeeping only.

### Reproduction Test

**File**: `repro/test_bug3_orphan_double_count.py`

**What it does**:
1. Sets up 2-shard cluster, starts moveChunk with failpoint pause
2. Uses `failCommand` on recipient to fail the `delete` on `config.rangeDeletions`
3. Checks orphan count before and after recovery

**Reproduction Result**: **REPRODUCTION FAILED**

Two approaches were attempted:
1. **failCommand on shard1**: The `delete` command targeting `config.rangeDeletions` was either retried by `invokeCommandOnShardWithIdempotentRetryPolicy` or consumed by other internal operations. The moveChunk completed successfully.
2. **Failpoint timing**: The only available failpoint (`hangBeforeSendingCommitDecision`) fires BEFORE `persistUpdatedNumOrphans`, not after it. There is no failpoint in the 2-line window between `persistUpdatedNumOrphans` (line 269) and `deleteRangeDeletionTaskOnRecipient` (line 278).

The bug is confirmed by code audit ($inc is clearly not idempotent), but the narrow timing window and lack of appropriate failpoints make external reproduction impractical.

### Recommendation

Replace `$inc` with `$set` using the absolute orphan count value, or add a "last applied migration ID" field to prevent duplicate `$inc` operations. Given the low severity (bookkeeping only), this is a low-priority fix.

---

## False Positives

### FP-1: w:1 forgetMigration Ghost CoordDocs (MC convergence Finding 1)

The w:1 write concern on `forgetMigration` (line 400) allows coordinator docs to reappear after stepdown. However, ghost recovery is safe because:
- Recipient-side operations use `migrationId` filter (lines 320-322), making them no-ops for stale migrations
- `migState` checks prevent ghost recovery from running during active migrations
- Range deletion tasks are cleaned up before recovery can run

### FP-2: Asymmetric migrationId Usage (MC convergence Finding 2)

Donor-side operations use range-based matching without migrationId, while recipient-side operations use migrationId. Model checking found no scenario where this asymmetry causes a safety violation. It is a latent risk but not a current bug.

### FP-3: Abort Path Error Ordering (MC-9)

If `deleteRangeDeletionTaskLocally` (line 347) fails in the abort path, `markAsReadyRangeDeletionTaskOnRecipient` (line 382) is skipped. However, the exception propagates and recovery retries the entire abort path, which handles this correctly.

### FP-4: persistCommitDecision Swallows NoMatchingDocument (TV-1)

`persistCommitDecision` (migration_util.cpp:291) catches `NoMatchingDocument` and logs ERROR but continues. This is extremely unlikely to trigger because the coordinator doc is inserted with majority write concern during migration start. Even if triggered, recovery on step-up would re-derive the decision from the config server.

### FP-5: Recipient Recovery Fields Uninitialized (CR-3)

`restoreRecoveredMigrationState` leaves `_fromShard` etc. uninitialized. Code audit shows no recovery code path references these fields — the recovery path uses the coordinator document's fields directly.

---

## Historical Bugs (Known, No Reproduction Needed)

The following bugs from the modeling brief have existing JIRA tickets confirming them:

| Ticket | Description | Status |
|--------|-------------|--------|
| SERVER-50890 | Coordinator doc insert fails, abort retries indefinitely | Fixed |
| SERVER-32593 | Stepdown after failed config commit triggers fassert | Fixed |
| SERVER-46395 | Rapid stepdown/stepup creates duplicate range deletion tasks | Fixed |
| SERVER-89163 | Missing majority write concern before recipient critical section | Fixed |
| SERVER-62245 | Recovery assumed only one migration needed recovery | Fixed |
| SERVER-62282 | Recovery gave up after first failure | Fixed |
| SERVER-65947 | Recipient recovery fails on critical section release failure | Fixed |
| SERVER-60518 | TOCTOU: metadata cleared by concurrent rename during range deletion | Fixed |
| SERVER-119435 | Range deletion registration deadlock with service shutdown | Recent (Feb 2026) |
| SERVER-115921 | SharedPromise double-complete race between step-up and shutdown | Recent (Dec 2025) |
| SERVER-26471 | Recipient becomes donor before refreshing metadata after commit | Fixed |
| SERVER-45246 | Decision sent to recipient was not retryable | Fixed |

---

## Code Quality Issues (Not Bugs)

| ID | Description | Suggested Action |
|----|-------------|-----------------|
| CR-1 | SERVER-71444 TODO: 5 occurrences of `UninterruptibleLockGuard` | Track ticket |
| CR-2 | `_notePending`/`_forgetPending` are dead code | Remove |
| CR-4 | `fassert` on multiple coordinator docs instead of graceful handling | Consider graceful handling |
| TV-5 | Abort delayed by continuous transferMods | Performance, not safety |
