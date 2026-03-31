# Changelog: MongoDB RaftMongoReplTimestamp Spec Validation

## Round 1 - Trace Validation
- [fix] Trace.tla: Complete rewrite using state-replay approach for sparse log-parsed traces
  - Traces only capture control-plane events (elections, term updates, commit points, recovery)
  - OpTime indices use MongoDB Timestamp.increment (not oplog positions), can't be validated
  - TraceUpdateTerm: direct term update with no-op for initialization events
  - TraceBecomePrimary: direct state update (spec models atomic election, traces show individual term updates)
  - TraceStepdown: uses base spec when Leader, no-op when Follower (mid-session traces)
  - TraceLearnCommitPoint/TraceAdvanceCommitPoint: no-ops (commitPoint values not validatable)
  - TraceRollbackOplog: no-op (oplog state not tracked)
  - Recovery events: use base spec actions (work with empty logs)
  - SilentSetupCrash: transitions node to Down+truncate for traces starting mid-recovery
  - All ValidatePostState replaced with ValidatePostStateWeak (term + state only)
  - TLC evaluation order: UNCHANGED vars must precede primed-variable checks
- Traces validated: basic_consensus (7 states), stepdown (15 states), crash_recovery (15 states), full_trace (43 states)

## Round 1 - Model Checking
- [fix-spec] Crash: committedSnapshot is volatile (_currentCommittedSnapshot) but was preserved across crashes (UNCHANGED). Fix: reset to NilOpTime on crash. CommittedSnapshotNeverRollback violated in 15-state trace — recovery recalculates CS below pre-crash value. (Case B)
- After fix: BFS explored 829M states (depth 19, no violations), simulation explored 6.6M traces / 592M states (no violations). All 6 invariants pass.

## Round 2 - Trace Validation
- All 4 traces re-validated after Crash fix. No regressions. SilentSetupCrash updated to match Crash's committedSnapshot reset.

## Round 2 - Model Checking
- No re-run needed (Round 2 trace validation required no spec changes).

## Convergence
Converged in 2 rounds. Spec modification: Crash resets committedSnapshot (volatile state). BFS depth 19 + simulation 6.6M traces, no violations.

## Bug Hunting
- [bug] MRT-1 (Bug Family 2): LastDurableImpliesInOplog violated — journal flusher TOCTOU (SERVER-50949). 9-state trace, 3s BFS. Flusher captures lastApplied, rollback truncates log, flusher sets lastDurable beyond log.
- [bug] MRT-2 (Bug Family 3): AcknowledgedWriteNeverRolledBack violated — write concern loss on stepdown (SERVER-113256). 15-state trace, 6m45s BFS. WC waiter survives rollback, satisfied by higher-term committedSnapshot at same index.
- Bug Family 1 (Holes): PASS — 370M+ states, depth 22, no violations.
- Bug Family 5 (Recovery): PASS — 398M+ states, depth 26, no violations.

## Result
Converged in 2 rounds. Bug hunting: 2 bugs found (MRT-1: flusher TOCTOU, MRT-2: WC loss).
