# Tarantool Raft Spec Changelog

## Round 1 - Trace Validation
- basic_election.ndjson: PASS (249 states). No spec modifications needed.

## Round 1 - Model Checking
- MC.cfg structural invariants (8 invariants):
  - BFS: 1.65B states at depth 17 (no complete — state space too large), 0 violations
  - Simulation: 823M states across 32.6M traces, 0 violations
- [fix-cfg] Removed SYMMETRY ModelSymmetry (Server uses integers, not model values)
- [fix-cfg] Added counter bounds for NotifyLeaderSeen (NotifyLimit) and BroadcastRaftState (BroadcastLimit) to control state space
- [fix-cfg] Reduced MaxMsgBuffer from 12 to 6
- No base spec modifications needed

## Result
Converged in 1 round. Bug hunting: 1 confirmed finding (Family 1 liveness), 1 Case A (Family 4), 2 clean (Families 2 & 3).

## Bug Hunting

### MC_hunt_witness.cfg (Family 1)
- [finding] WitnessMapAccuracy violated: 18-state counterexample via ReceiveMessage. Stale witness bit from resigned leader's broadcast blocks elections. (10M states, 22s BFS)
- [fix-spec] Restricted standalone NotifyLeaderSeen in MCNext to FALSE only (external callers replica_on_disconnect, replica_update_applier_health only pass false). TRUE path is already modeled inside ReceiveMessage.

### MC_hunt_wal.cfg (Family 2)
- PromoteNotDuringWrite violated (same as Family 4 hunt). Case A — implementation handles gracefully at raft_start_candidate:1144.
- ElectionSafety, WalWriteSafety, NotWritingWhenLeader: PASS (32 states, complete BFS)

### MC_hunt_persistence.cfg (Family 3)
- ElectionSafety, OneVotePerTerm, NoStaleVoteAfterCrash, VoteConsistency, LeaderHasVotedForSelf: PASS (230M states, 10min BFS depth 12, no violation)

### MC_hunt_promote.cfg (Family 4)
- [case-a] PromoteNotDuringWrite violated: 3-state counterexample. raft_promote called during WAL write. Implementation handles gracefully — raft_start_candidate checks is_write_in_progress at line 1144 and does nothing. Invariant too strong.
