# Brief Coverage Audit

Source: `modeling-brief.md` sections 2, 5, and 6.1. This audit was filled by
reading the generated `MC*.cfg` files.

## Scenario Coverage (Brief Section 2)

| Brief scenario | Primary spec mechanisms | Targeting hunt cfg | Enabled targets |
|---|---|---|---|
| Scenario 1: Dataplane Result Generation and Speculative RIB State | `selectedFib`, `routeGen`, `routeDplaneSeq`, `ctxQueue`, `providerOut`, `resultQueue`, stale result flags | `MC_hunt_scenario1_dataplane.cfg` | `NoStaleDplaneMutation`, `SelectedFibNeedsTerminalResult` |
| Scenario 2: Route-Owner/ZAPI Notification Correlation and BGP FIB-Pending State | `ownerSubscribed`, `zapiConn`, `bgpPending`, `bgpInstalledGen`, `ownerNotifyObligation`, `notifyQueue` | `MC_hunt_scenario2_owner_notify.cfg` | `OwnerInstalledImpliesCurrentFib`, `PendingImpliesOutstandingWork`, `NotifyAppliesToMatchingGeneration` |
| Scenario 3: NHT/RNH Observes Reduced or Stale Realization State | `rnhRegistered`, `rnhAttachedDest`, `rnhSnapshot`, `nhtEvalNeeded`, `nhtSuppressed` | `MC_hunt_scenario3_nht.cfg` | `NHTResolvedImpliesConfirmedRoute`, property `RNHRegistrationEventuallyAttached` |
| Scenario 4: MetaQ, Startup, Reconnect, and Queue Ordering Reconciliation | `metaQ`, `queuedBits`, `AnyQueuedMask`, `zebraRestarted`, `ownerLocalRoutes`, replay actions | `MC_hunt_scenario4_metaq_reconnect.cfg` | `MetaQSingleVisibleMembership`, `PendingImpliesOutstandingWork`, property `ReconnectEventuallyReplays` |
| Scenario 5: Provider/NHG Boundary and Partial Dataplane Pipelines | `providerIn`, `providerOut`, `providerPrivate`, `kernelRoute`, `nhgInstalled`, skip-kernel/provider restart actions | `MC_hunt_scenario5_provider.cfg` | `ProviderSuccessImpliesRealizedAttrs`, `OwnerInstalledImpliesCurrentFib` |

## Invariant Coverage (Brief Section 5)

| Brief invariant | Type | Defined in | Wired in MC | Enabled in cfg |
|---|---|---|---|---|
| `OwnerInstalledImpliesCurrentFib` | Safety | `base.tla` | Available through `MC.tla` / `MCSpec` | `MC_hunt_scenario2_owner_notify.cfg`, `MC_hunt_scenario5_provider.cfg` |
| `NoStaleDplaneMutation` | Safety | `base.tla` | Available through `MC.tla` / `MCSpec` | `MC_hunt_scenario1_dataplane.cfg` |
| `SelectedFibNeedsTerminalResult` | Safety/Liveness safety projection | `base.tla` | Available through `MC.tla` / `MCSpec` | `MC_hunt_scenario1_dataplane.cfg` |
| `PendingImpliesOutstandingWork` | Safety | `base.tla` | Available through `MC.tla` / `MCSpec` | `MC_hunt_scenario2_owner_notify.cfg`, `MC_hunt_scenario4_metaq_reconnect.cfg` |
| `NotifyAppliesToMatchingGeneration` | Safety | `base.tla` | Available through `MC.tla` / `MCSpec` | `MC_hunt_scenario2_owner_notify.cfg` |
| `NHTResolvedImpliesConfirmedRoute` | Safety | `base.tla` | Available through `MC.tla` / `MCSpec` | `MC_hunt_scenario3_nht.cfg` |
| `RNHRegistrationEventuallyAttached` | Liveness | `base.tla` | Available through `MC.tla` / `MCSpec` | `PROPERTIES` in `MC_hunt_scenario3_nht.cfg` |
| `MetaQSingleVisibleMembership` | Safety | `base.tla` | Available through `MC.tla` / `MCSpec` | `MC_hunt_scenario4_metaq_reconnect.cfg` |
| `ReconnectEventuallyReplays` | Liveness | `base.tla` | Available through `MC.tla` / `MCSpec` | `PROPERTIES` in `MC_hunt_scenario4_metaq_reconnect.cfg` |

Additional Scenario 5 invariant:

| Invariant | Why added | Enabled in cfg |
|---|---|---|
| `ProviderSuccessImpliesRealizedAttrs` | Brief Scenario 5 asks whether provider/NHG partial success can diverge from Zebra RIB state; the brief did not name a Scenario 5 invariant in section 5. | `MC_hunt_scenario5_provider.cfg` |

## Finding Coverage (Brief Section 6.1)

| Finding | Trigger mechanism in spec | Expected target | Hunt cfg |
|---|---|---|---|
| MC1 | `DPLANE_OP_ROUTE_NOTIFY`, `rib_process_result` with `c.gen # routeGen[p]` or seq mismatch; stale flags are set when mutation proceeds. | `NoStaleDplaneMutation` | `MC_hunt_scenario1_dataplane.cfg` |
| MC2 | `dplane_update_enqueue_failure` after `rib_install_kernel` has set `selectedFib`, with no explicit `enqueueFailed` terminal state. | `SelectedFibNeedsTerminalResult`, `OwnerInstalledImpliesCurrentFib` | `MC_hunt_scenario1_dataplane.cfg`, `MC_hunt_scenario2_owner_notify.cfg` |
| MC3 | `DPLANE_OP_ROUTE_NOTIFY` creates a late generation-less notify; `bgp_zebra_route_notify_owner` applies by current prefix/table owner state. | `NotifyAppliesToMatchingGeneration`, `NoStaleDplaneMutation` | `MC_hunt_scenario2_owner_notify.cfg`, `MC_hunt_scenario1_dataplane.cfg` |
| MC4 | `bgp_zebra_route_install` sets pending before Zebra usability; `ZebraRestart` / `bgp_zebra_connected` can leave owner state waiting without replay. | `PendingImpliesOutstandingWork`, `ReconnectEventuallyReplays` | `MC_hunt_scenario2_owner_notify.cfg`, `MC_hunt_scenario4_metaq_reconnect.cfg` |
| MC5 | `zebra_add_rnh` before a covering RIB dest leaves `rnhAttachedDest[p]=FALSE`; later route add must attach/evaluate. | `RNHRegistrationEventuallyAttached` | `MC_hunt_scenario3_nht.cfg` |
| MC6 | `compare_state_suppress` models reduced NHT comparison suppressing a changed route generation; MetaQ coalescing covered by qindex/mask model. | `NHTResolvedImpliesConfirmedRoute` | `MC_hunt_scenario3_nht.cfg`, `MC_hunt_scenario4_metaq_reconnect.cfg` |

## Standard Config Check

`MC.cfg` enables only convergence checks (`MCTypeOK`, `MCStructuralOK`) and
keeps all Scenario invariants commented out, as required by the Specula
model-checking pattern. Every safety invariant from brief section 5 is enabled
in at least one hunt cfg. The liveness properties from section 5 are enabled in
the relevant targeted cfgs rather than the broad convergence cfg.
