## Round 1 - Trace Validation
- [fix] Trace.cfg: limited trace validation invariants to structural checks so real traces are matched before scenario safety properties are judged; static qindex 6 and BGP send-to-Zebra pending gaps remain covered by hunt configs.
- [fix] rib_addnode: propagated the Zebra route table from RIB admission into `ribRoute[p].table` so later dataplane contexts match real FRR table 254. (Trace: static_route_realization.ndjson)
- [fix] kernel_dplane_process_func_success: matched provider terminal events against the pending input ctx before producing the success/failure output ctx, reflecting that instrumentation captures provider post-state. (Trace: static_route_realization.ndjson)
- [fix] dplane_thread_loop_result/rib_process_result: matched dataplane ctx queue handoff by ctx identity while ignoring `kernelTouched`, which is provider capture metadata not preserved by the result-visibility trace event; the queued spec ctx is still used for state updates. (Trace: static_route_realization.ndjson)
- [fix] TraceSpec: added weak fairness for `TraceNext` so TLC cannot satisfy the wrapper by stuttering forever before consuming an enabled final trace event. (Trace: static_route_realization.ndjson)
- [fix] bgp_zebra_route_notify_owner: matched BGP owner notification consumption without requiring table equality, reflecting that FRR decodes `table_id` but applies the route-owner note by BGP prefix/AFI/SAFI lookup. (Trace: bgp_suppress_fib_route_realization.ndjson)

## Round 1 - Model Checking
- MC.cfg: no invariant violations found within the 30-minute BFS budget; run reached depth 15 with 673,468,079 states generated and 168,871,229 distinct states. Output: `spec/output/MC_round1_bfs_direct.out`.

## Round 2 - Bug Hunting / Convergence Repair
- [fix-spec] rib_process_dplane_notify: classified `MC_hunt_scenario1_dataplane_bfs.out` as Case B; async route notifications in FRR clean up non-selected route flags and only update selected-FIB/offload/NHT/owner state when `re == dest->selected_fib`, and do not set `ROUTE_ENTRY_INSTALLED`. Updated the spec so a stale notify for an unselected route is not modeled as an install ack.
- [fix-spec] dplane_update_enqueue_failure: classified `MC_hunt_scenario1_dataplane_bfs_round2_single.out` as Case B; after `dplane_ctx_route_init()` succeeds, `dplane_provider_work_ready()` unconditionally returns `AOK`, so the post-ctx enqueue failure transition is not reachable in FRR.
- Trace validation: both real NDJSON traces still pass after the notify-path fix.
- MC.cfg: no invariant violations found within the 30-minute BFS budget after the notify-path fix; run reached depth 15 with 567,752,885 states generated and 133,309,469 distinct states. Output: `spec/output/MC_round2_bfs.out`.

## Round 3 - Bug Hunting / Convergence Repair
- [fix-spec] bgp_handle_route_announcements_to_zebra/rib_addnode: classified `PendingImpliesOutstandingWork` in Scenario 2/4 hunting as Case B; FRR clears BGP's scheduled-send flag after writing the ZAPI route message, while Zebra admits the route later in `rib_addnode()`. Added `zapiToZebra[p]` to model this in-transit delivery window and count it as outstanding work until Zebra admission or restart.
- Trace validation: both real NDJSON traces still pass after the ZAPI delivery-gap fix.
- MC.cfg: no invariant violations found within the 30-minute BFS budget after the ZAPI delivery-gap fix; run reached depth 17 with 568,648,243 states generated and 134,194,674 distinct states. Output: `spec/output/MC_round3_bfs.out`.
- [fix-spec] dplane_ctx_route_init: classified `ProviderSuccessImpliesRealizedAttrs` in `MC_hunt_scenario5_provider_bfs_round3.out` as Case B; FRR creates route dataplane contexts from `rib_install_kernel()` after `dest->selected_fib = re`, so the spec now requires `selectedFib[p] = submitGen[p]` before context creation.
- [fix-inv] RNHRegistrationEventuallyAttached: classified the stuttering counterexample in `MC_hunt_scenario3_nht_bfs_round3.out` as a temporal harness issue; FRR has an explicit RNH store/evaluate path, so `MCSpec` now applies weak fairness to `Pass_zebra_rnh_store_in_routing_table`.
- Trace validation: both real NDJSON traces still pass after the dataplane ordering and RNH fairness repairs.
- MC.cfg: no invariant violations found within the 30-minute BFS budget after the dataplane ordering and RNH fairness repairs; run reached depth 15 with 605,862,309 states generated and 141,640,622 distinct states. Output: `spec/output/MC_round4_bfs.out`.

## Round 4 - Bug Hunting
- [fix-inv] NHTResolvedImpliesConfirmedRoute: classified `MC_hunt_scenario3_nht_bfs_final2.out` as Case A; FRR can hold a stale-but-pending RNH snapshot while `rib_link()` has already scheduled NHT reevaluation. The invariant now requires snapshot/current-route agreement only when `nhtEvalNeeded[p]` is false.
- [bug] rib_process_result: stale normal dataplane results can log a sequence mismatch but still mark the current route installed, update FIB/NHT state, and enqueue owner notifications. Reproduced by `MC_hunt_scenario5_provider_bfs_final2.out` and as an NHT-facing duplicate in `MC_hunt_scenario3_nht_bfs_final3.out`.
- [bug] rib_process_dplane_notify: late async `DPLANE_OP_ROUTE_NOTIFY` can match the current selected route without generation gating and mutate FIB/NHT state for the wrong route generation. Reproduced by `MC_hunt_scenario1_dataplane_bfs_final2.out`.
- [bug] ZapiSendFail: BGP can keep `BGP_NODE_FIB_INSTALL_PENDING` after a route-announcement send failure even though no ZAPI add, Zebra route, dataplane work, or owner notification remains outstanding. Reproduced by `MC_hunt_scenario2_owner_notify_bfs_final2.out` and `MC_hunt_scenario4_metaq_reconnect_bfs_final2.out`.
- Trace validation after the NHT invariant repair: both real NDJSON traces pass; syntax and VAV checks pass.

## Result
Converged after 3 validation rounds (4 standard MC runs). Bug hunting: 3 bugs found.
