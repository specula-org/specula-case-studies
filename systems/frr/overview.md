# FRRouting

## Scope

Specula analyzed and tested FRRouting's Zebra route-realization pipeline, including RIB best-path selection, asynchronous dataplane/FIB programming, nexthop tracking, route-owner notifications, and coordination with BGP suppress-FIB state.

## Bugs

The independent review of the [2026-07-27 route-realization run](modules/core/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/review/independent-review.md) records **1 new bug and 1 known-fixed bug**:

- **New, Critical:** a late asynchronous FPM route notification can falsely acknowledge the current selected route as installed, allowing BGP advertisement before that route generation has its own offload completion.
- **Known-fixed, Critical:** a BGP-to-Zebra send failure can leave `suppress-fib-pending` without outstanding work; upstream later added selected-route replay after reconnect.

A third stale-result candidate was observable but masked in the archived run and is not counted.
