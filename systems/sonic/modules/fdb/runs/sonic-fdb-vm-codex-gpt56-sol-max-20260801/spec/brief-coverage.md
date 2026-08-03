# Modeling Brief Coverage Audit: SONiC FDB

This is the mandatory Phase 2.5 self-audit for `modeling-brief.md`. It was
filled from the active `INVARIANTS` and `PROPERTIES` lines in the actual hunt
configs, not from intended coverage. The broad `MC.cfg` deliberately keeps all
scenario extensions commented out and checks only standard/structural rules.

## Brief §2 scenarios

| Scenario | Base mechanisms/actions | Targeting hunt config(s) | Status |
|---|---|---|---|
| 1. Flush Is a Multi-Stage Protocol | `FdbOrchFlushFDBEntriesRequest`, `FdbOrchFlushFdbByVlanRequest`, `SaiFlushSuccess`, `SaiFlushFailure`, `SaiEnqueueFlushAck`, `SaiDuplicateFlushAck`, `FdbOrchHandleSyncdFlushNotif`, `FdbOrchStoreFdbEntryState`, bridge-port removal/recreation | `MC_hunt_scenario_1_flush.cfg`; narrow MC1/MC6 configs | Covered |
| 2. Events Lack an Entry Incarnation | `SaiLearnEvent`, `SaiMoveEvent`, `SaiAgeEvent`, split counter/store/observer handler, `FdbOrchNotificationRepairFailure` | `MC_hunt_scenario_2_incarnation.cfg`; `MC_hunt_mc2_stale_age.cfg` | Covered |
| 3. Deferred Work Is Not Latest-Intent State | `FdbOrchSubmitSet`, `FdbOrchSubmitDelete`, `FdbOrchUpdateVlanMemberDependencyAppears`, `FdbOrchUpdateVlanMemberReplay`, split SAI/store completion, consume-without-apply | `MC_hunt_scenario_3_deferred.cfg` | Covered |
| 4. Tunnel/NHG Graph Mutations Are Non-Atomic | group/member/BP creation, `L2NhgUpdateVtepIp*` remove/create/failure/retry stages, `FdbOrchAddNhgReference`, ignored remote-VNI SAI failure | `MC_hunt_scenario_4_nhg_graph.cfg`; `MC_hunt_mc4_vtep_replacement.cfg`; shared MC6 topology config | Covered |
| 5. Restart Reconstruction Misses One-Shot Inputs | `FdbSyncCrash`, `KernelNhgChangeWhileDown`, `FdbSyncStart`, `FdbSyncDumpKernelNhg`, config/warm replay/bake/reconcile, optional live event | `MC_hunt_scenario_5_restart.cfg` | Covered |

## Brief §5 proposed invariants

Every safety invariant is defined in `base.tla`, inherited by `MC.tla`, and
enabled in at least one hunt config. The two liveness properties are also
listed because the brief's model-checkable findings explicitly use them,
although liveness is not generally required by this audit.

| Invariant | Type | Defined | Wired through MC | Enabled in actual config(s) |
|---|---|---|---|---|
| `UniqueEffectiveDestination` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_2_incarnation.cfg`, `MC_hunt_scenario_3_deferred.cfg` |
| `DependencyBeforeReference` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_3_deferred.cfg`, `MC_hunt_scenario_4_nhg_graph.cfg` |
| `StaleEventCannotDeleteNewer` | Safety | `base.tla` | inherited by `MC.tla` | scenario 1/2 configs, `MC_hunt_mc1_stale_flush.cfg`, `MC_hunt_mc2_stale_age.cfg` |
| `FlushAckMatchesRequest` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_1_flush.cfg`, `MC_hunt_mc1_stale_flush.cfg` |
| `CounterAgreement` | Safety | `base.tla` | inherited by `MC.tla` | scenario 1/2 configs, `MC_hunt_mc6_topology_reuse.cfg` |
| `LatestDesiredWins` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_3_deferred.cfg` |
| `ActiveNhgHasMember` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_4_nhg_graph.cfg`, `MC_hunt_mc4_vtep_replacement.cfg` |
| `TunnelRefExact` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_4_nhg_graph.cfg`, `MC_hunt_mc4_vtep_replacement.cfg` |
| `NoDanglingTopologyReference` | Safety | `base.tla` | inherited by `MC.tla` | scenario 1/4 configs, `MC_hunt_mc6_topology_reuse.cfg` |
| `FailedWorkRetainsRetryIntent` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_2_incarnation.cfg` |
| `RestartConverges` | Liveness | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_5_restart.cfg` (`PROPERTIES`) |
| `CompletedFlushConverges` | Liveness | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_1_flush.cfg` (`PROPERTIES`) |

## Brief §6.1 model-checkable findings

| Finding | Reachable trigger setup in config | Expected checked property | Targeting config | Audit result |
|---|---|---|---|---|
| MC1: overlapping flushes bracket relearn; old ack arrives after new pending mark | `MCSpecMC1`; two FDB events, two standard all-scope requests, two independent ack IDs; SAI/handler steps unbounded | `StaleEventCannotDeleteNewer`, `FlushAckMatchesRequest` | `MC_hunt_mc1_stale_flush.cfg` | Reachable; TLC observed `FlushAckMatchesRequest` violation |
| MC2: delayed AGE(A) after destination moves to B | three FDB events, two ports, three event IDs; repair-failure injection disabled so stale deletion is isolated | `StaleEventCannotDeleteNewer` | `MC_hunt_mc2_stale_age.cfg` | Reachable; TLC observed violation |
| MC3: SET(A), SET(B), DEL, then readiness/replay | three intent inputs and one dependency wakeup; replay/SAI/cache stages unbounded | `LatestDesiredWins` | `MC_hunt_scenario_3_deferred.cfg` | Reachable; TLC observed violation |
| MC4: VTEP replacement across incremental group mutation/failure | one group creation, one FDB reference, one replacement, one create-failure allowance; remove/create/retry unbounded | `ActiveNhgHasMember`, `TunnelRefExact` | `MC_hunt_mc4_vtep_replacement.cfg` | Reachable; TLC observed `TunnelRefExact` violation; failure/retry path remains enabled for active-empty state |
| MC5: kernel NHG changes while down; dump precedes NVO; no later live event | one crash, one kernel change, zero live-event repairs; start/dump/config/replay/bake/reconcile unbounded | `RestartConverges` | `MC_hunt_scenario_5_restart.cfg` | Reachable; TLC observed temporal violation |
| MC6: FDB exists while BP removal/flush failure/recreation overlap | one FDB event, two topology inputs, one flush failure; topology flush/SAI remove reactive | `NoDanglingTopologyReference`, `CounterAgreement` | `MC_hunt_mc6_topology_reuse.cfg` | Reachable; TLC observed `NoDanglingTopologyReference` violation |

## Audit conclusion

There are no silent §2/§5-safety/§6.1 coverage gaps. Each scenario has a
targeting scenario config, every proposed safety invariant is actively enabled
in at least one hunt config, and each model-checkable finding has a config whose
bounds preserve its trigger. The narrow MC1/MC2/MC4/MC6 configs are explicit
supplements, not scenario mergers; they prevent an earlier invariant from
masking the named finding.
