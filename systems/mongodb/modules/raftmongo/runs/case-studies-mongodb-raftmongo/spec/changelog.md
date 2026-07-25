## Round 1 - Trace Validation
- [fix] Parser: `newCommitPoint` typo → `newCommittedOpTime` in handle_advance_commit_point (log ID 6795400 commit points were zero)
- [fix] Parser: Added `_ts` (seconds) field to optime parsing for correct normalization across timestamp boundaries
- [fix] Parser: 21337 state-only handler now extracts lastDurable from `opTime` attr (was missing, defaulted to zero)
- [fix] Parser: Added `newCommittedOpTime` to update_state_from_attrs commit point keys
- [fix] Parser: Two-pass optime normalization — maps MongoDB (term, sec, inc) to sequential indices per term

Traces validated: full_trace (196 states), basic_consensus (pass)
Mid-stream sub-traces (stepdown_election, write_concern) fail due to Init state mismatch — expected, covered by full_trace.

## Round 1 - Model Checking
- No spec or invariant changes needed
- BFS MC_small.cfg: 89M states, 7.7M distinct, all 11 invariants pass (2.5 min)
- Simulation MC.cfg: 329M states, 12.7M traces, no violations (killed after ~10 min)

## Result
Converged in 1 round. No spec modifications needed during convergence.

## Bug Hunting
- [expected-violation] NeverRollbackCommitted with WriteConcernMajorityShouldJournal=FALSE: 12-state counterexample (MC_hunt_nojournal.cfg, BFS 5s). Documented behavior — with journal disabled, committed entries can be lost after crash+re-election. Case A: invariant too strong for non-journal config.
- [no-violation] CommitPointOnCorrectBranch + NeverRollbackCommitted with MaxCrashes=2: 569M states explored (BFS, killed). No violation found.
- [no-violation] NeverRollbackCommitted at 5 servers: 198M states, 3.2M simulation traces. No SERVER-39626 reproduction at these bounds.
