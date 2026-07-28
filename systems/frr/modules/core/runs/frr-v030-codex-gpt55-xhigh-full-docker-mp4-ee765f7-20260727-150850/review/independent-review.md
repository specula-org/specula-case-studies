# Independent bug review

## Final adjudication

The second review records **1 new bug and 1 known-fixed bug**.

| Candidate | Final classification | Severity | Recorded? |
|---|---|---:|---:|
| MC-1 | Real stale-result path, but masked and weakly consequential in the archived run | — | No |
| MC-2 | Late FPM notification falsely acknowledges the current route as installed | Critical | New |
| MC-3 | Lost BGP-to-Zebra work after send failure; repaired by reconnect replay | Critical | Known, fixed |

The archived [confirmation report](../confirmed-bugs.md) is retained for provenance but is not the final novelty adjudication.

## New bug: late FPM notification acknowledges the wrong route generation

### Mechanism

At the target revision, `rib_route_match_ctx()` matches an ordinary BGP route notification by route type and instance, without a route generation or dataplane sequence. The asynchronous mode also skips the extra static-route distance and metric check. See [`zebra_rib.c` lines 1595-1657](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/zebra/zebra_rib.c#L1595-L1657).

`rib_process_dplane_notify()` uses that helper with `async=true`, requires only that the matched entry is the current `selected_fib`, then copies offload/FIB state from the context, sends an installed notification to the route owner, and schedules nexthop evaluation. There is no correlation to the route's current sequence. See [`zebra_rib.c` lines 2284-2388](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/zebra/zebra_rib.c#L2284-L2388).

The input is reachable through the public FPM path: an `RTM_NEWROUTE` message is converted to `DPLANE_OP_ROUTE_NOTIFY` and queued for Zebra processing. See [`dplane_fpm_nl.c` lines 714-732](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/zebra/dplane_fpm_nl.c#L714-L732). BGP treats the resulting `ZAPI_ROUTE_INSTALLED` as authoritative, clears `BGP_NODE_FIB_INSTALL_PENDING`, marks the route installed, and announces it. See [`bgp_zebra.c` lines 3084-3106](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/bgpd/bgp_zebra.c#L3084-L3106).

### Archived reproduction and impact

The archived [test](../repro/mc2-late-fpm-notify/test/test_mc2_late_fpm_notify.py) and [FPM responder](../repro/mc2-late-fpm-notify/test/mc2_fpm_responder.py) use normal BGP, Zebra, and FPM interfaces without patching FRR source. The responder withholds the first offload notification, lets a second route generation become current, and then sends only the stale first notification.

The final [JUnit result](../repro/mc2-late-fpm-notify/topotests.xml) passed. Its captured output shows the current route changing from `fibPending=true fibInstalled=false metric=200` to `fibPending=false fibInstalled=true metric=200` after the stale notification, while `sent_current_second=False`. The [trace](../repro/mc2-late-fpm-notify/mc2_trace.ndjson) records two route generations. The stale acknowledgement therefore reaches a real BGP consumer and can permit advertisement before the current generation has its own offload completion.

The archived prior-report search found related FPM and offload issues but no report of this late-notification generation mismatch at the target site. MC-2 is recorded as new, subject to upstream deduplication.

## Known-fixed bug: suppress-FIB state loses outstanding work

### Target mechanism

With `suppress-fib-pending` enabled, BGP sets `BGP_NODE_FIB_INSTALL_PENDING` before it queues the route for Zebra. See [`bgp_zebra.c` lines 2051-2145](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/bgpd/bgp_zebra.c#L2051-L2145). The queue worker attempts the actual send, clears the schedule flag, releases the inode, and continues unless the status is `ZCLIENT_SEND_BUFFERED`; a non-EVPN `ZCLIENT_SEND_FAILURE` is not requeued there. See [`bgp_zebra.c` lines 1922-1971](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/bgpd/bgp_zebra.c#L1922-L1971).

`zclient_send_message()` returns failure for a closed socket or buffer-write error, with the latter entering `zclient_failed()`. See [`zclient.c` lines 381-399](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/lib/zclient.c#L381-L399). At the target revision, the reconnect callback registers BGP again but does not replay selected routes, even though its own TODO asks whether configured peers and networks need to be restarted. See [`bgp_zebra.c` lines 3300-3326](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/bgpd/bgp_zebra.c#L3300-L3326).

The archived [wrapper](../repro/test_bugMC-3_zapi_send_failure.sh) exercised a single BGP-to-Zebra route-add write failure. The final [JUnit XML](../repro/mc3-zapi-send-failure/topotests.xml) records a passing test in which the transit router retained `fibPending`, Zebra had no route, and the downstream peer did not receive the route.

### Upstream fix and classification

The target commit dated 2026-06-15 is an ancestor of the BGP fix. Upstream [Issue #22362](https://github.com/FRRouting/frr/issues/22362) tracked selected routes not being restored after Zebra reconnect. [PR #22411](https://github.com/FRRouting/frr/pull/22411) added route replay after reconnect and was merged as [`7b77e986765f10ddb4027413f35f456b20f0321c`](https://github.com/FRRouting/frr/commit/7b77e986765f10ddb4027413f35f456b20f0321c).

The BGP-specific fix, [`67f78ccd10dd2d5aafe8986846c613ebfc43adac`](https://github.com/FRRouting/frr/commit/67f78ccd10dd2d5aafe8986846c613ebfc43adac), makes `bgp_zebra_connected()` replay every selected FIB-updating AFI/SAFI table through `bgp_zebra_announce_table()`. See the fixed [`bgp_zebra.c` lines 3300-3339](https://github.com/FRRouting/frr/blob/67f78ccd10dd2d5aafe8986846c613ebfc43adac/bgpd/bgp_zebra.c#L3300-L3339). Because a send error schedules reconnect and the merged replay restores the selected route work missing at the target, MC-3 is recorded as known-fixed rather than new.

## Not recorded: MC-1

MC-1 identifies a genuine weak spot: `rib_process_result()` logs a route sequence mismatch but continues into the success path that marks a route installed, copies FIB state, and can notify the owner. See [`zebra_rib.c` lines 2046-2097](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/zebra/zebra_rib.c#L2046-L2097) and [`zebra_rib.c` lines 2114-2178](https://github.com/FRRouting/frr/blob/ee765f7fa0d6533ec2479da3e442d17d4b93d474/zebra/zebra_rib.c#L2114-L2178).

The archived Level 3 run observed the stale owner notification, but the current generation result followed immediately and the final kernel route, selected nexthop, and downstream advertisement all reflected the current route. See [summary-level3.json](../repro/MC-1-stale-dplane/summary-level3.json). The archive does not establish a lasting wrong-route or reachability consequence, so this masked candidate is not counted.

## Review provenance and limits

- Review date: 2026-07-28
- Archived target: [`FRRouting/frr@ee765f7fa0d6533ec2479da3e442d17d4b93d474`](https://github.com/FRRouting/frr/tree/ee765f7fa0d6533ec2479da3e442d17d4b93d474)
- Source review: exact target checkout plus the upstream fix and merge commits named above
- Runtime evidence: existing archived results only; no new network or runtime test was executed during curation
- MC-3 evidence limit: the archive retains its wrapper and final JUnit XML, but not the generated topotest source/configuration as standalone members

The original reports remain byte-exact evidence of the pipeline's conclusions. This document is the final independent classification for publication.
