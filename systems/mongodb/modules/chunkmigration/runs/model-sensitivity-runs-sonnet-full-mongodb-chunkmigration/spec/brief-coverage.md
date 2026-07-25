# Brief Coverage Self-Audit

Maps brief §2 (Bug Families), §5 (Invariants), §6.1 (Model-Checkable Findings) → spec/MC artifacts.

---

## §2 Bug Families → Hunt Configs

| Family | Description | Hunt Config | Status |
|---|---|---|---|
| Family 1 | Commit decision durability vs crit-sec release ordering | `MC_hunt_family1.cfg` | Covered |
| Family 2 | Recovery kFail/kAbort guard asymmetry | `MC_hunt_family2.cfg` | Covered |
| Family 3 | Range deletion task lifecycle inconsistency | `MC_hunt_family3.cfg` | Covered |
| Family 4 | Transfer-mods MVCC staleness | Not modeled | Out of scope (brief §3.2: WiredTiger semantics not abstractable) |
| Family 5 | Non-atomic persistence / write concern | Not modeled | Out of scope (brief §3.2: idempotent re-execution is intended design; better addressed by code review) |

---

## §5 Invariants → Enabled in Hunt Configs

| Invariant | Hunt Config | Enabled? |
|---|---|---|
| `CommitDecisionDurabilityBeforeRelease` | `MC_hunt_family1.cfg` | Yes |
| `RangeDeletionConsistency` | `MC_hunt_family3.cfg` | Yes |
| `RangeDeletionConsistencyFinal` | `MC_hunt_family3.cfg` | Yes |
| `RecoveryHonorsAbort` | `MC_hunt_family2.cfg` | Yes |
| `NoOrphanAfterCommit` | `MC_hunt_family1.cfg`, `MC_hunt_family3.cfg` | Yes (both) |
| `CoordinatorDocEventuallyGone` (liveness) | Not in any hunt cfg | Liveness properties require fairness assumptions; deferred to manual TLC run with PROPERTIES after spec converges |

All safety invariants from brief §5 are enabled in at least one hunt config. The liveness property `CoordinatorDocEventuallyGone` is defined in `base.tla` but not placed in any `.cfg`; it requires weak fairness on `ForgetMigration` which needs a separate fairness-enabled spec run.

---

## §6.1 Model-Checkable Findings → Reachability

| Finding | Hunt Config | Reachable? | Notes |
|---|---|---|---|
| MC-1: No-decision early-return leaves inconsistent state | `MC_hunt_family1.cfg` | Yes | `RecoverDonorNoDecision` action models the no-decision path; `CommitDecisionDurabilityBeforeRelease` checks for `configCommitted=TRUE ∧ decision=NONE ∧ donorPhase=D_ABORTED` after crash |
| MC-2: Crash between `PersistCommitDecision` and `DeleteRecipientRangeDeletionTask` | `MC_hunt_family3.cfg` | Yes | `CrashDonor` can fire after `PersistCommitDecision` sets `coordinatorDocDecision=COMMITTED` but before `DeleteRecipientRangeDeletionTask` clears `recipientRDTask`; `RangeDeletionConsistencyFinal` catches this |
| MC-3: Concurrent abort overwrites kAbort → kEnteredCritSec via recovery | `MC_hunt_family2.cfg` | Yes | `ConcurrentAbortSignalDuringRecovery` sets `recipientAbortSignaled=TRUE`; `RecoverySetsCritSecState` then sets `recipientState=kEnteredCritSec`; `RecoveryHonorsAbort` detects the violation |
| MC-4: Early-exit at `coordinator.cpp:285-294` leaves recipient RD task alive | `MC_hunt_family3.cfg` | Yes | `RecoverDonorNoDecision` returns without running cleanup; `recipientRDTask` remains `RD_PENDING` with `coordinatorDocDecision=COMMITTED`; `RangeDeletionConsistency` catches this |

---

## Gaps and Limitations

1. **MC-4 fidelity**: The early-exit at `coordinator.cpp:285-294` (donor RD task absent on recovery → return without deleting recipient task) is approximated by `RecoverDonorNoDecision`. The spec does not distinguish the "crashed during cleanup after decision" case from "crashed before decision". A more precise model would add a `donorRDTaskGoneBeforeRecovery` variable. This is a known simplification.

2. **Family 1 crash window precision**: The spec allows `CrashDonor` to fire at any donor state. The critical window is specifically between `LaunchReleaseRecipientCritSec` and `PersistCommitDecision`. TLC will enumerate the crash in this window, but also in other positions. This is conservative (more states explored), not lossy.

3. **Liveness (`CoordinatorDocEventuallyGone`)**: Defined but not checked in hunt configs. To check: add `PROPERTIES CoordinatorDocEventuallyGone` to a copy of `MC.cfg` with fairness constraints `FAIRNESS WF_vars(ForgetMigration)`.
