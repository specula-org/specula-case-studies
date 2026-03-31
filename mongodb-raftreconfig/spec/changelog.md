# MongoRaftReconfig Validation Changelog

## Round 1 - Trace Validation
- [fix] CompleteDrain: removed configVersion increment — implementation only bumps configTerm during drain completion, not configVersion. (All traces)
- [fix] TraceServers: expanded from {"s1","s2","s3"} to {"s1","s2","s3","s4"} for traces involving s4.
- Validated: election_drain (8 events), basic_reconfig (20 events), force_reconfig (12 events)

## Round 1 - Model Checking
- No violations. 143M states, 15.5M distinct, depth 33, 1.5 min.

## Round 1 - Bug Hunting (initial)
- [bug] ForceReconfigQuorumOverlap: VIOLATED (2 states). Known: SERVER-47852/54746.
- [bug] ElectionSafety: VIOLATED (4 states) with force reconfig. Known: SERVER-47852/54746.
- [bug] DrainModeReconfigSafety: VIOLATED (4 states) with force reconfig. Same root cause.
- [fix-spec] GetTerm: added out-of-bounds guard (index > Len(xlog) returns 0).
- [fix-spec] NodeCommitIndex: replaced MaxCommittedIndex (global) with per-node bound Min({MaxCommittedIndex, Len(log[i])}).

## Round 2 - Trace Validation
- No regressions: all 3 traces pass.

## Round 2 - Model Checking
- No violations. 133M states, 14.4M distinct, depth 33, 3 min.

## Bug Hunting (post-convergence)
- [bug] NeverRollbackCommitted VIOLATED via force reconfig (11 states, MC_hunt_force_v2). Force reconfig creates isolated config island; committed entry rolled back when configs merge. Known: SERVER-55376.
- [bug] NeverRollbackCommitted VIOLATED via newlyAdded quorum reduction (20 states, MC_hunt_newlyadded_v2). **POTENTIALLY NEW BUG.** newlyAdded reduces effective voters to 1; committed entry with 1-node quorum rolled back after newlyAdded removal and stale-config election.
- [pass] ConfigPropagationSafety: NO violations. 207M states, 14.7M distinct (MC_hunt_heartbeat_v2).
- [pass] DrainModeReconfigSafety + NeverRollbackCommitted (no force): NO violations. 29M states (MC_hunt_drain_v3).
- [bug] ArbiterQuorumOverlap: VIOLATED in initial state (5-server, 3-arbiter config). Design limitation.

## Result
Converged in 2 rounds. Bug hunting: 4 violations found (1 potentially new).
