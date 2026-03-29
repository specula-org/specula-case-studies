# crossbeam-deque Spec Changelog

## Round 1 - Trace Validation
- [fix] TraceStealBegin/TraceBatchStealBeginFIFO/TraceBatchStealBeginLIFO: Category B concurrent replay fix — stealer begin actions now use logline.cachedFront and logline.result instead of reading front/back from current TLA+ state. Without this, stealers scheduled after worker events saw mutated state (front=8 instead of 0), causing false empty-queue detection and deadlock. (Trace: concurrent_fifo.json)

## Round 1 - Model Checking
- No violations. 8.3M states generated, 2.2M distinct, 7s BFS. All 6 invariants pass.

## Bug Hunting
- [VF-1] NoUseAfterFree violated: CVE-2021-32810 reproduction — prematureReclaim + skipRecheck enables UAF via freed buffer read (6 states, MC_hunt_family1_cve.cfg)
- [VF-2] NoUseAfterFree violated: MC-1 missing re-check at batchLIFOFirst — same prematureReclaim root cause, missing re-check not independently exploitable (6 states, MC_hunt_family1_mc1.cfg)
- [VF-3] NoUseAfterFree violated: Epoch lifecycle — prematureReclaim alone causes UAF regardless of re-check status (5 states, MC_hunt_family3.cfg)
- [pass] Family 4 FIFO rollback: No violations, 197K states exhaustive (MC_hunt_family4.cfg)

## Result
Converged in 1 round. Bug hunting: 0 new bugs found / 3 verification findings (expected fault-injection violations).
