# Spec Validation Changelog — crossbeam-epoch_2

## Round 1 - Trace Validation
- All 4 traces pass on first run: basic, concurrent_defer, nested_pin, repin_panic. No spec changes required.

## Round 2 - Model Checking (MC.cfg)
- BFS to depth 80, 790M distinct states explored. No errors. Spec passes all standard safety + structural invariants.

## Round 2 - Convergence
Phase 1 and Phase 2 both pass with no spec modifications. Spec converged.

## Round 3 - Bug Hunting (and incidental spec refinements)

Three Case-B abstraction gaps surfaced during hunt config runs and were fixed:

- [fix-spec] `Defer`: added `obj \notin reachable` precondition to model a contract-respecting caller. Without it, every legitimate Defer of a previously-published object trivially violated `RetireImpliesUnreachable`, masking the role of `BuggyRetire` as the explicit fault injector. (F2 hunt; trace validation re-run, all 4 traces still pass.)
- [fix-spec] `PublishObject`: now drops any previously-reclaimed retired entry for the same `obj` when republishing. Models address reuse — same abstract slot ID may belong to a fresh allocation after the previous one was destroyed. Without this, `NoUseAfterRetire` spuriously fired on legitimate re-publish following a completed reclamation. (F4 hunt; trace validation re-run, all 4 traces still pass.)
- [fix-spec] `CollectScan` + `BagDrop`: refactored so `CollectScan` atomically pops `sealedBags[1]` and stashes the items in `pcAux.bagDropItems` / `pcAux.bagDropSeal`. `BagDrop` now operates on the stashed items instead of `sealedBags[1]`. Models the implementation's atomic `try_pop_if`. Without this, two threads concurrently in `BagDrop` would race on the same head bag, eventually marking entries reclaimed without the gap-2 condition holding (`IsExpiredImpliesGap2` spuriously violated). (F5 hunt; trace validation re-run, all 4 traces still pass; MC.cfg re-run completes BFS to depth 76 with 110M distinct states, no errors.)

After each fix, traces re-validated and the relevant hunt config re-run. Final convergence run (MC.cfg post-fix) explored 110M distinct states to depth 76 with no violations.

## Round 3 - Bug Hunt Results

- F1 nested pin (`MC_hunt_F1_nested_pin.cfg`): exhaustive BFS, depth 66, no errors.
- F2 retire contract (`MC_hunt_F2_retire_contract.cfg`): `MCRetireImpliesUnreachable` fires on the injected `MCBuggyRetire` action (expected — confirms invariant detects Issue #238-class faults). Not a real bug — implementation has the retire-before-unlink fix in commit `2618830`.
- F3 SC fence (`MC_hunt_F3_sc_fence.cfg`): `MCLocalEpochBoundedByGlobal` fires after `MCSkipFence("TryAdvFence")` injection (expected — confirms SC fence is necessary for safety). Not a real bug — implementation has the SC fence at `internal.rs:447` and the cmpxchg-as-fence path at `:434-440`.
- F4 caller misuse (`MC_hunt_F4_caller_misuse.cfg`): exhaustive BFS, depth 90, 237M distinct states, no errors.
- F5 stalled advance (`MC_hunt_F5_stalled_advance.cfg`): exhaustive BFS, depth 88, 281M distinct states, no errors.
- F6 slot reuse (`MC_hunt_F6_slot_reuse.cfg`): exhaustive BFS, depth 65, no errors.

## Result
Converged in 1 round of trace validation + 1 round of MC.cfg checking + 3 incidental spec fixes during hunting. Bug hunting: 0 real bugs found across 6 family configs; F2/F3 confirm the spec correctly detects the corresponding fault classes when adversaries are enabled.
