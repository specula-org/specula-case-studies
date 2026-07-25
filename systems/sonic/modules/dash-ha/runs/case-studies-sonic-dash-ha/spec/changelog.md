# Changelog: sonic-dash-ha Spec Validation

## Round 1 - Trace Validation
- All traces passed without modification (1 trace: ha_scope_lifecycle.ndjson, 114 states)

## Round 1 - Model Checking
- Structural invariants (TypeOK, MessageWellFormed, TermNonNegative, FaultCountersOK) verified via complete BFS with MC_convergence.cfg: 5,565,331 states, 960,063 distinct, depth 66, no violations
- Partial BFS with MC.cfg (full bounds): depth 27, 806M states generated, no violations found before timeout

## Result
Converged in 1 round. No spec modifications needed.

## Bug Hunting (analytical + partial TLC)

### Election (MC_hunt_election.cfg)
- [bug] Cross-vote race: simultaneous RequestVote + ChangeDesiredState between send/receive → dual InitToActive → dual Active. Violates SingleDecisionMaker, NoDoubleActive, NoDoubleInitActive. (MC-8/MC-9 variants)
- [bug] DPU health race: oscillating DPU health → both nodes enter Standalone independently. Violates NoStandaloneStandalone.

### Lifecycle (MC_hunt_lifecycle.cfg)
- [bug] DeleteActor does not propagate to children → orphan actors persist. Violates NoOrphanActors. (MC-1, MC-2)

### Crash (MC_hunt_crash.cfg)
- [bug] CompleteInitToActive queues BulkSyncDone while in Active state → NoPendingWhileDeciding violated (Case A: invariant too strict for transient state)

### Ordering (MC_hunt_ordering.cfg)
- No violation expected — PrerequisiteRespected holds because all state transitions from Dead/Connecting require prerequisites

### Switchover (MC_hunt_switchover.cfg)
- [bug] Switchover + concurrent DPU failure → potential dual decision maker via Active + Standalone
