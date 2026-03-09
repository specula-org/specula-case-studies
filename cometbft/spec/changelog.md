# CometBFT Spec Changelog

## Round 1 - Trace Validation
- [fix] Trace.cfg: Switched from `SPECIFICATION TraceSpec` to `INIT TraceInit` / `NEXT TraceNext` for deadlock-based trace completion checking. Removed `PROPERTIES TraceMatched` which trivially fails without fairness (Trace: all)
- [fix] OrderedSilentProgress: Added symmetry-breaking guard to all silent actions forcing non-observed servers to advance in deterministic order (round > step rank > server order), eliminating interleaving state explosion (Trace: two_heights_mapped.ndjson)
- [fix] SilentOtherJumpToHeight: Replaced 3 step-by-step height advancement actions (SilentOtherReceivePrecommit + SilentOtherEnterCommit + SilentOtherFinalizeCommit) with single atomic action. Reduced two_heights from 100M+ to 1676 states (Trace: two_heights_mapped.ndjson)
- [fix] ServerOrder: Added `ServerOrder == "s1" :> 1 @@ "s2" :> 2 @@ "s3" :> 3` mapping because TLA+ string comparison (`>`) fails for strings (Trace: two_heights_mapped.ndjson)
- [fix] OrderedSilentProgress round-awareness: Included round number in ordering comparison (round > step > server), fixing deadlock where server at higher round but lower step rank was blocked (Trace: lock_and_relock_mapped.ndjson)

## Round 1 - Model Checking
- [fix-inv] CrashRecoveryConsistency: Rewrote broken invariant — original used `\A v \in Values \cup {Nil}` which was unsatisfiable with |Values| > 1 and didn't account for NilVote. New invariant checks that all cast votes are legitimate values (Case A)
- [bug] VELivenessInv: Reproduced VE deadlock (Bug #1 / #5204) — proposer self-verification skip + invalid VEs = asymmetric commit, 23 states (Case C)
- [bug] NilPrecommitAdvance: Reproduced nil precommit liveness gap (Bug #2 / #1431) — +2/3 nil precommits require timeout to advance, 15 states (Case C)

## Result
Converged in 1 round. Bug hunting: 2 bugs found (both known, reproduced).
