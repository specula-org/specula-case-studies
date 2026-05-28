--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for sonic-iccpd ICCP/MCLAG protocol.
 *
 * Replays implementation traces against the base spec to verify
 * that the base spec can reproduce every observed state transition.
 *
 * Trace format: NDJSON with tag="trace" and event records containing:
 *   - event.name: action name
 *   - event.nid: peer ID (which peer emitted the event)
 *   - event.state: post-action state snapshot
 *   - event.msg: message fields (for message-related events)
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

\* Read JSON file path from environment variable or use default.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load NDJSON, filter to trace events only.
TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

\* ============================================================================
\* PEER EXTRACTION FROM TRACE
\* ============================================================================

TracePeer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        : k \in 1..Len(TraceLog)
    })

ASSUME TracePeer /= {}
ASSUME TracePeer \subseteq Peer

\* Extract initial nodeId for each peer from their first trace event
TraceInitNodeIds == TLCEval(
    LET FirstIdx(p) == CHOOSE k \in 1..Len(TraceLog) :
            /\ TraceLog[k].event.nid = p
            /\ \A j \in 1..Len(TraceLog) : (j < k) => (TraceLog[j].event.nid /= p)
    IN [p \in Peer |->
        IF p \in TracePeer /\ "nodeId" \in DOMAIN TraceLog[FirstIdx(p)].event.state
        THEN TraceLog[FirstIdx(p)].event.state.nodeId
        ELSE 0])

\* Derive role from trace nodeIds: lower nodeId = Active (iccp_csm.c:852)
TraceInitRole == TLCEval(
    LET nids == TraceInitNodeIds IN
    [p \in Peer |->
        IF nids[p] < nids[CHOOSE q \in Peer : q /= p]
        THEN Active ELSE Standby])

\* ============================================================================
\* STATE MAPPING
\* ============================================================================

\* Map trace MLACP state strings to spec constants
MlacpStateMapping(s) ==
    CASE s = "INIT"     -> MlacpInit
      [] s = "STAGE1"   -> MlacpStage1
      [] s = "STAGE2"   -> MlacpStage2
      [] s = "EXCHANGE" -> MlacpExchange
      [] s = "ERROR"    -> MlacpError
      [] OTHER          -> MlacpInit

\* Map trace port state strings to spec constants
PortStateMapping(s) ==
    CASE s = "UP"   -> PortStateUp
      [] s = "DOWN" -> PortStateDown
      [] OTHER      -> PortStateUp

\* Map trace role strings to spec constants
RoleMapping(s) ==
    CASE s = "ACTIVE"  -> Active
      [] s = "STANDBY" -> Standby
      [] OTHER         -> Active

\* Parse age flag set from trace representation
\* Trace sends age_flag as integer: 0=none, 1=LOCAL, 2=PEER, 3=BOTH
AgeFlagMapping(n) ==
    CASE n = 0 -> {}
      [] n = 1 -> {"LOCAL"}
      [] n = 2 -> {"PEER"}
      [] n = 3 -> {"LOCAL", "PEER"}
      [] OTHER -> {}

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, p) ==
    /\ IsEvent(name)
    /\ logline.event.nid = p

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* Validate MLACP state after action
ValidateMlacpState(p) ==
    IF "mlacpState" \in DOMAIN logline.event.state
    THEN mlacpState'[p] = MlacpStateMapping(logline.event.state.mlacpState)
    ELSE TRUE

\* Validate connection state after action
ValidateConnected(p) ==
    IF "connected" \in DOMAIN logline.event.state
    THEN connected'[p] = logline.event.state.connected
    ELSE TRUE

\* Validate ICCP operational state
ValidateIccpOperational(p) ==
    IF "iccpOperational" \in DOMAIN logline.event.state
    THEN iccpOperational'[p] = logline.event.state.iccpOperational
    ELSE TRUE

\* Validate node ID
ValidateNodeId(p) ==
    IF "nodeId" \in DOMAIN logline.event.state
    THEN nodeId'[p] = logline.event.state.nodeId
    ELSE TRUE

\* Validate waitForSyncData
ValidateWaitForSyncData(p) ==
    IF "waitForSyncData" \in DOMAIN logline.event.state
    THEN waitForSyncData'[p] = logline.event.state.waitForSyncData
    ELSE TRUE

\* Validate needToSync
ValidateNeedToSync(p) ==
    IF "needToSync" \in DOMAIN logline.event.state
    THEN needToSync'[p] = logline.event.state.needToSync
    ELSE TRUE

\* Validate port state
ValidatePortState(p) ==
    IF "portState" \in DOMAIN logline.event.state
    THEN portState'[p] = PortStateMapping(logline.event.state.portState)
    ELSE TRUE

\* Validate MAC age flag for a specific MAC
ValidateAgeFlag(p, m) ==
    IF "ageFlag" \in DOMAIN logline.event.state
    THEN ageFlag'[p][m] = AgeFlagMapping(logline.event.state.ageFlag)
    ELSE TRUE

\* Validate pending local del for a specific MAC
ValidatePendingLocalDel(p, m) ==
    IF "pendingLocalDel" \in DOMAIN logline.event.state
    THEN pendingLocalDel'[p][m] = logline.event.state.pendingLocalDel
    ELSE TRUE

\* Combined post-state validation for protocol state actions
ValidateProtocolState(p) ==
    /\ ValidateMlacpState(p)
    /\ ValidateConnected(p)
    /\ ValidateIccpOperational(p)
    /\ ValidateNodeId(p)
    /\ ValidateWaitForSyncData(p)
    /\ ValidateNeedToSync(p)

\* Combined post-state validation for MAC actions
ValidateMacState(p, m) ==
    /\ ValidateAgeFlag(p, m)
    /\ ValidatePendingLocalDel(p, m)
    /\ ValidatePortState(p)

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- Connection management ---

TraceTcpConnect ==
    /\ IsEvent("TcpConnect")
    /\ LET p == logline.event.nid IN
       /\ TcpConnect(p)
       /\ ValidateConnected(p)
    /\ l' = l + 1

TraceIccpBecomeOperational ==
    /\ IsEvent("IccpBecomeOperational")
    /\ LET p == logline.event.nid IN
       /\ IccpBecomeOperational(p)
       /\ ValidateIccpOperational(p)
    /\ l' = l + 1

\* --- MLACP handshake ---

TraceMlacpInitToStage1 ==
    /\ IsEvent("MlacpInitToStage1")
    /\ LET p == logline.event.nid IN
       /\ MlacpInitToStage1(p)
       /\ ValidateMlacpState(p)
       /\ ValidateWaitForSyncData(p)
    /\ l' = l + 1

TraceMlacpSendSyncRequest ==
    /\ IsEvent("MlacpSendSyncRequest")
    /\ LET p == logline.event.nid IN
       /\ MlacpSendSyncRequest(p)
       /\ ValidateWaitForSyncData(p)
    /\ l' = l + 1

TraceMlacpStageSendAllInfo ==
    /\ IsEvent("MlacpStageSendAllInfo")
    /\ LET p == logline.event.nid IN
       /\ MlacpStageSendAllInfo(p)
       /\ ValidateMlacpState(p)
       /\ ValidateWaitForSyncData(p)
    /\ l' = l + 1

TraceMlacpReceiveSyncDone ==
    /\ IsEvent("MlacpReceiveSyncDone")
    /\ LET p == logline.event.nid IN
       /\ MlacpReceiveSyncDone(p)
       /\ ValidateMlacpState(p)
       /\ ValidateWaitForSyncData(p)
    /\ l' = l + 1

\* --- Exchange phase ---

TraceMlacpSendSyncRequestFromExchange ==
    /\ IsEvent("MlacpSendSyncRequestFromExchange")
    /\ LET p == logline.event.nid IN
       /\ MlacpSendSyncRequestFromExchange(p)
       /\ ValidateNeedToSync(p)
    /\ l' = l + 1

TraceMlacpReceiveSyncRequestInExchange ==
    /\ IsEvent("MlacpReceiveSyncRequestInExchange")
    /\ LET p == logline.event.nid IN
       /\ MlacpReceiveSyncRequestInExchange(p)
       /\ ValidateMlacpState(p)
    /\ l' = l + 1

\* --- NAK handling ---

TraceMlacpSendNAK ==
    /\ IsEvent("MlacpSendNAK")
    /\ LET p == logline.event.nid IN
       /\ MlacpSendNAK(p)
    /\ l' = l + 1

TraceMlacpReceiveNAK ==
    /\ IsEvent("MlacpReceiveNAK")
    /\ LET p == logline.event.nid IN
       /\ MlacpReceiveNAK(p)
       /\ ValidateNodeId(p)
       /\ ValidateNeedToSync(p)
    /\ l' = l + 1

\* --- Node ID ---

TraceReceiveSysConfig ==
    /\ IsEvent("ReceiveSysConfig")
    /\ LET p == logline.event.nid IN
       /\ ReceiveSysConfig(p)
       /\ ValidateNodeId(p)
    /\ l' = l + 1

\* --- MAC operations ---

TraceLocalMacLearn ==
    /\ IsEvent("LocalMacLearn")
    /\ LET p == logline.event.nid
           m == logline.event.mac
       IN
       /\ LocalMacLearn(p, m)
       /\ ValidateMacState(p, m)
    /\ l' = l + 1

TraceLocalMacAge ==
    /\ IsEvent("LocalMacAge")
    /\ LET p == logline.event.nid
           m == logline.event.mac
       IN
       /\ LocalMacAge(p, m)
       /\ ValidateAgeFlag(p, m)
    /\ l' = l + 1

TraceMacUpdateFromSyncd ==
    /\ IsEvent("MacUpdateFromSyncd")
    /\ LET p == logline.event.nid
           m == logline.event.mac
       IN
       /\ MacUpdateFromSyncd(p, m)
       /\ ValidateAgeFlag(p, m)
    /\ l' = l + 1

TraceReceivePeerMacAdd ==
    /\ IsEvent("ReceivePeerMacAdd")
    /\ LET p == logline.event.nid
           m == logline.event.mac
       IN
       /\ ReceivePeerMacAdd(p, m)
       /\ ValidateMacState(p, m)
    /\ l' = l + 1

TraceReceivePeerMacAddNew ==
    /\ IsEvent("ReceivePeerMacAddNew")
    /\ LET p == logline.event.nid
           m == logline.event.mac
       IN
       /\ ReceivePeerMacAddNew(p, m)
       /\ ValidateAgeFlag(p, m)
    /\ l' = l + 1

TraceReceivePeerMacDel ==
    /\ IsEvent("ReceivePeerMacDel")
    /\ LET p == logline.event.nid
           m == logline.event.mac
       IN
       /\ ReceivePeerMacDel(p, m)
       /\ ValidateAgeFlag(p, m)
    /\ l' = l + 1

TracePortStateDown ==
    /\ IsEvent("PortStateDown")
    /\ LET p == logline.event.nid IN
       /\ PortChannelDown(p)
       /\ ValidatePortState(p)
    /\ l' = l + 1

TracePortStateUp ==
    /\ IsEvent("PortStateUp")
    /\ LET p == logline.event.nid IN
       /\ PortChannelUp(p)
       /\ ValidatePortState(p)
    /\ l' = l + 1

\* --- Heartbeat ---

TraceSendHeartbeat ==
    /\ IsEvent("SendHeartbeat")
    /\ LET p == logline.event.nid IN
       /\ SendHeartbeat(p)
    /\ l' = l + 1

TraceReceiveHeartbeat ==
    /\ IsEvent("ReceiveHeartbeat")
    /\ LET p == logline.event.nid IN
       /\ ReceiveHeartbeat(p)
    /\ l' = l + 1

TraceHeartbeatTimeout ==
    /\ IsEvent("HeartbeatTimeout")
    /\ LET p == logline.event.nid IN
       /\ HeartbeatTimeout(p)
       /\ ValidateProtocolState(p)
    /\ l' = l + 1

\* --- Session disconnect ---

TraceSessionDisconnect ==
    /\ IsEvent("SessionDisconnect")
    /\ LET p == logline.event.nid IN
       /\ SessionDisconnect(p)
       /\ ValidateProtocolState(p)
    /\ l' = l + 1

\* --- Warm boot ---

TracePeerWarmBoot ==
    /\ IsEvent("PeerWarmBoot")
    /\ LET p == logline.event.nid IN
       /\ PeerWarmBoot(p)
    /\ l' = l + 1

TraceSendWarmBoot ==
    /\ IsEvent("SendWarmBoot")
    /\ LET p == logline.event.nid IN
       /\ SendWarmBoot(p)
    /\ l' = l + 1

TraceWarmBootTimeout ==
    /\ IsEvent("WarmBootTimeout")
    /\ LET p == logline.event.nid IN
       /\ WarmBootTimeout(p)
    /\ l' = l + 1

\* --- Exchange-state variant of MlacpStageSendAllInfo ---
\* The harness emits "MlacpStageSendAllInfo" for all calls to
\* mlacp_sync_send_all_info_handler, even when the caller is in EXCHANGE
\* state (which is actually MlacpReceiveSyncRequestInExchange — Bug Family 2).
TraceMlacpStageSendAllInfoFromExchange ==
    /\ IsEvent("MlacpStageSendAllInfo")
    /\ LET p == logline.event.nid IN
       /\ mlacpState[p] = MlacpExchange   \* Caller was in EXCHANGE
       /\ MlacpReceiveSyncRequestInExchange(p)
       /\ ValidateMlacpState(p)
    /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

\* Silent actions handle state changes that don't have trace events.
\* MUST be tightly constrained to avoid state space explosion.

\* Timer ticks happen implicitly (no trace event)
\* Constrained: only fire if the next trace event requires the timer
\* to have advanced (e.g., HeartbeatTimeout)
SilentTimerTick ==
    /\ l <= Len(TraceLog)
    \* Only tick if next event is HeartbeatTimeout and timer hasn't reached limit
    /\ logline.event.name = "HeartbeatTimeout"
    /\ \E p \in Peer :
        /\ heartbeatActive[p]
        /\ heartbeatTimer[p] < MaxTimer
        /\ TimerTick(p)
    /\ UNCHANGED l

\* needToSync set externally by test harness (no trace event)
\* Constrained: only fire if next event is MlacpSendSyncRequestFromExchange
\* and needToSync is currently FALSE
SilentSetNeedToSync ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "MlacpSendSyncRequestFromExchange"
    /\ LET p == logline.event.nid IN
       /\ ~needToSync[p]
       /\ needToSync' = [needToSync EXCEPT ![p] = TRUE]
       /\ UNCHANGED <<connVars, mlacpState, role, waitForSyncData,
                       nodeIdVars, macVars, heartbeatVars, warmBootVars,
                       networkVars>>
    /\ UNCHANGED l

\* ============================================================================
\* TRACE INIT AND NEXT
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1
    \* Constrain initial nodeId to match trace
    /\ nodeId = TraceInitNodeIds
    \* Constrain role to match trace (lower nodeId = Active, iccp_csm.c:852)
    /\ LET nids == TraceInitNodeIds IN
       IF \E p, q \in Peer : p /= q /\ nids[p] /= nids[q]
       THEN role = TraceInitRole
       ELSE TRUE  \* Don't constrain role if nodeIds are equal (collision scenario)

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceTcpConnect
          \/ TraceIccpBecomeOperational
          \/ TraceMlacpInitToStage1
          \/ TraceMlacpSendSyncRequest
          \/ TraceMlacpStageSendAllInfo
          \/ TraceMlacpReceiveSyncDone
          \/ TraceMlacpSendSyncRequestFromExchange
          \/ TraceMlacpReceiveSyncRequestInExchange
          \/ TraceMlacpStageSendAllInfoFromExchange
          \/ TraceMlacpSendNAK
          \/ TraceMlacpReceiveNAK
          \/ TraceReceiveSysConfig
          \/ TraceLocalMacLearn
          \/ TraceLocalMacAge
          \/ TraceMacUpdateFromSyncd
          \/ TraceReceivePeerMacAdd
          \/ TraceReceivePeerMacAddNew
          \/ TraceReceivePeerMacDel
          \/ TracePortStateDown
          \/ TracePortStateUp
          \/ TraceSendHeartbeat
          \/ TraceReceiveHeartbeat
          \/ TraceHeartbeatTimeout
          \/ TraceSessionDisconnect
          \/ TracePeerWarmBoot
          \/ TraceSendWarmBoot
          \/ TraceWarmBootTimeout
    \* Silent actions (no trace event consumed)
    \* Note: SilentMessageLoss removed — it's too unconstrained and eats
    \* messages needed by upcoming trace actions, causing false deadlocks.
    \/ /\ l <= Len(TraceLog)
       /\ \/ SilentTimerTick
          \/ SilentSetNeedToSync
    \* Stuttering when trace fully consumed
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED <<vars, l>>

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>>

\* ============================================================================
\* TRACE COMPLETION
\* ============================================================================

\* Temporal property: entire trace was consumed
TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* VIEW AND ALIAS
\* ============================================================================

TraceView == <<vars, l>>

TraceAlias == [
    l |-> l,
    event |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
    nid |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
    mlacpState |-> mlacpState,
    connected |-> connected,
    iccpOperational |-> iccpOperational,
    nodeId |-> nodeId,
    ageFlag |-> ageFlag,
    portState |-> portState,
    heartbeatTimer |-> heartbeatTimer,
    warmRebootDisconnTime |-> warmRebootDisconnTime,
    msgCount |-> BagCardinality(messages)
]

=============================================================================
