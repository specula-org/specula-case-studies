# Bug Report - frr

## Summary

- Scenarios tested: 5
- Bugs found: 3
- Configs run: `MC_hunt_scenario1_dataplane.cfg`, `MC_hunt_scenario2_owner_notify.cfg`, `MC_hunt_scenario3_nht.cfg`, `MC_hunt_scenario4_metaq_reconnect.cfg`, `MC_hunt_scenario5_provider.cfg`

## Bug 1: Stale normal dataplane result mutates a newer route

- **Scenario**: Scenario 5, with an NHT-facing duplicate in Scenario 3
- **Severity**: High
- **Invariant violated**: `ProviderSuccessImpliesRealizedAttrs`; duplicate: `NHTResolvedImpliesConfirmedRoute`
- **Config**: `MC_hunt_scenario5_provider.cfg`; duplicate: `MC_hunt_scenario3_nht.cfg`
- **Counterexample**: 15 states, `spec/output/MC_hunt_scenario5_provider_bfs_final2.out`; duplicate 21 states, `spec/output/MC_hunt_scenario3_nht_bfs_final3.out`

### Trace Summary

A generation-1 route is selected and submitted to the dataplane. Before its success result is processed, Zebra admits a generation-2 route for the same prefix. The old generation-1 result then returns and is matched to the current route entry, marking the generation-2 RIB route installed and setting FIB/NHT state while the kernel oracle still contains generation 1. In the Scenario 3 duplicate, this stale install also drives an RNH snapshot that later diverges from the selected FIB route.

### Root Cause

`rib_process_result()` detects sequence mismatch but only logs it; processing continues into the install success mutation path. The same stale context can set `ROUTE_ENTRY_INSTALLED`, call `rib_update_re_from_ctx()`, enqueue owner notifications, and schedule NHT evaluation even when the context sequence no longer matches the matched route entry. FRR's dataplane context has a sequence number, but the stale-result branch does not gate these later mutations on that sequence check.

### Affected Code

- `zebra/zebra_rib.c:2036`: scans current route entries to find a context match.
- `zebra/zebra_rib.c:2054`: reads the dataplane context sequence.
- `zebra/zebra_rib.c:2060`: detects `re->dplane_sequence != seq` but does not stop result processing.
- `zebra/zebra_rib.c:2101`: enters install/update success handling after the stale check.
- `zebra/zebra_rib.c:2103`: sets the matched route installed on success.
- `zebra/zebra_rib.c:2125`: updates route FIB fields from the stale context.
- `zebra/zebra_rib.c:2171`: sends route-owner install notification from the context.
- `zebra/zebra_rib.c:2260`: evaluates NHT after applying the result.

### Recommendation

Treat a sequence mismatch as a terminal stale result for normal route install/update/delete results. Drop or quarantine the context before mutating route flags, owner notifications, or NHT state, while preserving any required cleanup for the old route entry.

---

## Bug 2: Late async route notify mutates the current selected route without generation gating

- **Scenario**: Scenario 1
- **Severity**: High
- **Invariant violated**: `NoStaleDplaneMutation`
- **Config**: `MC_hunt_scenario1_dataplane.cfg`
- **Counterexample**: 11 states, `spec/output/MC_hunt_scenario1_dataplane_bfs_final2.out`

### Trace Summary

A stale async `DPLANE_OP_ROUTE_NOTIFY` for prefix `p1` is placed in the result queue before the newer generation-2 route is selected for FIB installation. When Zebra later processes the notify, it loosely matches the current route by prefix/type/instance and sees a selected FIB route. The notify clears pending route state, marks FIB nexthop state on the current route, and schedules NHT evaluation even though the notification came from an older generation.

### Root Cause

The async route notify path uses `rib_route_match_ctx(..., async=true)` and has no normal route generation or sequence guard. Once the matched route is `dest->selected_fib`, `rib_process_dplane_notify()` updates FIB/offload/NHT state directly from the notify context. Netlink/FPM route notify contexts carry route attributes such as prefix/table/type/flags, but no route generation that Zebra can use to reject stale notifications.

### Affected Code

- `zebra/zebra_rib.c:1603`: defines route/context matching helper.
- `zebra/zebra_rib.c:2310`: matches async notify contexts against current route entries.
- `zebra/zebra_rib.c:2335`: only skips selected-route updates when the matched route is not `dest->selected_fib`.
- `zebra/zebra_rib.c:2387`: updates route nexthop FIB flags from the notify context.
- `zebra/zebra_rib.c:2408`: makes notify changes visible to NHT processing.
- `zebra/dplane_fpm_nl.c:728`: creates `DPLANE_OP_ROUTE_NOTIFY` contexts from route notifications.
- `zebra/rt_netlink.c:1083`: parses route notify messages without a route generation field.

### Recommendation

Add a route identity or sequence correlation check for async route notifications, or validate that the notify still corresponds to the current selected FIB route before applying FIB/offload/NHT mutations. If route notifications cannot carry a generation, stale notifies should be limited to logging or explicit reconciliation.

---

## Bug 3: BGP suppress-fib pending can survive ZAPI route send failure with no outstanding work

- **Scenario**: Scenario 2, duplicated by Scenario 4
- **Severity**: High
- **Invariant violated**: `PendingImpliesOutstandingWork`
- **Config**: `MC_hunt_scenario2_owner_notify.cfg`; duplicate: `MC_hunt_scenario4_metaq_reconnect.cfg`
- **Counterexample**: 4 states, `spec/output/MC_hunt_scenario2_owner_notify_bfs_final2.out`; duplicate 3 states, `spec/output/MC_hunt_scenario4_metaq_reconnect_bfs_final2.out`

### Trace Summary

BGP selects a route while suppress-fib-pending is enabled and sets `BGP_NODE_FIB_INSTALL_PENDING`. The route announcement is queued for Zebra, but the later ZAPI send attempt fails. The queued install node is unlocked and freed, `BGP_NODE_SCHEDULE_FOR_INSTALL` is cleared, Zebra never admits the route, and no owner notification can arrive to clear BGP's pending state.

### Root Cause

`bgp_zebra_route_install()` marks a route as FIB-install pending before the later ZAPI route send is attempted. In `bgp_handle_route_announcements_to_zebra()`, a non-EVPN send failure is traced but the dequeued work item is still released and no retry/reconcile path is installed for the pending flag. `zclient_send_message()` can return `ZCLIENT_SEND_FAILURE` for a closed socket or buffer write error, and the BGP pending flag is normally cleared only when a route-owner notification is later received.

### Affected Code

- `bgpd/bgp_zebra.c:2061`: begins suppress-fib pending handling for route install.
- `bgpd/bgp_zebra.c:2074`: sets `BGP_NODE_FIB_INSTALL_PENDING` when the route has not previously been installed.
- `bgpd/bgp_zebra.c:2096`: creates or reuses the queued Zebra announcement inode.
- `bgpd/bgp_zebra.c:1923`: attempts the actual ZAPI route announcement.
- `bgpd/bgp_zebra.c:1937`: clears `BGP_NODE_SCHEDULE_FOR_INSTALL` after the send attempt.
- `bgpd/bgp_zebra.c:1968`: unlocks and frees the queued route announcement state.
- `lib/zclient.c:381`: returns `ZCLIENT_SEND_FAILURE` on socket or buffer write failure.
- `bgpd/bgp_zebra.c:3113`: clears pending only when BGP later consumes an installed notification.
- `bgpd/bgp_zebra.c:3153`: clears pending only when BGP later consumes a fail-install notification.

### Recommendation

On `ZCLIENT_SEND_FAILURE` for a suppress-fib-pending route announcement, either clear the pending flag with the corresponding pending counter update, requeue the announcement for reconnect, or trigger an explicit reconciliation path. The failure path must not leave BGP waiting for a Zebra owner notification that cannot be produced.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|----------|--------|-----------------|--------|
| Scenario 1 | `MC_hunt_scenario1_dataplane.cfg` | 83,121 generated / 20,803 distinct / depth 11 | Reproduced Bug 2 |
| Scenario 2 | `MC_hunt_scenario2_owner_notify.cfg` | 219 generated / 193 distinct / depth 7 | Reproduced Bug 3 |
| Scenario 3 | `MC_hunt_scenario3_nht.cfg` | 8,083,418 generated / 1,643,067 distinct / depth 22 | Duplicate reproducer for Bug 1 after one Case A invariant repair |
| Scenario 4 | `MC_hunt_scenario4_metaq_reconnect.cfg` | 192 generated / 167 distinct / depth 7 | Duplicate reproducer for Bug 3 |
| Scenario 5 | `MC_hunt_scenario5_provider.cfg` | 733,794 generated / 186,075 distinct / depth 17 | Reproduced Bug 1 |

## Spec Fixes During Hunting

- `NHTResolvedImpliesConfirmedRoute` was repaired after `MC_hunt_scenario3_nht_bfs_final2.out`: a resolved RNH snapshot may be stale while `nhtEvalNeeded[p]` is true, because FRR has already scheduled reevaluation. The repaired invariant still fails when a snapshot is stale with no pending NHT reevaluation.
