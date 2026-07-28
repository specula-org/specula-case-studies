# Severity Classification — frr

## Summary

- Total entries: 3
- Reproduced bugs: 2
- Severity-bearing findings: 1
- Critical: 2
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | MASKED | High | A stale normal dataplane success can reach the Zebra/BGP owner-notify path and mark the newer selected route installed, which could clear suppress-fib-pending and advertise a route generation whose FIB state was not actually realized. The observed Docker run masks the live wrong-route consequence because the current generation-2 result follows immediately and the kernel route is already on the current r3 nexthop. |
| 2 | MC-2 | REPRODUCED | Critical | A delayed first-generation FPM offload notify can be accepted through normal Zebra/FPM/BGP interfaces and mark the current selected route installed before its own offload completion, causing BGP to advertise based on a false installed state. In the reproduced run no downstream guard repaired it, and the state persisted until a future valid notify or route event. |
| 3 | MC-3 | REPRODUCED | Critical | A queued non-EVPN `ZEBRA_ROUTE_ADD` send failure under `bgp suppress-fib-pending` leaves `fibPending` set with no Zebra route, dataplane work, retry, or owner notification outstanding. The public BGP-to-Zebra failure path withholds the route from peers indefinitely, producing persistent external reachability loss until later route churn. |
