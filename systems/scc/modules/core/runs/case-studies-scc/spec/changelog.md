# scc Spec Validation Changelog

## Round 1 - Trace Validation

- [fix] Trace.tla: ValidatePostState/ValidatePostStateWeak changed to use primed variables (guardActive', currentArray') to match post-state trace events per instrumentation-spec
- [fix] Trace.cfg: Changed Key from model values {k1, k2} to strings {"k1", "k2"} to match JSON trace data
- [fix] Trace.cfg: Switched from SPECIFICATION to INIT/NEXT with TraceDone self-loop for deadlock-based completion checking
- [fix] Trace.tla: Added TraceDone (self-loop at l > Len(TraceLog)) and TraceNextOrDone to prevent spurious deadlock reports
- All 3 traces pass: basic_ops (7 events, 8 states), concurrent_rw (10 events), resize_rehash (9 events)

## Round 1 - Model Checking

- MC.cfg convergence: 190M states, 26.7M distinct, depth 45, 8min 46s — all 9 invariants pass
- No spec modifications needed

## Bug Hunting

- [fix-spec] base.tla: BuggyEndSyncRead replaced with BuggyReleaseLockEarly — split into separate action so UAF window is observable (accessingData=TRUE with lockHeld=NoLock)
- MC.tla: MCBuggyEndSyncRead → MCBuggyReleaseLockEarly
- Re-verified convergence: 190M states, no violations (spec change only affects bug variant paths)
- MC_hunt_F1: F1_BugDetector violated — 7-state trace, 114 states (validates known yanked-version pattern)
- MC_hunt_F2: AsyncRefValidity violated — 9-state trace, 3,915 states (validates known ABA/stale-ref pattern)
- MC_hunt_F3: No violation — 81,467 states, 9,024 distinct (resize protocol correct)
- MC_hunt_F5: F5_BugDetector violated — 8-state trace, 2,814 states (validates known premature-reclaim pattern)

## Result
Converged in 1 round. Bug hunting: 0 new bugs found; 3 known bug patterns validated via fault injection (F1, F2, F5).
