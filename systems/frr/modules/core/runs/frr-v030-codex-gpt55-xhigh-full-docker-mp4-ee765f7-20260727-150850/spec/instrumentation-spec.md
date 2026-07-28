# Instrumentation Spec: FRR Zebra Route Realization

This document maps `base.tla` / `Trace.tla` actions to FRR source locations.
Trace events must be real NDJSON events from the instrumented FRR topotest
runtime. Synthetic traces are acceptable only for debugging the trace spec.

## 1. Trace Event Schema

Emit one NDJSON object per spec action:

```json
{
  "tag": "frr_route_realization",
  "event": {
    "name": "rib_process_result",
    "prefix": "p1",
    "owner": "bgp0",
    "table": 0,
    "gen": 1,
    "ctxId": 3,
    "op": "install",
    "seq": 17,
    "oldSeq": 0,
    "status": "success",
    "attrs": 0,
    "stale": false,
    "kernelTouched": true,
    "notifyId": 3,
    "note": "installed",
    "causeGen": 1,
    "qindex": 8,
    "state": {}
  }
}
```

Required common fields:

- `name`: exact Trace wrapper event name.
- `prefix`: bounded test prefix identifier, e.g. `p1`; normalize real prefix/table/type/instance to this symbol.
- `owner`: bounded owner identifier, e.g. `bgp0`.
- `table`: Zebra table id, normalized to `0..MaxTableId`.
- `gen`: instrumentation-maintained route generation per `(prefix, table, type, instance)`.
- `attrs`: compact enum for route attributes relevant to this model, currently parity/enum of metric, distance, tag, MTU, NHE/NHG id as configured by the harness.
- `state`: post-action snapshot. If a field is present, `Trace.tla` validates it.

State snapshot fields validated by `Trace.tla`:

- Route/kernel: `routeGen`, `selectedFib`, `routePresent`, `routeQueued`, `routeInstalled`, `routeFailed`, `routeRemoved`, `routeReplacing`, `routeAttrs`, `routeDplaneSeq`, `kernelInstalled`, `kernelGen`, `kernelAttrs`, `kernelFibNH`.
- BGP/ZAPI: `bgpPending`, `bgpInstalled`, `bgpSelectedGen`, `bgpInstalledGen`, `zapiAddInFlight`.
- Queues: `ctxQueueLen`, `providerInLen`, `providerOutLen`, `providerPrivateLen`, `resultQueueLen`, `ownerNotifyObligationLen`, `notifyQueueLen`, `nhtQueueLen`.
- NHT/MetaQ/global: `rnhAttached`, `rnhResolved`, `rnhGen`, `nhtEvalNeeded`, `nhtSuppressed`, `queuedBitCount`, `visibleQueued`, `ribProcessReady`, `shutdownStarted`, `providerAlive`, `zebraRestarted`, `lostNotifications`, `reconnects`.

Context fields for dataplane actions:

- `ctxId`: stable numeric id for the `struct zebra_dplane_ctx *`, assigned by instrumentation.
- `op`: one of `install`, `update`, `delete`, `route_notify`.
- `seq`: `dplane_ctx_get_seq(ctx)` / `ctx->zd_seq`.
- `oldSeq`: `dplane_ctx_get_old_seq(ctx)` / `ctx->zd_old_seq`.
- `status`: `pending`, `success`, or `failure`.
- `kernelTouched`: true only when the provider path actually updated the modeled kernel oracle.

Notification fields:

- `notifyId`: use ctx id when notification comes from a ctx, otherwise a monotonic notification id.
- `note`: `installed`, `fail_install`, `removed`, `remove_fail`, or `better_admin_won`.
- `causeGen`: hidden instrumentation generation for the route state that caused the notification. This is not present in the real ZAPI payload; it is trace metadata needed to validate generation correlation.

## 2. Action-To-Code Mapping

| Spec action / event | Code location | Trigger point | Fields | Notes |
|---|---|---|---|---|
| `bgp_zebra_route_install` | `bgpd/bgp_zebra.c:2037-2087` | After `BGP_NODE_FIB_INSTALL_PENDING` is set or cleared and after the Zebra usability check is known. | common state, BGP fields | Captures the window where pending is set before `bgp_install_info_to_zebra()` can return false. |
| `bgp_handle_route_announcements_to_zebra` | `bgpd/bgp_zebra.c:1880-1982` | After `bgp_zebra_announce_actual()` / withdraw returns and schedule flags are cleared. | common state, BGP fields, queue lengths | Use only for successful or buffered send attempts that still correspond to an in-flight ZAPI add. |
| `ZapiSendFail` | `bgpd/bgp_zebra.c:1880-1982`, send-status branch | After a real `ZCLIENT_SEND_FAILURE` for a route announcement. | common state, BGP fields | Do not synthesize; emit only when the send path returns failure. |
| `zread_route_notify_request` | `zebra/zapi_msg.c:850-855` | Immediately after `client->notify_owner = notify`. | owner, global state | Connection-local subscription state. |
| `bgp_zebra_connected` | `bgpd/bgp_zebra.c:3299-3325`, `zebra/zserv.c:799-807` | After reconnect callback registration/retry path. | owner, global state | New zserv clients are zeroed, so notify subscription must be captured as false until request is seen. |
| `bgp_zebra_announce_table` | `bgpd/bgp_zebra.c:1744-1780` | After selected route is handed to `bgp_zebra_route_install()`. | common state, BGP fields | Reconnect/replay path; useful for Scenario 4 traces. |
| `rib_addnode` | `zebra/zebra_rib.c:4075-4088` | After un-remove return or after `rib_link()` returns. | route state, MetaQ fields | If instrumenting inside the caller, prefer after `rib_addnode()` completes. |
| `rib_link` | `zebra/zebra_rib.c:4056-4072` | After `re_list_add_head()` and `rib_queue_add()`. | route state, MetaQ fields | `Trace.tla` consumes this through `rib_addnode`; emit `rib_addnode` unless a dedicated debug trace is needed. |
| `rib_delnode` | `zebra/zebra_rib.c:4122-4133` | After `ROUTE_ENTRY_REMOVED` is set and `rib_queue_add()` is called. | route state, MetaQ fields | Preserve add/delete ordering for same prefix. |
| `rib_meta_queue_add` | `zebra/zebra_rib.c:3262-3325`, `zebra/rib.h:189-204`, `zebra/rib.h:262-264` | After `SET_FLAG(... RIB_ROUTE_QUEUED(qindex))` and `listnode_add()`. | `qindex`, route/meta fields | Required for Scenario 4; capture qindex 6/8 for static/BGP tests. |
| `meta_queue_process` | `zebra/zebra_rib.c:3212-3239`, `zebra/zebra_rib.c:2548-2581` | After `rib_process(rnode)` and queue-bit clear. | `qindex`, route/meta fields, queue lengths | If dataplane queue blocks at `3218-3231`, do not emit this action. |
| `rib_process` | `zebra/zebra_rib.c:1290-1565` | After selected route flags/FIB work decision. | route state, `selectedFib`, `ribProcessReady` | Keep separate from `rib_install_kernel`; `selected_fib` is not committed here in the model. |
| `rib_install_kernel` | `zebra/zebra_rib.c:684-747` | Immediately after `dest->selected_fib = re` / `hook_call(rib_update, ...)`, before dataplane result. | route state, `selectedFib`, submit fields | Critical Scenario 1 precompletion window. |
| `rib_uninstall_kernel` | `zebra/zebra_rib.c:750-784` | After `dplane_route_delete()` returns queued/failure/success. | route state, submit fields | Deletion owner notifications are applied at result processing. |
| `dplane_ctx_route_init` | `zebra/zebra_dplane.c:4014-4151` | After `ctx->zd_seq = re->dplane_sequence`. | context fields, route dplane seq | Also capture old sequence for update path at `zebra/zebra_dplane.c:4843-4845`. |
| `dplane_update_enqueue` | `zebra/zebra_dplane.c:4777-4815`, `zebra/zebra_dplane.c:4873-4882` | After enqueue succeeds and `ZEBRA_DPLANE_REQUEST_QUEUED` is known. | context fields, queue lengths, route queued flags | Context id must match the prior `dplane_ctx_route_init` event. |
| `dplane_update_enqueue_failure` | `zebra/zebra_dplane.c:4881-4888`, `zebra/zebra_rib.c:733-738` | After enqueue failure frees ctx / after caller logs failure. | context fields, route state | Emit only for real failure. It should leave no explicit terminal `enqueueFailed` state. |
| `dplane_thread_loop_to_provider` | `zebra/zebra_dplane.c:8111-8145` and provider handoff in loop | After ctx moves from global input queue to first provider input. | context fields, queue lengths | Do not collapse with provider callback. |
| `kernel_dplane_process_func_success` | `zebra/zebra_dplane.c:7716-7788` | After normal kernel handling and before/after `dplane_provider_enqueue_out_ctx()`. | context fields with `status=success`, kernel state | `kernelTouched=true` only for actual kernel/provider update. |
| `kernel_dplane_process_func_failure` | `zebra/zebra_dplane.c:7716-7788` | After provider sets failure status. | context fields with `status=failure`, kernel state | Capture failures before output enqueue. |
| `kernel_dplane_process_func_skip_kernel` | `zebra/zebra_dplane.c:7747-7758` | After skip-kernel success path enqueues output. | context fields with `status=success`, `kernelTouched=false` | Scenario 5 route-attrs/NHG boundary. |
| `fpm_nl_process_private` | `zebra/dplane_fpm_nl.c:1753-1813` | After ctx enters `fnc->ctxqueue`. | context fields, provider-private length | Optional provider path; keep short traces. |
| `fpm_process_queue` | `zebra/dplane_fpm_nl.c:1550-1594` | After ctx leaves FPM private queue and output is enqueued/wake requested. | context fields, provider queues | Captures whether wake happened after private completion. |
| `dplane_thread_loop_result` | `zebra/zebra_dplane.c:8111-8122`, `zebra/zebra_rib.c:5221-5225` | When completed ctx becomes visible to Zebra main-thread result dispatch. | context fields, result queue length | Separate from `rib_process_result`. |
| `dplane_result_lost` | Result-drop/error cleanup hook only | After a real ctx is freed/dropped before main-thread dispatch. | context fields | Model-checking fault; emit only if a real code path observes such a drop. |
| `DPLANE_OP_ROUTE_NOTIFY` | provider/kernel route notify creation, `zebra/zebra_dplane.c:812`, `zebra/zebra_dplane.c:7341`, `zebra/zebra_dplane.c:7627` | When an async route notify ctx is created/enqueued for Zebra. | context fields with `op=route_notify`, `gen`/`causeGen` | The real notify lacks normal route generation gating; instrumentation supplies hidden cause generation. |
| `rib_process_result` | `zebra/zebra_rib.c:1976-2247` | After route flags, owner notify obligation, and NHT evaluation scheduling are updated. | context fields, route/kernel/BGP queue/NHT state | Capture stale seq comparison result from `2048-2090`; do not suppress event on mismatch. |
| `rib_process_dplane_notify` | `zebra/zebra_rib.c:2254-2325` | After queued/replacing clear and owner/NHT obligations are produced. | context fields, route state, notify/NHT queues | Async notify path matches loosely by prefix/type. |
| `route_notify_internal` | `zebra/zapi_msg.c:751-812` | After client lookup/subscription decision and send attempt. | notify fields, queue lengths | Payload has no generation; `causeGen` is trace metadata. |
| `OwnerNotifyDrop` | `zebra/zapi_msg.c:812` send failure or zserv output failure hook | After a real route-owner notification is lost/not delivered. | notify fields, `lostNotifications` | Emit only on observed send/drop failure. |
| `bgp_zebra_route_notify_owner` | `bgpd/bgp_zebra.c:3047-3155` | After BGP applies installed/fail/removed note to current dest. | notify fields, BGP state | Validates prefix/table/status correlation against hidden `causeGen`. |
| `zebra_add_rnh` | `zebra/zebra_rnh.c:167-245`, `zebra/zapi_msg.c:1254` | After RNH entry creation/lookup and initial store attempt. | prefix, owner, NHT state | Register-before-covering-route should show `rnhAttached=false`. |
| `zebra_rnh_store_in_routing_table` | `zebra/zebra_rnh.c:139-164` | After RNH is added to `dest->nht`. | NHT state | Emit when a later covering route causes attachment. |
| `zebra_rnh_resolve_nexthop_entry` | `zebra/zebra_rnh.c:678-769` | After a usable installed route entry is chosen. | NHT and route/kernel state | Captures queued-but-not-installed skip at `741-748`. |
| `compare_state_suppress` | `zebra/zebra_rnh.c:1020-1042`, `zebra/zebra_rnh.c:1127-1148` | When reduced comparison reports no change while hidden generation/path metadata changed. | NHT state, `nhtSuppressed=true` | Emit only when instrumentation can observe reduced-equal/current-gen-different state. |
| `zebra_send_rnh_update` | `zebra/zebra_rnh.c:1151-1248` | After update payload is encoded/sent. | NHT queue/message state | Include route type/instance/nexthop count in debug fields if available. |
| `ZebraRestart` | topotest lifecycle / Zebra process restart | Immediately after Zebra state is lost/reinitialized. | global state | Harness event, not a C function. |
| `rib_sweep_table` | `zebra/zebra_rib.c:4898-4955` | After stale self-route is marked installed/FIB and queued for uninstall/delete. | route/kernel state | Startup cleanup Scenario 4. |
| `ProviderRestart` | provider restart/finish path, `zebra/zebra_dplane.c:8009-8032`, `zebra/dplane_fpm_nl.c:1685-1750` | After provider-private work is dropped or provider is reinitialized. | provider queues/global state | Emit only for actual provider restart/loss. |
| `zebra_dplane_shutdown` | `zebra/zebra_dplane.c:8009-8088`, `zebra/zebra_dplane.c:8385` | When shutdown observes no visible pending work and finalizes. | provider queues/global state | Must include provider-private queue length. |

## 3. Special Considerations

- Build/run constraint: apply instrumentation to the host FRR source tree, generate `git ls-files -z --cached --others --exclude-standard`, mount source at `/root/host-frr`, mount the run/output directory at `/tmp`, mount persistent build cache at `/root/persist`, and run with image `ncp/frr-replay:ubuntu22-topotest` through `/opt/topotests/entrypoint.sh`.
- Trace output location: real NDJSON traces go under `.specula-output/traces`; `Trace.tla` defaults to `../traces/trace.ndjson` and supports `IOEnv.JSON`.
- Do not use single-line grep/sed assumptions for C insertion. FRR frequently splits calls and conditions over multiple lines; use context patches or a source-aware patch script.
- Under `set -euo pipefail`, optional probes must be guarded. Missing required locations should fail with a clear message.
- Maintain shadow maps for `gen`, `ctxId`, and compact `attrs`. FRR has `dplane_sequence`, but not a route generation/path id in owner notify payloads.
- Capture state after each action at the exact trigger point. For `rib_install_kernel`, the useful post-state is after `selected_fib` assignment and before dataplane completion.
- Keep traces short and scenario-focused. A useful first batch is one route add success, one enqueue failure, one late notify, one RNH register-before-route, one reconnect replay/no-replay, and one provider skip-kernel path.
