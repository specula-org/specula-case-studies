# MC-3 Investigation

## Code Audit

Finding source: model checking counterexample `spec/output/MC_hunt_scenario2_owner_notify_bfs_final2.out`.

Counterexample facts read from the provided output:

- State 2 and State 3 execute `MCbgp_zebra_route_install(bgp0,p1)`, leaving `bgpPending = TRUE`, `zapiAddInFlight = TRUE`, and no Zebra RIB/dataplane state yet.
- State 4 executes `MCZapiSendFail(bgp0,p1)`, leaving `bgpPending = TRUE` while `zapiAddInFlight = FALSE`, `zapiToZebra = FALSE`, `ctxQueue = {}`, `providerIn = {}`, `providerOut = {}`, `resultQueue = {}`, `notifyQueue = {}`, and `ownerNotifyObligation = {}`.
- The violated invariant is `PendingImpliesOutstandingWork`.

Relevant implementation facts:

- `bgpd/bgp_zebra.c:2042` defines `bgp_zebra_route_install()`. For non-EVPN installs with `bgp suppress-fib-pending` enabled, it sets `BGP_NODE_FIB_INSTALL_PENDING` before checking Zebra connectivity and before queueing/sending the ZAPI route add (`bgpd/bgp_zebra.c:2061`, `bgpd/bgp_zebra.c:2074`, `bgpd/bgp_zebra.c:2076`).
- The same function queues the destination for later Zebra announcement only after the pending flag is already set (`bgpd/bgp_zebra.c:2096` through `bgpd/bgp_zebra.c:2117`) and schedules `bgp_handle_route_announcements_to_zebra()` (`bgpd/bgp_zebra.c:2151`).
- `bgp_handle_route_announcements_to_zebra()` pops a queued inode, sends the install with `bgp_zebra_announce_actual()`, clears only `BGP_NODE_SCHEDULE_FOR_INSTALL`, then always unlocks/releases the inode and clears `dest->za_inode` (`bgpd/bgp_zebra.c:1923`, `bgpd/bgp_zebra.c:1934`, `bgpd/bgp_zebra.c:1937`, `bgpd/bgp_zebra.c:1968` through `bgpd/bgp_zebra.c:1973`). It breaks only on `ZCLIENT_SEND_BUFFERED`, not on `ZCLIENT_SEND_FAILURE`.
- `lib/zclient.c:381` implements `zclient_send_message()`. If the socket is closed it returns `ZCLIENT_SEND_FAILURE`; if `buffer_write()` returns `BUFFER_ERROR`, it logs, calls `zclient_failed()`, stops the zclient, schedules reconnect, and returns `ZCLIENT_SEND_FAILURE` (`lib/zclient.c:383`, `lib/zclient.c:388` through `lib/zclient.c:392`; reconnect scheduling at `lib/zclient.c:341` through `lib/zclient.c:346` and `lib/zclient.c:4997` through `lib/zclient.c:5013`).
- BGP clears `BGP_NODE_FIB_INSTALL_PENDING` in the route-owner notification handler on installed, fail-install, or better-admin-won notifications (`bgpd/bgp_zebra.c:3110` through `bgpd/bgp_zebra.c:3115`, `bgpd/bgp_zebra.c:3148` through `bgpd/bgp_zebra.c:3155`, `bgpd/bgp_zebra.c:3164` through `bgpd/bgp_zebra.c:3171`). A send failure before Zebra receives the route creates no Zebra RIB entry and therefore no dataplane result or owner notification.
- The real consumer is BGP outbound update generation. `bgp_check_advertise()` returns false when suppress-fib is enabled and `BGP_NODE_FIB_INSTALL_PENDING` remains set (`bgpd/bgp_route.h:721` through `bgpd/bgp_route.h:729`), and `group_announce_route()` returns immediately on that false result (`bgpd/bgp_updgrp_adv.c:1189` through `bgpd/bgp_updgrp_adv.c:1193`). The path announcement code documents the behavior at `bgpd/bgp_route.c:3785` through `bgpd/bgp_route.c:3789`.
- Operator-visible state also exposes the stuck bit: BGP JSON route output includes `fibPending` (`bgpd/bgp_route.c:13700` through `bgpd/bgp_route.c:13703`) and detailed FIB flags include `fibWaitForInstall` (`bgpd/bgp_route.c:13766` through `bgpd/bgp_route.c:13775`).
- Zebra route-owner notification is opt-in. BGP sends `ZEBRA_ROUTE_NOTIFY_REQUEST` when suppress-fib is enabled (`bgpd/bgpd.c:577` through `bgpd/bgpd.c:582`; encoded in `lib/zclient.c:2691` through `lib/zclient.c:2703`), and Zebra records the subscription in `zapi_msg.c:875` through `zapi_msg.c:881`.
- Zebra sends owner notifications from actual RIB/dataplane paths, for example installed/fail-install in `zebra/zebra_rib.c:2171` through `zebra/zebra_rib.c:2195` and fallback/offload notifications at `zebra/zebra_rib.c:2400` through `zebra/zebra_rib.c:2405`. If the ZAPI route add write fails before Zebra receives the message, these paths have no route entry to operate on.
- `bgp_zebra_connected()` on reconnect registers the default instance, retries deferred suppress-fib config, and sends GR capability (`bgpd/bgp_zebra.c:3327` through `bgpd/bgp_zebra.c:3353`). I did not find a reconnect hook that walks ordinary selected BGP routes and requeues route installs after this send-failure path.

Reachability and trigger scenario:

1. Run normal BGP with `bgp suppress-fib-pending` enabled on a transit router.
2. A peer advertises a new IPv4 unicast prefix to the transit router.
3. BGP selects the path, calls `bgp_zebra_route_install()`, sets `BGP_NODE_FIB_INSTALL_PENDING`, and queues a Zebra route announcement.
4. Before/during the queued ZAPI route add write, the bgpd-to-zebra socket write fails. This is a normal OS/socket failure that `zclient_send_message()` explicitly handles by returning `ZCLIENT_SEND_FAILURE`.
5. `bgp_handle_route_announcements_to_zebra()` releases the inode and clears `za_inode`, but does not clear `BGP_NODE_FIB_INSTALL_PENDING` on failure. Zebra never received the route add, so no dataplane work or route-owner notification remains outstanding.
6. Later `group_announce_route()` observes the stuck pending flag and suppresses advertisement to downstream BGP peers.

Safeguards encountered:

- If Zebra successfully receives and processes the route, owner notifications clear the pending flag.
- If the route is withdrawn or a later bestpath process reaches explicit uninstall/no-new-select paths, other code can clear pending.
- I found no automatic cleanup for the specific state where the queued route add has already been popped and then `zclient_send_message()` returns failure before Zebra receives it.

## Developer Knowledge Search

Local git history and blame:

- `git blame` attributes the pending-set block in `bgp_zebra_route_install()` primarily to `ccfe452763d` and later suppress-fib edits to `f6b4ebe74da`, `95f0a2b7b40`, and `e104afb0d7f`.
- Commit `be785e356abf6b4c8ced8a9083ff772a935e2851` / `de93609c3f97c502f1cb6eda84b4f2f373720687` / `878140e499ddbc067674a22d5721d0db29e71f70` ("bgpd, tests: Add code to handle failed installations") documents that `ROUTE_INSTALL_FAILED` and `BETTER_ADMIN_DISTANCE_WON` must notify peers with withdrawal rather than leaving suppress-fib behavior silent. This is adjacent but depends on Zebra receiving the route and sending a route-owner notification.
- Commit `cd40cea1e0345b4d50a1a9df694092a5b7eb6320` ("bgpd: With suppress-fib-pending ensure withdrawal is sent") fixes a stuck pending/withdrawal ordering case when no new selected path remains. It is adjacent but not the queued ZAPI send-failure mechanism.
- Commit `f6b4ebe74da4d9d60677173aaca0081cc8fdcfe9` ("bgpd: Allow for suppress-fib to not wait for already installed route") intentionally avoids waiting when a dest is already FIB installed, but the finding concerns a not-yet-installed route.
- Commit `e104afb0d7f1c9b69d2bdc9ed31a1c513fd211be` ("bgpd: fix suppress-fib-pending blocking EVPN GR") records a known EVPN no-ack class and skips pending for EVPN. The finding is non-EVPN `ZEBRA_ROUTE_ADD` send failure.
- Commit `6cf5b7931101c343f6efaa1668f72fdf156f51c7` / `d4e8279adcafc61b1015b4c380ac12c316fc42bd` ("bgpd: backpressure - log error for evpn when route install to zebra fails") adds EVPN logging on `ZCLIENT_SEND_FAILURE`; it does not clear/requeue non-EVPN suppress-fib pending after send failure.
- Commit `1b25fbf924f714b7868b4a2fc1a949363328dc56` ("bgpd: fix aggregate->count errors in ZAPI route notifications") removes aggregate counting from notification handlers. It is adjacent to ZAPI notification handling but not this mechanism.

Issue/PR search:

- GitHub issue/PR search for `repo:FRRouting/frr "suppress-fib-pending" "ZCLIENT_SEND_FAILURE"` returned zero results.
- GitHub issue/PR search for `repo:FRRouting/frr "BGP_NODE_FIB_INSTALL_PENDING" "zclient_send_message"` returned zero results.
- GitHub issue/PR search for `repo:FRRouting/frr "bgp_zebra_route_install" "send failure"` returned zero results.
- GitHub issue/PR search for `repo:FRRouting/frr "suppress-fib-pending" "route install" failure` returned five adjacent results: PR 21818 (EVPN GR), issue 12112 (connected routes with suppress-fib), issue 12706 (neighbor active/TCP), PR 4770 (original advertise-FIB-installed feature), and PR 3147 (original feature). None report a queued non-EVPN route add ZAPI send failure leaving `BGP_NODE_FIB_INSTALL_PENDING` with no outstanding work.
- GitHub issue/PR search for `repo:FRRouting/frr "FIB_INSTALL_PENDING"` returned PR 21789 (aggregate count notification bug), PR 21231 (EVPN GR no-ack), PR 21035 (JSON detail attributes), and issue 21298 (hardcoded advertisement delay). None is the same mechanism at this site.

Known-status evidence:

- I found adjacent suppress-fib fixes and developer comments, but no public issue/PR/CVE/advisory in the checked upstream tracker or local PR refs that reports this exact non-EVPN queued ZAPI route-add send failure leaving pending state after the inode is released.

## Phase 2 Plan

Attempt Level 0 and timing-only behavior with normal public BGP route injection first. Then use a Level 2 syscall fault shim only for r2 bgpd to make one legitimate `ZEBRA_ROUTE_ADD` write return an error, corresponding to counterexample State 4 `MCZapiSendFail`. The injected fault is a real OS-level outcome of the bgpd-to-zebra socket write and is explicitly handled by `zclient_send_message()`.
