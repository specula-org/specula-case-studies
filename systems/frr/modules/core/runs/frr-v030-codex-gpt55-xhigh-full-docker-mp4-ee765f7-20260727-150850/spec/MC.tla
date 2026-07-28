----------------------------- MODULE MC -----------------------------
\* Model-checking wrapper for base.tla.
\*
\* The base spec models FRR Zebra control flow. This module bounds only
\* nondeterministic/external/fault-introducing actions: route input, enqueue
\* failures, provider outcomes, lost/late notifications, restart/reconnect, and
\* shutdown. Deterministic reactive actions pass through without counters.

EXTENDS base

B == INSTANCE base

----
\* Counter-bound constants
----

CONSTANT MaxBGPInstallLimit
CONSTANT MaxRouteAddLimit
CONSTANT MaxRouteDeleteLimit
CONSTANT MaxZapiSendFailLimit
CONSTANT MaxNotifySubscribeLimit
CONSTANT MaxMetaQueueLimit
CONSTANT MaxEnqueueFailLimit
CONSTANT MaxDplaneSuccessLimit
CONSTANT MaxDplaneFailureLimit
CONSTANT MaxProviderSkipLimit
CONSTANT MaxProviderPrivateLimit
CONSTANT MaxResultLostLimit
CONSTANT MaxRouteNotifyLimit
CONSTANT MaxNotifyDropLimit
CONSTANT MaxRNHRegisterLimit
CONSTANT MaxRNHSuppressLimit
CONSTANT MaxRestartLimit
CONSTANT MaxReconnectLimit
CONSTANT MaxReplayLimit
CONSTANT MaxProviderRestartLimit
CONSTANT MaxShutdownLimit
CONSTANT MaxCtxQueueLimit
CONSTANT MaxNotifyQueueLimit

ASSUME MaxBGPInstallLimit \in Nat
ASSUME MaxRouteAddLimit \in Nat
ASSUME MaxRouteDeleteLimit \in Nat
ASSUME MaxZapiSendFailLimit \in Nat
ASSUME MaxNotifySubscribeLimit \in Nat
ASSUME MaxMetaQueueLimit \in Nat
ASSUME MaxEnqueueFailLimit \in Nat
ASSUME MaxDplaneSuccessLimit \in Nat
ASSUME MaxDplaneFailureLimit \in Nat
ASSUME MaxProviderSkipLimit \in Nat
ASSUME MaxProviderPrivateLimit \in Nat
ASSUME MaxResultLostLimit \in Nat
ASSUME MaxRouteNotifyLimit \in Nat
ASSUME MaxNotifyDropLimit \in Nat
ASSUME MaxRNHRegisterLimit \in Nat
ASSUME MaxRNHSuppressLimit \in Nat
ASSUME MaxRestartLimit \in Nat
ASSUME MaxReconnectLimit \in Nat
ASSUME MaxReplayLimit \in Nat
ASSUME MaxProviderRestartLimit \in Nat
ASSUME MaxShutdownLimit \in Nat
ASSUME MaxCtxQueueLimit \in Nat
ASSUME MaxNotifyQueueLimit \in Nat

----
\* Counter state
----

VARIABLE constraintCounters

faultVars == <<constraintCounters>>
mcVars == <<vars, faultVars>>

CounterSet ==
    [ bgpInstall      : 0..MaxBGPInstallLimit,
      routeAdd        : 0..MaxRouteAddLimit,
      routeDelete     : 0..MaxRouteDeleteLimit,
      zapiSendFail    : 0..MaxZapiSendFailLimit,
      notifySubscribe : 0..MaxNotifySubscribeLimit,
      metaQueue       : 0..MaxMetaQueueLimit,
      enqueueFail     : 0..MaxEnqueueFailLimit,
      dplaneSuccess   : 0..MaxDplaneSuccessLimit,
      dplaneFailure   : 0..MaxDplaneFailureLimit,
      providerSkip    : 0..MaxProviderSkipLimit,
      providerPrivate : 0..MaxProviderPrivateLimit,
      resultLost      : 0..MaxResultLostLimit,
      routeNotify     : 0..MaxRouteNotifyLimit,
      notifyDrop      : 0..MaxNotifyDropLimit,
      rnhRegister     : 0..MaxRNHRegisterLimit,
      rnhSuppress     : 0..MaxRNHSuppressLimit,
      restart         : 0..MaxRestartLimit,
      reconnect       : 0..MaxReconnectLimit,
      replay          : 0..MaxReplayLimit,
      providerRestart : 0..MaxProviderRestartLimit,
      shutdown        : 0..MaxShutdownLimit ]

ZeroCounters ==
    [ bgpInstall      |-> 0,
      routeAdd        |-> 0,
      routeDelete     |-> 0,
      zapiSendFail    |-> 0,
      notifySubscribe |-> 0,
      metaQueue       |-> 0,
      enqueueFail     |-> 0,
      dplaneSuccess   |-> 0,
      dplaneFailure   |-> 0,
      providerSkip    |-> 0,
      providerPrivate |-> 0,
      resultLost      |-> 0,
      routeNotify     |-> 0,
      notifyDrop      |-> 0,
      rnhRegister     |-> 0,
      rnhSuppress     |-> 0,
      restart         |-> 0,
      reconnect       |-> 0,
      replay          |-> 0,
      providerRestart |-> 0,
      shutdown        |-> 0 ]

----
\* Counter-bounded wrappers
----

MCbgp_zebra_route_install(o, p) ==
    /\ constraintCounters.bgpInstall < MaxBGPInstallLimit
    /\ B!bgp_zebra_route_install(o, p)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.bgpInstall = @ + 1]

MCrib_addnode(p, o, t) ==
    /\ constraintCounters.routeAdd < MaxRouteAddLimit
    /\ B!rib_addnode(p, o, t)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.routeAdd = @ + 1]

MCrib_delnode(p) ==
    /\ constraintCounters.routeDelete < MaxRouteDeleteLimit
    /\ B!rib_delnode(p)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.routeDelete = @ + 1]

MCZapiSendFail(o, p) ==
    /\ constraintCounters.zapiSendFail < MaxZapiSendFailLimit
    /\ B!ZapiSendFail(o, p)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.zapiSendFail = @ + 1]

MCzread_route_notify_request(o) ==
    /\ constraintCounters.notifySubscribe < MaxNotifySubscribeLimit
    /\ B!zread_route_notify_request(o)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.notifySubscribe = @ + 1]

MCrib_meta_queue_add(p, q) ==
    /\ constraintCounters.metaQueue < MaxMetaQueueLimit
    /\ B!rib_meta_queue_add(p, q)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.metaQueue = @ + 1]

MCdplane_update_enqueue_failure(c) ==
    /\ constraintCounters.enqueueFail < MaxEnqueueFailLimit
    /\ B!dplane_update_enqueue_failure(c)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.enqueueFail = @ + 1]

MCkernel_dplane_process_func_success(c) ==
    /\ constraintCounters.dplaneSuccess < MaxDplaneSuccessLimit
    /\ B!kernel_dplane_process_func_success(c)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.dplaneSuccess = @ + 1]

MCkernel_dplane_process_func_failure(c) ==
    /\ constraintCounters.dplaneFailure < MaxDplaneFailureLimit
    /\ B!kernel_dplane_process_func_failure(c)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.dplaneFailure = @ + 1]

MCkernel_dplane_process_func_skip_kernel(c) ==
    /\ constraintCounters.providerSkip < MaxProviderSkipLimit
    /\ B!kernel_dplane_process_func_skip_kernel(c)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.providerSkip = @ + 1]

MCfpm_nl_process_private(c) ==
    /\ constraintCounters.providerPrivate < MaxProviderPrivateLimit
    /\ B!fpm_nl_process_private(c)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.providerPrivate = @ + 1]

MCdplane_result_lost(c) ==
    /\ constraintCounters.resultLost < MaxResultLostLimit
    /\ B!dplane_result_lost(c)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.resultLost = @ + 1]

MCDPLANE_OP_ROUTE_NOTIFY(p, g) ==
    /\ constraintCounters.routeNotify < MaxRouteNotifyLimit
    /\ B!DPLANE_OP_ROUTE_NOTIFY(p, g)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.routeNotify = @ + 1]

MCOwnerNotifyDrop(n) ==
    /\ constraintCounters.notifyDrop < MaxNotifyDropLimit
    /\ B!OwnerNotifyDrop(n)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.notifyDrop = @ + 1]

MCzebra_add_rnh(p, o) ==
    /\ constraintCounters.rnhRegister < MaxRNHRegisterLimit
    /\ B!zebra_add_rnh(p, o)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.rnhRegister = @ + 1]

MCcompare_state_suppress(p) ==
    /\ constraintCounters.rnhSuppress < MaxRNHSuppressLimit
    /\ B!compare_state_suppress(p)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.rnhSuppress = @ + 1]

MCZebraRestart ==
    /\ constraintCounters.restart < MaxRestartLimit
    /\ B!ZebraRestart
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.restart = @ + 1]

MCbgp_zebra_connected(o) ==
    /\ constraintCounters.reconnect < MaxReconnectLimit
    /\ B!bgp_zebra_connected(o)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.reconnect = @ + 1]

MCbgp_zebra_announce_table(o, p) ==
    /\ constraintCounters.replay < MaxReplayLimit
    /\ B!bgp_zebra_announce_table(o, p)
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.replay = @ + 1]

MCProviderRestart ==
    /\ constraintCounters.providerRestart < MaxProviderRestartLimit
    /\ B!ProviderRestart
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.providerRestart = @ + 1]

MCzebra_dplane_shutdown ==
    /\ constraintCounters.shutdown < MaxShutdownLimit
    /\ B!zebra_dplane_shutdown
    /\ constraintCounters' =
        [constraintCounters EXCEPT !.shutdown = @ + 1]

----
\* Reactive pass-through actions
----

Pass_bgp_handle_route_announcements_to_zebra(o, p) ==
    /\ B!bgp_handle_route_announcements_to_zebra(o, p)
    /\ UNCHANGED faultVars

Pass_meta_queue_process(p, q) ==
    /\ B!meta_queue_process(p, q)
    /\ UNCHANGED faultVars

Pass_rib_process(p) ==
    /\ B!rib_process(p)
    /\ UNCHANGED faultVars

Pass_rib_install_kernel(p) ==
    /\ B!rib_install_kernel(p)
    /\ UNCHANGED faultVars

Pass_rib_uninstall_kernel(p) ==
    /\ B!rib_uninstall_kernel(p)
    /\ UNCHANGED faultVars

Pass_dplane_ctx_route_init(p) ==
    /\ B!dplane_ctx_route_init(p)
    /\ UNCHANGED faultVars

Pass_dplane_update_enqueue(c) ==
    /\ B!dplane_update_enqueue(c)
    /\ UNCHANGED faultVars

Pass_dplane_thread_loop_to_provider(c) ==
    /\ B!dplane_thread_loop_to_provider(c)
    /\ UNCHANGED faultVars

Pass_fpm_process_queue(c) ==
    /\ B!fpm_process_queue(c)
    /\ UNCHANGED faultVars

Pass_dplane_thread_loop_result(c) ==
    /\ B!dplane_thread_loop_result(c)
    /\ UNCHANGED faultVars

Pass_rib_process_result(c) ==
    /\ B!rib_process_result(c)
    /\ UNCHANGED faultVars

Pass_rib_process_dplane_notify(c) ==
    /\ B!rib_process_dplane_notify(c)
    /\ UNCHANGED faultVars

Pass_route_notify_internal(n) ==
    /\ B!route_notify_internal(n)
    /\ UNCHANGED faultVars

Pass_bgp_zebra_route_notify_owner(n) ==
    /\ B!bgp_zebra_route_notify_owner(n)
    /\ UNCHANGED faultVars

Pass_zebra_rnh_store_in_routing_table(p) ==
    /\ B!zebra_rnh_store_in_routing_table(p)
    /\ UNCHANGED faultVars

Pass_zebra_rnh_resolve_nexthop_entry(p) ==
    /\ B!zebra_rnh_resolve_nexthop_entry(p)
    /\ UNCHANGED faultVars

Pass_zebra_send_rnh_update(p) ==
    /\ B!zebra_send_rnh_update(p)
    /\ UNCHANGED faultVars

Pass_rib_sweep_table(p) ==
    /\ B!rib_sweep_table(p)
    /\ UNCHANGED faultVars

----
\* Initialization and next-state relation
----

MCInit ==
    /\ Init
    /\ constraintCounters = ZeroCounters

MCNext ==
    \/ \E o \in Owner, p \in Prefix : MCbgp_zebra_route_install(o, p)
    \/ \E o \in Owner, p \in Prefix : Pass_bgp_handle_route_announcements_to_zebra(o, p)
    \/ \E o \in Owner, p \in Prefix : MCZapiSendFail(o, p)
    \/ \E o \in Owner : MCzread_route_notify_request(o)
    \/ \E o \in Owner : MCbgp_zebra_connected(o)
    \/ \E o \in Owner, p \in Prefix : MCbgp_zebra_announce_table(o, p)
    \/ \E o \in Owner, p \in Prefix, t \in TableId : MCrib_addnode(p, o, t)
    \/ \E p \in Prefix : MCrib_delnode(p)
    \/ \E p \in Prefix, q \in QueueKind : MCrib_meta_queue_add(p, q)
    \/ \E p \in Prefix, q \in QueueKind : Pass_meta_queue_process(p, q)
    \/ \E p \in Prefix : Pass_rib_process(p)
    \/ \E p \in Prefix : Pass_rib_install_kernel(p)
    \/ \E p \in Prefix : Pass_rib_uninstall_kernel(p)
    \/ \E p \in Prefix : Pass_dplane_ctx_route_init(p)
    \/ \E p \in Prefix : Pass_dplane_update_enqueue(ctxDraft[p])
    \/ \E p \in Prefix : MCdplane_update_enqueue_failure(ctxDraft[p])
    \/ \E c \in ctxQueue : Pass_dplane_thread_loop_to_provider(c)
    \/ \E c \in providerIn : MCkernel_dplane_process_func_success(c)
    \/ \E c \in providerIn : MCkernel_dplane_process_func_failure(c)
    \/ \E c \in providerIn : MCkernel_dplane_process_func_skip_kernel(c)
    \/ \E c \in providerIn : MCfpm_nl_process_private(c)
    \/ \E c \in providerPrivate : Pass_fpm_process_queue(c)
    \/ \E c \in providerOut : Pass_dplane_thread_loop_result(c)
    \/ \E c \in providerOut \cup resultQueue : MCdplane_result_lost(c)
    \/ \E p \in Prefix, g \in 0..MaxGen : MCDPLANE_OP_ROUTE_NOTIFY(p, g)
    \/ \E c \in resultQueue : Pass_rib_process_result(c)
    \/ \E c \in resultQueue : Pass_rib_process_dplane_notify(c)
    \/ \E n \in ownerNotifyObligation : Pass_route_notify_internal(n)
    \/ \E n \in notifyQueue : MCOwnerNotifyDrop(n)
    \/ \E n \in notifyQueue : Pass_bgp_zebra_route_notify_owner(n)
    \/ \E o \in Owner, p \in Prefix : MCzebra_add_rnh(p, o)
    \/ \E p \in Prefix : Pass_zebra_rnh_store_in_routing_table(p)
    \/ \E p \in Prefix : Pass_zebra_rnh_resolve_nexthop_entry(p)
    \/ \E p \in Prefix : MCcompare_state_suppress(p)
    \/ \E p \in Prefix : Pass_zebra_send_rnh_update(p)
    \/ MCZebraRestart
    \/ \E p \in Prefix : Pass_rib_sweep_table(p)
    \/ MCProviderRestart
    \/ MCzebra_dplane_shutdown

MCSpec ==
    /\ MCInit
    /\ [][MCNext]_mcVars
    /\ \A p \in Prefix : WF_mcVars(Pass_zebra_rnh_store_in_routing_table(p))

----
\* Constraints, symmetry, and invariants
----

MCStateConstraint ==
    /\ Cardinality(ctxQueue) <= MaxCtxQueueLimit
    /\ Cardinality(providerIn) <= MaxCtxQueueLimit
    /\ Cardinality(providerOut) <= MaxCtxQueueLimit
    /\ Cardinality(providerPrivate) <= MaxCtxQueueLimit
    /\ Cardinality(resultQueue) <= MaxCtxQueueLimit
    /\ Cardinality(ownerNotifyObligation) <= MaxNotifyQueueLimit
    /\ Cardinality(notifyQueue) <= MaxNotifyQueueLimit
    /\ Cardinality(nhtQueue) <= MaxNotifyQueueLimit

Symmetry == Permutations(Prefix)

MCTypeOK ==
    /\ TypeOK
    /\ constraintCounters \in CounterSet

MCStructuralOK ==
    /\ CtxIdsUnique
    /\ DraftsMatchPrefix
    /\ SelectedFibReferencesRoute

=====================================================================
