------------------------------ MODULE Trace ------------------------------
(*
 * Linear Category-A trace replay for the iccpd base model.
 *
 * Every event has exactly one wrapper and every wrapper calls the complete
 * base action.  The common post-state snapshot includes implementation state,
 * external-effect shadow state, and monitor-only semantic provenance.  This
 * makes validation strong without treating absent fields as vacuously true.
 *)

EXTENDS base, Json, Sequences, TLC

\* ==========================================================================
\* TRACE LOADING
\* ==========================================================================

(*
 * JSONPath is the runner-set override.  IOEnv is represented as the same
 * record shape used by Specula's runner so JsonFile retains the required
 * IOEnv.JSON selection contract without requiring a non-standard TLA module.
 *)
CONSTANT JSONPath

IOEnv ==
    IF JSONPath = ""
    THEN [k \in {} |-> ""]
    ELSE [JSON |-> JSONPath]

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

VARIABLE l

traceVars == <<vars, l>>

logline == TraceLog[l]

TraceNode == TLCEval(
    {TraceLog[k].event.nid : k \in 1..Len(TraceLog)})

ASSUME TraceNode /= {}
ASSUME TraceNode \subseteq Node

\* ==========================================================================
\* TRACE VALUE MAPPING
\* ==========================================================================

TraceEpoch(v) == IF v = -1 THEN NoEpoch ELSE v
TraceVersion(v) == IF v = -1 THEN NoVersion ELSE v
TraceGen(v) == IF v = -1 THEN NoGen ELSE v

TraceTxKind(i) ==
    IF txFrame'[i] = NoFrame THEN "None" ELSE txFrame'[i].kind

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

StepTrace == l' = l + 1

\* ==========================================================================
\* MANDATORY STRONG POST-STATE VALIDATION
\* ==========================================================================

(*
 * All fields below are required in every event.state object by
 * instrumentation-spec.md.  No DOMAIN guard is used: a missing capture field
 * is a trace-schema error rather than a vacuously skipped check.
 *)
ValidatePostState(i) ==
    LET s == logline.event.state
    IN
    \* Scenario 1 recovery/session fields.
    /\ recovery'[i].sessionUp = s.sessionUp
    /\ recovery'[i].crashed = s.crashed
    /\ recovery'[i].disconnectPC = s.disconnectPC
    /\ recovery'[i].warmAnnounced = s.warmAnnounced
    /\ recovery'[i].graceArmed = s.graceArmed
    /\ recovery'[i].graceAge = s.graceAge
    /\ recovery'[i].cleanupDone = s.cleanupDone
    /\ recovery'[i].recoveryPending = s.recoveryPending
    /\ recovery'[i].startupPC = s.startupPC
    /\ recovery'[i].kernelTruth = s.kernelTruth
    /\ recovery'[i].observedState = s.observedState
    /\ recovery'[i].snapshotReady = s.snapshotReady
    /\ recovery'[i].advertisedState =
         TraceVersion(s.advertisedState)
    /\ recovery'[i].resyncPending = s.resyncPending

    \* Scenario 2 synchronization fields and monitors.
    /\ sync'[i].epoch = s.syncEpoch
    /\ sync'[i].phase = s.syncPhase
    /\ sync'[i].outstanding = TraceEpoch(s.outstandingReq)
    /\ sync'[i].responderEpoch = TraceEpoch(s.responderEpoch)
    /\ sync'[i].sendStep = s.syncSendStep
    /\ sync'[i].activeEnvelope = TraceEpoch(s.activeEnvelope)
    /\ sync'[i].configEpoch = TraceEpoch(s.configEpoch)
    /\ sync'[i].aggConfigEpoch = TraceEpoch(s.aggConfigEpoch)
    /\ sync'[i].stateEpoch = TraceEpoch(s.stateEpoch)
    /\ sync'[i].complete = TraceEpoch(s.syncComplete)
    /\ sync'[i].dirtyVersion = TraceVersion(s.dirtyVersion)
    /\ sync'[i].peerVersion = s.peerVersion
    /\ sync'[i].envelopeViolation = s.envelopeViolation
    /\ sync'[i].configOrderViolation = s.configOrderViolation
    /\ sync'[i].legalResyncActive = s.legalResyncActive
    /\ sync'[i].errorReason = s.errorReason

    \* Scenario 4 scheduler/heartbeat/sidecar fields.
    /\ runtime'[i].schedulerEnabled = s.schedulerEnabled
    /\ runtime'[i].streamState = s.streamState
    /\ runtime'[i].sessionActivity = s.sessionActivity
    /\ runtime'[i].protocolProgress = s.protocolProgress
    /\ runtime'[i].heartbeatAge = s.heartbeatAge
    /\ runtime'[i].nonProgressTraffic = s.nonProgressTraffic
    /\ runtime'[i].ignoredAppFrames = s.ignoredAppFrames
    /\ runtime'[i].syncdConnected = s.syncdConnected
    /\ runtime'[i].syncdFdPositive = s.syncdFdPositive

    \* Scenario 3 LAG/isolation/traffic fields.
    /\ lag'[i].gen = s.lagGen
    /\ lag'[i].localUp = s.localLagUp
    /\ lag'[i].dirty = s.lagDirty
    /\ lag'[i].peerKnownGen = TraceGen(s.peerKnownGen)
    /\ lag'[i].peerUp = s.peerLagUp
    /\ lag'[i].peerInterfaceKnown = s.peerInterfaceKnown
    /\ lag'[i].isolationDesired = s.isolationDesired
    /\ lag'[i].isolationPendingGen =
         TraceGen(s.isolationPendingGen)
    /\ lag'[i].isolationAppliedEnabled =
         s.isolationAppliedEnabled
    /\ lag'[i].isolationAppliedGen =
         TraceGen(s.isolationAppliedGen)
    /\ lag'[i].trafficEnabled = s.trafficEnabled
    /\ lag'[i].trafficApplyPending = s.trafficApplyPending
    /\ lag'[i].ackPending = TraceGen(s.ackPending)
    /\ lag'[i].ackGen = TraceGen(s.ackGen)

    \* Transport/buffer fields validate actions whose key update is a queue.
    /\ Len(wire'[i]) = s.outWireDepth
    /\ Len(wire'[Peer(i)]) = s.inWireDepth
    /\ Len(inbox'[i]) = s.inboxDepth
    /\ Len(inbox'[Peer(i)]) = s.peerInboxDepth
    /\ txContext'[i] = s.txContext
    /\ TraceTxKind(i) = s.txKind
    /\ sendOutcome'[i] = s.sendOutcome

Logged(i, name, action) ==
    /\ IsNodeEvent(name, i)
    /\ action
    /\ ValidatePostState(i)
    /\ StepTrace

\* ==========================================================================
\* ACTION WRAPPERS -- ONE EVENT TYPE PER BASE ACTION
\* ==========================================================================

\* scheduler.c:412-430.
mlacp_sync_send_warmboot_flag_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_send_warmboot_flag",
               mlacp_sync_send_warmboot_flag(i))

\* mlacp_sync_update.c:1342-1350.
mlacp_fsm_update_warmboot_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_fsm_update_warmboot",
               mlacp_fsm_update_warmboot(i))

\* scheduler.c:831-856.
scheduler_session_disconnect_handler_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_session_disconnect_handler",
               scheduler_session_disconnect_handler(i))

\* mlacp_link_handler.c:2376-2389.
mlacp_peer_disconn_handler_Grace_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_peer_disconn_handler_Grace",
               mlacp_peer_disconn_handler_Grace(i))

\* mlacp_link_handler.c:2391-2439.
mlacp_peer_disconn_handler_Cleanup_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_peer_disconn_handler_Cleanup",
               mlacp_peer_disconn_handler_Cleanup(i))

\* iccp_csm.c:129-166.
iccp_csm_status_reset_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_csm_status_reset",
               iccp_csm_status_reset(i))

\* mlacp_fsm.c:935-965.
mlacp_fsm_transit_WarmTimeout_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_fsm_transit_WarmTimeout",
               mlacp_fsm_transit_WarmTimeout(i))

\* system.c:94-190.
system_finalize_Crash_IfLogged ==
    \E i \in Node :
        Logged(i, "system_finalize_Crash",
               system_finalize_Crash(i))

\* system.c:60-92,175-190; scheduler.c:375-395.
scheduler_init_Restart_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_init_Restart",
               scheduler_init_Restart(i))

\* scheduler.c:383-395; iccp_ifm.c:188-268,448-528.
iccp_neigh_get_init_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_neigh_get_init",
               iccp_neigh_get_init(i))

\* mlacp_link_handler.c:3295-3324.
iccp_mclagsyncd_vlan_mbr_update_handler_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_mclagsyncd_vlan_mbr_update_handler",
               iccp_mclagsyncd_vlan_mbr_update_handler(i))

\* iccp_ifm.c:116-305,407-588.
do_arp_learn_from_kernel_IfLogged ==
    \E i \in Node :
        Logged(i, "do_arp_learn_from_kernel",
               do_arp_learn_from_kernel(i))

\* iccp_netlink.c:2059-2075.
iccp_netlink_route_sock_event_handler_Error_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_netlink_route_sock_event_handler_Error",
               iccp_netlink_route_sock_event_handler_Error(i))

\* iccp_netlink.c:2027-2056.
iccp_netlink_sync_again_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_netlink_sync_again",
               iccp_netlink_sync_again(i))

\* iccp_csm.c:297-367; mlacp_fsm.c:1008-1015.
iccp_csm_transit_Reconnect_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_csm_transit_Reconnect",
               iccp_csm_transit_Reconnect(i))

\* mlacp_fsm.c:1497-1517.
mlacp_stage_sync_request_handler_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_stage_sync_request_handler",
               mlacp_stage_sync_request_handler(i))

\* mlacp_fsm.c:1544-1576.
mlacp_exchange_handler_PrepareResync_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_exchange_handler_PrepareResync",
               mlacp_exchange_handler_PrepareResync(i))

\* mlacp_fsm.c:557-570.
mlacp_sync_recv_syncReq_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_recv_syncReq",
               mlacp_sync_recv_syncReq(i))

\* mlacp_fsm.c:1393-1463.
mlacp_sync_send_all_info_handler_Prepare_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_send_all_info_handler_Prepare",
               mlacp_sync_send_all_info_handler_Prepare(i))

\* mlacp_fsm.c:260-366,1393-1435.
mlacp_sync_sender_handler_SkipObject_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_sender_handler_SkipObject",
               mlacp_sync_sender_handler_SkipObject(i))

\* mlacp_fsm.c:538-550.
mlacp_sync_recv_syncData_Start_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_recv_syncData_Start",
               mlacp_sync_recv_syncData_Start(i))

\* mlacp_fsm.c:447-486.
mlacp_sync_recv_sysConf_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_recv_sysConf",
               mlacp_sync_recv_sysConf(i))

\* mlacp_fsm.c:488-505.
mlacp_sync_recv_aggConf_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_recv_aggConf",
               mlacp_sync_recv_aggConf(i))

\* mlacp_fsm.c:508-535.
mlacp_sync_recv_aggState_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_recv_aggState",
               mlacp_sync_recv_aggState(i))

\* mlacp_fsm.c:1296-1359.
mlacp_sync_recv_ObjectData_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_recv_ObjectData",
               mlacp_sync_recv_ObjectData(i))

\* mlacp_fsm.c:538-568,1497-1517.
mlacp_sync_recv_syncData_End_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_sync_recv_syncData_End",
               mlacp_sync_recv_syncData_End(i))

\* mlacp_link_handler.c:2067-2099.
mlacp_portchannel_state_handler_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_portchannel_state_handler",
               mlacp_portchannel_state_handler(
                   i, logline.event.args.up))

\* mlacp_fsm.c:1634-1645.
mlacp_exchange_handler_PreparePortState_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_exchange_handler_PreparePortState",
               mlacp_exchange_handler_PreparePortState(i))

\* mlacp_sync_update.c:165-210; mlacp_fsm.c:508-534.
mlacp_fsm_update_Aggport_state_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_fsm_update_Aggport_state",
               mlacp_fsm_update_Aggport_state(i))

\* mlacp_link_handler.c:1021-1220.
update_peerlink_isolate_from_all_csm_lif_Apply_IfLogged ==
    \E i \in Node :
        Logged(i, "update_peerlink_isolate_from_all_csm_lif_Apply",
               update_peerlink_isolate_from_all_csm_lif_Apply(i))

\* mlacp_link_handler.c:1021-1220.
update_peerlink_isolate_from_all_csm_lif_Fail_IfLogged ==
    \E i \in Node :
        Logged(i, "update_peerlink_isolate_from_all_csm_lif_Fail",
               update_peerlink_isolate_from_all_csm_lif_Fail(i))

\* mlacp_fsm.c:1676-1709.
mlacp_fsm_send_if_up_ack_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_fsm_send_if_up_ack",
               mlacp_fsm_send_if_up_ack(i))

\* mlacp_fsm.c:759-793.
mlacp_fsm_recv_if_up_ack_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_fsm_recv_if_up_ack",
               mlacp_fsm_recv_if_up_ack(i))

\* mlacp_link_handler.c:3588-3613.
mlacp_link_disable_traffic_distribution_Success_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_link_disable_traffic_distribution_Success",
               mlacp_link_disable_traffic_distribution_Success(i))

\* mlacp_link_handler.c:3588-3613.
mlacp_link_disable_traffic_distribution_Fail_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_link_disable_traffic_distribution_Fail",
               mlacp_link_disable_traffic_distribution_Fail(i))

\* mlacp_link_handler.c:3622-3638.
mlacp_link_enable_traffic_distribution_Success_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_link_enable_traffic_distribution_Success",
               mlacp_link_enable_traffic_distribution_Success(i))

\* mlacp_link_handler.c:3622-3638.
mlacp_link_enable_traffic_distribution_Fail_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_link_enable_traffic_distribution_Fail",
               mlacp_link_enable_traffic_distribution_Fail(i))

\* mlacp_link_handler.c:2143-2168.
mlacp_peer_mlag_intf_delete_handler_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_peer_mlag_intf_delete_handler",
               mlacp_peer_mlag_intf_delete_handler(i))

\* mlacp_sync_update.c:85-158.
mlacp_fsm_update_Agg_conf_IfLogged ==
    \E i \in Node :
        Logged(i, "mlacp_fsm_update_Agg_conf",
               mlacp_fsm_update_Agg_conf(i))

\* scheduler.c:244-253; iccp_netlink.c:2225-2235.
scheduler_csm_read_callback_Complete_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_csm_read_callback_Complete",
               scheduler_csm_read_callback_Complete(i))

\* scheduler.c:172-239.
scheduler_csm_read_callback_Corrupt_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_csm_read_callback_Corrupt",
               scheduler_csm_read_callback_Corrupt(i))

\* scheduler.c:129-170.
scheduler_csm_read_callback_PartialHeader_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_csm_read_callback_PartialHeader",
               scheduler_csm_read_callback_PartialHeader(i))

\* scheduler.c:155-167,193-257.
scheduler_csm_read_callback_ReadError_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_csm_read_callback_ReadError",
               scheduler_csm_read_callback_ReadError(i))

\* app_csm.c:100-145.
app_csm_EnableNonProgressTraffic_IfLogged ==
    \E i \in Node :
        Logged(i, "app_csm_EnableNonProgressTraffic",
               app_csm_EnableNonProgressTraffic(i))

\* iccp_csm.c:245-281.
iccp_csm_send_NonProgress_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_csm_send_NonProgress",
               iccp_csm_send_NonProgress(i))

\* app_csm.c:100-166.
app_csm_enqueue_msg_NonProgress_IfLogged ==
    \E i \in Node :
        Logged(i, "app_csm_enqueue_msg_NonProgress",
               app_csm_enqueue_msg_NonProgress(i))

\* scheduler.c:102-126,462-486.
scheduler_transit_fsm_Tick_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_transit_fsm_Tick",
               scheduler_transit_fsm_Tick(i))

\* scheduler.c:74-87.
heartbeat_check_IfLogged ==
    \E i \in Node :
        Logged(i, "heartbeat_check",
               heartbeat_check(i))

\* mlacp_link_handler.c:3350-3417; iccp_netlink.c:2212-2215.
iccp_mclagsyncd_msg_handler_EOF_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_mclagsyncd_msg_handler_EOF",
               iccp_mclagsyncd_msg_handler_EOF(i))

\* scheduler.c:469-474.
scheduler_loop_ReconnectSyncd_IfLogged ==
    \E i \in Node :
        Logged(i, "scheduler_loop_ReconnectSyncd",
               scheduler_loop_ReconnectSyncd(i))

\* iccp_csm.c:245-281 full/partial/failed branches.
iccp_csm_send_Full_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_csm_send_Full",
               iccp_csm_send_Full(i))

iccp_csm_send_Partial_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_csm_send_Partial",
               iccp_csm_send_Partial(i))

iccp_csm_send_Failed_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_csm_send_Failed",
               iccp_csm_send_Failed(i))

\* iccp_netlink.c:668-1070.
iccp_netlink_ObjectUpdate_IfLogged ==
    \E i \in Node :
        Logged(i, "iccp_netlink_ObjectUpdate",
               iccp_netlink_ObjectUpdate(
                   i, logline.event.args.version))

\* ==========================================================================
\* TRACE INIT, NEXT, COMPLETION
\* ==========================================================================

TraceInit ==
    /\ Init
    /\ l = 1

ConsumeLoggedEvent ==
    \/ mlacp_sync_send_warmboot_flag_IfLogged
    \/ mlacp_fsm_update_warmboot_IfLogged
    \/ scheduler_session_disconnect_handler_IfLogged
    \/ mlacp_peer_disconn_handler_Grace_IfLogged
    \/ mlacp_peer_disconn_handler_Cleanup_IfLogged
    \/ iccp_csm_status_reset_IfLogged
    \/ mlacp_fsm_transit_WarmTimeout_IfLogged
    \/ system_finalize_Crash_IfLogged
    \/ scheduler_init_Restart_IfLogged
    \/ iccp_neigh_get_init_IfLogged
    \/ iccp_mclagsyncd_vlan_mbr_update_handler_IfLogged
    \/ do_arp_learn_from_kernel_IfLogged
    \/ iccp_netlink_route_sock_event_handler_Error_IfLogged
    \/ iccp_netlink_sync_again_IfLogged
    \/ iccp_csm_transit_Reconnect_IfLogged
    \/ mlacp_stage_sync_request_handler_IfLogged
    \/ mlacp_exchange_handler_PrepareResync_IfLogged
    \/ mlacp_sync_recv_syncReq_IfLogged
    \/ mlacp_sync_send_all_info_handler_Prepare_IfLogged
    \/ mlacp_sync_sender_handler_SkipObject_IfLogged
    \/ mlacp_sync_recv_syncData_Start_IfLogged
    \/ mlacp_sync_recv_sysConf_IfLogged
    \/ mlacp_sync_recv_aggConf_IfLogged
    \/ mlacp_sync_recv_aggState_IfLogged
    \/ mlacp_sync_recv_ObjectData_IfLogged
    \/ mlacp_sync_recv_syncData_End_IfLogged
    \/ mlacp_portchannel_state_handler_IfLogged
    \/ mlacp_exchange_handler_PreparePortState_IfLogged
    \/ mlacp_fsm_update_Aggport_state_IfLogged
    \/ update_peerlink_isolate_from_all_csm_lif_Apply_IfLogged
    \/ update_peerlink_isolate_from_all_csm_lif_Fail_IfLogged
    \/ mlacp_fsm_send_if_up_ack_IfLogged
    \/ mlacp_fsm_recv_if_up_ack_IfLogged
    \/ mlacp_link_disable_traffic_distribution_Success_IfLogged
    \/ mlacp_link_disable_traffic_distribution_Fail_IfLogged
    \/ mlacp_link_enable_traffic_distribution_Success_IfLogged
    \/ mlacp_link_enable_traffic_distribution_Fail_IfLogged
    \/ mlacp_peer_mlag_intf_delete_handler_IfLogged
    \/ mlacp_fsm_update_Agg_conf_IfLogged
    \/ scheduler_csm_read_callback_Complete_IfLogged
    \/ scheduler_csm_read_callback_Corrupt_IfLogged
    \/ scheduler_csm_read_callback_PartialHeader_IfLogged
    \/ scheduler_csm_read_callback_ReadError_IfLogged
    \/ app_csm_EnableNonProgressTraffic_IfLogged
    \/ iccp_csm_send_NonProgress_IfLogged
    \/ app_csm_enqueue_msg_NonProgress_IfLogged
    \/ scheduler_transit_fsm_Tick_IfLogged
    \/ heartbeat_check_IfLogged
    \/ iccp_mclagsyncd_msg_handler_EOF_IfLogged
    \/ scheduler_loop_ReconnectSyncd_IfLogged
    \/ iccp_csm_send_Full_IfLogged
    \/ iccp_csm_send_Partial_IfLogged
    \/ iccp_csm_send_Failed_IfLogged
    \/ iccp_netlink_ObjectUpdate_IfLogged

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED traceVars

TraceNext ==
    \/ ConsumeLoggedEvent
    \/ TraceDone

(*
 * The fairness clause rules out bracket-generated stuttering while the next
 * logged event is matchable.  If no wrapper can reproduce the event,
 * ConsumeLoggedEvent is disabled and TraceMatched is violated.
 *)
TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceVars
    /\ WF_traceVars(ConsumeLoggedEvent)

TraceMatched == <>(l > Len(TraceLog))

TraceView == <<vars, l>>

TraceAlias ==
    [cursor       |-> l,
     traceLength  |-> Len(TraceLog),
     event        |->
         IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
     nid          |->
         IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
     recovery     |-> recovery,
     sync         |-> sync,
     runtime      |-> runtime,
     lag          |-> lag,
     wireDepth    |-> [i \in Node |-> Len(wire[i])],
     inboxDepth   |-> [i \in Node |-> Len(inbox[i])],
     txContext    |-> txContext,
     sendOutcome  |-> sendOutcome]

=============================================================================
