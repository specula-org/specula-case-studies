# Bug Report — crossbeam-epoch (Round 2)

## Summary

- Bug families tested: 6 (Family 1 through Family 6 per modeling-brief §2)
- Bugs found: 0 real implementation bugs
- Configs run: `MC_hunt_F1_nested_pin.cfg`, `MC_hunt_F2_retire_contract.cfg`, `MC_hunt_F3_sc_fence.cfg`, `MC_hunt_F4_caller_misuse.cfg`, `MC_hunt_F5_stalled_advance.cfg`, `MC_hunt_F6_slot_reuse.cfg`
- Spec fixes applied during hunting: 3 (Case-B abstraction gaps, see Changelog round 3)

The converged spec faithfully models crossbeam-epoch's pin/unpin/repin/defer/collect/finalize lifecycle plus the F1-F6 bug-family invariants. Trace validation passed all four harness scenarios (basic, concurrent_defer, nested_pin, repin_panic). MC.cfg with standard safety + structural invariants exhausted to depth 76 with 110M distinct states and no violations after the post-hunt fixes.

Across the six family-specific hunt configs, four (F1, F4, F5, F6) explored their state space exhaustively without invariant violations once the spec's modeling gaps were closed. The remaining two (F2, F3) terminated with the *expected* invariant violations triggered by their explicit fault-injection actions:

- **F2** triggers `MCRetireImpliesUnreachable` only via `MCBuggyRetire`, the action that intentionally retires a still-reachable object. The implementation's data-structure code (notably MS-Queue, fixed in commit `2618830`) does not exhibit this pattern.
- **F3** triggers `MCLocalEpochBoundedByGlobal` only after `MCSkipFence("TryAdvFence")`, which removes the SeqCst fence that pairs with `pin()`'s SC fence. The implementation has both fences in place (`internal.rs:239` and `:434-447`), so the violation is unreachable in a correct build.

These two outcomes confirm the invariants are sound *and* effective — they detect their target fault class precisely when the adversary fires, and never otherwise.

## Bug 1: (none — no real bug found)

No counterexample matched a Case-C classification. All invariant violations during hunting were either:
- Triggered by an explicit fault-injection action (F2 `MCBuggyRetire`, F3 `MCSkipFence`) that models a hypothetical buggy implementation, not crossbeam-epoch's actual behavior.
- Caused by a spec abstraction gap (Case B), which was patched and verified.

## Not Reproduced

| Bug Family | Config | Diameter | Distinct states | Result |
|---|---|---|---|---|
| F1 — Reentrant pin / nested-pin epoch advance | `MC_hunt_F1_nested_pin.cfg` | 66 (exhaustive BFS) | 2,640,446 | No violation. The `guardCount = 0` gate at `PinIncGuardCount` correctly suppresses local-epoch publication on nested pin; `Local::finalize`'s temporary `handle_count = 1` likewise prevents recursive finalize. |
| F2 — Retire-before-unlink lifetime mismatch | `MC_hunt_F2_retire_contract.cfg` | 16 (BFS halted at first counterexample) | 420 | Expected violation via `MCBuggyRetire(t1, o1)` — confirms `RetireImpliesUnreachable` detects Issue #238-class faults. Real bug fixed by commit `2618830`. |
| F3 — SC fence pair across pin / try_advance | `MC_hunt_F3_sc_fence.cfg` | 22 (BFS halted at first counterexample) | 28,938 | Expected violation via `MCSkipFence("TryAdvFence")` — confirms `LocalEpochBoundedByGlobal` requires the SC fence to remain. Real implementation has the fence at `internal.rs:239` and the cmpxchg-as-fence/store+fence pair in `Local::pin`. |
| F4 — Adversarial caller / Guard misuse | `MC_hunt_F4_caller_misuse.cfg` | 90 (exhaustive BFS) | 237,866,093 | No violation. Defer-that-pins (re-entry into protocol), repin_after, unprotected defer, and arbitrary nesting did not break safety. |
| F5 — Iterator stall returning stale global | `MC_hunt_F5_stalled_advance.cfg` | 88 (exhaustive BFS) | 281,694,420 | No violation. Stalled `try_advance` returning its cached global never causes premature reclamation in the (post-fix) atomic CollectScan/BagDrop model. |
| F6 — Pointer/slot reuse for retired Local nodes | `MC_hunt_F6_slot_reuse.cfg` | 65 (exhaustive BFS) | 2,629,931 | No violation. The Local lifecycle (`Live` → `Tagged` → `Free` → `Reused`) plus `objectGen` bumping does not enable ABA on the linked-list iterator. |

All hunts ran via BFS within a 30-minute timebox; F1, F4, F5, F6 reached "0 states left on queue" (full exhaustive coverage of the bounded state space), so no simulation follow-up was needed.

## Spec fixes during hunting

Three Case-B abstraction gaps were closed during this round (see `changelog.md` round 3 for full details and traces re-run after each):

1. **`Defer` precondition** — added `obj \notin reachable`. Without it, every legitimate `Defer(t, obj, kind)` of a previously published object trivially violated `RetireImpliesUnreachable`, masking the role of `BuggyRetire` as the explicit fault injector. With it, the `Defer`/`BuggyRetire` split now matches the modeling-brief intent: `Defer` models a contract-respecting caller, `BuggyRetire` models a contract-violating caller.

2. **`PublishObject` slot reuse** — now removes any previously-reclaimed retired entry for the same `obj`. Models address reuse — the same abstract Object ID can belong to a fresh allocation after the previous one was destroyed. Without it, `NoUseAfterRetire` spuriously fired on legitimate re-publish after reclamation (which an adversarial caller harness routinely exercises).

3. **`CollectScan` / `BagDrop` atomicity** — `CollectScan` now atomically pops `sealedBags[1]` and stashes its items in `pcAux.bagDropItems` / `pcAux.bagDropSeal`; `BagDrop` operates on the stashed items, not on `sealedBags[1]` directly. Models the implementation's `try_pop_if`, which atomically combines peek + condition-check + pop on the MS-Queue. Without it, two threads concurrently in `BagDrop` would race on the same head bag, eventually marking retired entries reclaimed when the gap-2 condition no longer held — spurious `IsExpiredImpliesGap2` violation.

All three are spec modeling improvements that bring the spec's atomicity / contract assumptions closer to the implementation. None of them was prompted by a real bug in crossbeam-epoch.
