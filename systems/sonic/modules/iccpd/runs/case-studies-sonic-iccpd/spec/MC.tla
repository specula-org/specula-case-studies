--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for sonic-iccpd ICCP/MCLAG protocol.
 *
 * Wraps the base spec with counter-bounded fault-injection actions.
 * Deterministic/reactive actions pass through unbounded.
 *
 * Counter-bounded actions (fault injection):
 *   - TcpDisconnect (network failure)
 *   - MessageLoss (unreliable network)
 *   - TimerTick (heartbeat timer advance)
 *   - MlacpSendNAK (trigger need_to_sync / node_id collision)
 *   - PortStateDown / PortStateUp (port flap)
 *   - SendWarmBoot (warm boot notification)
 *
 * Unbounded actions (deterministic/reactive):
 *   - TcpConnect, IccpBecomeOperational
 *   - MlacpInitToStage1, MlacpSendSyncRequest, MlacpStageSendAllInfo
 *   - MlacpReceiveSyncDone, MlacpReceiveSyncRequestInExchange
 *   - MlacpSendSyncRequestFromExchange, MlacpReceiveNAK
 *   - ReceiveSysConfig, ReceiveHeartbeat, SendHeartbeat
 *   - LocalMacLearn, LocalMacAge, MacUpdateFromSyncd
 *   - ReceivePeerMacAdd/AddNew/Del, PeerWarmBoot, WarmBootTimeout
 *   - HeartbeatTimeout, SessionDisconnect
 *)

EXTENDS base

\* Access original (un-overridden) operator definitions
iccpd == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxDisconnectLimit   \* Max TCP disconnect events
CONSTANT MaxLoseLimit         \* Max message loss events
CONSTANT MaxTimerTickLimit    \* Max timer tick events
CONSTANT MaxNAKLimit          \* Max NAK send events
CONSTANT MaxPortFlapLimit     \* Max port down/up cycles
CONSTANT MaxWarmBootLimit     \* Max warm boot notifications
CONSTANT MaxMsgBufferLimit    \* Max messages in flight

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION ACTIONS
\* ============================================================================

\* --- TCP disconnect (network failure) ---
MCTcpDisconnect(p) ==
    /\ faultCounters.disconnect < MaxDisconnectLimit
    /\ iccpd!TcpDisconnect(p)
    /\ faultCounters' = [faultCounters EXCEPT !.disconnect = @ + 1]

\* --- Message loss (unreliable network) ---
MCMessageLoss ==
    /\ faultCounters.lose < MaxLoseLimit
    /\ iccpd!MessageLoss
    /\ faultCounters' = [faultCounters EXCEPT !.lose = @ + 1]

\* --- Timer tick (heartbeat timer advance) ---
MCTimerTick(p) ==
    /\ faultCounters.timerTick < MaxTimerTickLimit
    /\ iccpd!TimerTick(p)
    /\ faultCounters' = [faultCounters EXCEPT !.timerTick = @ + 1]

\* --- NAK send (trigger need_to_sync / node_id collision) ---
MCMlacpSendNAK(p) ==
    /\ faultCounters.nak < MaxNAKLimit
    /\ iccpd!MlacpSendNAK(p)
    /\ faultCounters' = [faultCounters EXCEPT !.nak = @ + 1]

\* --- Port flap (port down) ---
MCPortChannelDown(p) ==
    /\ faultCounters.portFlap < MaxPortFlapLimit
    /\ iccpd!PortChannelDown(p)
    /\ faultCounters' = [faultCounters EXCEPT !.portFlap = @ + 1]

\* --- Port flap (port up) ---
MCPortChannelUp(p) ==
    /\ faultCounters.portFlap < MaxPortFlapLimit
    /\ iccpd!PortChannelUp(p)
    /\ faultCounters' = [faultCounters EXCEPT !.portFlap = @ + 1]

\* --- Warm boot notification ---
MCSendWarmBoot(p) ==
    /\ faultCounters.warmBoot < MaxWarmBootLimit
    /\ iccpd!SendWarmBoot(p)
    /\ faultCounters' = [faultCounters EXCEPT !.warmBoot = @ + 1]

\* ============================================================================
\* UNCONSTRAINED ACTIONS (deterministic/reactive)
\* ============================================================================

\* Connection management
UCTcpConnect(p)            == iccpd!TcpConnect(p)            /\ UNCHANGED faultVars
UCIccpBecomeOperational(p) == iccpd!IccpBecomeOperational(p) /\ UNCHANGED faultVars

\* MLACP handshake
UCMlacpInitToStage1(p)      == iccpd!MlacpInitToStage1(p)      /\ UNCHANGED faultVars
UCMlacpSendSyncRequest(p)   == iccpd!MlacpSendSyncRequest(p)   /\ UNCHANGED faultVars
UCMlacpStageSendAllInfo(p)  == iccpd!MlacpStageSendAllInfo(p)  /\ UNCHANGED faultVars
UCMlacpReceiveSyncDone(p)   == iccpd!MlacpReceiveSyncDone(p)   /\ UNCHANGED faultVars

\* Exchange phase
UCMlacpSendSyncRequestFromExchange(p) ==
    iccpd!MlacpSendSyncRequestFromExchange(p) /\ UNCHANGED faultVars
UCMlacpReceiveSyncRequestInExchange(p) ==
    iccpd!MlacpReceiveSyncRequestInExchange(p) /\ UNCHANGED faultVars

\* NAK reception
UCMlacpReceiveNAK(p) == iccpd!MlacpReceiveNAK(p) /\ UNCHANGED faultVars

\* Node ID
UCReceiveSysConfig(p) == iccpd!ReceiveSysConfig(p) /\ UNCHANGED faultVars

\* MAC operations
UCLocalMacLearn(p, m) == iccpd!LocalMacLearn(p, m) /\ UNCHANGED faultVars
UCLocalMacAge(p, m)   == iccpd!LocalMacAge(p, m)   /\ UNCHANGED faultVars
UCMacUpdateFromSyncd(p, m) == iccpd!MacUpdateFromSyncd(p, m) /\ UNCHANGED faultVars
UCReceivePeerMacAdd(p, m)    == iccpd!ReceivePeerMacAdd(p, m)    /\ UNCHANGED faultVars
UCReceivePeerMacAddNew(p, m) == iccpd!ReceivePeerMacAddNew(p, m) /\ UNCHANGED faultVars
UCReceivePeerMacDel(p, m)    == iccpd!ReceivePeerMacDel(p, m)    /\ UNCHANGED faultVars

\* Heartbeat
UCSendHeartbeat(p)    == iccpd!SendHeartbeat(p)    /\ UNCHANGED faultVars
UCReceiveHeartbeat(p) == iccpd!ReceiveHeartbeat(p) /\ UNCHANGED faultVars
UCHeartbeatTimeout(p) == iccpd!HeartbeatTimeout(p) /\ UNCHANGED faultVars

\* Session disconnect
UCSessionDisconnect(p) == iccpd!SessionDisconnect(p) /\ UNCHANGED faultVars

\* Warm boot
UCPeerWarmBoot(p)      == iccpd!PeerWarmBoot(p)      /\ UNCHANGED faultVars
UCWarmBootTimeout(p)   == iccpd!WarmBootTimeout(p)   /\ UNCHANGED faultVars

\* ============================================================================
\* MC INIT AND NEXT
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [disconnect |-> 0, lose |-> 0, timerTick |-> 0,
                         nak |-> 0, portFlap |-> 0, warmBoot |-> 0]

MCNext ==
    \/ \E p \in Peer :
        \* Unconstrained connection management
        \/ UCTcpConnect(p)
        \/ UCIccpBecomeOperational(p)
        \* Unconstrained MLACP handshake
        \/ UCMlacpInitToStage1(p)
        \/ UCMlacpSendSyncRequest(p)
        \/ UCMlacpStageSendAllInfo(p)
        \/ UCMlacpReceiveSyncDone(p)
        \* Unconstrained exchange phase
        \/ UCMlacpSendSyncRequestFromExchange(p)
        \/ UCMlacpReceiveSyncRequestInExchange(p)
        \* Constrained NAK send
        \/ MCMlacpSendNAK(p)
        \* Unconstrained NAK reception
        \/ UCMlacpReceiveNAK(p)
        \* Unconstrained node ID
        \/ UCReceiveSysConfig(p)
        \* Unconstrained MAC operations
        \/ \E m \in MAC :
            \/ UCLocalMacLearn(p, m)
            \/ UCLocalMacAge(p, m)
            \/ UCMacUpdateFromSyncd(p, m)
            \/ UCReceivePeerMacAdd(p, m)
            \/ UCReceivePeerMacAddNew(p, m)
            \/ UCReceivePeerMacDel(p, m)
        \* Constrained port flap
        \/ MCPortChannelDown(p)
        \/ MCPortChannelUp(p)
        \* Constrained timer tick
        \/ MCTimerTick(p)
        \* Unconstrained heartbeat send/receive
        \/ UCSendHeartbeat(p)
        \/ UCReceiveHeartbeat(p)
        \/ UCHeartbeatTimeout(p)
        \* Unconstrained session disconnect
        \/ UCSessionDisconnect(p)
        \* Constrained fault injection
        \/ MCTcpDisconnect(p)
        \* Constrained warm boot
        \/ MCSendWarmBoot(p)
        \/ UCPeerWarmBoot(p)
        \/ UCWarmBootTimeout(p)
    \* Constrained message loss
    \/ MCMessageLoss

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* Symmetry reduction: peers are symmetric in model checking
\* Note: role assignment breaks symmetry, so only use if Init assigns
\* roles non-deterministically from symmetric initial state.
\* Symmetry == Permutations(Peer)

\* View excludes fault counters from state space
ModelView == <<vars>>

\* ============================================================================
\* STATE SPACE PRUNING
\* ============================================================================

\* Bound total messages in flight
MsgBufferConstraint ==
    BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

\* MLACP state progression: state only increases during handshake
\* (except on disconnect which resets to INIT)
MlacpStateMonotonic ==
    \A p \in Peer :
        connected[p] /\ iccpOperational[p] =>
            MlacpStateOrd(mlacpState[p]) >= 0

\* waitForSyncData only meaningful in STAGE1/STAGE2
WaitForSyncDataValid ==
    \A p \in Peer :
        waitForSyncData[p] =>
            mlacpState[p] \in {MlacpStage1, MlacpStage2}

\* needToSync only meaningful in EXCHANGE or after receiving NAK
NeedToSyncValid ==
    \A p \in Peer :
        needToSync[p] =>
            mlacpState[p] \in {MlacpStage1, MlacpStage2, MlacpExchange, MlacpError}

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Node IDs eventually diverge after SysConfig exchange (Family 3)
MCNodeIdEventuallyDiverge ==
    <>(\A p \in Peer : remoteNodeId[p] /= Nil =>
        nodeId[p] /= nodeId[Other(p)])

\* Warm boot FDB cleanup eventually happens (Family 5)
MCWarmBootEventualCleanup ==
    \A p \in Peer :
        [](peerWarmRebootTime[p] => <>(fdbCleaned[p]))

=============================================================================
