## Round 1 - Trace Validation
- All 4 traces passed validation on first run, no spec modifications needed.
  - sequential.ndjson — pass
  - slow_reader_overlap.ndjson — pass
  - nested_enters.ndjson — pass
  - try_publish.ndjson — pass

## Round 1 - Model Checking
- MC.cfg passed with 0 violations: 318897 distinct states, depth 54, completed in 14s. No spec modifications.

## Result
Converged in 1 round (no modifications needed in either phase). Proceeding to bug hunting.

## Bug Hunting
- [bug] F1 take_inner stale-snapshot UAF: MCStaleSnapshotIsCaught violated at depth 20 in MC_hunt_F1_uaf.cfg (16-state counterexample). Confirms PR #144 finding.
- [verify] F1 PR #144 fix: MC_hunt_F1_uaf_fixed.cfg passes (depth 78, 13.7M distinct states) with ApplyPR144Fix=TRUE; the WriterTakeInnerResnapshot action closes the race.
- [bug] F2 reentrant enter() panic: MCNoUnreachablePanic violated at depth 20 in MC_hunt_F2_panic.cfg (16-state counterexample). New finding (not yet upstream).
- [verify] F3 liveness: MC_hunt_F3_liveness.cfg violates EventualPublish without fairness; MC_hunt_F3_liveness_fair.cfg holds with WF on ClientHoldGuardRelease — confirms the documented reader contract.
- [verify] F4 per-reader snap consistency: MC_hunt_F4_snap.cfg passes (depth 72, 11.2M distinct states); the per-reader snap split is sound.

## Bug Hunting Result
2 real bugs found (F1 UAF, F2 panic), 1 documented liveness contract verified (F3), 1 abstraction sanity-check passed (F4). Full report in spec/bug-report.md.
