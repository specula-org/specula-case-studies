--------------------------- MODULE Trace ----------------------------
\* Trace validation spec for FRRouting Zebra route realization.
\*
\* The trace is a linear NDJSON file produced by instrumentation described in
\* instrumentation-spec.md. Each event corresponds 1:1 with a base spec action.

EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "frr_route_realization"
        /\ "event" \in DOMAIN x))

----
\* Trace cursor
----

VARIABLE l

traceVars == <<l>>
traceAllVars == <<vars, traceVars>>

logline == TraceLog[l]

TraceInit ==
    /\ Init
    /\ l = 1

----
\* Event helpers
----

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

StateHas(field) ==
    /\ "state" \in DOMAIN logline.event
    /\ field \in DOMAIN logline.event.state

EventCtx ==
    [ id            |-> logline.event.ctxId,
      prefix        |-> logline.event.prefix,
      owner         |-> logline.event.owner,
      table         |-> logline.event.table,
      op            |-> logline.event.op,
      seq           |-> logline.event.seq,
      oldSeq        |-> logline.event.oldSeq,
      gen           |-> logline.event.gen,
      status        |-> logline.event.status,
      attrs         |-> logline.event.attrs,
      stale         |-> IF "stale" \in DOMAIN logline.event THEN logline.event.stale ELSE FALSE,
      kernelTouched |-> IF "kernelTouched" \in DOMAIN logline.event THEN logline.event.kernelTouched ELSE FALSE ]

EventNotify ==
    [ id       |-> logline.event.notifyId,
      prefix   |-> logline.event.prefix,
      owner    |-> logline.event.owner,
      table    |-> logline.event.table,
      note     |-> logline.event.note,
      causeGen |-> logline.event.causeGen ]

----
\* Post-state validation
\*
\* These predicates are field-sensitive: every field captured in the event
\* schema is checked against the primed spec state. Instrumentation must capture
\* the fields listed in instrumentation-spec.md for the relevant action.
----

ValidateRoutePost(p) ==
    /\ IF StateHas("routeGen") THEN routeGen'[p] = logline.event.state.routeGen ELSE TRUE
    /\ IF StateHas("selectedFib") THEN selectedFib'[p] = logline.event.state.selectedFib ELSE TRUE
    /\ IF StateHas("routePresent") THEN ribRoute'[p].present = logline.event.state.routePresent ELSE TRUE
    /\ IF StateHas("routeQueued") THEN ribRoute'[p].queued = logline.event.state.routeQueued ELSE TRUE
    /\ IF StateHas("routeInstalled") THEN ribRoute'[p].installed = logline.event.state.routeInstalled ELSE TRUE
    /\ IF StateHas("routeFailed") THEN ribRoute'[p].failed = logline.event.state.routeFailed ELSE TRUE
    /\ IF StateHas("routeRemoved") THEN ribRoute'[p].removed = logline.event.state.routeRemoved ELSE TRUE
    /\ IF StateHas("routeReplacing") THEN ribRoute'[p].replacing = logline.event.state.routeReplacing ELSE TRUE
    /\ IF StateHas("routeAttrs") THEN ribRoute'[p].attrs = logline.event.state.routeAttrs ELSE TRUE
    /\ IF StateHas("routeDplaneSeq") THEN routeDplaneSeq'[p] = logline.event.state.routeDplaneSeq ELSE TRUE
    /\ IF StateHas("kernelInstalled") THEN kernelRoute'[p].installed = logline.event.state.kernelInstalled ELSE TRUE
    /\ IF StateHas("kernelGen") THEN kernelRoute'[p].gen = logline.event.state.kernelGen ELSE TRUE
    /\ IF StateHas("kernelAttrs") THEN kernelRoute'[p].attrs = logline.event.state.kernelAttrs ELSE TRUE
    /\ IF StateHas("kernelFibNH") THEN kernelRoute'[p].fibNH = logline.event.state.kernelFibNH ELSE TRUE

ValidateBGPPost(p) ==
    /\ IF StateHas("bgpPending") THEN bgpPending'[p] = logline.event.state.bgpPending ELSE TRUE
    /\ IF StateHas("bgpInstalled") THEN bgpInstalled'[p] = logline.event.state.bgpInstalled ELSE TRUE
    /\ IF StateHas("bgpSelectedGen") THEN bgpSelectedGen'[p] = logline.event.state.bgpSelectedGen ELSE TRUE
    /\ IF StateHas("bgpInstalledGen") THEN bgpInstalledGen'[p] = logline.event.state.bgpInstalledGen ELSE TRUE
    /\ IF StateHas("zapiAddInFlight") THEN zapiAddInFlight'[p] = logline.event.state.zapiAddInFlight ELSE TRUE

ValidateQueuePost ==
    /\ IF StateHas("ctxQueueLen") THEN Cardinality(ctxQueue') = logline.event.state.ctxQueueLen ELSE TRUE
    /\ IF StateHas("providerInLen") THEN Cardinality(providerIn') = logline.event.state.providerInLen ELSE TRUE
    /\ IF StateHas("providerOutLen") THEN Cardinality(providerOut') = logline.event.state.providerOutLen ELSE TRUE
    /\ IF StateHas("providerPrivateLen") THEN Cardinality(providerPrivate') = logline.event.state.providerPrivateLen ELSE TRUE
    /\ IF StateHas("resultQueueLen") THEN Cardinality(resultQueue') = logline.event.state.resultQueueLen ELSE TRUE
    /\ IF StateHas("ownerNotifyObligationLen") THEN Cardinality(ownerNotifyObligation') = logline.event.state.ownerNotifyObligationLen ELSE TRUE
    /\ IF StateHas("notifyQueueLen") THEN Cardinality(notifyQueue') = logline.event.state.notifyQueueLen ELSE TRUE
    /\ IF StateHas("nhtQueueLen") THEN Cardinality(nhtQueue') = logline.event.state.nhtQueueLen ELSE TRUE

ValidateNHTPost(p) ==
    /\ IF StateHas("rnhAttached") THEN rnhAttachedDest'[p] = logline.event.state.rnhAttached ELSE TRUE
    /\ IF StateHas("rnhResolved") THEN rnhSnapshot'[p].resolved = logline.event.state.rnhResolved ELSE TRUE
    /\ IF StateHas("rnhGen") THEN rnhSnapshot'[p].gen = logline.event.state.rnhGen ELSE TRUE
    /\ IF StateHas("nhtEvalNeeded") THEN nhtEvalNeeded'[p] = logline.event.state.nhtEvalNeeded ELSE TRUE
    /\ IF StateHas("nhtSuppressed") THEN nhtSuppressed'[p] = logline.event.state.nhtSuppressed ELSE TRUE

ValidateMetaPost(p) ==
    /\ IF StateHas("queuedBitCount") THEN Cardinality(queuedBits'[p]) = logline.event.state.queuedBitCount ELSE TRUE
    /\ IF StateHas("visibleQueued") THEN VisibleQueued(p)' = logline.event.state.visibleQueued ELSE TRUE
    /\ IF StateHas("ribProcessReady") THEN ribProcessReady'[p] = logline.event.state.ribProcessReady ELSE TRUE

ValidateGlobalPost ==
    /\ IF StateHas("shutdownStarted") THEN shutdownStarted' = logline.event.state.shutdownStarted ELSE TRUE
    /\ IF StateHas("providerAlive") THEN providerAlive' = logline.event.state.providerAlive ELSE TRUE
    /\ IF StateHas("zebraRestarted") THEN zebraRestarted' = logline.event.state.zebraRestarted ELSE TRUE
    /\ IF StateHas("lostNotifications") THEN lostNotifications' = logline.event.state.lostNotifications ELSE TRUE
    /\ IF StateHas("reconnects") THEN reconnects' = logline.event.state.reconnects ELSE TRUE
    /\ ValidateQueuePost

ValidatePostState(p) ==
    /\ ValidateRoutePost(p)
    /\ ValidateBGPPost(p)
    /\ ValidateNHTPost(p)
    /\ ValidateMetaPost(p)
    /\ ValidateGlobalPost

----
\* Action wrappers
----

Trace_bgp_zebra_route_install ==
    /\ IsEvent("bgp_zebra_route_install")
    /\ bgp_zebra_route_install(logline.event.owner, logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_bgp_handle_route_announcements_to_zebra ==
    /\ IsEvent("bgp_handle_route_announcements_to_zebra")
    /\ bgp_handle_route_announcements_to_zebra(logline.event.owner, logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_ZapiSendFail ==
    /\ IsEvent("ZapiSendFail")
    /\ ZapiSendFail(logline.event.owner, logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_zread_route_notify_request ==
    /\ IsEvent("zread_route_notify_request")
    /\ zread_route_notify_request(logline.event.owner)
    /\ ValidateGlobalPost
    /\ l' = l + 1

Trace_bgp_zebra_connected ==
    /\ IsEvent("bgp_zebra_connected")
    /\ bgp_zebra_connected(logline.event.owner)
    /\ ValidateGlobalPost
    /\ l' = l + 1

Trace_bgp_zebra_announce_table ==
    /\ IsEvent("bgp_zebra_announce_table")
    /\ bgp_zebra_announce_table(logline.event.owner, logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_addnode ==
    /\ IsEvent("rib_addnode")
    /\ rib_addnode(logline.event.prefix, logline.event.owner, logline.event.table)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_delnode ==
    /\ IsEvent("rib_delnode")
    /\ rib_delnode(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_meta_queue_add ==
    /\ IsEvent("rib_meta_queue_add")
    /\ rib_meta_queue_add(logline.event.prefix, logline.event.qindex)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_meta_queue_process ==
    /\ IsEvent("meta_queue_process")
    /\ meta_queue_process(logline.event.prefix, logline.event.qindex)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_process ==
    /\ IsEvent("rib_process")
    /\ rib_process(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_install_kernel ==
    /\ IsEvent("rib_install_kernel")
    /\ rib_install_kernel(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_uninstall_kernel ==
    /\ IsEvent("rib_uninstall_kernel")
    /\ rib_uninstall_kernel(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_dplane_ctx_route_init ==
    /\ IsEvent("dplane_ctx_route_init")
    /\ dplane_ctx_route_init(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_dplane_update_enqueue ==
    /\ IsEvent("dplane_update_enqueue")
    /\ dplane_update_enqueue(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_dplane_update_enqueue_failure ==
    /\ IsEvent("dplane_update_enqueue_failure")
    /\ dplane_update_enqueue_failure(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_dplane_thread_loop_to_provider ==
    /\ IsEvent("dplane_thread_loop_to_provider")
    /\ dplane_thread_loop_to_provider(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_kernel_dplane_process_func_success ==
    /\ IsEvent("kernel_dplane_process_func_success")
    /\ kernel_dplane_process_func_success(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_kernel_dplane_process_func_failure ==
    /\ IsEvent("kernel_dplane_process_func_failure")
    /\ kernel_dplane_process_func_failure(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_kernel_dplane_process_func_skip_kernel ==
    /\ IsEvent("kernel_dplane_process_func_skip_kernel")
    /\ kernel_dplane_process_func_skip_kernel(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_fpm_nl_process_private ==
    /\ IsEvent("fpm_nl_process_private")
    /\ fpm_nl_process_private(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_fpm_process_queue ==
    /\ IsEvent("fpm_process_queue")
    /\ fpm_process_queue(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_dplane_thread_loop_result ==
    /\ IsEvent("dplane_thread_loop_result")
    /\ dplane_thread_loop_result(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_dplane_result_lost ==
    /\ IsEvent("dplane_result_lost")
    /\ dplane_result_lost(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_DPLANE_OP_ROUTE_NOTIFY ==
    /\ IsEvent("DPLANE_OP_ROUTE_NOTIFY")
    /\ DPLANE_OP_ROUTE_NOTIFY(logline.event.prefix, logline.event.gen)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_process_result ==
    /\ IsEvent("rib_process_result")
    /\ rib_process_result(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_rib_process_dplane_notify ==
    /\ IsEvent("rib_process_dplane_notify")
    /\ rib_process_dplane_notify(EventCtx)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_route_notify_internal ==
    /\ IsEvent("route_notify_internal")
    /\ route_notify_internal(EventNotify)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_OwnerNotifyDrop ==
    /\ IsEvent("OwnerNotifyDrop")
    /\ OwnerNotifyDrop(EventNotify)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_bgp_zebra_route_notify_owner ==
    /\ IsEvent("bgp_zebra_route_notify_owner")
    /\ bgp_zebra_route_notify_owner(EventNotify)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_zebra_add_rnh ==
    /\ IsEvent("zebra_add_rnh")
    /\ zebra_add_rnh(logline.event.prefix, logline.event.owner)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_zebra_rnh_store_in_routing_table ==
    /\ IsEvent("zebra_rnh_store_in_routing_table")
    /\ zebra_rnh_store_in_routing_table(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_zebra_rnh_resolve_nexthop_entry ==
    /\ IsEvent("zebra_rnh_resolve_nexthop_entry")
    /\ zebra_rnh_resolve_nexthop_entry(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_compare_state_suppress ==
    /\ IsEvent("compare_state_suppress")
    /\ compare_state_suppress(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_zebra_send_rnh_update ==
    /\ IsEvent("zebra_send_rnh_update")
    /\ zebra_send_rnh_update(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_ZebraRestart ==
    /\ IsEvent("ZebraRestart")
    /\ ZebraRestart
    /\ ValidateGlobalPost
    /\ l' = l + 1

Trace_rib_sweep_table ==
    /\ IsEvent("rib_sweep_table")
    /\ rib_sweep_table(logline.event.prefix)
    /\ ValidatePostState(logline.event.prefix)
    /\ l' = l + 1

Trace_ProviderRestart ==
    /\ IsEvent("ProviderRestart")
    /\ ProviderRestart
    /\ ValidateGlobalPost
    /\ l' = l + 1

Trace_zebra_dplane_shutdown ==
    /\ IsEvent("zebra_dplane_shutdown")
    /\ zebra_dplane_shutdown
    /\ ValidateGlobalPost
    /\ l' = l + 1

MatchEvent ==
    \/ Trace_bgp_zebra_route_install
    \/ Trace_bgp_handle_route_announcements_to_zebra
    \/ Trace_ZapiSendFail
    \/ Trace_zread_route_notify_request
    \/ Trace_bgp_zebra_connected
    \/ Trace_bgp_zebra_announce_table
    \/ Trace_rib_addnode
    \/ Trace_rib_delnode
    \/ Trace_rib_meta_queue_add
    \/ Trace_meta_queue_process
    \/ Trace_rib_process
    \/ Trace_rib_install_kernel
    \/ Trace_rib_uninstall_kernel
    \/ Trace_dplane_ctx_route_init
    \/ Trace_dplane_update_enqueue
    \/ Trace_dplane_update_enqueue_failure
    \/ Trace_dplane_thread_loop_to_provider
    \/ Trace_kernel_dplane_process_func_success
    \/ Trace_kernel_dplane_process_func_failure
    \/ Trace_kernel_dplane_process_func_skip_kernel
    \/ Trace_fpm_nl_process_private
    \/ Trace_fpm_process_queue
    \/ Trace_dplane_thread_loop_result
    \/ Trace_dplane_result_lost
    \/ Trace_DPLANE_OP_ROUTE_NOTIFY
    \/ Trace_rib_process_result
    \/ Trace_rib_process_dplane_notify
    \/ Trace_route_notify_internal
    \/ Trace_OwnerNotifyDrop
    \/ Trace_bgp_zebra_route_notify_owner
    \/ Trace_zebra_add_rnh
    \/ Trace_zebra_rnh_store_in_routing_table
    \/ Trace_zebra_rnh_resolve_nexthop_entry
    \/ Trace_compare_state_suppress
    \/ Trace_zebra_send_rnh_update
    \/ Trace_ZebraRestart
    \/ Trace_rib_sweep_table
    \/ Trace_ProviderRestart
    \/ Trace_zebra_dplane_shutdown

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ MatchEvent
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceAllVars

TraceSpec == TraceInit /\ [][TraceNext]_traceAllVars /\ WF_traceAllVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

=====================================================================
