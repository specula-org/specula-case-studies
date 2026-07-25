# MongoDB Chunk Migration — Bug Report

**Target**: mongodb-chunkmigration  
**Model checking run date**: 2026-06-07  
**Spec**: `spec/base.tla` / `spec/MC.tla`  
**TLC runs**: `MC.cfg`, `MC_hunt_family1.cfg`, `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`  
**State space**: 89–218 distinct states per config (exhaustively explored)  

---

## Summary

| Bug ID | Severity | Category | Invariant Violated | Status |
|--------|----------|----------|--------------------|--------|
| BUG-1 | High | Race condition / Crash recovery | `CommitDecisionDurabilityBeforeRelease` | CONFIRMED |
| BUG-2 | High | Missing guard / State machine corruption | `RecoveryHonorsAbort` | CONFIRMED |

Two real bugs (Case C) were confirmed by TLC model checking. Both were found by the targeted hunt configs after eliminating two spec modeling issues (Case A, Case B) through spec refinement.

---

## BUG-1: Async Critical-Section Release Before Commit Decision Persist

### Summary

The donor coordinator fires an async RPC to release the recipient's critical section (`launchReleaseRecipientCriticalSection`, coordinator.cpp:204–206) **before** persisting the commit decision to the coordinator document (`persistCommitDecision`, coordinator.cpp:240). A donor crash in this window leaves the migration in an irrecoverable inconsistent state: the config server has committed the chunk transfer (chunk ownership now on recipient) and the recipient's critical section has been released (data accessible), but the coordinator document has no durable decision. On recovery, `completeMigration()` finds no decision and returns early (coordinator.cpp:186–196) without finalizing anything, effectively abandoning the migration.

### Root Cause

**`coordinator.cpp`, lines 204–240**

```cpp
// Line 204-206: async RPC launched FIRST — before any decision is durable
if (!_releaseRecipientCriticalSectionFuture) {
    launchReleaseRecipientCriticalSection(opCtx);
}
// ... (line 211: VectorClock wait) ...
// Line 215-221: switch on decision
switch (*decision) {
    case DecisionEnum::kCommitted:
        cleanupCompleteFuture = _commitMigrationOnDonorAndRecipient(opCtx);  // line 221
        // Inside: persistCommitDecision() at line 240 — called AFTER the RPC above
```

The abort path correctly persists the abort decision **before** waiting for the crit-sec release (line 334 before line 338). The commit path has the reversed ordering.

### Counterexample (11 steps, `MC_hunt_family1.cfg`)

| Step | Action | Key State Change |
|------|--------|-----------------|
| 1 | Initial | All variables at initial values |
| 2 | StartClone | donorPhase=D_CLONING, coordinatorDocPresent=TRUE, donorRDTask=PENDING |
| 3 | RecipientBeginClone | recipientState=kCloning, recipientRDTask=PENDING, recipientRecoveryDocPresent=TRUE |
| 4 | RecipientEnterCriticalSection | recipientState=kEnteredCritSec |
| 5 | StartRecipientRecovery | recipientInRecovery=TRUE (concurrent) |
| 6 | DonorEnterCriticalSection | donorPhase=D_CRITSEC |
| 7 | CommitChunkMigrationOnConfigServer | **configCommitted=TRUE** |
| 8 | LaunchReleaseRecipientCritSec | **critSecReleaseRPCSent=TRUE** (async RPC fired) |
| 9 | RecipientReleaseCritSec | **recipientCritSecReleased=TRUE** (crit sec released) |
| 10 | CrashDonor | donorCrashed=TRUE, donorPhase=D_INIT, coordinatorDocDecision=NONE ← **crash in the window** |
| 11 | RecoverDonorNoDecision | donorCrashed=FALSE, **donorPhase=D_ABORTED**, coordinatorDocDecision=NONE ← **VIOLATION** |

**Violating state (step 11)**:
- `recipientCritSecReleased = TRUE` — crit sec released, chunk accessible on recipient
- `donorCrashed = FALSE` — donor recovered
- `donorPhase = D_ABORTED` — recovery took no-decision early-return path
- `coordinatorDocDecision = NONE` — no durable commit decision ever written
- `configCommitted = TRUE` — config server records chunk as owned by recipient

**Invariant check**: `CommitDecisionDurabilityBeforeRelease` (base.tla:484–491) forbids exactly this state: `recipientCritSecReleased=TRUE ∧ donorCrashed=FALSE ∧ donorPhase=D_ABORTED ∧ coordinatorDocDecision=NONE ∧ configCommitted=TRUE`.

### Impact

After recovery, the migration coordinator considers the migration aborted (`donorPhase=D_ABORTED`) but the config server records the chunk as committed to the recipient. The system reaches a split-brain state:
- Recipient believes it owns the chunk (config says so) and data is accessible
- Donor considers the migration aborted, leaving its range deletion task ready to delete

This can lead to data loss if the donor's range deletion task fires and deletes documents that now legitimately belong to the recipient.

### Affected Code

- **Primary**: `src/mongo/db/s/migration_coordinator.cpp`, `MigrationCoordinator::completeMigration()`, lines 204–240
- The fix is to persist the commit decision **before** (or atomically with) launching the async crit-sec release RPC, matching the ordering used by the abort path.

---

## BUG-2: Recovery Path Missing kAbort/kFail Guard

### Summary

The recipient's recovery code path (`_migrateDriver` with `skipToCritSecTaken=true`, `migration_destination_manager.cpp:1927–1930`) unconditionally sets `_state = kEnteredCritSec` without checking whether `_state == kAbort` or `_state == kFail`. The normal (non-recovery) path at line 1899 correctly guards this transition with `if (_state != kFail && _state != kAbort)`. A concurrent `abort()` call that sets `_state = kAbort` before the recovery thread reaches line 1929 is silently overwritten, causing the recipient to proceed into the critical section despite an in-progress abort signal.

### Root Cause

**`migration_destination_manager.cpp`, lines 1896–1931**

```cpp
// Normal path (line 1896-1903): CORRECT — guard present
{
    stdx::lock_guard<stdx::mutex> sl(_mutex);
    if (_state != kFail && _state != kAbort) {    // ← guard prevents overwrite
        _state = kEnteredCritSec;
        _stateChangedCV.notify_all();
    }
}
// ...
// Recovery path (line 1927-1931): BUG — guard ABSENT
{
    stdx::lock_guard<stdx::mutex> sl(_mutex);
    _state = kEnteredCritSec;                     // ← unconditional, overwrites kAbort
    _stateChangedCV.notify_all();
}
```

### Counterexample (6 steps, `MC_hunt_family2.cfg`)

| Step | Action | Key State Change |
|------|--------|-----------------|
| 1 | Initial | All variables at initial values |
| 2 | StartClone | donorPhase=D_CLONING, coordinatorDocPresent=TRUE |
| 3 | RecipientBeginClone | recipientState=kCloning, recipientRecoveryDocPresent=TRUE |
| 4 | StartRecipientRecovery | **recipientInRecovery=TRUE** |
| 5 | ConcurrentAbortSignal | **recipientAbortSignaled=TRUE**, recipientState=kAbort |
| 6 | RecoverySetsCritSecState | **recipientState=kEnteredCritSec** (overwrites kAbort!) ← **VIOLATION** |

**Violating state (step 6)**:
- `recipientAbortSignaled = TRUE` — abort was signaled before recovery completed
- `recipientInRecovery = FALSE` — recovery completed (line 1929 ran)
- `recipientState = kEnteredCritSec` — abort signal was silently discarded

**Invariant check**: `RecoveryHonorsAbort` (base.tla:514–517) forbids this state: `recipientAbortSignaled=TRUE ∧ recipientInRecovery=FALSE ∧ recipientState=kEnteredCritSec`.

### Impact

The recipient proceeds to hold the critical section (`kEnteredCritSec`) while an abort has been signaled. Depending on what the abort represents:
- The recipient may expose data under a critical section it should not be holding
- The abort flow and crit-sec release flow may conflict, leading to an inconsistent metadata state
- Downstream steps that check for `kAbort` to suppress critical-section operations will be bypassed

### Affected Code

- **Primary**: `src/mongo/db/s/migration_destination_manager.cpp`, `_migrateDriver()`, lines 1927–1930  
- The fix is to add the same `if (_state != kFail && _state != kAbort)` guard that the normal path has at line 1899.

---

## Spec Refinements Applied

Two issues were found in the spec (not implementation bugs) and corrected before the final model checking run:

### Case A: `CoordDocConsistency` Invariant Too Strong

The original invariant did not allow for a donor crash **after** `ForgetMigration`. A crash after `ForgetMigration` is valid: `donorPhase` resets to `D_INIT` (volatile), but `coordinatorDocPresent=FALSE` and `coordinatorDocDecision!=NONE` is correct because the doc was already deleted. Fix: added `∧ ~donorCrashed` to the invariant's antecedent.

**File**: `spec/base.tla`, `CoordDocConsistency`

### Case B: `PersistAbortDecision` / `CommitChunkMigrationOnConfigServer` Missing Mutual-Exclusivity Guards

The spec allowed sequencing that cannot happen in the real implementation:
- `CommitChunkMigrationOnConfigServer` → `PersistAbortDecision` (config commit then abort decision)
- `PersistAbortDecision` → `CommitChunkMigrationOnConfigServer` (abort decision then config commit)

In the real coordinator, the migration decision (commit or abort) is set by `migration_source_manager.cpp` based on the config commit outcome; the two paths are exclusive.

Fix:
- Added `~configCommitted` to `PersistAbortDecision`
- Added `coordinatorDocDecision = NONE` to `CommitChunkMigrationOnConfigServer`

**File**: `spec/base.tla`, `PersistAbortDecision` and `CommitChunkMigrationOnConfigServer`

---

## Spec Modeling Gap (Not a Bug)

**Pre-existing deadlocks (2 per config)**: The spec is missing an action to delete the recipient recovery document (`recipientRecoveryDocPresent`) after migration cleanup. Without this, `StartRecipientRecovery` can fire indefinitely after `RecoverySetsCritSecState`, cycling until fault injection tokens are exhausted and `recipientState=kEnteredCritSec` blocks `RecoverySetsCritSecState` from firing again — leaving `recipientInRecovery=TRUE` with no action to advance it. This is a spec modeling gap (not an implementation bug); the recipient recovery document is cleaned up in the real system during migration finalization.

---

## Model Checking Statistics

| Config | States (distinct) | Violations Found | Final |
|--------|--------------------|-----------------|-------|
| `MC.cfg` (base) | 218 | 0 invariants, 2 deadlocks | Clean |
| `MC_hunt_family1.cfg` | 107 | 2 × CommitDecisionDurabilityBeforeRelease, 2 deadlocks | BUG-1 confirmed |
| `MC_hunt_family2.cfg` | 89 | 17 × RecoveryHonorsAbort, 2 deadlocks | BUG-2 confirmed |
| `MC_hunt_family3.cfg` | 107 | 0 invariants, 2 deadlocks | Clean |

*After 3 rounds of spec refinement (r1: parse fix, r2: CoordDocConsistency + PersistAbortDecision, r3: CommitChunkMigrationOnConfigServer).*
