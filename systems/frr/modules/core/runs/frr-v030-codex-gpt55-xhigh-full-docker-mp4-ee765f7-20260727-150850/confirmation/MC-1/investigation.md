# MC-1 Investigation

## Code Audit

Finding: stale normal dataplane success can be matched to a newer route entry.

Cited location:
- `zebra/zebra_rib.c:1984` defines `rib_process_result()`, the main-thread handler for completed dataplane route operations.
- `zebra/zebra_rib.c:2036-2052` finds `re` and optional `old_re` by `rib_route_match_ctx()`.
- `zebra/zebra_rib.c:1603-1665` shows `rib_route_match_ctx()` matches normal BGP routes by route type and instance. It does not require the dataplane sequence to match.
- `zebra/zebra_rib.c:2054-2067` reads `seq = dplane_ctx_get_seq(ctx)` and logs "Stale dplane result for re" when `re->dplane_sequence != seq`, but execution continues.
- `zebra/zebra_rib.c:2101-2155` handles route install/update success. If `re` is non-null, it clears `ROUTE_ENTRY_FAILED`, sets `ROUTE_ENTRY_INSTALLED`, calls `rib_update_re_from_ctx()`, stores `re->nhe_installed_id`, updates import-table state, and redistributes if selected.
- `zebra/zebra_rib.c:2171-2176` sends `ZAPI_ROUTE_INSTALLED` using the dataplane context when notify-on-ack is enabled.
- `zebra/zebra_rib.c:2260` calls `zebra_rib_evaluate_rn_nexthops(rn, seq, rt_delete)` after the result path, even for the stale case.

Dataplane sequence producer and call chain:
- `zebra/zebra_dplane.c:4175-4179` assigns `re->dplane_sequence = zebra_router_get_next_sequence()` and copies it into `ctx->zd_seq`.
- `zebra/zebra_dplane.c:4856-4880` creates route update contexts and assigns `old_re->dplane_sequence` for update operations with a distinct old route.
- `zebra/zebra_dplane.c:8248-8421` moves contexts through providers and enqueues completed results back to the Zebra main thread.
- `zebra/zebra_rib.c:5178-5257` drains completed dataplane results; route install/update/delete contexts with `notif_provider == 0` call `rib_process_result()`.

Reachability through normal operation:
- `doc/developer/zebra.rst:168-172` documents that Zebra programs the kernel through a dataplane pthread.
- `doc/developer/zebra.rst:239-243` documents that netlink responses are matched to requests and then set status on dataplane context objects.
- BGP route installs reach Zebra through `bgpd/bgp_zebra.c:2094`, which traces `bgp_zebra_route_install()` before queueing the Zebra announcement.
- Zebra owner notifications reach BGP through `zebra/zapi_msg.c:769-837` and `zebra/zapi_msg.c:858-872`.
- BGP consumes `ZAPI_ROUTE_INSTALLED` in `bgpd/bgp_zebra.c:3071-3195`; specifically `bgpd/bgp_zebra.c:3110-3130` clears `BGP_NODE_FIB_INSTALL_PENDING`, sets `BGP_NODE_FIB_INSTALLED`, and calls `group_announce_route()`.

Safeguards observed:
- The sequence mismatch is detected in `zebra/zebra_rib.c:2060`, but the handler only logs and proceeds to the success, notification, and NHT-evaluation paths.
- `bgpd/bgp_route.h:721-729` suppresses advertisement while `BGP_NODE_FIB_INSTALL_PENDING` is set, but `bgpd/bgp_zebra.c:3110-3130` clears that flag on `ZAPI_ROUTE_INSTALLED`.
- `zebra dplane limit` can reduce provider work per cycle but does not reject stale contexts.

Concrete trigger scenario from code and counterexample:
1. BGP selects prefix `p1` and sends a route add to Zebra.
2. Zebra creates route generation 1, selects it for FIB, assigns dataplane sequence 1, and enqueues a normal kernel install context.
3. Before the dataplane result is processed by the Zebra main thread, BGP selects a newer route for the same prefix/type/instance. Zebra creates generation 2 and assigns a newer dataplane sequence.
4. The generation-1 dataplane success returns. `rib_process_result()` matches the current generation-2 route entry by route type/instance, detects `re->dplane_sequence != ctx->seq`, logs it, and still enters the install success path.
5. Zebra marks the current route installed and notifies the BGP owner using the stale context, so BGP observes `ZAPI_ROUTE_INSTALLED` for a route whose current selected attributes/nexthop are not the ones the kernel success realized.

Counterexample evidence:
- State 9, `<Pass_dplane_ctx_route_init(p1)>`: creates ctx id 1 for generation 1 with attrs 1 and seq 1.
- State 10, `<MCrib_addnode(p1,bgp0,0)>`: before ctx id 1 returns, `routeGen(p1)` becomes 2 and `ribRoute(p1).attrs` becomes 0.
- State 13: provider success for ctx id 1 updates `kernelRoute(p1)` to generation 1 attrs 1.
- State 15: processing that result sets `ribRoute(p1).installed = TRUE` and `fibNH = TRUE` while `ribRoute(p1).gen = 2`, `ribRoute(p1).attrs = 0`, and `kernelRoute(p1)` remains generation 1 attrs 1. `staleResultApplied = TRUE`, and the owner notification obligation has `causeGen = 1`.

## Developer Knowledge Search

Blame/comments:
- `zebra/zebra_rib.c:2056-2058` says sequence numbers are checked "to detect stale results before continuing"; the code path then continues after the mismatch log.
- `git blame -L2030,2180 -- zebra/zebra_rib.c` shows the stale detection and success path are long-standing, while local Specula trace calls are uncommitted instrumentation. No nearby comment says stale route-install success should be accepted.
- `zebra/zebra_rib.c:2108-2114` documents an update ambiguity for same route type, but limits that comment to old/new identification for update cleanup and redistribution, not to accepting a stale dataplane success as current realization.

Local git history:
- Local `git log --grep` for `stale dplane`, `dplane_sequence`, `rib_process_result`, `notify_owner`, and `suppress-fib` found related suppress-fib/NHT work but no commit that reports or fixes stale route-install success mutating the current route in `rib_process_result()`.
- Recent local history touching the relevant files includes suppress-fib fixes, NHG/NHT lifecycle work, and provider FIFO/skipped-kernel ordering, but no exact sequence-mismatch success-path fix.

Upstream issue / PR search:
- GitHub search `repo:FRRouting/frr "Stale dplane result"` returned issues/PRs including #5215, #12742, #8611, #20540, and #22224.
- #5215 reports stale `old_re` failure logs with BGP routes not installed; it is not the same stale success path notifying a newer current route.
- #12742 reports inactive BGP routes and stale delete/result symptoms; it is not the same route-install success mutation/owner-ack mechanism.
- #8611 concerns connected route redistribution when an interface has multiple addresses.
- #20540 concerns static route invalidation on interface up/down flap.
- #22224 concerns NHG behavior across down/up interface handling.
- GitHub searches for `"dplane_sequence" "rib_process_result"`, `"ZAPI_ROUTE_INSTALLED" "dplane_sequence"`, `"suppress-fib-pending" "Stale dplane result"`, closed PRs with `"rib_process_result" "notify_owner"`, and closed PRs with `"dplane" "stale" "notify_owner"` found no exact public report or recently merged/closed PR for this mechanism.

Known-status evidence:
- No public issue/PR found that reports the same mechanism at the same site: a stale successful normal dataplane route context passing the sequence mismatch in `rib_process_result()` and driving current-route installed state plus owner notification.
