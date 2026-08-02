------------------------------- MODULE MC -------------------------------
(*
 * Counter-bounded model-checking wrapper for the iccpd base model.
 *
 * Only nondeterminism-introducing events are bounded.  FIFO delivery,
 * receive processing, stage advancement, successful external application,
 * restart processing, cleanup, and timer reactions remain unbounded.
 *)

EXTENDS base

\* Access the original actions even if a future cfg uses operator overrides.
iccpd == INSTANCE base

\* ==========================================================================
\* MODEL-CHECKING LIMITS AND STATE
\* ==========================================================================

CONSTANTS
    MaxWarmLimit,
    MaxDisconnectLimit,
    MaxCrashLimit,
    MaxReconnectLimit,
    MaxPartialWriteLimit,
    MaxFailedWriteLimit,
    MaxResyncLimit,
    MaxObjectUpdateLimit,
    MaxLagTransitionLimit,
    MaxApplyFailLimit,
    MaxPeerTopologyLimit,
    MaxPartialHeaderLimit,
    MaxNonProgressLimit,
    MaxSyncdEOFLimit,
    MaxNetlinkLossLimit,
    MaxSnapshotEventLimit,
    MaxChannelLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>
mc_vars == <<vars, faultVars>>

CounterStateType == [
    warm          : 0..MaxWarmLimit,
    disconnect    : 0..MaxDisconnectLimit,
    crash         : 0..MaxCrashLimit,
    reconnect     : 0..MaxReconnectLimit,
    partialWrite  : 0..MaxPartialWriteLimit,
    failedWrite   : 0..MaxFailedWriteLimit,
    resync        : 0..MaxResyncLimit,
    objectUpdate  : 0..MaxObjectUpdateLimit,
    lagTransition : 0..MaxLagTransitionLimit,
    applyFail     : 0..MaxApplyFailLimit,
    peerTopology  : 0..MaxPeerTopologyLimit,
    partialHeader : 0..MaxPartialHeaderLimit,
    nonProgress   : 0..MaxNonProgressLimit,
    syncdEOF      : 0..MaxSyncdEOFLimit,
    netlinkLoss   : 0..MaxNetlinkLossLimit,
    snapshotEvent : 0..MaxSnapshotEventLimit
]

\* ==========================================================================
\* BOUNDED NONDETERMINISM / FAULT INJECTION
\* ==========================================================================

MCmlacp_sync_send_warmboot_flag(i) ==
    \* Scenario 1: injecting a local warm announcement begins the recovery case.
    /\ faultCounters.warm < MaxWarmLimit
    /\ iccpd!mlacp_sync_send_warmboot_flag(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.warm = @ + 1]

MCscheduler_session_disconnect_handler(i) ==
    \* Scenarios 1/2: externally chosen EOF/session loss.
    /\ faultCounters.disconnect < MaxDisconnectLimit
    /\ iccpd!scheduler_session_disconnect_handler(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.disconnect = @ + 1]

MCsystem_finalize_Crash(i) ==
    \* Scenario 1: externally injected process loss.
    /\ faultCounters.crash < MaxCrashLimit
    /\ iccpd!system_finalize_Crash(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.crash = @ + 1]

MCiccp_csm_transit_Reconnect(i) ==
    \* Scenario 1: peer/network availability chooses whether reconnect occurs.
    /\ faultCounters.reconnect < MaxReconnectLimit
    /\ iccpd!iccp_csm_transit_Reconnect(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.reconnect = @ + 1]

MCiccp_csm_send_Partial(i) ==
    \* Scenario 2: positive short write corrupts the FIFO byte stream.
    /\ faultCounters.partialWrite < MaxPartialWriteLimit
    /\ iccpd!iccp_csm_send_Partial(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.partialWrite = @ + 1]

MCiccp_csm_send_Failed(i) ==
    \* Scenario 2: failed one-shot write with no rollback.
    /\ faultCounters.failedWrite < MaxFailedWriteLimit
    /\ iccpd!iccp_csm_send_Failed(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.failedWrite = @ + 1]

MCmlacp_exchange_handler_PrepareResync(i) ==
    \* Scenario 2: an established need_to_sync request is external work input.
    /\ faultCounters.resync < MaxResyncLimit
    /\ iccpd!mlacp_exchange_handler_PrepareResync(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.resync = @ + 1]

MCiccp_netlink_ObjectUpdate(i, v) ==
    \* Scenarios 1/2: finite external kernel/object mutation.
    /\ faultCounters.objectUpdate < MaxObjectUpdateLimit
    /\ iccpd!iccp_netlink_ObjectUpdate(i, v)
    /\ faultCounters' =
         [faultCounters EXCEPT !.objectUpdate = @ + 1]

MCmlacp_portchannel_state_handler(i, up) ==
    \* Scenario 3: local LAG flap/ABA input.
    /\ faultCounters.lagTransition < MaxLagTransitionLimit
    /\ iccpd!mlacp_portchannel_state_handler(i, up)
    /\ faultCounters' =
         [faultCounters EXCEPT !.lagTransition = @ + 1]

MCupdate_peerlink_isolate_from_all_csm_lif_Fail(i) ==
    \* Scenario 3: isolation side effect fails after desired-state mutation.
    /\ faultCounters.applyFail < MaxApplyFailLimit
    /\ iccpd!update_peerlink_isolate_from_all_csm_lif_Fail(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.applyFail = @ + 1]

MCmlacp_link_disable_traffic_distribution_Fail(i) ==
    \* Scenario 3: traffic-disable side effect failure shares the apply budget.
    /\ faultCounters.applyFail < MaxApplyFailLimit
    /\ iccpd!mlacp_link_disable_traffic_distribution_Fail(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.applyFail = @ + 1]

MCmlacp_link_enable_traffic_distribution_Fail(i) ==
    \* Scenario 3: ACK-triggered traffic-enable failure shares the budget.
    /\ faultCounters.applyFail < MaxApplyFailLimit
    /\ iccpd!mlacp_link_enable_traffic_distribution_Fail(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.applyFail = @ + 1]

MCmlacp_peer_mlag_intf_delete_handler(i) ==
    \* Scenario 3: remove the matching peer-interface record.
    /\ faultCounters.peerTopology < MaxPeerTopologyLimit
    /\ iccpd!mlacp_peer_mlag_intf_delete_handler(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.peerTopology = @ + 1]

MCmlacp_fsm_update_Agg_conf(i) ==
    \* Scenario 3: later peer config can restore that record.
    /\ faultCounters.peerTopology < MaxPeerTopologyLimit
    /\ iccpd!mlacp_fsm_update_Agg_conf(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.peerTopology = @ + 1]

MCscheduler_csm_read_callback_PartialHeader(i) ==
    \* Scenario 4: adversarial 1-7 byte peer-header prefix.
    /\ faultCounters.partialHeader < MaxPartialHeaderLimit
    /\ iccpd!scheduler_csm_read_callback_PartialHeader(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.partialHeader = @ + 1]

MCapp_csm_EnableNonProgressTraffic(i) ==
    \* Scenario 4: enable an ongoing stream of complete unsupported APP frames.
    /\ faultCounters.nonProgress < MaxNonProgressLimit
    /\ iccpd!app_csm_EnableNonProgressTraffic(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.nonProgress = @ + 1]

MCiccp_mclagsyncd_msg_handler_EOF(i) ==
    \* Scenario 4: sidecar EOF leaves a stale positive descriptor.
    /\ faultCounters.syncdEOF < MaxSyncdEOFLimit
    /\ iccpd!iccp_mclagsyncd_msg_handler_EOF(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.syncdEOF = @ + 1]

MCiccp_netlink_route_sock_event_handler_Error(i) ==
    \* Scenario 1: netlink loss records event-dependent resync.
    /\ faultCounters.netlinkLoss < MaxNetlinkLossLimit
    /\ iccpd!iccp_netlink_route_sock_event_handler_Error(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.netlinkLoss = @ + 1]

MCdo_arp_learn_from_kernel(i) ==
    \* Scenario 1: a later live event may repair the missing snapshot.
    /\ faultCounters.snapshotEvent < MaxSnapshotEventLimit
    /\ iccpd!do_arp_learn_from_kernel(i)
    /\ faultCounters' =
         [faultCounters EXCEPT !.snapshotEvent = @ + 1]

\* ==========================================================================
\* UNBOUNDED REACTIVE/DETERMINISTIC ACTION GROUPS
\* ==========================================================================

MCRecoveryProgress(i) ==
    \* Scenario 1 normal reactions are never counter-pruned.
    /\ \/ iccpd!mlacp_fsm_update_warmboot(i)
       \/ iccpd!mlacp_peer_disconn_handler_Grace(i)
       \/ iccpd!mlacp_peer_disconn_handler_Cleanup(i)
       \/ iccpd!iccp_csm_status_reset(i)
       \/ iccpd!mlacp_fsm_transit_WarmTimeout(i)
       \/ iccpd!scheduler_init_Restart(i)
       \/ iccpd!iccp_neigh_get_init(i)
       \/ iccpd!iccp_mclagsyncd_vlan_mbr_update_handler(i)
       \/ iccpd!iccp_netlink_sync_again(i)
    /\ UNCHANGED faultVars

MCSyncResponseProgress(i) ==
    \* Scenario 2 normal request/response and full writes remain unbounded.
    /\ \/ iccpd!mlacp_stage_sync_request_handler(i)
       \/ iccpd!mlacp_sync_recv_syncReq(i)
       \/ iccpd!mlacp_sync_send_all_info_handler_Prepare(i)
       \/ iccpd!mlacp_sync_sender_handler_SkipObject(i)
       \/ iccpd!iccp_csm_send_Full(i)
    /\ UNCHANGED faultVars

MCProtocolReceive(i) ==
    \* All decoded protocol handlers react to an existing FIFO head.
    /\ \/ iccpd!mlacp_sync_recv_syncData_Start(i)
       \/ iccpd!mlacp_sync_recv_sysConf(i)
       \/ iccpd!mlacp_sync_recv_aggConf(i)
       \/ iccpd!mlacp_sync_recv_aggState(i)
       \/ iccpd!mlacp_sync_recv_ObjectData(i)
       \/ iccpd!mlacp_sync_recv_syncData_End(i)
       \/ iccpd!mlacp_fsm_update_Aggport_state(i)
       \/ iccpd!mlacp_fsm_recv_if_up_ack(i)
       \/ iccpd!app_csm_enqueue_msg_NonProgress(i)
    /\ UNCHANGED faultVars

MCDataPlaneProgress(i) ==
    \* Scenario 3 successful application and ACK production are reactive.
    /\ \/ iccpd!mlacp_exchange_handler_PreparePortState(i)
       \/ iccpd!update_peerlink_isolate_from_all_csm_lif_Apply(i)
       \/ iccpd!mlacp_fsm_send_if_up_ack(i)
       \/ iccpd!mlacp_link_disable_traffic_distribution_Success(i)
       \/ iccpd!mlacp_link_enable_traffic_distribution_Success(i)
    /\ UNCHANGED faultVars

MCTransportDelivery(i) ==
    \* Scenario 4 FIFO delivery/corrupt-frame reaction is not a new fault.
    /\ \/ iccpd!scheduler_csm_read_callback_Complete(i)
       \/ iccpd!scheduler_csm_read_callback_Corrupt(i)
    /\ UNCHANGED faultVars

MCscheduler_csm_read_callback_ReadError(i) ==
    \* Once supplied by the peer/OS, the read-error reaction is deterministic.
    /\ iccpd!scheduler_csm_read_callback_ReadError(i)
    /\ UNCHANGED faultVars

MCscheduler_csm_read_callback_DeterministicRecovery(i) ==
    \* scheduler.c:185-239: a body read cannot remain in its bounded retry
    \* loop forever; retry exhaustion deterministically closes the session.
    \* A close at the other endpoint likewise eventually releases a blocked
    \* recv() with EOF.  A partial header while the peer remains live is
    \* intentionally excluded because scheduler.c:152-170 has no timeout.
    /\ MCscheduler_csm_read_callback_ReadError(i)
    /\ \/ runtime[i].streamState = "BodyRetry"
       \/ ~recovery[Peer(i)].sessionUp

MCiccp_csm_send_NonProgress(i) ==
    \* After one bounded enable, complete nonprogress traffic can continue.
    /\ iccpd!iccp_csm_send_NonProgress(i)
    /\ UNCHANGED faultVars

MCscheduler_transit_fsm_Tick(i) ==
    \* Normal scheduler timer progress is never bounded.
    /\ iccpd!scheduler_transit_fsm_Tick(i)
    /\ UNCHANGED faultVars

MCheartbeat_check(i) ==
    \* Enabled heartbeat timeout reaction is never bounded.
    /\ iccpd!heartbeat_check(i)
    /\ UNCHANGED faultVars

MCscheduler_loop_ReconnectSyncd(i) ==
    \* Descriptor-based sidecar reconnect reaction is never bounded.
    /\ iccpd!scheduler_loop_ReconnectSyncd(i)
    /\ UNCHANGED faultVars

\* ==========================================================================
\* INIT, NEXT, FAIRNESS
\* ==========================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
         warm          |-> 0,
         disconnect    |-> 0,
         crash         |-> 0,
         reconnect     |-> 0,
         partialWrite  |-> 0,
         failedWrite   |-> 0,
         resync        |-> 0,
         objectUpdate  |-> 0,
         lagTransition |-> 0,
         applyFail     |-> 0,
         peerTopology  |-> 0,
         partialHeader |-> 0,
         nonProgress   |-> 0,
         syncdEOF      |-> 0,
         netlinkLoss   |-> 0,
         snapshotEvent |-> 0]

MCNext(i) ==
    \* Bounded nondeterministic/fault actions.
    \/ MCmlacp_sync_send_warmboot_flag(i)
    \/ MCscheduler_session_disconnect_handler(i)
    \/ MCsystem_finalize_Crash(i)
    \/ MCiccp_csm_transit_Reconnect(i)
    \/ MCiccp_csm_send_Partial(i)
    \/ MCiccp_csm_send_Failed(i)
    \/ MCmlacp_exchange_handler_PrepareResync(i)
    \/ MCmlacp_peer_mlag_intf_delete_handler(i)
    \/ MCmlacp_fsm_update_Agg_conf(i)
    \/ MCscheduler_csm_read_callback_PartialHeader(i)
    \/ MCapp_csm_EnableNonProgressTraffic(i)
    \/ MCiccp_mclagsyncd_msg_handler_EOF(i)
    \/ MCiccp_netlink_route_sock_event_handler_Error(i)
    \/ MCdo_arp_learn_from_kernel(i)

    \* Unbounded deterministic/reactive actions.
    \/ MCRecoveryProgress(i)
    \/ MCSyncResponseProgress(i)
    \/ MCProtocolReceive(i)
    \/ MCDataPlaneProgress(i)
    \/ MCTransportDelivery(i)
    \/ MCscheduler_csm_read_callback_ReadError(i)
    \/ MCiccp_csm_send_NonProgress(i)
    \/ MCscheduler_transit_fsm_Tick(i)
    \/ MCheartbeat_check(i)
    \/ MCscheduler_loop_ReconnectSyncd(i)

MCNextWithValue ==
    \E i \in Node, v \in Versions :
        MCiccp_netlink_ObjectUpdate(i, v)

MCNextWithLagState ==
    \E i \in Node, up \in BOOLEAN :
        MCmlacp_portchannel_state_handler(i, up)

MCNextApplyFailure ==
    \E i \in Node :
        \/ MCupdate_peerlink_isolate_from_all_csm_lif_Fail(i)
        \/ MCmlacp_link_disable_traffic_distribution_Fail(i)
        \/ MCmlacp_link_enable_traffic_distribution_Fail(i)

MCNextAll ==
    \/ \E i \in Node : MCNext(i)
    \/ MCNextWithValue
    \/ MCNextWithLagState
    \/ MCNextApplyFailure

(*
 * Weak fairness is limited to enabled, non-blocked implementation reactions.
 * No fairness is imposed on faults, reconnect availability, snapshots, or
 * external input.  Aggregate actions are sufficient here because each node
 * has one tx buffer and each destination consumes only its FIFO head.
 *)
MCFairness ==
    /\ \A i \in Node : WF_mc_vars(MCRecoveryProgress(i))
    /\ \A i \in Node : WF_mc_vars(MCSyncResponseProgress(i))
    /\ \A i \in Node : WF_mc_vars(MCProtocolReceive(i))
    /\ \A i \in Node : WF_mc_vars(MCDataPlaneProgress(i))
    /\ \A i \in Node : WF_mc_vars(MCTransportDelivery(i))
    /\ \A i \in Node :
         WF_mc_vars(MCscheduler_csm_read_callback_DeterministicRecovery(i))
    /\ \A i \in Node : WF_mc_vars(MCscheduler_transit_fsm_Tick(i))
    /\ \A i \in Node : WF_mc_vars(MCheartbeat_check(i))

MCSpec ==
    /\ MCInit
    /\ [][MCNextAll]_mc_vars
    /\ MCFairness

\* ==========================================================================
\* SYMMETRY, VIEW, AND STATE-SPACE CONSTRAINTS
\* ==========================================================================

Symmetry == Permutations(Node)

\* Fault counters affect which future fault actions remain enabled, so they
\* are part of model-checking state equivalence.  Omitting them from VIEW can
\* merge behaviorally different states and make temporal trace recovery fail.
ModelView == mc_vars

ChannelConstraint ==
    \A i \in Node :
        /\ Len(wire[i]) <= MaxChannelLimit
        /\ Len(inbox[i]) <= MaxChannelLimit

\* ==========================================================================
\* STANDARD / STRUCTURAL INVARIANTS
\* ==========================================================================

CounterTypeOK == faultCounters \in CounterStateType

MCTypeOK == TypeOK /\ CounterTypeOK

MCTxPreparationConsistency == TxPreparationConsistency
MCIsolationGenerationConsistency == IsolationGenerationConsistency

PreparedFramesAreValid ==
    \A i \in Node :
        txFrame[i] /= NoFrame => txFrame[i].valid

CrashedSchedulerDisabled ==
    \A i \in Node :
        recovery[i].crashed =>
            /\ ~recovery[i].sessionUp
            /\ ~runtime[i].schedulerEnabled

SyncResponseHasEpoch ==
    \A i \in Node :
        sync[i].sendStep /= "Idle" =>
            sync[i].responderEpoch \in Epochs

FaultCountersWithinBounds == CounterTypeOK

\* ==========================================================================
\* EXPLICIT MC WIRING FOR BRIEF §5 INVARIANTS / PROPERTIES
\* ==========================================================================

MCLegalFSMState == LegalFSMState
MCSyncEnvelopeOrdering == SyncEnvelopeOrdering
MCConfigBeforeState == ConfigBeforeState
MCExchangeAgreement == ExchangeAgreement
MCDirtyStateAccounted == DirtyStateAccounted
MCRecoveryBeforeAdvertise == RecoveryBeforeAdvertise
MCCurrentIsolationBeforeTraffic == CurrentIsolationBeforeTraffic
MCNoPeerLinkLoop == NoPeerLinkLoop

MCWarmRecoveryTerminates == WarmRecoveryTerminates
MCSyncEventuallyResolves == SyncEventuallyResolves
MCStuckSessionDetected == StuckSessionDetected

=============================================================================
