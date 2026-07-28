# MC-2 Investigation

## Code Audit

Finding target: late async route notify mutates the current selected route without generation gating.

Relevant implementation facts:

- `zebra/zebra_rib.c:1603` defines `rib_route_match_ctx(re, ctx, is_update, async)`. In the ordinary route case it matches only `re->type == dplane_ctx_get_type(ctx)` and `re->instance == dplane_ctx_get_instance(ctx)` for BGP routes; there is no route-generation or dataplane sequence check. The extra static distance/metric guard is skipped when `async == true` at `zebra/zebra_rib.c:1648`.
- `zebra/zebra_rib.c:2276` `rib_process_dplane_notify()` handles `DPLANE_OP_ROUTE_NOTIFY`. It locates the route node from the ctx, then loops `RNODE_FOREACH_RE` and calls `rib_route_match_ctx(re, ctx, false, true)` at `zebra/zebra_rib.c:2311`.
- Once a matching `re` is found, `rib_process_dplane_notify()` clears `ROUTE_ENTRY_QUEUED` / `ROUTE_ENTRY_ROUTE_REPLACING` at `zebra/zebra_rib.c:2327-2329`. If `re == dest->selected_fib`, it applies ctx offload flags to that selected route at `zebra/zebra_rib.c:2375-2384`, copies nexthop FIB state from the ctx via `rib_update_re_from_ctx()` at `zebra/zebra_rib.c:2390`, may send owner notification through `zsend_route_notify_owner_ctx()` at `zebra/zebra_rib.c:2400-2405`, and schedules NHT re-evaluation at `zebra/zebra_rib.c:2408-2410`.
- The ordinary dataplane result path does have a stale-result guard: `rib_process_result()` reads `dplane_ctx_get_seq(ctx)` at `zebra/zebra_rib.c:2054`, checks `re->dplane_sequence != seq` at `zebra/zebra_rib.c:2060`, and checks `old_re->dplane_sequence != dplane_ctx_get_old_seq(ctx)` at `zebra/zebra_rib.c:2090`.
- Dataplane route sequences are assigned when the route ctx is created: `zebra/zebra_dplane.c:4178-4179` sets `re->dplane_sequence` and `ctx->zd_seq`; update old-route sequences are assigned at `zebra/zebra_dplane.c:4878-4880`.
- FPM route notifications are a public async dataplane input: `zebra/dplane_fpm_nl.c:728-732` allocates a ctx, initializes it as `DPLANE_OP_ROUTE_NOTIFY`, and calls `netlink_route_notify_read_ctx()`. `zebra/rt_netlink.c:1083-1091` parses the notification with the common route parser. `zebra/rt_netlink.c:870-873` maps Linux `RTM_F_OFFLOAD` and `RTM_F_OFFLOAD_FAILED` to Zebra offload flags.
- The FPM developer documentation describes route status notification from an ASIC over the same FPM TCP socket using an FPM frame containing an `RTM_NEWROUTE` netlink message whose `rtm_flags` include `RTM_F_OFFLOAD`, `RTM_F_TRAP`, or `RTM_F_OFFLOAD_FAILED`.

Public reachability / call chain:

1. BGP enables route-owner notifications when `bgp suppress-fib-pending` is configured. `bgpd/bgpd.c:582` sends `ZEBRA_ROUTE_NOTIFY_REQUEST`; Zebra receives it in `zebra/zapi_msg.c:875-881` and sets `client->notify_owner`.
2. A protocol route from BGP reaches Zebra through normal ZAPI route add. BGP schedules route install in `bgpd/bgp_zebra.c:2042-2152`; the actual send path calls `bgp_zebra_announce_actual()` and `zclient_route_send()` at `bgpd/bgp_zebra.c:1934-1940` / `bgpd/bgp_zebra.c:1740`.
3. Zebra RIB selection submits route work to dataplane. The selected route receives a sequence in `dplane_ctx_route_init()`.
4. An external FPM implementation can delay an `RTM_NEWROUTE` offload notification for an earlier route event and later send it over the established FPM socket. Zebra accepts that as `DPLANE_OP_ROUTE_NOTIFY`.
5. `rib_process_dplane_notify()` matches the notify by prefix/type/instance and selected route, without comparing it to the current route's `dplane_sequence` or generation.
6. When Zebra runs with `--asic-offload=notify_on_offload`, `zebra_router_notify_on_ack()` is false, so `rib_process_dplane_notify()` sends `ZAPI_ROUTE_INSTALLED` to the owner on offload notification.
7. BGP consumes the owner notify in `bgpd/bgp_zebra.c:3071-3195`. For `ZAPI_ROUTE_INSTALLED`, it clears `BGP_NODE_FIB_INSTALL_PENDING`, sets `BGP_NODE_FIB_INSTALLED`, and calls `group_announce_route()` at `bgpd/bgp_zebra.c:3110-3130`. `bgpd/bgp_route.h:727-729` suppresses advertisement while the pending flag is set.

Counterexample facts from `spec/output/MC_hunt_scenario1_dataplane_bfs_final2.out` / `.json`:

- TLC violates `NoStaleDplaneMutation`.
- Action sequence: `MCbgp_zebra_route_install`, `MCrib_addnode`, `MCzread_route_notify_request`, second `MCrib_addnode`, `MCrib_meta_queue_add`, `MCDPLANE_OP_ROUTE_NOTIFY`, then meta queue / RIB processing / install.
- The stale route notify is created while `routeGen.p1 = 2` and before selected FIB reaches generation 2. Final state 11 has `staleDplaneNotifyApplied = TRUE`, `routeGen.p1 = 2`, `selectedFib.p1 = 2`, `ribRoute.p1.fibNH = TRUE`, and `nhtEvalNeeded.p1 = TRUE`.

Safeguards / masks observed during audit:

- The normal dataplane result path has sequence gates and will ignore stale kernel dataplane results.
- The async route notify path has a selected-FIB check, but that check only tests the currently selected `route_entry *`; it does not prove the notification belongs to that route's current generation.
- NHT has some additional logic around installed/active routes, so NHT client harm is not assumed without reproduction. The owner-notify consumer is direct: BGP updates its FIB pending/installed state from the notify.

## Developer Knowledge Search

Issue / PR search performed against `FRRouting/frr` through GitHub search:

- `repo:FRRouting/frr "rib_process_dplane_notify"` returned PRs #22221, #12708, #8849, #5452, and #5546.
- `repo:FRRouting/frr "DPLANE_OP_ROUTE_NOTIFY" stale` returned 0 results.
- `repo:FRRouting/frr "route notify" offload stale zebra_rib` returned 0 results.
- `repo:FRRouting/frr "suppress-fib-pending" "offload" "route notify"` returned issue #13587.

Relevant non-duplicate precedents:

- https://github.com/FRRouting/frr/pull/5452 says dataplane route notification processing was off-target after nexthop-group rework and should better understand route status changes. It does not report stale late notifications or a missing generation/sequence gate.
- https://github.com/FRRouting/frr/pull/5546 makes route changes via the notify path trigger NHT. It is about missing NHT processing, not stale matching.
- https://github.com/FRRouting/frr/pull/12708 discusses NHT state sent to protocols after dplane notifications and the `notify_on_ack` wall. It does not report a late-notify mutation of the current selected route.
- https://github.com/FRRouting/frr/pull/22221 changes RNH evaluation for queued and not-installed route nodes. It is adjacent NHT behavior, not stale FPM route notify matching.
- https://github.com/FRRouting/frr/issues/13587 reports IPv6 routes not advertised with `--asic-offload=notify_on_offload`; it does not describe a stale route notification from an older generation mutating a newer selected route.

Git history / blame:

- `rib_process_dplane_notify()` originated in `54818e3b017` ("zebra: begin dataplane notifications").
- The async match call at `zebra/zebra_rib.c:2311` is from `d0123a90120` ("zebra: Static routes async notification do not need this test"), which made async static matching skip the distance/metric test. It did not add generation gating.
- Owner notification from the offload notify path is in `06525c4f99d` ("zebra: Add `zrouter.asic_notification_nexthop_control`").
- FPM route notify input was added by `a8d5b5d014` ("zebra: Read from the dplane_fpm_nl a route update").

## Known Status

No public upstream issue or recently closed/merged PR found that reports this exact mechanism at this site: a late `DPLANE_OP_ROUTE_NOTIFY` matched by prefix/type/instance mutating the current `dest->selected_fib` without generation or sequence gating and causing owner/NHT state to reflect a stale offload notification.

Known-status evidence supports recording novelty as `NEW` unless reproduction uncovers a more specific already-fixed report.
