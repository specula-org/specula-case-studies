# FRR Specula Trace Harness

Run from `.specula-output`:

```sh
bash harness/run.sh
```

`run.sh` applies instrumentation to the host FRR tree, writes
`git-ls-files`, mounts the source at `/root/host-frr`, mounts this output
directory at `/tmp`, rebuilds FRR through `/opt/topotests/entrypoint.sh`, and
runs `tests/topotests/specula_route_realization`.

## Trace Module

Trace emission lives in `lib/specula_trace.c` / `lib/specula_trace.h`, copied
from `harness/src/lib/` by `harness/apply.sh`. The writer is enabled only when
`SPECULA_TRACE_FILE` is set. It emits NDJSON with tag
`frr_route_realization`, real wall-clock timestamps, the exact Trace.tla event
name, common context fields, and an empty `state` object.

Prefix normalization is controlled by:

- `SPECULA_PREFIX_P1`
- `SPECULA_PREFIX_P2`

The BGP owner is normalized to `bgp0`. Zebra-to-BGP route owner notification
correlation uses `SPECULA_NOTIFY_STATE` as a small sidecar file because zebra
and bgpd are separate processes.

`SPECULA_TRACE_ROUTER` scopes emission to one topotest router. The wrapper
checks the daemon working directory name and unsets trace env for other routers;
the shipped scenarios trace `r1` only. This prevents r2 setup routes from
entering the same bounded `p1` trace.

Two trace-module reorderings are intentional and local to adjacent abstract
events:

- `rib_meta_queue_add` is captured in the real MetaQ add handler, then emitted
  after the matching `rib_addnode` / `rib_delnode` wrapper, or immediately
  before `meta_queue_process` if no add/delete wrapper appears first. FRR calls
  `rib_queue_add()` inside `rib_link()`, but `Trace.tla` models route presence
  before queue membership.
- `zebra_rnh_resolve_nexthop_entry` is delayed until after
  `zebra_rnh_store_in_routing_table` when an RNH was registered before the
  covering route existed. The real code can resolve before store; `base.tla`
  requires attachment before resolution.

## Instrumentation Points

After `apply.sh`, current insertion points are:

- `bgpd/bgp_zebra.c:1954`: route announcement send result.
- `bgpd/bgp_zebra.c:2094`: route install intent after Zebra usability check.
- `bgpd/bgp_zebra.c:3191`: owner notification consumption.
- `zebra/zapi_msg.c:790` and `zebra/zapi_msg.c:833`: route notify send/drop
  decisions.
- `zebra/zapi_msg.c:881`: route notify subscription request.
- `zebra/zebra_rib.c:709`: speculative `selected_fib` install before
  dataplane completion.
- `zebra/zebra_rib.c:766`: uninstall submit result.
- `zebra/zebra_rib.c:1556`: RIB process selected-FIB decision.
- `zebra/zebra_rib.c:2173`, `2181`, `2203`, `2229`, `2238`: dataplane result
  owner-notification obligations.
- `zebra/zebra_rib.c:2584`: MetaQ route process.
- `zebra/zebra_rib.c:3353`: MetaQ enqueue capture.
- `zebra/zebra_rib.c:4117`, `4122`, `4168`: RIB add/delete.
- `zebra/zebra_dplane.c:4180`: route ctx initialization.
- `zebra/zebra_dplane.c:4848`: dataplane enqueue result.
- `zebra/zebra_dplane.c:7778`, `7794`, `7824`: provider terminal result.
- `zebra/zebra_dplane.c:8286`: provider handoff.
- `zebra/zebra_dplane.c:8420`: result visibility to Zebra main thread.
- `zebra/zebra_dplane.c:8438`: dataplane shutdown.
- `zebra/zebra_rnh.c:165`, `246`, `763`, `1258`: RNH store/create/resolve/send.

## Adjusting Events

To add a field to every event, update `specula_emit_locked()` in
`lib/specula_trace.c` and add the same field name to `Trace.tla` validation if
it should be checked. To add one event type, add a wrapper function in
`specula_trace.h/.c`, call it at the real code point, then regenerate
`harness/patches/instrumentation.patch` with:

```sh
git -C /home/ubuntu/network-control-plane/workspaces/frr/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850 diff -- bgpd/bgp_zebra.c lib/subdir.am zebra/zapi_msg.c zebra/zebra_dplane.c zebra/zebra_rib.c zebra/zebra_rnh.c > harness/patches/instrumentation.patch
```

To move a capture point, move only the `specula_trace_*` call. Keep it in the
real FRR path and preserve before/after ordering from
`spec/instrumentation-spec.md`.

## Coverage Notes

The first scenarios generate short traces for static route realization and BGP
suppress-fib route realization. `run_specula_topotests.sh` trims each trace
after the scenario's success boundary (`route_notify_internal/installed` for
static, `bgp_zebra_route_notify_owner/installed` for BGP), so teardown
delete/shutdown events do not pollute the scenario trace.

Current trace coverage:

- `static_route_realization.ndjson`: 14 events, covering notify subscription,
  RIB admission, MetaQ, RIB process, dataplane submit/provider/result, and Zebra
  owner notification send.
- `bgp_suppress_fib_route_realization.ndjson`: 17 events, covering the static
  set plus BGP install intent, BGP-to-Zebra route announcement send, and BGP
  owner notification consumption.

Failure-only paths (`ZapiSendFail`, `dplane_update_enqueue_failure`,
`OwnerNotifyDrop`, provider restart, and FPM private queue actions) are
instrumented only where a real failure path exists or are left for targeted
Phase 3 scenarios.

## Validation Notes

`bash harness/run.sh` currently rebuilds FRR in Docker and produces real
NDJSON traces successfully. `Trace.cfg` validation is blocked by base invariant
semantics, not by NDJSON format:

- `static_route_realization.ndjson` reaches `rib_meta_queue_add` and violates
  `MetaQSingleVisibleMembership`. The trace records real FRR qindex `6`
  (`META_QUEUE_STATIC`); `base.tla` currently defines visible queued bits as
  `0..5`.
- `bgp_suppress_fib_route_realization.ndjson` reaches
  `bgp_handle_route_announcements_to_zebra` and violates
  `PendingImpliesOutstandingWork`. The base action clears `zapiAddInFlight`
  before Zebra admission/RIB add is modeled, leaving a real send-to-Zebra gap
  that the invariant does not count as outstanding work.

Phase 3 should adjust/classify those invariants or add the missing in-flight
ZAPI-delivery state before treating these as harness failures.
