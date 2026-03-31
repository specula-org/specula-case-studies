# Bug Report — MongoDB Resharding Coordinator

## Summary

- Bug families tested: 2 (failover, promise deadlock)
- Bugs found: 1
- Configs run: MC.cfg (convergence), MC_hunt_failover.cfg, MC_hunt_promise.cfg

---

## Bug RS-1: Observer Promise Deadlock on Early Abort

- **Bug Family**: 2 — Observer Promise Deadlock
- **Severity**: High
- **Invariant violated**: NoPromiseDeadlock
- **Config**: MC_hunt_promise.cfg (MaxCrash=1, MaxAbort=1, MaxParticipantError=1)
- **Counterexample**: 7 states, 156 states explored
- **Possibly corresponds to**: SERVER-120917 (2026-03, "Resharding hangs in cloning phase")

### Counterexample Trace

| State | Action | coordState | coordDocDurable | donors | recipients | promDonorsReady | promDonorsDone |
|-------|--------|-----------|-----------------|--------|-----------|-----------------|----------------|
| 1 | Init | CUnused(0) | FALSE | D_none | R_none | pending | pending |
| 2 | CoordInitialize | CInitializing(1) | FALSE | D_none | R_none | pending | pending |
| 3 | CoordInitializeMajority | CInitializing(1) | TRUE | D_none | R_none | pending | pending |
| 4 | CoordPrepare | CPreparingToDonate(2) | FALSE | D_none | R_none | pending | pending |
| 5 | **CoordAbortRequest** | CPreparingToDonate(2) | FALSE | D_none | R_none | pending | pending |
| 6 | CoordAbortPersist | CAborting(7) | FALSE | D_none | R_none | pending | pending |
| 7 | CoordAbortMajority | CAborting(7) | TRUE | **D_done** | **R_done** | **pending** | **pending** |

### Root Cause

The coordinator aborts at kPreparingToDonate before `CoordPrepareMajority` runs (which is responsible for writing participant entries into the coordinator doc and notifying participants). The abort path:

1. Coordinator enters kAborting, persists abort doc with majority
2. `_tellAllParticipantsToAbort` sends abort to all participants
3. Participants receive abort and transition to Done, updating coordinator doc's `donorShards`/`recipientShards` sub-fields
4. OpObserver triggers `onReshardingParticipantTransition`
5. Observer checks sequential promises starting from `_allDonorsReportedMinFetchTimestamp`

**The deadlock occurs because:**
- `allParticipantsInStateGTE` returns FALSE when `participants.size() == 0` (observer.cpp:76-78)
- If coordinator doc's `donorShards` array was never populated (because abort happened before kPreparingToDonate was majority-committed and flushed), the array is empty
- Sequential check returns FALSE at the first promise → early return at line 183
- Done promises (`_allRecipientsDone`, `_allDonorsDone`) are never checked
- `_onAbortOrStepdown` (line 274-286) only errors the first 3 promises, NOT the done promises
- `_awaitAllParticipantShardsDone` (coordinator.inl:1793-1795) waits on done-promise futures
- **Result: coordinator blocks forever in `_onAbortCoordinatorAndParticipants`**

### Code Evidence

1. **observer.cpp:76-78** — empty participants array returns false:
   ```cpp
   if (participants.size() == 0) {
       return false;
   }
   ```

2. **observer.cpp:179-183** — sequential check early return:
   ```cpp
   if (!stateTransistionsComplete(lk, _allDonorsReportedMinFetchTimestamp,
                                   DonorStateEnum::kDonatingInitialData, updatedStateDoc)) {
       return;  // Done promises never reached
   }
   ```

3. **observer.cpp:274-286** — `_onAbortOrStepdown` only errors first 3 promises:
   ```cpp
   void _onAbortOrStepdown(WithLock, Status status) {
       // Sets error on _allDonorsReportedMinFetchTimestamp,
       //                _allRecipientsFinishedCloning,
       //                _allRecipientsReportedStrictConsistencyTimestamp
       // Does NOT set error on _allRecipientsDone or _allDonorsDone
   }
   ```

4. **coordinator.inl:865** — invariant allows this path:
   ```cpp
   invariant(_coordinatorDoc.getState() >= CoordinatorStateEnum::kPreparingToDonate);
   // kPreparingToDonate is allowed — but participants may not be populated yet
   ```

5. **coordinator.inl:895-896** — waits on done-promise futures:
   ```cpp
   return future_util::withCancellation(
       _awaitAllParticipantShardsDone(executor), _ctHolder->getStepdownToken());
   ```

### Trigger Scenario

1. User initiates `reshardCollection` command
2. Coordinator creates doc (kInitializing), then transitions to kPreparingToDonate
3. Before majority-commit + participant notification, an external abort fires (user abort, critical section timeout, or admin intervention)
4. Coordinator enters `_onAbortCoordinatorAndParticipants` (invariant at line 865 passes because state >= kPreparingToDonate)
5. Abort doc is persisted and majority-committed
6. `_tellAllParticipantsToAbort` sends abort to participants
7. Participants process abort and update coordinator doc's sub-fields
8. Observer's `onReshardingParticipantTransition` fires but sequential check blocks on empty donorShards array
9. **Coordinator hangs forever waiting for done-promise futures**

### Mitigation

The only escape is a step-down, which calls `interrupt()` (observer.cpp:238-248) — this errors ALL promises including done-promises. On step-up, recovery restarts the abort flow and may succeed if participant entries are now populated.

### Recommendation

Either:
1. `_onAbortOrStepdown` should also error `_allRecipientsDone` and `_allDonorsDone` promises (matching `interrupt()` behavior)
2. Or `_onAbortCoordinatorAndParticipants` should check if participants are populated before calling `_awaitAllParticipantShardsDone`, and use `_onAbortCoordinatorOnly` if they're not

---

## Not Reproduced

| Bug Family | Config | States | Depth | Invariants | Result |
|------------|--------|--------|-------|------------|--------|
| Family 1: Failover | MC_hunt_failover.cfg | 86,144 | 25 | NoCommitAfterAbort, AbortDecisionSurvivesFailover | PASS |

### Convergence

| Config | States | Depth | Invariants | Result |
|--------|--------|-------|------------|--------|
| MC.cfg (0 faults) | 5,821 | 23 | CoordStateValid, NoCommitAfterAbort, PostCommitNoAbort, DAOConsistency | PASS |

### Trace Validation

| Trace | Events | States | Result |
|-------|--------|--------|--------|
| basic_resharding.ndjson | 9 | 1,658 | PASS |
