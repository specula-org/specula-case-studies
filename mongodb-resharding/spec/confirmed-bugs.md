# Confirmed Bug Report — MongoDB Resharding Coordinator

## Summary

- Total findings reviewed: 1 (MC counterexample for NoPromiseDeadlock)
- Confirmed: 0
- False positives: 1 (Case B — Spec Modeling Issue)
- Reproduced: 0

## Finding RS-1: Observer Promise Deadlock — FALSE POSITIVE (Case B)

- **Source**: MC (7-state counterexample, MC_hunt_promise.cfg)
- **Status**: FALSE POSITIVE — Spec Modeling Issue
- **Original claim**: Observer sequential promise check causes coordinator to hang forever during abort

### Why it's a false positive

The MC counterexample shows `CoordAbortMajority` atomically setting all participants to Done AND majority-committing the abort doc in a single step. The invariant `NoPromiseDeadlock` then checks that done-promises are fulfilled. They aren't, because `ObserverCheck` hasn't had a chance to run.

In the real system:
1. `_tellAllParticipantsToAbort` sends abort to participants (async)
2. Participants process abort, update coordinator doc sub-fields
3. OpObserver triggers `onReshardingParticipantTransition`
4. `_onAbortOrStepdown` has already errored first 3 promises → `stateTransistionsComplete` returns true for those (line 97-100: `isReady() → true`)
5. Sequential check reaches `_allRecipientsDone` → checks `allParticipantsInStateGTE(kDone)` → TRUE (participants are Done) → promise fulfilled
6. Same for `_allDonorsDone`
7. **Coordinator does NOT hang — promises are eventually fulfilled through subsequent observer calls**

### Spec fix needed

The spec's `CoordAbortMajority` should not atomically set participants to Done. Instead:
- `CoordAbortMajority` should only majority-commit the abort doc
- `_tellAllParticipantsToAbort` should be a separate action
- Participants should transition to Done asynchronously
- `ObserverCheck` then fulfills done-promises

Alternatively, weaken `NoPromiseDeadlock` to only check after `ObserverCheck` has had a chance to run (e.g., check in a state where both `AllParticipantsDone` AND `ObserverCheck` has been enabled at least once since abort).

### Developer evidence

- Comment at observer.cpp:176: "Don't exit early since the coordinator waits for all participants to report state 'done'" — confirms done-promises ARE expected to be fulfilled during abort
- `stateTransistionsComplete` (observer.cpp:97-100): errored promises return `isReady()=true`, allowing sequential check to proceed past them
- `_onAbortOrStepdown` errors first 3 promises → unblocks sequential check for later promises
- **No deadlock possible because**: observer is called each time coordinator doc is updated (via OpObserver), and each call re-evaluates the sequential check. Once participants reach Done and update the doc, the next observer call will fulfill done-promises.

---

## Verification Summary

| Config | States | Depth | Result |
|--------|--------|-------|--------|
| MC.cfg (convergence) | 5,821 | 23 | PASS |
| MC_hunt_failover.cfg | 86,144 | 25 | PASS |
| MC_hunt_promise.cfg | 156 | 7 | **NoPromiseDeadlock violated — Case B (spec issue)** |
| Trace validation (basic_resharding.ndjson) | 1,658 | 21 | PASS |
