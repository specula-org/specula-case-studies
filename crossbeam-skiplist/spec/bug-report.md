# Bug Report — crossbeam-skiplist

## Summary

- Bug families tested: 3 (F1: Ref Count Lifecycle, F2: Concurrent Insert/Remove Linearizability, F4: Tower Marking Protocol)
- Bugs found: 0
- Configs run: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family4.cfg

## Not Reproduced

| Bug Family | Config | BFS States (depth) | Sim States (traces) | Result |
|------------|--------|--------------------|---------------------|--------|
| F1 — Ref Count Lifecycle | MC_hunt_family1.cfg | 750M (depth 22) | 1.39B (13.5M traces) | No violation |
| F2 — Linearizability (MarkBeforeCAS=TRUE) | MC_hunt_family2.cfg | 742M (depth 21) | 2.84B (26.8M traces) | No violation |
| F4 — Tower Marking Protocol | MC_hunt_family4.cfg | 691M (depth 20) | 2.16B (20.4M traces) | No violation |

### Notes on Bug Family F2

The F2 config sets `MarkBeforeCASFlag = TRUE` to inject the bug #1023 pattern (marking the old node before the CAS that replaces it). However, the spec models this by atomically updating `listMap` alongside the mark, keeping the abstract state consistent. The `InsertGetConsistency` invariant checks that keys in `listMap` have corresponding live nodes — since `listMap` is updated when the mark happens, the invariant is trivially satisfied. A stronger invariant that models the "key should be accessible to concurrent readers during replace" would be needed to catch this bug class.

### Notes on Bug Family F3 (Iterator)

F3 (Iterator Exhaustion, bug #1142) is modeled in the base spec (`ExhaustedStaysExhausted` invariant, `IterNext` buggy path) but not checked during hunting because the spec intentionally models the buggy behavior (to confirm the bug exists). Checking `ExhaustedStaysExhausted` against the buggy model would trivially violate it — this is by design.

## Convergence Summary

The spec converged in 2 rounds:
- Round 1 Trace Validation: 4 fixes (stuttering clause, inverted invariant, ValidateBuildLevel tid, StringToNat multi-digit)
- Round 1 Model Checking: 3 fixes (tEntry guard, PhysicalLinks split, RefCountCorrect bounds)
- Round 2 Trace Validation: no regressions

Convergence MC run: 1.5B states, 360M distinct, depth 21, 30 min BFS — all 8 invariants pass (HeadNodeAlive, ListSorted, MarkingOrderTopDown, RefCountCorrect, NoUseAfterFinalize, InsertGetConsistency, RemoveLinearizability, Level0Authoritative).
