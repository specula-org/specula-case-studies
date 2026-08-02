------------------------------ MODULE base ------------------------------
(*
 * Scenario-driven TLA+ model of SONiC iccpd at revision
 * 9df8ccbf72c31948741b5554d09c38ac6c1ec6e9.
 *
 * Category A: distributed / message-passing.
 *
 * Scope:
 *   Scenario 1 -- warm-restart evidence, reconstruction, and cleanup
 *   Scenario 2 -- fallible FIFO synchronization transactions
 *   Scenario 3 -- generation-free IF_UP acknowledgement and data plane
 *   Scenario 4 -- scheduler progress versus transport activity
 *
 * The implementation has one serialized epoll scheduler.  Actions are split
 * where the brief identifies an observable failure boundary: local mutation,
 * write result, FIFO delivery, receive processing, external application, and
 * acknowledgement.  Monitor fields (for example recoveryPending and the
 * semantic frame epoch/gen) are ghost state: they expose obligations that the
 * C implementation does not retain, without strengthening its guards.
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ==========================================================================
\* CONSTANTS AND FINITE DOMAINS
\* ==========================================================================

CONSTANTS
    Node,                   \* Exactly the two ICCP peers
    MaxEpoch,               \* Semantic sync epochs explored
    MaxVersion,             \* Abstract replicated-object versions
    MaxLagGen,              \* Abstract local LAG transition generations
    MaxHeartbeatAge,        \* Abstract configured heartbeat timeout
    MaxProgress,            \* Saturation bound for trace/debug counters
    NoEpoch,
    NoVersion,
    NoGen,
    NoFrame

ASSUME Cardinality(Node) = 2
ASSUME MaxEpoch >= 1
ASSUME MaxVersion >= 1
ASSUME MaxLagGen >= 2
ASSUME MaxHeartbeatAge >= 1
ASSUME MaxProgress >= 1

Epochs == 0..MaxEpoch
Versions == 0..MaxVersion
LagGens == 0..MaxLagGen

EpochOrNone == Epochs \cup {NoEpoch}
VersionOrNone == Versions \cup {NoVersion}
GenOrNone == LagGens \cup {NoGen}

FSMStates == {"Init", "Stage1", "Stage2", "Exchange", "Error"}
DisconnectPCs == {"Idle", "Detected", "Handled"}
StartupPCs == {"Running", "NeedNeighborDump", "NeighborDumped"}
StreamStates == {"Idle", "PartialHeader", "BodyRetry"}
SendSteps == {"Idle", "Start", "SysConfig", "AggConfig",
              "AggState", "Object", "End"}
TxContexts == {"None", "Warmboot", "SyncRequest", "SyncResponse",
               "PortState", "IfUpAck"}
SendOutcomes == {"None", "Full", "Partial", "Failed"}
TrafficApplyStates == {"None", "Enable", "Disable"}
ErrorReasons == {"None", "LegalResyncAdvance", "ProtocolReject"}

FrameKinds == {
    "Warmboot",
    "SyncReq",
    "SyncStart",
    "SysConfig",
    "AggConfig",
    "AggState",
    "ObjectData",
    "SyncEnd",
    "PortState",
    "IfUpAck",
    "NonProgress"
}

FrameType == [
    kind    : FrameKinds,
    epoch   : EpochOrNone,
    version : VersionOrNone,
    gen     : GenOrNone,
    up      : BOOLEAN,
    valid   : BOOLEAN
]

RecoveryStateType == [
    sessionUp        : BOOLEAN,
    crashed          : BOOLEAN,
    disconnectPC     : DisconnectPCs,
    warmAnnounced    : BOOLEAN,
    graceArmed       : BOOLEAN,
    graceAge         : 0..(MaxHeartbeatAge + 1),
    cleanupDone      : BOOLEAN,
    recoveryPending  : BOOLEAN,
    startupPC        : StartupPCs,
    kernelTruth      : Versions,
    observedState    : Versions,
    snapshotReady    : BOOLEAN,
    advertisedState  : VersionOrNone,
    resyncPending    : BOOLEAN
]

SyncStateType == [
    epoch                 : Epochs,
    phase                 : FSMStates,
    outstanding           : EpochOrNone,
    responderEpoch        : EpochOrNone,
    sendStep              : SendSteps,
    activeEnvelope        : EpochOrNone,
    configEpoch           : EpochOrNone,
    aggConfigEpoch        : EpochOrNone,
    stateEpoch            : EpochOrNone,
    complete              : EpochOrNone,
    dirtyVersion          : VersionOrNone,
    peerVersion           : Versions,
    envelopeViolation     : BOOLEAN,
    configOrderViolation  : BOOLEAN,
    legalResyncActive     : BOOLEAN,
    errorReason           : ErrorReasons
]

RuntimeStateType == [
    schedulerEnabled   : BOOLEAN,
    streamState        : StreamStates,
    sessionActivity    : 0..MaxProgress,
    protocolProgress   : 0..MaxProgress,
    heartbeatAge       : 0..(MaxHeartbeatAge + 1),
    nonProgressTraffic : BOOLEAN,
    ignoredAppFrames   : 0..MaxProgress,
    syncdConnected     : BOOLEAN,
    syncdFdPositive    : BOOLEAN
]

LagStateType == [
    gen                       : LagGens,
    localUp                   : BOOLEAN,
    dirty                     : BOOLEAN,
    peerKnownGen              : GenOrNone,
    peerUp                    : BOOLEAN,
    peerInterfaceKnown        : BOOLEAN,
    isolationDesired          : BOOLEAN,
    isolationPendingGen       : GenOrNone,
    isolationAppliedEnabled   : BOOLEAN,
    isolationAppliedGen       : GenOrNone,
    trafficEnabled            : BOOLEAN,
    trafficApplyPending       : TrafficApplyStates,
    ackPending                : GenOrNone,
    ackGen                    : GenOrNone
]

\* ==========================================================================
\* VARIABLES
\* ==========================================================================

\* Scenario 1 state.  Fields retain the brief's variable names.
VARIABLE recovery

\* Scenario 2 transaction state and safety monitors.
VARIABLE sync

\* Per-source FIFO wire and per-destination decoded receive queue.
VARIABLE wire
VARIABLE inbox

\* A prepared userspace buffer and the caller waiting for iccp_csm_send.
VARIABLE txFrame
VARIABLE txContext
VARIABLE sendOutcome

\* Scenario 4 scheduler/heartbeat/sidecar state.
VARIABLE runtime

\* Scenario 3 local/peer LAG and forwarding state.
VARIABLE lag

vars == <<recovery, sync, wire, inbox, txFrame, txContext,
          sendOutcome, runtime, lag>>

\* ==========================================================================
\* HELPERS
\* ==========================================================================

Peer(i) == CHOOSE j \in Node : j /= i

IncBounded(x, limit) == IF x < limit THEN x + 1 ELSE x

MkFrame(kind, epoch, version, gen, up) ==
    [kind    |-> kind,
     epoch   |-> epoch,
     version |-> version,
     gen     |-> gen,
     up      |-> up,
     valid   |-> TRUE]

Corrupt(f) == [f EXCEPT !.valid = FALSE]

Incoming(i) == Head(inbox[i])
OnWireTo(i) == Head(wire[Peer(i)])

NextSendStep(step) ==
    CASE step = "Start"     -> "SysConfig"
      [] step = "SysConfig" -> "AggConfig"
      [] step = "AggConfig" -> "AggState"
      [] step = "AggState"  -> "Object"
      [] step = "Object"    -> "End"
      [] step = "End"       -> "Idle"

NextFSMState(state) ==
    CASE state = "Init"     -> "Stage1"
      [] state = "Stage1"   -> "Stage2"
      [] state = "Stage2"   -> "Exchange"
      [] state = "Exchange" -> "Error"
      [] state = "Error"    -> "Error"

FrameCarriesVersion(f, v) ==
    /\ f.kind = "ObjectData"
    /\ f.version = v
    /\ f.valid

SeqCarriesVersion(q, v) ==
    \E k \in 1..Len(q) : FrameCarriesVersion(q[k], v)

VersionInFlight(i, v) ==
    \/ /\ txFrame[i] /= NoFrame
       /\ FrameCarriesVersion(txFrame[i], v)
    \/ SeqCarriesVersion(wire[i], v)
    \/ SeqCarriesVersion(inbox[Peer(i)], v)

ProtocolQuiescent ==
    /\ \A i \in Node :
        /\ sync[i].outstanding = NoEpoch
        /\ sync[i].dirtyVersion = NoVersion
        /\ sync[i].sendStep = "Idle"
        /\ txFrame[i] = NoFrame
        /\ Len(wire[i]) = 0
        /\ Len(inbox[i]) = 0

PeerIsolationCurrent(i) ==
    /\ lag[Peer(i)].isolationAppliedEnabled
    /\ lag[Peer(i)].isolationAppliedGen = lag[i].gen

Stuck(i) ==
    /\ recovery[i].sessionUp
    /\ \/ ~runtime[i].schedulerEnabled
       \/ sync[i].phase = "Error"
       \/ sync[i].outstanding /= NoEpoch

Resolved(i) ==
    \/ ~recovery[i].sessionUp
    \/ /\ runtime[i].schedulerEnabled
       /\ sync[i].phase /= "Error"
       /\ sync[i].outstanding = NoEpoch

\* ==========================================================================
\* TRANSPORT SEND COMPLETION
\* ==========================================================================

(*
 * FinishSend mirrors the return boundary of iccp_csm_send.
 * The call performs one write and reports full, positive-short, or failed.
 * The calling code then advances or clears state according to its own branch.
 *)
FinishSend(i, outcome, newWire) ==
    LET f == txFrame[i]
        ctx == txContext[i]
        isResponse == ctx = "SyncResponse"
        isEnd == isResponse /\ f.kind = "SyncEnd"
        oldPhase == sync[i].phase
        responsePhase ==
            IF isEnd THEN NextFSMState(oldPhase) ELSE oldPhase
        responseStep ==
            IF isResponse THEN NextSendStep(sync[i].sendStep)
            ELSE sync[i].sendStep
        wrotePositive == outcome \in {"Full", "Partial"}
    IN
    \* iccp_csm.c:252-269 validates arguments and performs exactly one write.
    /\ txFrame[i] /= NoFrame
    /\ txContext[i] /= "None"

    \* iccp_csm.c:269-280: only a full write is valid; a positive short write
    \* is logged as an error but is still returned as a positive rc.
    /\ wire' = [wire EXCEPT ![i] = newWire]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = outcome]

    \* mlacp_fsm.c:1447-1461: full-response state advances after every send
    \* result; EXCHANGE is blindly incremented to ERROR on an established
    \* resync.  The semantic responder epoch is monitor-only.
    /\ sync' = [sync EXCEPT
         ![i].sendStep =
             IF isResponse THEN responseStep ELSE @,
         ![i].phase =
             IF isEnd THEN responsePhase ELSE @,
         ![i].complete =
             IF isEnd THEN sync[i].responderEpoch ELSE @,
         ![i].legalResyncActive =
             IF isEnd /\ oldPhase /= "Exchange" THEN FALSE ELSE @,
         ![i].errorReason =
             IF isEnd /\ oldPhase = "Exchange"
             THEN "LegalResyncAdvance"
             ELSE @]

    \* mlacp_fsm.c:270-302,315-366: object deltas were removed before the
    \* write.  A positive write, including a corrupt partial write, counts as
    \* an advertisement attempt.
    /\ recovery' = [recovery EXCEPT
         ![i].advertisedState =
             IF /\ ctx = "SyncResponse"
                /\ f.kind = "ObjectData"
                /\ f.version /= NoVersion
                /\ wrotePositive
             THEN f.version
             ELSE @]

    \* mlacp_fsm.c:1634-1645: the LAG changed flag is cleared on rc > 0,
    \* including a positive short write, but retained on rc <= 0.
    /\ lag' = [lag EXCEPT
         ![i].dirty =
             IF ctx = "PortState" /\ wrotePositive THEN FALSE ELSE @]

    \* The prepared global buffer is immediately reusable after return.
    \* iccp_csm.c:269-281; mlacp_fsm.c:1438-1465,1634-1645,1676-1709.
    /\ txFrame' = [txFrame EXCEPT ![i] = NoFrame]
    /\ txContext' = [txContext EXCEPT ![i] = "None"]
    /\ UNCHANGED <<inbox, runtime>>

\* Full write: a valid frame enters the ordered TCP stream.
\* iccp_csm.c:269-280.
iccp_csm_send_Full(i) ==
    \* iccp_csm.c:252-269: a live socket and prepared positive-length buffer.
    /\ recovery[i].sessionUp
    /\ ~recovery[i].crashed
    /\ txFrame[i] /= NoFrame
    \* iccp_csm.c:269,276-280: rc == msg_len.
    /\ FinishSend(i, "Full", Append(wire[i], txFrame[i]))

\* Positive short write: the prefix enters TCP and corrupts framing.
\* iccp_csm.c:269-275; scheduler.c:172-239.
iccp_csm_send_Partial(i) ==
    \* iccp_csm.c:252-269: same call preconditions as the full path.
    /\ recovery[i].sessionUp
    /\ ~recovery[i].crashed
    /\ txFrame[i] /= NoFrame
    \* iccp_csm.c:270-275: 0 < rc < msg_len is only logged.
    /\ FinishSend(i, "Partial", Append(wire[i], Corrupt(txFrame[i])))

\* Failed write: no frame is delivered, but destructive callers still advance.
\* iccp_csm.c:269-281.
iccp_csm_send_Failed(i) ==
    \* iccp_csm.c:252-269: call is made on the current socket.
    /\ recovery[i].sessionUp
    /\ ~recovery[i].crashed
    /\ txFrame[i] /= NoFrame
    \* iccp_csm.c:270-275: rc <= 0 is logged without rollback/retry.
    /\ FinishSend(i, "Failed", wire[i])

\* ==========================================================================
\* SCENARIO 1 -- RECOVERY EVIDENCE AND RECONSTRUCTION
\* ==========================================================================

\* Local warm shutdown prepares the peer-visible warmboot TLV.
\* scheduler.c:412-430 (mlacp_sync_send_warmboot_flag).
mlacp_sync_send_warmboot_flag(i) ==
    \* scheduler.c:418-424: only an EXCHANGE CSM sends this TLV.
    /\ recovery[i].sessionUp
    /\ sync[i].phase = "Exchange"
    /\ txFrame[i] = NoFrame
    \* scheduler.c:425-427: prepare then call iccp_csm_send.
    /\ txFrame' = [txFrame EXCEPT ![i] =
         MkFrame("Warmboot", NoEpoch, NoVersion, NoGen, FALSE)]
    /\ txContext' = [txContext EXCEPT ![i] = "Warmboot"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    /\ UNCHANGED <<recovery, sync, wire, inbox, runtime, lag>>

\* Peer receipt stores transient peer_warm_reboot_time.
\* mlacp_sync_update.c:1342-1350 (mlacp_fsm_update_warmboot).
mlacp_fsm_update_warmboot(i) ==
    \* mlacp_sync_update.c:1343-1345: valid CSM/TLV on the live scheduler.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ Incoming(i).kind = "Warmboot"
    /\ Incoming(i).valid
    \* mlacp_sync_update.c:1347-1349: set the transient warm marker.
    /\ recovery' = [recovery EXCEPT ![i].warmAnnounced = TRUE]
    \* mlacp_fsm.c:1296-1382: the dequeued message is consumed.
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<sync, wire, txFrame, txContext, sendOutcome, lag>>

(*
 * Disconnect detection is split from the handler and reset because the brief
 * explicitly targets those semantic boundaries.
 *)
BeginDisconnect(i) ==
    \* scheduler.c:831-850: unregister and close the peer socket first.
    /\ recovery[i].sessionUp
    /\ recovery[i].disconnectPC = "Idle"
    /\ recovery' = [recovery EXCEPT
         ![i].sessionUp = FALSE,
         ![i].disconnectPC = "Detected",
         ![i].cleanupDone = FALSE,
         ![i].recoveryPending = TRUE]
    \* scheduler.c:255-257,831-856: a completed read error returns control to
    \* the scheduler before the disconnect handler continues.
    /\ runtime' = [runtime EXCEPT
         ![i].schedulerEnabled = TRUE,
         ![i].streamState = "Idle"]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* External EOF/session-loss entry to scheduler_session_disconnect_handler.
\* scheduler.c:255-257,831-856.
scheduler_session_disconnect_handler(i) ==
    \* scheduler.c:836-850: valid live CSM whose socket is being removed.
    /\ ~recovery[i].crashed
    /\ BeginDisconnect(i)

\* Warm branch: install grace and return before ordinary cleanup.
\* mlacp_link_handler.c:2349-2389 (mlacp_peer_disconn_handler).
mlacp_peer_disconn_handler_Grace(i) ==
    \* mlacp_link_handler.c:2360-2378: handler entered for a non-local-warm
    \* shutdown after socket teardown.
    /\ recovery[i].disconnectPC = "Detected"
    /\ recovery[i].warmAnnounced
    \* mlacp_link_handler.c:2380-2388: clear peer marker, arm disconnect grace,
    \* and return before FDB/isolation/interface recovery.
    /\ recovery' = [recovery EXCEPT
         ![i].warmAnnounced = FALSE,
         ![i].graceArmed = TRUE,
         ![i].graceAge = 0,
         ![i].disconnectPC = "Handled"]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* Ordinary branch: perform failover cleanup.
\* mlacp_link_handler.c:2391-2439 (mlacp_peer_disconn_handler).
mlacp_peer_disconn_handler_Cleanup(i) ==
    \* mlacp_link_handler.c:2376-2391: normal cleanup only when no warm marker.
    /\ recovery[i].disconnectPC = "Detected"
    /\ ~recovery[i].warmAnnounced
    \* mlacp_link_handler.c:2391-2439: FDB conversion, ICCP-down notification,
    \* isolation cleanup, traffic recovery, and remote-interface removal.
    /\ recovery' = [recovery EXCEPT
         ![i].cleanupDone = TRUE,
         ![i].recoveryPending = FALSE,
         ![i].disconnectPC = "Handled",
         ![i].advertisedState = NoVersion]
    \* mlacp_link_handler.c:2399-2417: cleanup removes peer isolation and
    \* re-enables a locally disabled MLAG interface.
    /\ lag' = [lag EXCEPT
         ![i].isolationDesired = FALSE,
         ![i].isolationPendingGen = NoGen,
         ![i].trafficEnabled = TRUE,
         ![i].trafficApplyPending = "None"]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Status reset immediately destroys both warm-recovery timestamps.
\* iccp_csm.c:129-166 (iccp_csm_status_reset).
iccp_csm_status_reset(i) ==
    \* scheduler.c:851-853: reset follows peer-disconnect handling.
    /\ recovery[i].disconnectPC = "Handled"
    \* iccp_csm.c:140-158: socket/state reset; lines 145-146 zero both markers.
    /\ recovery' = [recovery EXCEPT
         ![i].disconnectPC = "Idle",
         ![i].warmAnnounced = FALSE,
         ![i].graceArmed = FALSE,
         ![i].graceAge = 0]
    \* iccp_csm.c:132,158-163 and app_csm initialization clear queued
    \* protocol state and return mLACP to Init.
    /\ sync' = [sync EXCEPT
         ![i].phase = "Init",
         ![i].outstanding = NoEpoch,
         ![i].responderEpoch = NoEpoch,
         ![i].sendStep = "Idle",
         ![i].activeEnvelope = NoEpoch,
         ![i].legalResyncActive = FALSE]
    \* Closing this sole modeled TCP connection drops both directions; this
    \* excludes old-connection data/ACK crossing reconnect.
    \* scheduler.c:844-853,861-895.
    /\ wire' = [n \in Node |-> <<>>]
    /\ inbox' = [n \in Node |-> <<>>]
    /\ txFrame' = [txFrame EXCEPT ![i] = NoFrame]
    /\ txContext' = [txContext EXCEPT ![i] = "None"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    /\ UNCHANGED <<runtime, lag>>

\* Intended grace timeout; its session-operational guard makes it unreachable
\* during the disconnected interval.
\* mlacp_fsm.c:935-965 (mlacp_fsm_transit).
mlacp_fsm_transit_WarmTimeout(i) ==
    \* mlacp_fsm.c:935-954: disconnected/non-operational CSM returns first.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    \* mlacp_fsm.c:956-965: only then can the 90-second grace be tested.
    /\ recovery[i].graceArmed
    /\ recovery[i].graceAge > MaxHeartbeatAge
    /\ recovery' = [recovery EXCEPT
         ![i].graceArmed = FALSE,
         ![i].graceAge = 0,
         ![i].cleanupDone = TRUE,
         ![i].recoveryPending = FALSE]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* Process loss destroys volatile reconstruction state but not kernel truth.
\* system.c:94-173 (system_finalize) and 175-190 (system_create_csm).
system_finalize_Crash(i) ==
    \* system.c:102-115: tear down the live CSM and its peer socket.
    /\ ~recovery[i].crashed
    /\ recovery' = [recovery EXCEPT
         ![i].crashed = TRUE,
         ![i].sessionUp = FALSE,
         ![i].warmAnnounced = FALSE,
         ![i].graceArmed = FALSE,
         ![i].graceAge = 0,
         ![i].disconnectPC = "Idle",
         ![i].startupPC = "NeedNeighborDump",
         ![i].snapshotReady = FALSE,
         ![i].advertisedState = NoVersion]
    \* system.c:118-171: volatile protocol and descriptor state is released.
    /\ sync' = [sync EXCEPT
         ![i].phase = "Init",
         ![i].outstanding = NoEpoch,
         ![i].responderEpoch = NoEpoch,
         ![i].sendStep = "Idle",
         ![i].activeEnvelope = NoEpoch,
         ![i].dirtyVersion = NoVersion]
    /\ runtime' = [runtime EXCEPT
         ![i].schedulerEnabled = FALSE,
         ![i].streamState = "Idle",
         ![i].syncdConnected = FALSE,
         ![i].syncdFdPositive = FALSE]
    \* scheduler.c:861-895: connection contents cannot survive close.
    /\ wire' = [n \in Node |-> <<>>]
    /\ inbox' = [n \in Node |-> <<>>]
    /\ txFrame' = [txFrame EXCEPT ![i] = NoFrame]
    /\ txContext' = [txContext EXCEPT ![i] = "None"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    /\ UNCHANGED lag

\* Restart creates zeroed userspace caches before ordered startup dumps.
\* system.c:60-92,175-190; scheduler.c:375-395.
scheduler_init_Restart(i) ==
    \* system.c:60-92,175-190: allocate and initialize a fresh System/CSM.
    /\ recovery[i].crashed
    /\ recovery' = [recovery EXCEPT
         ![i].crashed = FALSE,
         ![i].sessionUp = FALSE,
         ![i].startupPC = "NeedNeighborDump",
         ![i].observedState = 0,
         ![i].snapshotReady = FALSE,
         ![i].advertisedState = NoVersion,
         ![i].cleanupDone = FALSE]
    \* scheduler.c:375-383: the single scheduler is runnable again.
    /\ runtime' = [runtime EXCEPT
         ![i].schedulerEnabled = TRUE,
         ![i].streamState = "Idle",
         ![i].heartbeatAge = 0]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* Startup neighbor dump occurs before syncd supplies VLAN membership.
\* scheduler.c:383-395; iccp_ifm.c:188-268,448-528.
iccp_neigh_get_init(i) ==
    \* scheduler.c:383-393: GETLINK/GETADDR/config precede this one GETNEIGH.
    /\ ~recovery[i].crashed
    /\ recovery[i].startupPC = "NeedNeighborDump"
    \* iccp_ifm.c:188-268,448-528: L2 neighbors are retained only if VLAN
    \* membership is already known; otherwise the zeroed cache remains.
    /\ recovery' = [recovery EXCEPT
         ![i].observedState =
             IF recovery[i].snapshotReady
             THEN recovery[i].kernelTruth
             ELSE 0,
         ![i].startupPC = "NeighborDumped"]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* Later syncd VLAN membership makes classification possible but does not
\* trigger a second neighbor dump.
\* mlacp_link_handler.c:3295-3324.
iccp_mclagsyncd_vlan_mbr_update_handler(i) ==
    \* mlacp_link_handler.c:3303-3323: consume add/delete membership updates.
    /\ ~recovery[i].crashed
    /\ recovery[i].startupPC = "NeighborDumped"
    /\ runtime[i].syncdConnected
    \* mlacp_link_handler.c:3324-3326: return without iccp_neigh_get_init.
    /\ recovery' = [recovery EXCEPT
         ![i].snapshotReady = TRUE,
         ![i].startupPC = "Running"]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* A later real neighbor event can authoritatively repair one abstract object.
\* iccp_ifm.c:116-305,407-588 (do_arp/ndisc_learn_from_kernel).
do_arp_learn_from_kernel(i) ==
    \* iccp_ifm.c:188-268,448-528: classification now succeeds only after
    \* interface/VLAN reconstruction is available.
    /\ recovery[i].snapshotReady
    /\ recovery[i].observedState /= recovery[i].kernelTruth
    \* iccp_ifm.c:279-305,541-588: update the local cache and enqueue a delta.
    /\ recovery' = [recovery EXCEPT
         ![i].observedState = recovery[i].kernelTruth]
    /\ sync' = [sync EXCEPT
         ![i].dirtyVersion = recovery[i].kernelTruth]
    /\ UNCHANGED <<wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* A normal kernel object change updates truth/cache and creates dirty state.
\* iccp_netlink.c:668-1070; mlacp_link_handler.c:2654-2925.
iccp_netlink_ObjectUpdate(i, v) ==
    \* iccp_netlink.c:668-1070: a live netlink event carries a new object view.
    /\ v \in Versions
    /\ v /= recovery[i].kernelTruth
    /\ recovery[i].snapshotReady
    \* mlacp_link_handler.c:2654-2925: mutate the cache and enqueue peer delta.
    /\ recovery' = [recovery EXCEPT
         ![i].kernelTruth = v,
         ![i].observedState = v]
    /\ sync' = [sync EXCEPT ![i].dirtyVersion = v]
    /\ UNCHANGED <<wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* Route-netlink failure records a deferred resync request.
\* iccp_netlink.c:2059-2075.
iccp_netlink_route_sock_event_handler_Error(i) ==
    \* iccp_netlink.c:2063-2069: receive failure sets the resync flag.
    /\ ~recovery[i].resyncPending
    /\ recovery' = [recovery EXCEPT ![i].resyncPending = TRUE]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* Event-driven retry clears the flag but performs GETLINK only.
\* iccp_netlink.c:2027-2056; iccp_ifm.c:63-114.
iccp_netlink_sync_again(i) ==
    \* iccp_netlink.c:2071-2075: retry runs only after a later successful event.
    /\ recovery[i].resyncPending
    /\ runtime[i].schedulerEnabled
    \* iccp_netlink.c:2035-2041: clear before unchecked GETLINK work; no
    \* address or neighbor dump changes observedState.
    /\ recovery' = [recovery EXCEPT ![i].resyncPending = FALSE]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* Re-establish TCP/application state and begin staged mLACP synchronization.
\* iccp_csm.c:297-367; app_csm.c:85-95; mlacp_fsm.c:1008-1015.
iccp_csm_transit_Reconnect(i) ==
    \* iccp_csm.c:310-367: the configured socket/capability/RG handshake
    \* eventually reaches ICCP_OPERATIONAL.
    /\ ~recovery[i].crashed
    /\ ~recovery[i].sessionUp
    /\ recovery[i].disconnectPC = "Idle"
    /\ runtime[i].schedulerEnabled
    \* app_csm.c:92-95 and mlacp_fsm.c:1008-1015: application operational
    \* enters Stage1 and repopulates ARP/ND delta queues from the current cache.
    /\ recovery' = [recovery EXCEPT
         ![i].sessionUp = TRUE,
         ![i].recoveryPending = FALSE]
    /\ sync' = [sync EXCEPT
         ![i].phase = "Stage1",
         ![i].outstanding = NoEpoch,
         ![i].responderEpoch = NoEpoch,
         ![i].sendStep = "Idle",
         ![i].activeEnvelope = NoEpoch,
         ![i].dirtyVersion = recovery[i].observedState,
         ![i].errorReason = "None"]
    /\ runtime' = [runtime EXCEPT ![i].heartbeatAge = 0]
    /\ UNCHANGED <<wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* ==========================================================================
\* SCENARIO 2 -- SYNCHRONIZATION TRANSACTION
\* ==========================================================================

\* Stage requester prepares request zero and marks itself waiting before any
\* delivery proof.
\* mlacp_fsm.c:1497-1517; mlacp_sync_prepare.c:49-98.
mlacp_stage_sync_request_handler(i) ==
    LET nextEpoch == sync[i].epoch + 1
    IN
    \* mlacp_fsm.c:1501-1507: requester in Stage1/Stage2 prepares the request.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ sync[i].phase \in {"Stage1", "Stage2"}
    /\ sync[i].outstanding = NoEpoch
    /\ sync[i].epoch < MaxEpoch
    /\ txFrame[i] = NoFrame
    \* mlacp_sync_prepare.c:77-89: wire request number is always zero; epoch is
    \* ghost provenance used only by the monitor.
    /\ txFrame' = [txFrame EXCEPT ![i] =
         MkFrame("SyncReq", nextEpoch, NoVersion, NoGen, FALSE)]
    /\ txContext' = [txContext EXCEPT ![i] = "SyncRequest"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    \* mlacp_fsm.c:1507-1509: wait state advances after unchecked send; the
    \* model records the obligation at preparation so failure remains visible.
    /\ sync' = [sync EXCEPT
         ![i].epoch = nextEpoch,
         ![i].outstanding = nextEpoch]
    /\ UNCHANGED <<recovery, wire, inbox, runtime, lag>>

\* Established resync clears need_to_sync and emits another uncorrelated zero
\* request even if an earlier request is still outstanding.
\* mlacp_fsm.c:1544-1576 (mlacp_exchange_handler).
mlacp_exchange_handler_PrepareResync(i) ==
    LET nextEpoch == sync[i].epoch + 1
    IN
    \* mlacp_fsm.c:1569-1575: a legal EXCHANGE need_to_sync request.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ sync[i].phase = "Exchange"
    /\ sync[i].epoch < MaxEpoch
    /\ txFrame[i] = NoFrame
    \* mlacp_sync_prepare.c:77-89: req_num remains zero; replacing the ghost
    \* outstanding epoch exposes absent implementation correlation.
    /\ txFrame' = [txFrame EXCEPT ![i] =
         MkFrame("SyncReq", nextEpoch, NoVersion, NoGen, FALSE)]
    /\ txContext' = [txContext EXCEPT ![i] = "SyncRequest"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    /\ sync' = [sync EXCEPT
         ![i].epoch = nextEpoch,
         ![i].outstanding = nextEpoch]
    /\ recovery' = [recovery EXCEPT ![i].resyncPending = FALSE]
    /\ UNCHANGED <<wire, inbox, runtime, lag>>

\* Receive Sync Request and enter the synchronous Start/Data/End response loop.
\* mlacp_fsm.c:557-570,1296-1340.
mlacp_sync_recv_syncReq(i) ==
    LET f == Incoming(i)
    IN
    \* mlacp_fsm.c:1296-1340: dispatch a decoded Sync Request.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "SyncReq"
    /\ f.valid
    /\ sync[i].sendStep = "Idle"
    /\ txFrame[i] = NoFrame
    \* mlacp_fsm.c:561-568: store req_num (always zero) and call send-all.
    /\ sync' = [sync EXCEPT
         ![i].responderEpoch = f.epoch,
         ![i].sendStep = "Start",
         ![i].legalResyncActive =
             (sync[i].phase = "Exchange")]
    \* mlacp_fsm.c:1035-1039: consumed message is freed.
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* Prepare the current full-response element.  Each write remains separate.
\* mlacp_fsm.c:1393-1463 (mlacp_sync_sender/send_all_info_handler).
mlacp_sync_send_all_info_handler_Prepare(i) ==
    LET step == sync[i].sendStep
        kind ==
            CASE step = "Start"     -> "SyncStart"
              [] step = "SysConfig" -> "SysConfig"
              [] step = "AggConfig" -> "AggConfig"
              [] step = "AggState"  -> "AggState"
              [] step = "Object"    -> "ObjectData"
              [] step = "End"       -> "SyncEnd"
        version ==
            IF step = "Object" THEN sync[i].dirtyVersion ELSE NoVersion
    IN
    \* mlacp_fsm.c:1438-1452: loop prepares exactly the current sender stage.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ step /= "Idle"
    /\ ~(step = "Object" /\ sync[i].dirtyVersion = NoVersion)
    /\ txFrame[i] = NoFrame
    \* mlacp_fsm.c:1393-1429,1442-1455: Start, ordered config/state,
    \* abstract object delta, and End are sent in this order.
    /\ txFrame' = [txFrame EXCEPT ![i] =
         MkFrame(kind, sync[i].responderEpoch, version, NoGen, FALSE)]
    /\ txContext' = [txContext EXCEPT ![i] = "SyncResponse"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    \* mlacp_fsm.c:270-366: the abstract object is removed/freed before its
    \* unchecked write, unlike a retained retry queue.
    /\ sync' = [sync EXCEPT
         ![i].dirtyVersion =
             IF step = "Object" THEN NoVersion ELSE @]
    /\ UNCHANGED <<recovery, wire, inbox, runtime, lag>>

\* Empty persistent/delta queues make established "all info" omit the object.
\* mlacp_fsm.c:260-366,1393-1435.
mlacp_sync_sender_handler_SkipObject(i) ==
    \* mlacp_fsm.c:260-366: empty MAC/ARP/ND delta queues send no frame.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ sync[i].sendStep = "Object"
    /\ sync[i].dirtyVersion = NoVersion
    /\ txFrame[i] = NoFrame
    \* mlacp_fsm.c:1449-1455: the enclosing loop still advances to DONE.
    /\ sync' = [sync EXCEPT ![i].sendStep = "End"]
    /\ UNCHANGED <<recovery, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* Receive the response envelope Start marker without checking req_num.
\* mlacp_fsm.c:538-550.
mlacp_sync_recv_syncData_Start(i) ==
    LET f == Incoming(i)
    IN
    \* mlacp_fsm.c:538-543: dispatch a Sync Data TLV with flags == Start.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "SyncStart"
    /\ f.valid
    \* mlacp_fsm.c:543-550: only the flag is inspected; req_num is not
    \* compared.  Monitor records semantic mismatch but does not block it.
    /\ sync' = [sync EXCEPT
         ![i].activeEnvelope = f.epoch,
         ![i].configEpoch = NoEpoch,
         ![i].aggConfigEpoch = NoEpoch,
         ![i].stateEpoch = NoEpoch,
         ![i].envelopeViolation =
             @ \/ sync[i].outstanding = NoEpoch
                \/ sync[i].outstanding /= f.epoch]
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* Receive system configuration inside (or, in the implementation, outside)
\* the current semantic envelope.
\* mlacp_fsm.c:447-486,1296-1311.
mlacp_sync_recv_sysConf(i) ==
    LET f == Incoming(i)
    IN
    \* mlacp_fsm.c:1296-1311: dispatch the system configuration TLV.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "SysConfig"
    /\ f.valid
    \* mlacp_fsm.c:447-486: apply configuration without an envelope check.
    /\ sync' = [sync EXCEPT
         ![i].configEpoch = f.epoch,
         ![i].envelopeViolation =
             @ \/ sync[i].activeEnvelope /= f.epoch]
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* Receive aggregation configuration after system configuration.
\* mlacp_fsm.c:488-505,1296-1328.
mlacp_sync_recv_aggConf(i) ==
    LET f == Incoming(i)
    IN
    \* mlacp_fsm.c:1325-1328: dispatch aggregator configuration.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "AggConfig"
    /\ f.valid
    \* mlacp_fsm.c:488-505: apply without checking response identity.
    /\ sync' = [sync EXCEPT
         ![i].aggConfigEpoch = f.epoch,
         ![i].envelopeViolation =
             @ \/ sync[i].activeEnvelope /= f.epoch]
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* Receive aggregation/port state; monitor RFC ordering without enforcing it.
\* mlacp_fsm.c:508-535,1296-1332.
mlacp_sync_recv_aggState(i) ==
    LET f == Incoming(i)
    IN
    \* mlacp_fsm.c:1330-1332: dispatch aggregator state.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "AggState"
    /\ f.valid
    \* mlacp_fsm.c:508-535: update state with no envelope/order predicate.
    /\ sync' = [sync EXCEPT
         ![i].stateEpoch = f.epoch,
         ![i].envelopeViolation =
             @ \/ sync[i].activeEnvelope /= f.epoch,
         ![i].configOrderViolation =
             @ \/ sync[i].configEpoch /= f.epoch
                \/ sync[i].aggConfigEpoch /= f.epoch]
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* Receive the one abstract persistent/delta object.
\* mlacp_fsm.c:1296-1359; mlacp_sync_update.c:843-1252.
mlacp_sync_recv_ObjectData(i) ==
    LET f == Incoming(i)
    IN
    \* mlacp_fsm.c:1350-1359: dispatch MAC/ARP/ND data.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "ObjectData"
    /\ f.valid
    /\ f.version \in Versions
    \* mlacp_sync_update.c:843-1252: mutate the received peer view without
    \* request correlation; monitor records an out-of-envelope acceptance.
    /\ sync' = [sync EXCEPT
         ![i].peerVersion = f.version,
         ![i].envelopeViolation =
             @ \/ sync[i].activeEnvelope /= f.epoch]
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* End clears wait and advances a staged requester without correlating req_num.
\* mlacp_fsm.c:538-568,1497-1517.
mlacp_sync_recv_syncData_End(i) ==
    LET f == Incoming(i)
        oldOutstanding == sync[i].outstanding
        nextPhase ==
            IF sync[i].phase \in {"Stage1", "Stage2"}
            THEN NextFSMState(sync[i].phase)
            ELSE sync[i].phase
    IN
    \* mlacp_fsm.c:538-547: dispatch End solely by its flag.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "SyncEnd"
    /\ f.valid
    \* mlacp_fsm.c:543-568: clear wait with no req_num comparison.  Completion
    \* is attributed to the current ghost request, exposing stale End/ABA.
    /\ sync' = [sync EXCEPT
         ![i].complete =
             IF oldOutstanding /= NoEpoch
             THEN oldOutstanding
             ELSE f.epoch,
         ![i].outstanding = NoEpoch,
         ![i].activeEnvelope = NoEpoch,
         ![i].phase = nextPhase,
         ![i].envelopeViolation =
             @ \/ oldOutstanding = NoEpoch
                \/ sync[i].activeEnvelope /= f.epoch
                \/ oldOutstanding /= f.epoch]
    \* mlacp_fsm.c:1511-1517: consumed End permits stage increment.
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* ==========================================================================
\* SCENARIO 3 -- GENERATION-FREE DATA-PLANE ACK
\* ==========================================================================

\* Local PortChannel transition updates desired isolation before external
\* application and marks state for peer transmission.
\* mlacp_link_handler.c:2067-2099,1304-1354.
mlacp_portchannel_state_handler(i, up) ==
    LET nextGen == lag[i].gen + 1
    IN
    \* mlacp_link_handler.c:2071-2081: valid changed local PortChannel.
    /\ up \in BOOLEAN
    /\ up /= lag[i].localUp
    /\ lag[i].gen < MaxLagGen
    /\ sync[i].phase = "Exchange"
    \* mlacp_link_handler.c:1304-1350: for local UP, desired isolation is
    \* changed immediately from the cached peer state, before external writes.
    /\ lag' = [lag EXCEPT
         ![i].gen = nextGen,
         ![i].localUp = up,
         ![i].dirty = TRUE,
         ![i].isolationDesired =
             IF up THEN lag[i].peerUp ELSE @,
         ![i].isolationPendingGen =
             IF up /\ lag[i].peerUp THEN nextGen ELSE @,
         ![i].trafficApplyPending =
             IF ~up THEN "Disable" ELSE @,
         ![i].ackGen =
             IF ~up THEN NoGen ELSE @]
    \* mlacp_link_handler.c:2083-2097: local state is recorded, then DOWN
    \* requests traffic disable; UP waits for an ACK.
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Exchange sender prepares the current LAG state frame.
\* mlacp_fsm.c:1634-1645 (mlacp_exchange_handler).
mlacp_exchange_handler_PreparePortState(i) ==
    \* mlacp_fsm.c:1634-1642: changed PortChannel in EXCHANGE is serialized.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ sync[i].phase = "Exchange"
    /\ lag[i].dirty
    /\ txFrame[i] = NoFrame
    \* mlacp_fsm.c:1637-1642: prepare current state then call iccp_csm_send.
    /\ txFrame' = [txFrame EXCEPT ![i] =
         MkFrame("PortState", NoEpoch, NoVersion,
                 lag[i].gen, lag[i].localUp)]
    /\ txContext' = [txContext EXCEPT ![i] = "PortState"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    /\ UNCHANGED <<recovery, sync, wire, inbox, runtime, lag>>

\* Peer state receipt mutates desired isolation when a matching PIF exists,
\* but always schedules an UP ACK even when processing found no match.
\* mlacp_sync_update.c:165-210; mlacp_fsm.c:508-534.
mlacp_fsm_update_Aggport_state(i) ==
    LET f == Incoming(i)
        matched == lag[i].peerInterfaceKnown
        shouldApply == matched /\ lag[i].localUp
    IN
    \* mlacp_sync_update.c:170-185: validate TLV and search matching PIF.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ sync[i].phase = "Exchange"
    /\ Len(inbox[i]) > 0
    /\ f.kind = "PortState"
    /\ f.valid
    /\ f.gen \in LagGens
    \* mlacp_sync_update.c:187-207,1242-1301: only a match updates peer state
    \* and desired isolation; external application remains a separate step.
    /\ lag' = [lag EXCEPT
         ![i].peerKnownGen =
             IF matched THEN f.gen ELSE @,
         ![i].peerUp =
             IF matched THEN f.up ELSE @,
         ![i].isolationDesired =
             IF shouldApply THEN f.up ELSE @,
         ![i].isolationPendingGen =
             IF shouldApply THEN f.gen ELSE @,
         \* mlacp_fsm.c:525-533: UP is ACKed regardless of update return code.
         ![i].ackPending =
             IF f.up THEN f.gen ELSE @]
    \* mlacp_fsm.c:508-535: decoded state message is consumed.
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, sync, wire, txFrame, txContext,
                   sendOutcome>>

\* Successful external isolation application.
\* mlacp_link_handler.c:1021-1220.
update_peerlink_isolate_from_all_csm_lif_Apply(i) ==
    \* mlacp_link_handler.c:1064-1169,1194-1213: valid peer-link/LAG and
    \* pending desired isolation.
    /\ lag[i].isolationPendingGen /= NoGen
    /\ runtime[i].syncdConnected
    \* mlacp_link_handler.c:1169-1182,1210-1220: sidecar/kernel/STATE_DB
    \* effects succeed for the pending semantic generation.
    /\ lag' = [lag EXCEPT
         ![i].isolationAppliedEnabled = lag[i].isolationDesired,
         ![i].isolationAppliedGen = lag[i].isolationPendingGen,
         ![i].isolationPendingGen = NoGen]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Failed/ignored external application leaves desired and applied state split.
\* mlacp_link_handler.c:1021-1220.
update_peerlink_isolate_from_all_csm_lif_Fail(i) ==
    \* mlacp_link_handler.c:1031-1040,1168-1183,1210-1220: system/write/helper
    \* results can fail or be ignored after desired state was already mutated.
    /\ lag[i].isolationPendingGen /= NoGen
    /\ lag' = [lag EXCEPT ![i].isolationPendingGen = NoGen]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Prepare an ACK containing no real wire generation.  f.gen is ghost
\* provenance associated with the triggering UP transition.
\* mlacp_fsm.c:1676-1709; mlacp_tlv.h:447-470.
mlacp_fsm_send_if_up_ack(i) ==
    \* mlacp_fsm.c:1686-1696: ACK only in EXCHANGE after an UP notification.
    /\ recovery[i].sessionUp
    /\ sync[i].phase = "Exchange"
    /\ lag[i].ackPending /= NoGen
    /\ txFrame[i] = NoFrame
    \* mlacp_tlv.h:465-470: wire has type, isolation byte, and if_id only;
    \* semantic gen is not serialized and is invisible to the receiver guard.
    /\ txFrame' = [txFrame EXCEPT ![i] =
         MkFrame("IfUpAck", NoEpoch, NoVersion,
                 lag[i].ackPending, TRUE)]
    /\ txContext' = [txContext EXCEPT ![i] = "IfUpAck"]
    /\ sendOutcome' = [sendOutcome EXCEPT ![i] = "None"]
    \* mlacp_fsm.c:1697-1708: no ACK retry state is retained after this call.
    /\ lag' = [lag EXCEPT ![i].ackPending = NoGen]
    /\ UNCHANGED <<recovery, sync, wire, inbox, runtime>>

\* ACK receipt ignores isolation field/provenance and checks only current UP.
\* mlacp_fsm.c:759-793.
mlacp_fsm_recv_if_up_ack(i) ==
    LET f == Incoming(i)
    IN
    \* mlacp_fsm.c:759-773: decode a PortChannel ACK and find local if_id.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ f.kind = "IfUpAck"
    /\ f.valid
    \* mlacp_fsm.c:775-784: current po_active alone requests traffic enable;
    \* port_isolation_state and transition provenance are ignored.
    /\ lag' = [lag EXCEPT
         ![i].ackGen = f.gen,
         ![i].trafficApplyPending =
             IF lag[i].localUp THEN "Enable" ELSE @]
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].protocolProgress =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, sync, wire, txFrame, txContext,
                   sendOutcome>>

\* Successful DOWN sidecar application.
\* mlacp_link_handler.c:3588-3613.
mlacp_link_disable_traffic_distribution_Success(i) ==
    \* mlacp_link_handler.c:3592-3607: bound PortChannel, EXCHANGE, currently
    \* active traffic, and a DOWN transition invoke sidecar disable.
    /\ lag[i].trafficApplyPending = "Disable"
    /\ runtime[i].syncdConnected
    \* mlacp_link_handler.c:3607-3612: rc == 0 records traffic disabled.
    /\ lag' = [lag EXCEPT
         ![i].trafficEnabled = FALSE,
         ![i].trafficApplyPending = "None"]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Failed DOWN application leaves traffic state unchanged.
\* mlacp_link_handler.c:3588-3613.
mlacp_link_disable_traffic_distribution_Fail(i) ==
    \* mlacp_link_handler.c:3607-3612: rc != 0 does not set is_traffic_disable.
    /\ lag[i].trafficApplyPending = "Disable"
    /\ lag' = [lag EXCEPT ![i].trafficApplyPending = "None"]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Successful ACK-triggered traffic enable.
\* mlacp_link_handler.c:3622-3638.
mlacp_link_enable_traffic_distribution_Success(i) ==
    \* mlacp_link_handler.c:3626-3632: bound PortChannel currently disabled.
    /\ lag[i].trafficApplyPending = "Enable"
    /\ runtime[i].syncdConnected
    \* mlacp_link_handler.c:3632-3636: rc == 0 records traffic enabled.
    /\ lag' = [lag EXCEPT
         ![i].trafficEnabled = TRUE,
         ![i].trafficApplyPending = "None"]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Failed ACK-triggered enable leaves traffic disabled.
\* mlacp_link_handler.c:3622-3638.
mlacp_link_enable_traffic_distribution_Fail(i) ==
    \* mlacp_link_handler.c:3632-3636: rc != 0 retains is_traffic_disable.
    /\ lag[i].trafficApplyPending = "Enable"
    /\ lag' = [lag EXCEPT ![i].trafficApplyPending = "None"]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* Remove/restore the matching PIF abstraction used by the ACK-without-match
\* path.
\* mlacp_link_handler.c:2143-2168; mlacp_sync_update.c:85-158.
mlacp_peer_mlag_intf_delete_handler(i) ==
    \* mlacp_link_handler.c:2143-2168: peer interface deletion removes match.
    /\ lag[i].peerInterfaceKnown
    /\ lag' = [lag EXCEPT ![i].peerInterfaceKnown = FALSE]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

mlacp_fsm_update_Agg_conf(i) ==
    \* mlacp_sync_update.c:85-158: a valid peer aggregator config creates or
    \* finds the peer interface.
    /\ ~lag[i].peerInterfaceKnown
    /\ lag' = [lag EXCEPT ![i].peerInterfaceKnown = TRUE]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, runtime>>

\* ==========================================================================
\* SCENARIO 4 -- TRANSPORT ACTIVITY VERSUS SCHEDULER PROGRESS
\* ==========================================================================

\* Complete FIFO delivery is distinct from peer receive processing.  Every
\* complete frame refreshes heartbeat, including unsupported APP traffic.
\* scheduler.c:244-253; iccp_netlink.c:2225-2235.
scheduler_csm_read_callback_Complete(i) ==
    LET source == Peer(i)
        f == OnWireTo(i)
    IN
    \* scheduler.c:144-181,185-253: a complete header/body decodes a frame.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(wire[source]) > 0
    /\ f.valid
    \* scheduler.c:244-249: enqueue decoded frame in FIFO order.
    /\ wire' = [wire EXCEPT ![source] = Tail(@)]
    /\ inbox' = [inbox EXCEPT ![i] = Append(@, f)]
    \* iccp_netlink.c:2231-2235: any successfully read frame refreshes liveness.
    /\ runtime' = [runtime EXCEPT
         ![i].sessionActivity =
             IncBounded(@, MaxProgress),
         ![i].heartbeatAge = 0,
         ![i].streamState = "Idle"]
    /\ UNCHANGED <<recovery, sync, txFrame, txContext,
                   sendOutcome, lag>>

\* A corrupt partial-write prefix drives the inline body retry window.
\* scheduler.c:172-239.
scheduler_csm_read_callback_Corrupt(i) ==
    LET source == Peer(i)
        f == OnWireTo(i)
    IN
    \* scheduler.c:172-239: frame length/body cannot complete coherently.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ Len(wire[source]) > 0
    /\ ~f.valid
    \* scheduler.c:185-239: the sole scheduler sleeps/retries inline.
    /\ wire' = [wire EXCEPT ![source] = Tail(@)]
    /\ runtime' = [runtime EXCEPT
         ![i].schedulerEnabled = FALSE,
         ![i].streamState = "BodyRetry"]
    /\ UNCHANGED <<recovery, sync, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* Direct 1-7 byte header arrival blocks the blocking header loop indefinitely.
\* scheduler.c:129-170.
scheduler_csm_read_callback_PartialHeader(i) ==
    \* scheduler.c:144-154: epoll-selected live peer socket.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ runtime[i].streamState = "Idle"
    \* scheduler.c:152-170: blocking recv loop has no timeout after a prefix.
    /\ runtime' = [runtime EXCEPT
         ![i].schedulerEnabled = FALSE,
         ![i].streamState = "PartialHeader"]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* Peer close/error releases a blocked read and invokes disconnect handling.
\* scheduler.c:155-167,193-239,255-257.
scheduler_csm_read_callback_ReadError(i) ==
    \* scheduler.c:155-167,193-239: blocked header/body eventually returns
    \* EOF/error only if the peer/OS supplies one.
    /\ runtime[i].streamState \in {"PartialHeader", "BodyRetry"}
    /\ BeginDisconnect(i)

\* Enable a stream of syntactically complete but application-nonprogress data.
\* app_csm.c:100-145.
app_csm_EnableNonProgressTraffic(i) ==
    \* app_csm.c:122-145: unsupported/boundary RG APP frames are legal enough
    \* to enqueue but are not consumed by app_csm_transit.
    /\ recovery[i].sessionUp
    /\ ~runtime[i].nonProgressTraffic
    /\ runtime' = [runtime EXCEPT ![i].nonProgressTraffic = TRUE]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* Once enabled, the environment can keep writing complete nonprogress frames.
\* iccp_csm.c:245-281; app_csm.c:122-145.
iccp_csm_send_NonProgress(i) ==
    \* iccp_csm.c:252-269: live peer can repeatedly issue complete writes.
    /\ recovery[i].sessionUp
    \* scheduler.c:102-126,462-486: the sole event loop drives protocol
    \* sends; a node blocked in scheduler_csm_read_callback cannot emit more.
    /\ runtime[i].schedulerEnabled
    /\ runtime[i].nonProgressTraffic
    \* iccp_csm.c:276-280: full unsupported frame enters FIFO.
    /\ wire' = [wire EXCEPT ![i] =
         Append(@, MkFrame("NonProgress", NoEpoch, NoVersion,
                           NoGen, FALSE))]
    /\ UNCHANGED <<recovery, sync, inbox, txFrame, txContext,
                   sendOutcome, runtime, lag>>

\* APP enqueue consumes it from the protocol inbox but retains unbounded
\* application backlog abstracted by a saturating counter.
\* app_csm.c:100-166.
app_csm_enqueue_msg_NonProgress(i) ==
    \* app_csm.c:118-145: unsupported APP parameter goes to app_msg_list.
    /\ runtime[i].schedulerEnabled
    /\ Len(inbox[i]) > 0
    /\ Incoming(i).kind = "NonProgress"
    /\ Incoming(i).valid
    /\ inbox' = [inbox EXCEPT ![i] = Tail(@)]
    \* app_csm.c:80-98,155-166: the FSM never dequeues this list.
    /\ runtime' = [runtime EXCEPT
         ![i].ignoredAppFrames =
             IncBounded(@, MaxProgress)]
    /\ UNCHANGED <<recovery, sync, wire, txFrame, txContext,
                   sendOutcome, lag>>

\* A scheduler tick advances timers only while the sole loop is runnable.
\* scheduler.c:102-126,462-486.
scheduler_transit_fsm_Tick(i) ==
    \* scheduler.c:469-479: epoll returns and the scheduler reaches FSM/timers.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ runtime[i].heartbeatAge <= MaxHeartbeatAge
    \* scheduler.c:74-97,111-117: heartbeat and FSM timers advance.
    /\ runtime' = [runtime EXCEPT
         ![i].heartbeatAge =
             IncBounded(@, MaxHeartbeatAge + 1)]
    \* mlacp_fsm.c:956-965: grace age is observable only past the early return.
    /\ recovery' = [recovery EXCEPT
         ![i].graceAge =
             IF recovery[i].graceArmed
             THEN IncBounded(@, MaxHeartbeatAge + 1)
             ELSE @]
    /\ UNCHANGED <<sync, wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* Heartbeat timeout calls the same disconnect handler.
\* scheduler.c:74-87.
heartbeat_check(i) ==
    \* scheduler.c:76-82: live socket with age strictly above timeout.
    /\ recovery[i].sessionUp
    /\ runtime[i].schedulerEnabled
    /\ runtime[i].heartbeatAge > MaxHeartbeatAge
    \* scheduler.c:82-87: invoke scheduler_session_disconnect_handler.
    /\ BeginDisconnect(i)

\* syncd EOF changes reality but the positive descriptor is retained.
\* mlacp_link_handler.c:3350-3417; iccp_netlink.c:2212-2215.
iccp_mclagsyncd_msg_handler_EOF(i) ==
    \* mlacp_link_handler.c:3364-3377,3412-3417: EOF returns MCLAG_ERROR.
    /\ runtime[i].syncdConnected
    \* iccp_netlink.c:2181-2215: the same scheduler dispatches syncd events.
    /\ runtime[i].schedulerEnabled
    \* iccp_netlink.c:2212-2215: caller ignores return and does not close/reset.
    /\ runtime' = [runtime EXCEPT
         ![i].syncdConnected = FALSE,
         ![i].syncdFdPositive = TRUE]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* Scheduler reconnect condition tests only the stale descriptor sign.
\* scheduler.c:469-474.
scheduler_loop_ReconnectSyncd(i) ==
    \* scheduler.c:469-474: reconnect is attempted only for sync_fd <= 0.
    /\ ~runtime[i].syncdFdPositive
    /\ runtime[i].schedulerEnabled
    /\ runtime' = [runtime EXCEPT
         ![i].syncdConnected = TRUE,
         ![i].syncdFdPositive = TRUE]
    /\ UNCHANGED <<recovery, sync, wire, inbox, txFrame, txContext,
                   sendOutcome, lag>>

\* ==========================================================================
\* INITIALIZATION AND NEXT
\* ==========================================================================

Init ==
    \* Stable post-bootstrap two-peer Exchange state.
    /\ recovery = [i \in Node |->
         [sessionUp       |-> TRUE,
          crashed         |-> FALSE,
          disconnectPC    |-> "Idle",
          warmAnnounced   |-> FALSE,
          graceArmed      |-> FALSE,
          graceAge        |-> 0,
          cleanupDone     |-> TRUE,
          recoveryPending |-> FALSE,
          startupPC       |-> "Running",
          kernelTruth     |-> 1,
          observedState   |-> 1,
          snapshotReady   |-> TRUE,
          advertisedState |-> 1,
          resyncPending   |-> FALSE]]
    /\ sync = [i \in Node |->
         [epoch                |-> 0,
          phase                |-> "Exchange",
          outstanding          |-> NoEpoch,
          responderEpoch       |-> NoEpoch,
          sendStep             |-> "Idle",
          activeEnvelope       |-> NoEpoch,
          configEpoch          |-> NoEpoch,
          aggConfigEpoch       |-> NoEpoch,
          stateEpoch           |-> NoEpoch,
          complete             |-> 0,
          dirtyVersion         |-> NoVersion,
          peerVersion          |-> 1,
          envelopeViolation    |-> FALSE,
          configOrderViolation |-> FALSE,
          legalResyncActive    |-> FALSE,
          errorReason          |-> "None"]]
    /\ wire = [i \in Node |-> <<>>]
    /\ inbox = [i \in Node |-> <<>>]
    /\ txFrame = [i \in Node |-> NoFrame]
    /\ txContext = [i \in Node |-> "None"]
    /\ sendOutcome = [i \in Node |-> "None"]
    /\ runtime = [i \in Node |->
         [schedulerEnabled   |-> TRUE,
          streamState        |-> "Idle",
          sessionActivity    |-> 0,
          protocolProgress   |-> 0,
          heartbeatAge       |-> 0,
          nonProgressTraffic |-> FALSE,
          ignoredAppFrames   |-> 0,
          syncdConnected     |-> TRUE,
          syncdFdPositive    |-> TRUE]]
    /\ lag = [i \in Node |->
         [gen                     |-> 0,
          localUp                 |-> TRUE,
          dirty                   |-> FALSE,
          peerKnownGen            |-> 0,
          peerUp                  |-> TRUE,
          peerInterfaceKnown      |-> TRUE,
          isolationDesired        |-> TRUE,
          isolationPendingGen     |-> NoGen,
          isolationAppliedEnabled |-> TRUE,
          isolationAppliedGen     |-> 0,
          trafficEnabled          |-> TRUE,
          trafficApplyPending     |-> "None",
          ackPending              |-> NoGen,
          ackGen                  |-> 0]]

Next ==
    \/ \E i \in Node :
        \* Recovery and reconstruction (Scenario 1).
        \/ mlacp_sync_send_warmboot_flag(i)
        \/ mlacp_fsm_update_warmboot(i)
        \/ scheduler_session_disconnect_handler(i)
        \/ mlacp_peer_disconn_handler_Grace(i)
        \/ mlacp_peer_disconn_handler_Cleanup(i)
        \/ iccp_csm_status_reset(i)
        \/ mlacp_fsm_transit_WarmTimeout(i)
        \/ system_finalize_Crash(i)
        \/ scheduler_init_Restart(i)
        \/ iccp_neigh_get_init(i)
        \/ iccp_mclagsyncd_vlan_mbr_update_handler(i)
        \/ do_arp_learn_from_kernel(i)
        \/ iccp_netlink_route_sock_event_handler_Error(i)
        \/ iccp_netlink_sync_again(i)
        \/ iccp_csm_transit_Reconnect(i)

        \* Sync transaction (Scenario 2).
        \/ mlacp_stage_sync_request_handler(i)
        \/ mlacp_exchange_handler_PrepareResync(i)
        \/ mlacp_sync_recv_syncReq(i)
        \/ mlacp_sync_send_all_info_handler_Prepare(i)
        \/ mlacp_sync_sender_handler_SkipObject(i)
        \/ mlacp_sync_recv_syncData_Start(i)
        \/ mlacp_sync_recv_sysConf(i)
        \/ mlacp_sync_recv_aggConf(i)
        \/ mlacp_sync_recv_aggState(i)
        \/ mlacp_sync_recv_ObjectData(i)
        \/ mlacp_sync_recv_syncData_End(i)

        \* Data plane generation/ACK (Scenario 3).
        \/ mlacp_exchange_handler_PreparePortState(i)
        \/ mlacp_fsm_update_Aggport_state(i)
        \/ update_peerlink_isolate_from_all_csm_lif_Apply(i)
        \/ update_peerlink_isolate_from_all_csm_lif_Fail(i)
        \/ mlacp_fsm_send_if_up_ack(i)
        \/ mlacp_fsm_recv_if_up_ack(i)
        \/ mlacp_link_disable_traffic_distribution_Success(i)
        \/ mlacp_link_disable_traffic_distribution_Fail(i)
        \/ mlacp_link_enable_traffic_distribution_Success(i)
        \/ mlacp_link_enable_traffic_distribution_Fail(i)
        \/ mlacp_peer_mlag_intf_delete_handler(i)
        \/ mlacp_fsm_update_Agg_conf(i)

        \* Transport/scheduler split (Scenario 4).
        \/ scheduler_csm_read_callback_Complete(i)
        \/ scheduler_csm_read_callback_Corrupt(i)
        \/ scheduler_csm_read_callback_PartialHeader(i)
        \/ scheduler_csm_read_callback_ReadError(i)
        \/ app_csm_EnableNonProgressTraffic(i)
        \/ iccp_csm_send_NonProgress(i)
        \/ app_csm_enqueue_msg_NonProgress(i)
        \/ scheduler_transit_fsm_Tick(i)
        \/ heartbeat_check(i)
        \/ iccp_mclagsyncd_msg_handler_EOF(i)
        \/ scheduler_loop_ReconnectSyncd(i)

        \* Common fallible one-shot write boundary (Scenarios 1-3).
        \/ iccp_csm_send_Full(i)
        \/ iccp_csm_send_Partial(i)
        \/ iccp_csm_send_Failed(i)

    \* External kernel input and local LAG transitions choose a finite value.
    \/ \E i \in Node, v \in Versions :
        iccp_netlink_ObjectUpdate(i, v)
    \/ \E i \in Node, up \in BOOLEAN :
        mlacp_portchannel_state_handler(i, up)

Spec == Init /\ [][Next]_vars

\* ==========================================================================
\* INVARIANTS
\* ==========================================================================

\* Brief §5: all implementation and ghost fields stay in declared domains.
TypeOK ==
    /\ recovery \in [Node -> RecoveryStateType]
    /\ sync \in [Node -> SyncStateType]
    /\ wire \in [Node -> Seq(FrameType)]
    /\ inbox \in [Node -> Seq(FrameType)]
    /\ txFrame \in [Node -> (FrameType \cup {NoFrame})]
    /\ txContext \in [Node -> TxContexts]
    /\ sendOutcome \in [Node -> SendOutcomes]
    /\ runtime \in [Node -> RuntimeStateType]
    /\ lag \in [Node -> LagStateType]

\* Brief §5 / Scenario 2: legal established resync must not manufacture ERROR.
LegalFSMState ==
    \A i \in Node :
        ~(sync[i].phase = "Error"
          /\ sync[i].errorReason = "LegalResyncAdvance")

\* Brief §5 / Scenario 2: no response item was accepted outside its semantic
\* Start/End envelope or for a different outstanding request.
SyncEnvelopeOrdering ==
    \A i \in Node : ~sync[i].envelopeViolation

\* Brief §5 / Scenario 2: system and aggregation configuration precede state.
ConfigBeforeState ==
    \A i \in Node : ~sync[i].configOrderViolation

\* Brief §5 / Scenario 2: once both peers are quiescent in Exchange, their
\* completed semantic epoch and replicated-object views agree.
ExchangeAgreement ==
    (ProtocolQuiescent /\ \A i \in Node : sync[i].phase = "Exchange") =>
        \A i \in Node :
            /\ sync[i].complete = sync[Peer(i)].complete
            /\ sync[i].peerVersion = recovery[Peer(i)].observedState

\* Brief §5 / Scenario 2: clearing dirty state needs peer delivery, an intact
\* in-flight retry, or equality with the peer's accepted version.
DirtyStateAccounted ==
    \A i \in Node :
        sync[i].dirtyVersion = NoVersion =>
            \/ sync[Peer(i)].peerVersion = recovery[i].observedState
            \/ VersionInFlight(i, recovery[i].observedState)

\* Brief §5 / Scenario 1: never emit an object view before an authoritative
\* snapshot barrier and equality with current kernel truth.
RecoveryBeforeAdvertise ==
    \A i \in Node :
        recovery[i].advertisedState /= NoVersion =>
            /\ recovery[i].snapshotReady
            /\ recovery[i].observedState = recovery[i].kernelTruth
            /\ recovery[i].advertisedState = recovery[i].observedState

\* Brief §5 / Scenario 3: traffic dependent on the peer may be enabled only
\* after the peer applied isolation for this local transition generation.
CurrentIsolationBeforeTraffic ==
    \A i \in Node :
        (/\ recovery[i].sessionUp
         /\ sync[i].phase = "Exchange"
         /\ lag[i].localUp
         /\ lag[i].peerUp
         /\ lag[i].trafficEnabled)
        => PeerIsolationCurrent(i)

\* Brief §5 / Scenario 3: the two-node peer/member forwarding cycle is absent.
NoPeerLinkLoop ==
    ~\E i \in Node :
        /\ recovery[i].sessionUp
        /\ recovery[Peer(i)].sessionUp
        /\ lag[i].localUp
        /\ lag[Peer(i)].localUp
        /\ lag[i].trafficEnabled
        /\ lag[Peer(i)].trafficEnabled
        /\ ~PeerIsolationCurrent(i)
        /\ ~PeerIsolationCurrent(Peer(i))

\* Structural sanity: a prepared frame has a caller and vice versa.
TxPreparationConsistency ==
    \A i \in Node :
        (txFrame[i] = NoFrame) <=> (txContext[i] = "None")

\* Structural sanity: successful applied isolation always names a generation.
IsolationGenerationConsistency ==
    \A i \in Node :
        lag[i].isolationAppliedEnabled =>
            lag[i].isolationAppliedGen \in LagGens

\* ==========================================================================
\* TEMPORAL PROPERTIES FROM BRIEF §5
\* ==========================================================================

\* Scenario 1 / MC1: every recorded disconnect obligation eventually resolves
\* through reconnect or ordinary cleanup.  recoveryPending is ghost history,
\* so resetting the implementation timestamps cannot erase the obligation.
WarmRecoveryTerminates ==
    \A i \in Node :
        recovery[i].recoveryPending
        ~> (~recovery[i].recoveryPending
            /\ (recovery[i].sessionUp \/ recovery[i].cleanupDone))

\* Scenarios 2/4 / MC2: a semantic request eventually completes or disconnects.
SyncEventuallyResolves ==
    \A i \in Node :
        \A e \in Epochs :
            (sync[i].outstanding = e)
            ~> (sync[i].complete = e \/ ~recovery[i].sessionUp)

\* Scenario 4 / MC5: blocking or logically stuck sessions eventually recover,
\* irrespective of complete nonprogress traffic.
StuckSessionDetected ==
    \A i \in Node : Stuck(i) ~> Resolved(i)

=============================================================================
