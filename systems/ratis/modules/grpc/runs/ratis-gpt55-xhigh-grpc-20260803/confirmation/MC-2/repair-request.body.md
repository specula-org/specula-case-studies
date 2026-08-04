---
target: SPEC_REPAIR
counterexample: spec/output/final-MC_hunt_rg4_staging_restart-20260803-192310.out
scope:
  actions: [MCRestartAppender]
  invariants: [RestartPreservesUsefulProgress]
  hunt_cfgs: [MC_hunt_rg4_staging_restart.cfg]
  fault_actions: []
---

## Trigger

`MCRestartAppender(F2)` allows a staging-only peer to be removed and recreated as
a fresh follower, resetting useful catch-up state after snapshot progress. In the
current implementation, a peer that is only in the staging configuration is not
returned by `LeaderStateImpl.getPeer`, so `LeaderStateImpl.restart` removes the
staging appender but does not execute `addAndStartSenders` for that peer.

## Evidence

- Counterexample state 6,
  `MCSnapshotAlreadyInstalled(F2,1)`, sets F2 `attemptedSnapshot = TRUE`,
  `snapshotIndex = 1`, `matchIndex = 1`, and `nextIndex = 2` in
  `spec/output/final-MC_hunt_rg4_staging_restart-20260803-192310.out`.
- Counterexample state 8, `MCRestartAppender(F2)`, resets F2 to
  `attemptedSnapshot = FALSE`, `snapshotIndex = 0`, `matchIndex = -1`, and
  `nextIndex = 0`.
- Implementation `LeaderStateImpl.restart` calls
  `stopAndRemoveSenders(Collections.singleton(sender))`, then re-adds only
  `Optional.ofNullable(getPeer(info.getId()))` peers
  (`ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java:715-728`).
- `getPeer` reads only `server.getRaftConf().getPeer(id, FOLLOWER, LISTENER)`
  (`LeaderStateImpl.java:676-678`), while staging peers are introduced by
  `startSetConfiguration` before the old-new configuration is applied
  (`LeaderStateImpl.java:519-553`).
- The reproduction script
  `.specula-output/repro/test_bugMC-2_staging_restart_progress.sh` reached
  staging snapshot progress through public `setConfiguration`; the trace file
  `.specula-output/repro/MC-2-traces/mc2-level1-restart-after-progress.ndjson`
  records `SnapshotInstalled` with `snapshotIndex = 31`, `matchIndex = 31`,
  `nextIndex = 32`, and `attemptedSnapshot = true`.
- The same reproduction invoked `LeaderStateImpl.restart` for staging appenders,
  but surefire output reports: `restart stopped staging appenders but did not
  create replacement FollowerInfo; appenders after restart=[], RestartAppender
  events=0`.

## Proposed change

Constrain or split the model's restart action so a staging-only peer cannot take
the replacement/reinitialization branch unless that peer is present in the
current Raft configuration, matching `LeaderStateImpl.getPeer`. If the model also
needs to represent the current implementation's staging restart behavior, add a
separate branch that stops/removes the staging appender without recreating
`FollowerInfoImpl` or resetting its fields through `addAndStartSenders`.
