# Validation Changelog

## Round 1 - Trace Validation

- No fixes required: all four implementation traces passed structural validation, strong post-state validation, and `TraceMatched`.

## Round 1 - Model Checking

- No fixes required: `MC.cfg` completed with no violations (54,946 generated states; 2,033 distinct states; diameter 15).

## Bug Hunting

- [fix-spec] `MCSpec` / `MCSpecMC1`: added an explicit quiescent select-loop transition so TLC deadlock checking does not classify finite-input terminal states as system deadlocks (Case B; original outputs: `output/MC_hunt_mc1_stale_flush_bfs.out`, `output/MC_hunt_scenario_3_deferred_bfs.out`, and `output/MC_hunt_scenario_5_restart_bfs.out`).

## Round 2 - Trace Validation

- No regressions: all four implementation traces passed after the MC-wrapper fix.

## Round 2 - Model Checking

- No further fixes required: `MC.cfg` completed with no violations (56,979 generated states; 2,033 distinct states; diameter 15).

## Bug-Hunting Fidelity Refinement

- [fix-inv] `LatestDesiredWins`: stopped treating replay of an older but value-identical SET generation as unsafe; the oracle still rejects replay after DELETE or to a destination different from the latest SET (Case A; original output: `output/MC_hunt_scenario_3_deferred_bfs_caseb_fixed.out`).
- [fix-spec] `FdbOrchFlushFDBEntriesRequest` / `FdbOrchFlushFdbByVlanRequest`: require the serialized FdbOrch transaction to be idle, preventing a flush call from interleaving between store and observer delivery (Case B).
- [fix-spec] `L2NhgUpdateVtepIpBegin`: require an idle FdbOrch transaction and stable matching NHGs, matching the synchronous completion of `addL2NextHopGroupEntry` before another consumer item is dispatched (Case B).
- [fix-spec] `FdbOrchNotificationRepairFailure`: require an existing cache entry, matching the implementation guard before AGE/MOVE repair mutation paths (Case B).

## Round 3 - Trace Validation

- No regressions: all four implementation traces passed after the invariant and fidelity refinements.

## Round 3 - Model Checking

- No further fixes required: `MC.cfg` completed with no violations (49,811 generated states; 1,942 distinct states; diameter 15).

## Bug-Hunting Fidelity Refinement II

- [fix-spec] FdbOrchAddNhgReference: disallow dispatch while a synchronous L2-NHG VTEP replacement is active, matching the serialized orchagent consumer loop (Case B).
- [fix-spec] FdbSyncProcessCfgEvpnNvo: require the startup GETNEXTHOP dump to be observed before CONFIG_DB processing, preventing an unconstrained skip of the source-ordered dump (Case B; superseded output: output/MC_hunt_scenario_5_restart_bfs_caseb_fixed.out).

## Round 4 - Trace Validation

- No regressions: all four implementation traces passed structural validation, strong post-state validation, and TraceMatched after the final fidelity refinements.

## Round 4 - Model Checking

- No further fixes required: MC.cfg completed with no violations and deadlock checking enabled (45,092 generated states; 1,786 distinct states; diameter 15).

## Final Bug Hunting

- [bug] FlushAckMatchesRequest: an epoch-1 acknowledgement consumed an entry carrying the epoch-2 pending marker (MC_hunt_mc1_stale_flush.cfg).
- [bug] StaleEventCannotDeleteNewer: an AGE event for generation 1 deleted software generation 2 while the newer ASIC entry remained (MC_hunt_mc2_stale_age.cfg).
- [bug] TunnelRefExact: VTEP replacement installed the new member but incremented the old endpoint reference (MC_hunt_mc4_vtep_replacement.cfg; independently reproduced by MC_hunt_scenario_4_nhg_graph.cfg).
- [bug] NoDanglingTopologyReference: bridge-port removal completed after its FDB flush failed, leaving an ASIC FDB reference to the removed generation (MC_hunt_mc6_topology_reuse.cfg; independently reproduced by MC_hunt_scenario_1_flush.cfg).
- [bug] UniqueEffectiveDestination: a failed notification repair was consumed without retry or compensation, leaving software generation 1 and hardware generation 2 (MC_hunt_scenario_2_incarnation.cfg).
- [bug] LatestDesiredWins: deferred replay applied an obsolete SET to p1 while the latest desired SET to p2 remained queued (MC_hunt_scenario_3_deferred.cfg).
- [bug] RestartConverges: the startup NHG dump was filtered before NVO readiness and warm replay could not reconstruct it (MC_hunt_scenario_5_restart.cfg).

## Repair Round 1 - Scoped Repairs

- [fix-inv] `FlushAckMatchesRequest` (RR-001): replaced unsupported callback-epoch equality with execution-time flush coverage. Added `flushRemoved` audit state so a successful removal of generation n covers only cached incarnations at or before n; scope and type checks remain mandatory.
- [fix-inv] `StaleEventCannotDeleteNewer` / `MC_hunt_mc1_stale_flush.cfg` (RR-001): scoped the generic stale-event predicate to non-flush deletions and removed it from the flush-only hunt because a FLUSHED callback has no incarnation token; the AGE-specific hunt still checks that invariant independently.
- [fix-spec] `FdbOrchNotificationRepairFailure` / notification commit (RR-002): added cache-origin state, limited MOVE repair failure to MCLAG-origin entries whose bridge port changes, retained the MOVE event as the continuation owner, and modeled same-port local duplicates without replacing the implementation's pending flag.
- [fix-spec] `FdbOrchMclagAdvertise` / `MCFdbOrchMclagAdvertise` (RR-002): added the ready MCLAG input path and its bounded counter/config constants so the real repair branch remains reachable.

## Repair Round 1 - Final Trace Validation

- No regressions: `flush_failure`, `learn_age`, `mac_move`, and `vlan_flush` all passed structural validation, strong post-state validation, and `TraceMatched` (`output/repair_final_trace_*.out`).

## Repair Round 1 - Final Model Checking

- `MC.cfg` completed with no violation or deadlock (50,813 generated states; 1,943 distinct states; diameter 13; `output/repair_final_MC_bfs.out`).
- [bug] `FlushAckMatchesRequest`: after a successful generation-1 flush, a same-port generation-2 relearn retained the pending boolean and a delayed callback deleted software generation 2 while ASIC/kernel retained it (`output/repair_final_RR001_mc1_bfs.out`).
- [bug] `FailedWorkRetainsRetryIntent`: a failed MCLAG remote AGE recreation returned with software present, hardware absent, and no retry or compensation owner (`output/repair_final_MC_hunt_scenario_2_incarnation_bfs.out`).
- The other seven hunt configurations reproduced the five previously indexed roots; all final outputs are saved as `output/repair_final_MC_hunt_*_bfs.out`.

## Result

Repair requests RR-001 and RR-002 consumed after a complete conformance pass. Seven distinct current model-checking violations remain in `findings.json`; the two repaired artifacts were removed from the report and replaced only where the repaired model produced a different implementation-backed violation.

## Repair Round 2 - RR-003 Spec Repair

- [fix-spec] `FdbOrchMclagAdvertise`: separated the logical software `dynamic` row from the installed SAI `static` row, matching `fdborch.cpp:2035-2058` and the static-only `ALLOW_MAC_MOVE` contract.
- [fix-spec] `SaiAgeEvent`: required the installed ASIC entry to be dynamic, so ordinary switch aging cannot remove the current static-plus-allow-move MCLAG row.
- [fix-spec] `SaiLearnEvent` / `SaiMoveEvent` / `FdbOrchUpdateStart`: preserved installed static type at raw notification delivery and moved the source's static-to-dynamic conversion to the guarded same-port LEARN or changed-port MOVE handler step.
- [fix-spec] remote/static AGE disposition: added `FdbOrchNotificationRepairComplete`, excluded recreate-and-return cases from destructive AGE cleanup, treated an implementation-visible matching ASIC row as compensation, and retained a queued LEARN/MOVE as continuation ownership. Ghost generation is not used for SAI duplicate-create equivalence because neither the implementation nor the SAI FDB key carries it.
- [fix-doc] `instrumentation-spec.md`: documented plane-relative type, aging eligibility, repair completion, compensation, and continuation capture.

## Repair Round 2 - Full Trace Validation

- Structural gate passed for all 4 traces / 29 events.
- `learn_age`, `mac_move`, `vlan_flush`, and `flush_failure` each completed with no error under mandatory post-state validation and `TraceMatched` (`output/repair_RR003_trace_*.out`).
- Final replay state counts were 13/11, 14/11, 10/8, and 4/3 generated/distinct respectively.

## Repair Round 2 - Model Checking and Hunting

- `MC.cfg` completed with no violation or deadlock: 56,211 generated states, 1,949 distinct states, diameter 15 (`output/repair_RR003_MC_bfs.out`).
- All nine supplied `MC_hunt_*.cfg` files were rerun with deadlock checking and 30-minute bounds. They reproduced the seven current roots indexed in `findings.json`: `FlushAckMatchesRequest`, `StaleEventCannotDeleteNewer`, `TunnelRefExact`, `NoDanglingTopologyReference`, `UniqueEffectiveDestination`, `LatestDesiredWins`, and `RestartConverges`.
- The scoped scenario-2 hunt no longer reaches the source-impossible remote AGE recreation failure. Its shortest result is a distinct delayed-LEARN path: a generation-1 LEARN replaces newer same-port MCLAG ownership, makes the ASIC row dynamic, and publishes local ownership (`output/repair_RR003_MC_hunt_scenario_2_incarnation_bfs.out`).
- A diagnostic rerun with `MaxRepairFailureLimit = 0` reproduced the same `UniqueEffectiveDestination` result in 9 states, proving the revised MC-5 does not depend on repair-failure injection (`output/repair_RR003_MC_hunt_scenario_2_no_repair_failure_bfs.out`). No confirmation was run.

## Repair Round 2 - Result

RR-003 consumed after the complete conformance pass. The cited remote-aging artifact is absent, and `findings.json` contains the seven current deduplicated model-checking violations, with MC-5 revised only to the distinct implementation-backed stale-LEARN result produced by the repaired model.
