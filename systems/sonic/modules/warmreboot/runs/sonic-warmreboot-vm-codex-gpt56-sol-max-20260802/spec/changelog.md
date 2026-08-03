# Validation Changelog

## Round 1 - Trace Validation

- All 4 implementation traces passed; no specification changes were required.

## Round 1 - Model Checking

- [bug] `PhaseMonotonicity` / `ClearBoot`: two independent callers can both pass the non-atomic warm-flag scan and publish warm state; the older caller's unscoped `clear_boot` trap then disables the newer caller's global flags before that newer caller begins irreversible work (Case C; `output/MC_round1_bfs.out`).
- The required 30-minute continued `MC.cfg` BFS reached depth 16 with at least 19,028,937 generated / 3,161,214 distinct states. Only the recorded `PhaseMonotonicity` Case C recurred; no Case A or Case B required a spec or invariant change (`output/MC_round1_continue_suppressed.out`).

## Bug Hunting - Scenarios 1-2

- [bug] Scenario 1 / `PhaseMonotonicity`: focused `UseEpochCAS=TRUE` hunting reproduced stale owner-1 cleanup erasing owner 2's epoch-2 flags before owner 2 enters irreversible work (Case C; 13 states, `output/MC_hunt_scenario1_bfs.out`).
- [fix-spec] `CentralizeDatabase_RedisSave`: required every ASIC's swss stop to have succeeded or produced the modeled masked-failure status before SAVE, matching the source-ordered service loop before `backup_database` (Case B; supersedes the first Scenario 2 witness in `output/MC_hunt_scenario2_bfs.out`).

## Round 2 - Trace Validation

- `Trace.tla` remained syntactically valid after the service-stop ordering fix.
- All 4 implementation traces passed against the revised base specification.

## Round 2 - Model Checking

- Standard `MC.cfg` BFS reproduced the already-classified stale-cleanup `PhaseMonotonicity` Case C in 13 states (`output/MC_round2_bfs.out`).
- The required 30-minute continued BFS reached depth 17 with at least 22,006,968 generated / 3,600,086 distinct states. Only `PhaseMonotonicity` recurred; no Case A or Case B remained after the service-stop ordering fix (`output/MC_round2_continue_suppressed.out`).

## Bug Hunting - Scenarios 2-3

- [bug] Scenario 2 / `CheckpointAfterQuiescence`: after the ordering fix, forced mode can ignore orchagent freeze failure, cross the irreversible boundary, stop swss, and save a snapshot while an orch producer still has queued/in-flight work (Case C; 10 states, `output/MC_hunt_scenario2_after_stop_order_bfs.out`).
- [fix-spec] Scenario 3 / `EventualRecoveryDecision`: excluded unfair infinite stuttering by adding weak fairness for all five `MCNext` action families; removed symmetry from every hunt config that checks temporal properties, as TLC warns symmetry reduction is unsound for liveness (Case B; supersedes `output/MC_hunt_scenario3_bfs.out`).

## Round 3 - Trace Validation

- `MC.tla` remained syntactically valid after adding fairness.
- All 4 implementation traces passed after the liveness-model correction.

## Round 3 - Model Checking

- Standard `MC.cfg` BFS reproduced the same stale-cleanup `PhaseMonotonicity` Case C in 13 states (`output/MC_round3_bfs.out`).
- The required 30-minute continued BFS reached depth 17 with at least 22,234,365 generated / 3,619,217 distinct states. Only `PhaseMonotonicity` recurred; the fairness correction introduced no Case A or Case B (`output/MC_round3_continue_suppressed.out`).

## Bug Hunting - Scenarios 3-4

- [bug] Scenario 3 / `CompleteSameEpochSnapshot`: orchagent publishes READY before its ring drain, FDB changes, pipeline flush, and heartbeat freeze; the coordinator can checkpoint and later consume the dump while the modeled producer fence is incomplete (Case C; 18 states, `output/MC_hunt_scenario3_fair_bfs.out`).
- [fix-spec] Scenario 4 frame conditions: `RedisClient_SetVidAndRidMapDeleteVidToRid` and `...DeleteRidToVid` changed `applyState` while also declaring `applyVars` (which contains `applyState`) unchanged. Replaced those conflicting frames with the explicit unchanged apply fields (Case A; supersedes the warning-bearing clean result in `output/MC_hunt_scenario4_bfs.out`).

## Round 4 - Trace Validation

- `MC.tla` and `base.tla` remained syntactically valid after the APPLY frame-condition repair.
- All 4 implementation traces passed against the revised specification.

## Round 4 - Model Checking

- Standard `MC.cfg` BFS reproduced the existing admission/ownership `PhaseMonotonicity` Case C in 12 states: owner 2 overwrote the global owner/epoch before owner 1 entered irreversible work (`output/MC_round4_bfs.out`).
- The required 30-minute continued BFS reached depth 17 with at least 21,774,559 generated / 3,564,519 distinct states. Only `PhaseMonotonicity` recurred; no Case A or Case B remained after the frame-condition repair (`output/MC_round4_continue_suppressed.out`).

## Bug Hunting - Scenarios 4-6

- [no-bug] Scenario 4 completed after the frame fix with 96,798 generated / 28,130 distinct states and full diameter 43; all configured invariants and temporal properties held (`output/MC_hunt_scenario4_after_frame_fix_bfs.out`). Diameter exceeded 25, so no simulation follow-up was required.
- [bug] Scenario 5 / `IdentityMapBijective`: Redis publication deletes `VIDTORID` and `RIDTOVID` separately and then writes each reciprocal pair with separate commands, exposing a non-bijective map at a crashable cut (Case C; 25 states, `output/MC_hunt_scenario5_bfs.out`).
- [bug] Scenario 6 / `ReconciledImpliesOutputsPublished`: timeout reconciliation publishes fpmsyncd `RECONCILED` while derived routes remain only in the Redis pipeline; the explicit flush occurs afterward (Case C; 7 states, `output/MC_hunt_scenario6_bfs.out`).
- [bug] Scenario 6 / `WarmFlagSafeToClear`: after the finalizer's bounded wait expires, it clears global warm/fast flags even though fpmsyncd is only restored, orchagent remains initial, and the attempt is pending (Case C; 7 states, `output/MC_hunt_scenario6_flags_bfs.out`).
- The 30-minute continued Scenario 6 BFS reached depth 18 with at least 278,410 generated / 66,631 distinct states. Exactly the two recorded Scenario 6 safety invariants recurred; no additional invariant or temporal failure appeared (`output/MC_hunt_scenario6_continue_suppressed.out`).
