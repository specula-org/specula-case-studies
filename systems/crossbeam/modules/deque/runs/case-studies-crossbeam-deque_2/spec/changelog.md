# Spec Validation Changelog — crossbeam-deque_2

## Round 1 - Trace Validation
- All three traces (`fifo_short.json`, `fifo_two_stealers.json`, `lifo_three_stealers.json`) passed `Trace.cfg` validation on the first run. No spec changes required.

## Round 1 - Model Checking
- MC.cfg completed with no violations: 20,565,794 states generated, 4,331,442 distinct, depth 39, no errors. Output: `output/MC_run1.out`.

## Result
Converged in 1 round (no spec modifications during validation). Proceeding to bug hunting.

## Bug Hunting
- [fix-inv] NoLostPopUnderStrongCAS: bullet-style rewrite. Original `wPC \in {...}` disjunct was nested inside the `\E pos`, making it FALSE whenever `front..(back-1)` was empty. Triggered on the transient `PushSlotWritten` state. Case A — invariant malformed (parsing precedence), not a real bug.
- Family A (`MC_hunt_familyA.cfg`): `NoUseAfterFree` under `prematureReclaim` adversary — expected fault demo, not a bug. 11-state CE in `output/MC_hunt_familyA_bfs.out`.
- Family B (`MC_hunt_familyB.cfg`): `NoDoublePop`/`NoGarbageSteal` under `relaxBackStore` adversary — expected fault demo, not a bug. 10-state CE in `output/MC_hunt_familyB_bfs.out`.
- Family C (`MC_hunt_familyC.cfg`): no violations. 13.6M states, depth 40.
- Family D (`MC_hunt_familyD.cfg`): no violations after invariant fix. 704K states, depth 33.
- Family F (`MC_hunt_familyF.cfg`): no violations. 20.7M states, depth 39.

Bug hunting summary: 0 real bugs found. 1 spec invariant repair. Two expected fault-model demonstrations (Families A, B). See `bug-report.md`.


