# RedisRaft Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] TraceNext: added termination self-loop (`l > Len(TraceLog) => UNCHANGED`) to prevent false deadlock reports at trace completion (all 3 traces: basic_consensus, leader_failover, snapshot_basic)

## Round 1 - Model Checking
- [fix-spec] ClientNonQuorumRead: added parentheses around `staleReadDetected' = (... \/ ...)` and `noopReadDetected' = (... \/ ...)` — TLA+ precedence caused `\/` to bind looser than `=`, leaving variables unconstrained (Case B)
- [fix-inv] LeaderAppendOnlyProp: added `logOffset'[i] = logOffset[i]` guard to exclude snapshot compaction from append-only check — TakeSnapshot legitimately removes compacted entries from physical log (Case A)
- MC convergence run: 202M states, 37M distinct, depth 14, 14 min — 0 violations (killed by timeout, BFS incomplete)

## Convergence
- Round 2 trace validation: all 3 traces pass (no regressions from spec changes)
- Converged in 1 round (spec changes from MC didn't break traces)

## Bug Hunting
- [bug] SnapshotLogConsistency: crash between begin_load_snapshot and end_load_snapshot leaves logOffset > snapshotLastIdx gap (MC_hunt_snapshot.cfg, 13-state counterexample)
- [bug] NoReadBeforeNoOp: non-quorum read served before leader's noop committed (MC_hunt_staleread.cfg, 7-state counterexample)
- Membership (135M states): no violation
- Crash recovery (64M states): no violation

## Result
Converged in 1 round. Bug hunting: 2 bugs found (snapshot crash window, read before noop).
