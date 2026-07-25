--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for sonic-iccpd (ICCP/MCLAG protocol).
 *
 * Derived from: sonic-buildimage/src/iccpd/src/
 * Bug Families: 1 (MAC Age Flag State Machine), 2 (MLACP FSM Transitions),
 *               3 (Node ID Collision Livelock), 4 (Heartbeat/Session),
 *               5 (Warm Boot Recovery Race)
 *
 * Category A: Distributed system — two MCLAG peers with TCP-based protocol.
 * Models the implementation's actual control flow, not RFC 7275.
 *)

EXTENDS Integers, FiniteSets, Sequences, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Peer              \* Set of peer IDs {p1, p2}
CONSTANT MAC               \* Set of abstract MAC addresses
CONSTANT MaxNodeId         \* Upper bound on node IDs for model checking
CONSTANT MaxTimer          \* Abstract timer bound
CONSTANT Nil               \* Sentinel value

\* Role constants (iccp_csm.h:95-100)
CONSTANTS Active, Standby

\* MLACP FSM state constants (mlacp_fsm.h:39-46)
CONSTANTS MlacpInit, MlacpStage1, MlacpStage2, MlacpExchange, MlacpError

\* Port state constants
CONSTANTS PortStateUp, PortStateDown

\* Message type constants
CONSTANTS
    SysConfigMsg,          \* System config TLV (carries node_id)
    SyncRequestMsg,        \* Sync request TLV
    SyncDataDoneMsg,       \* Sync data done marker
    HeartbeatMsg,          \* Heartbeat/keepalive
    MacSyncAddMsg,         \* MAC sync ADD
    MacSyncDelMsg,         \* MAC sync DEL
    NAKSysConfigMsg,       \* NAK for system config
    NAKOtherMsg,           \* NAK for other TLVs
    WarmBootMsg            \* Warm boot notification

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-peer connection state ---
VARIABLE connected           \* [Peer -> BOOLEAN] TCP connection established
VARIABLE iccpOperational     \* [Peer -> BOOLEAN] ICCP handshake complete (APP_OPERATIONAL)

\* --- Per-peer MLACP FSM state (mlacp_fsm.h:151-183) ---
VARIABLE mlacpState          \* [Peer -> MLACP_STATE] current FSM state
VARIABLE role                \* [Peer -> {Active, Standby}] peer role
VARIABLE waitForSyncData     \* [Peer -> BOOLEAN] wait_for_sync_data flag
VARIABLE needToSync          \* [Peer -> BOOLEAN] need_to_sync flag

\* --- Extension: Node ID collision (Family 3, mlacp_fsm.h:161) ---
VARIABLE nodeId              \* [Peer -> 0..MaxNodeId] local node_id
VARIABLE remoteNodeId        \* [Peer -> 0..MaxNodeId \cup {Nil}] remote node_id

\* --- Extension: MAC age flags (Family 1) ---
\* Models the 2-bit age flag scheme (MAC_AGE_LOCAL=1, MAC_AGE_PEER=2)
\* from mlacp_link_handler.c and mlacp_sync_update.c
VARIABLE ageFlag             \* [Peer -> [MAC -> SUBSET {"LOCAL", "PEER"}]]
VARIABLE pendingLocalDel     \* [Peer -> [MAC -> BOOLEAN]]
VARIABLE macExists           \* [Peer -> [MAC -> BOOLEAN]]
VARIABLE addToSyncd          \* [Peer -> [MAC -> BOOLEAN]]
VARIABLE portState           \* [Peer -> PortState] one abstract MCLAG port

\* --- Extension: Heartbeat timer (Family 4, scheduler.c:74-90) ---
VARIABLE heartbeatTimer      \* [Peer -> 0..MaxTimer] ticks since last heartbeat recv
VARIABLE heartbeatActive     \* [Peer -> BOOLEAN] whether timer is ticking

\* --- Extension: Warm boot recovery (Family 5, scheduler.c:831-858) ---
VARIABLE peerWarmRebootTime  \* [Peer -> BOOLEAN] peer_warm_reboot_time != 0
VARIABLE warmRebootDisconnTime \* [Peer -> BOOLEAN] warm_reboot_disconn_time != 0
VARIABLE fdbCleaned          \* [Peer -> BOOLEAN] whether FDB cleanup happened

\* --- Network ---
VARIABLE messages            \* Bag of message records

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED clauses)
\* ============================================================================

connVars     == <<connected, iccpOperational>>
mlacpVars    == <<mlacpState, role, waitForSyncData, needToSync>>
nodeIdVars   == <<nodeId, remoteNodeId>>
macVars      == <<ageFlag, pendingLocalDel, macExists, addToSyncd, portState>>
heartbeatVars == <<heartbeatTimer, heartbeatActive>>
warmBootVars == <<peerWarmRebootTime, warmRebootDisconnTime, fdbCleaned>>
networkVars  == <<messages>>

vars == <<connVars, mlacpVars, nodeIdVars, macVars, heartbeatVars,
          warmBootVars, networkVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* The other peer in a 2-peer system
Other(p) == CHOOSE q \in Peer : q /= p

\* MLACP state ordering (mlacp_fsm.h:39-46)
MlacpStateOrd(s) ==
    CASE s = MlacpInit     -> 0
      [] s = MlacpStage1   -> 1
      [] s = MlacpStage2   -> 2
      [] s = MlacpExchange -> 3
      [] s = MlacpError    -> 4

\* Next MLACP state (current_state++, mlacp_fsm.c:1372)
\* BUG: no guard prevents advancing from EXCHANGE to ERROR
NextMlacpState(s) ==
    CASE s = MlacpInit     -> MlacpStage1
      [] s = MlacpStage1   -> MlacpStage2
      [] s = MlacpStage2   -> MlacpExchange
      [] s = MlacpExchange -> MlacpError     \* BUG (Family 2)
      [] s = MlacpError    -> MlacpError     \* saturate

\* Role-based sender/requester in handshake stages
\* STAGE1: Active sends info (sender), Standby requests (requester)
\* STAGE2: Standby sends info (sender), Active requests (requester)
\* (mlacp_fsm.c:1434-1454)
IsSenderInStage(p) ==
    \/ /\ mlacpState[p] = MlacpStage1 /\ role[p] = Active    \* mlacp_fsm.c:1439-1440
    \/ /\ mlacpState[p] = MlacpStage2 /\ role[p] = Standby   \* mlacp_fsm.c:1449-1450

IsRequesterInStage(p) ==
    \/ /\ mlacpState[p] = MlacpStage1 /\ role[p] = Standby   \* mlacp_fsm.c:1441-1442
    \/ /\ mlacpState[p] = MlacpStage2 /\ role[p] = Active    \* mlacp_fsm.c:1447-1448

\* MAC age flag helpers (models MAC_AGE_LOCAL=0x01, MAC_AGE_PEER=0x02)
HasLocalAge(p, m) == "LOCAL" \in ageFlag[p][m]
HasPeerAge(p, m)  == "PEER"  \in ageFlag[p][m]
HasBothAge(p, m)  == ageFlag[p][m] = {"LOCAL", "PEER"}

\* ---- Message bag helpers ----
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
DiscardAndSend(req, resp) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})
DiscardAndSendAll(req, resps) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag(resps)

\* ============================================================================
\* INIT
\* ============================================================================

Init ==
    \* Both peers start disconnected
    /\ connected         = [p \in Peer |-> FALSE]
    /\ iccpOperational   = [p \in Peer |-> FALSE]
    \* MLACP FSM starts at INIT (mlacp_fsm.c:857)
    /\ mlacpState        = [p \in Peer |-> MlacpInit]
    \* Role assignment: deterministic, lower = Active (iccp_csm.c:852)
    /\ role \in {r \in [Peer -> {Active, Standby}] :
                   \E a, s \in Peer : a /= s /\ r[a] = Active /\ r[s] = Standby}
    /\ waitForSyncData   = [p \in Peer |-> FALSE]
    /\ needToSync        = [p \in Peer |-> FALSE]
    \* Node IDs start equal for collision scenario (Family 3)
    /\ nodeId \in [Peer -> 0..MaxNodeId]
    /\ remoteNodeId      = [p \in Peer |-> Nil]
    \* No MACs initially
    /\ ageFlag           = [p \in Peer |-> [m \in MAC |-> {}]]
    /\ pendingLocalDel   = [p \in Peer |-> [m \in MAC |-> FALSE]]
    /\ macExists         = [p \in Peer |-> [m \in MAC |-> FALSE]]
    /\ addToSyncd        = [p \in Peer |-> [m \in MAC |-> FALSE]]
    /\ portState         = [p \in Peer |-> PortStateUp]
    \* Heartbeat timer not active
    /\ heartbeatTimer    = [p \in Peer |-> 0]
    /\ heartbeatActive   = [p \in Peer |-> FALSE]
    \* No warm boot
    /\ peerWarmRebootTime    = [p \in Peer |-> FALSE]
    /\ warmRebootDisconnTime = [p \in Peer |-> FALSE]
    /\ fdbCleaned            = [p \in Peer |-> FALSE]
    \* Empty message bag
    /\ messages = EmptyBag

\* ============================================================================
\* CONNECTION MANAGEMENT
\* ============================================================================

\* --- TcpConnect: Establish TCP connection ---
\* Both peers connect simultaneously (scheduler.c socket setup)
\* Heartbeat timer starts when sock_fd > 0 (scheduler.c:76-79)
TcpConnect(p) ==
    /\ ~connected[p]
    /\ ~connected[Other(p)]  \* Both connect together
    /\ connected' = [q \in Peer |-> TRUE]
    \* Heartbeat timer starts ticking (scheduler.c:76-78)
    \* BUG (Family 4): timer starts before heartbeats are exchanged
    /\ heartbeatActive' = [q \in Peer |-> TRUE]
    /\ heartbeatTimer' = [q \in Peer |-> 0]
    /\ UNCHANGED <<iccpOperational, mlacpVars, nodeIdVars, macVars,
                    warmBootVars, networkVars>>

\* --- IccpBecomeOperational: ICCP handshake completes ---
\* Abstraction of NONEXISTENT → INITIALIZED → CAPSENT → CAPREC →
\* CONNECTING → OPERATIONAL (iccp_csm.h:83-91)
\* Requires TCP connection
IccpBecomeOperational(p) ==
    /\ connected[p]
    /\ ~iccpOperational[p]
    /\ iccpOperational' = [iccpOperational EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<connected, mlacpVars, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars, networkVars>>

\* ============================================================================
\* MLACP FSM HANDSHAKE (Family 2: mlacp_fsm.c:833-953)
\* ============================================================================

\* --- MlacpInitToStage1: INIT → STAGE1 ---
\* (mlacp_fsm.c:921-927)
\* Triggered when ICCP is operational and MLACP is in INIT
MlacpInitToStage1(p) ==
    /\ connected[p]
    /\ iccpOperational[p]
    \* csm->app_csm.current_state == APP_OPERATIONAL (mlacp_fsm.c:848)
    /\ mlacpState[p] = MlacpInit
    \* Transition INIT → STAGE1 (mlacp_fsm.c:924)
    /\ mlacpState' = [mlacpState EXCEPT ![p] = MlacpStage1]
    /\ waitForSyncData' = [waitForSyncData EXCEPT ![p] = FALSE]  \* mlacp_fsm.c:923
    /\ UNCHANGED <<connVars, role, needToSync, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars, networkVars>>

\* --- MlacpSendSyncRequest: Requester sends sync request ---
\* (mlacp_fsm.c:1409-1431, mlacp_stage_sync_request_handler)
\* Socket server (Standby in STAGE1, Active in STAGE2) sends request first
MlacpSendSyncRequest(p) ==
    /\ connected[p]
    /\ iccpOperational[p]
    /\ mlacpState[p] \in {MlacpStage1, MlacpStage2}
    /\ IsRequesterInStage(p)
    /\ waitForSyncData[p] = FALSE   \* mlacp_fsm.c:1414
    \* Send sync request and wait (mlacp_fsm.c:1417-1420)
    /\ waitForSyncData' = [waitForSyncData EXCEPT ![p] = TRUE]
    /\ Send([mtype |-> SyncRequestMsg, src |-> p, dst |-> Other(p)])
    /\ UNCHANGED <<connVars, mlacpState, role, needToSync, nodeIdVars,
                    macVars, heartbeatVars, warmBootVars>>

\* --- MlacpStageSendAllInfo: Sender receives sync request, sends all info ---
\* (mlacp_fsm.c:1380-1407, mlacp_stage_sync_send_handler)
\* Then calls mlacp_sync_send_all_info_handler (mlacp_fsm.c:1350-1378)
\* which sends all sync data and advances current_state++ (line 1372)
MlacpStageSendAllInfo(p) ==
    LET q == Other(p)
        req == [mtype |-> SyncRequestMsg, src |-> q, dst |-> p]
    IN
    /\ connected[p]
    /\ iccpOperational[p]
    /\ mlacpState[p] \in {MlacpStage1, MlacpStage2}
    /\ IsSenderInStage(p)
    /\ waitForSyncData[p] = FALSE   \* mlacp_fsm.c:1386
    \* Receive sync request from peer
    /\ BagIn(req, messages)
    \* Set wait_for_sync_data = 1 (mlacp_fsm.c:1397)
    \* Then mlacp_sync_send_all_info_handler resets it to 0 (line 1371)
    /\ waitForSyncData' = [waitForSyncData EXCEPT ![p] = FALSE]
    \* Send SysConfig (with node_id) + SyncDataDone (mlacp_fsm.c:1350-1378)
    /\ messages' = (messages (-) SetToBag({req}))
                   (+) SetToBag({
                       [mtype |-> SysConfigMsg, src |-> p, dst |-> q,
                        mnodeId |-> nodeId[p]],
                       [mtype |-> SyncDataDoneMsg, src |-> p, dst |-> q]})
    \* current_state++ (mlacp_fsm.c:1372)
    /\ mlacpState' = [mlacpState EXCEPT ![p] = NextMlacpState(@)]
    /\ UNCHANGED <<connVars, role, needToSync, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars>>

\* --- MlacpReceiveSyncDone: Requester receives sync done, advances state ---
\* (mlacp_fsm.c:1422-1428, mlacp_stage_sync_request_handler)
\* wait_for_sync_data set to 0 by mlacp_sync_recv_syncData (mlacp_fsm.c:546)
\* then current_state++ (mlacp_fsm.c:1427)
MlacpReceiveSyncDone(p) ==
    LET q == Other(p)
        msg == [mtype |-> SyncDataDoneMsg, src |-> q, dst |-> p]
    IN
    /\ connected[p]
    /\ iccpOperational[p]
    /\ mlacpState[p] \in {MlacpStage1, MlacpStage2}
    /\ IsRequesterInStage(p)
    /\ waitForSyncData[p] = TRUE    \* mlacp_fsm.c:1422 (else branch)
    /\ BagIn(msg, messages)
    \* wait_for_sync_data = 0 (mlacp_fsm.c:546)
    /\ waitForSyncData' = [waitForSyncData EXCEPT ![p] = FALSE]
    \* current_state++ (mlacp_fsm.c:1427)
    /\ mlacpState' = [mlacpState EXCEPT ![p] = NextMlacpState(@)]
    /\ Discard(msg)
    /\ UNCHANGED <<connVars, role, needToSync, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars>>

\* ============================================================================
\* EXCHANGE PHASE (Family 2: mlacp_fsm.c:1456-1505)
\* ============================================================================

\* --- MlacpSendSyncRequestFromExchange: Send sync request due to need_to_sync ---
\* (mlacp_fsm.c:1481-1488)
\* Triggered when need_to_sync is set (by NAK reception, line 1191)
MlacpSendSyncRequestFromExchange(p) ==
    /\ connected[p]
    /\ iccpOperational[p]
    /\ mlacpState[p] = MlacpExchange
    /\ needToSync[p] = TRUE   \* mlacp_fsm.c:1481
    \* Clear need_to_sync (mlacp_fsm.c:1484)
    /\ needToSync' = [needToSync EXCEPT ![p] = FALSE]
    \* Send sync request TLV (mlacp_fsm.c:1486-1487)
    /\ Send([mtype |-> SyncRequestMsg, src |-> p, dst |-> Other(p)])
    /\ UNCHANGED <<connVars, mlacpState, role, waitForSyncData, nodeIdVars,
                    macVars, heartbeatVars, warmBootVars>>

\* --- MlacpReceiveSyncRequestInExchange: BUG — sync request during EXCHANGE ---
\* Path: mlacp_exchange_handler (mlacp_fsm.c:1474-1477)
\*    → mlacp_sync_receiver_handler (mlacp_fsm.c:1250-1252)
\*    → mlacp_sync_recv_syncReq (mlacp_fsm.c:557-568)
\*    → mlacp_sync_send_all_info_handler (mlacp_fsm.c:1350-1378)
\*
\* BUG (Family 2, Finding M4): current_state++ at line 1372 advances
\* EXCHANGE(3) to ERROR(4) with no state guard.
MlacpReceiveSyncRequestInExchange(p) ==
    LET q == Other(p)
        req == [mtype |-> SyncRequestMsg, src |-> q, dst |-> p]
    IN
    /\ connected[p]
    /\ iccpOperational[p]
    /\ mlacpState[p] = MlacpExchange  \* mlacp_fsm.c:1474
    \* Receive sync request
    /\ BagIn(req, messages)
    \* mlacp_sync_recv_syncReq calls mlacp_sync_send_all_info_handler (line 568)
    \* mlacp_sync_send_all_info_handler does current_state++ (line 1372)
    \* EXCHANGE(3) + 1 = ERROR(4) — BUG!
    /\ mlacpState' = [mlacpState EXCEPT ![p] = MlacpError]
    /\ waitForSyncData' = [waitForSyncData EXCEPT ![p] = FALSE]  \* line 1371
    \* Send SyncDataDone + SysConfig as response
    /\ messages' = (messages (-) SetToBag({req}))
                   (+) SetToBag({
                       [mtype |-> SysConfigMsg, src |-> p, dst |-> q,
                        mnodeId |-> nodeId[p]],
                       [mtype |-> SyncDataDoneMsg, src |-> p, dst |-> q]})
    /\ UNCHANGED <<connVars, role, needToSync, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars>>

\* ============================================================================
\* NAK HANDLING (Families 2, 3: mlacp_fsm.c:1160-1202)
\* ============================================================================

\* --- MlacpSendNAK: Send a NAK message ---
\* Abstraction: NAK can be sent for any TLV type
MlacpSendNAK(p) ==
    /\ connected[p]
    /\ iccpOperational[p]
    /\ mlacpState[p] \in {MlacpStage1, MlacpStage2, MlacpExchange}
    /\ \E nakType \in {NAKSysConfigMsg, NAKOtherMsg} :
        /\ Send([mtype |-> nakType, src |-> p, dst |-> Other(p)])
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars>>

\* --- MlacpReceiveNAK: Receive NAK, update state ---
\* (mlacp_fsm.c:1170-1202, mlacp_sync_recv_nak_handler)
MlacpReceiveNAK(p) ==
    LET q == Other(p) IN
    \/ \* Case 1: NAK for SysConfig → decrement node_id (mlacp_fsm.c:1184)
       LET msg == [mtype |-> NAKSysConfigMsg, src |-> q, dst |-> p] IN
       /\ BagIn(msg, messages)
       /\ nodeId' = [nodeId EXCEPT ![p] = IF @ > 0 THEN @ - 1 ELSE 0]  \* line 1184
       /\ needToSync' = [needToSync EXCEPT ![p] = needToSync[p]]
       /\ Discard(msg)
       /\ UNCHANGED <<connVars, mlacpState, role, waitForSyncData,
                       remoteNodeId, macVars, heartbeatVars, warmBootVars>>
    \/ \* Case 2: NAK for other → set need_to_sync (mlacp_fsm.c:1191)
       LET msg == [mtype |-> NAKOtherMsg, src |-> q, dst |-> p] IN
       /\ BagIn(msg, messages)
       /\ needToSync' = [needToSync EXCEPT ![p] = TRUE]  \* line 1191
       /\ Discard(msg)
       /\ UNCHANGED <<connVars, mlacpState, role, waitForSyncData,
                       nodeIdVars, macVars, heartbeatVars, warmBootVars>>

\* ============================================================================
\* NODE ID COLLISION (Family 3: mlacp_sync_update.c:44-79)
\* ============================================================================

\* --- ReceiveSysConfig: Process SysConfig, detect node_id collision ---
\* (mlacp_sync_update.c:44-79, mlacp_fsm_update_system_conf)
\* BUG (Family 3, Finding M6): Both peers increment on collision,
\* creating infinite livelock when starting with same node_id.
\* Also: node_id is uint8_t on wire (mlacp_tlv.h:56) but uint32_t
\* locally (mlacp_fsm.h:69) — truncation after 255 increments.
ReceiveSysConfig(p) ==
    LET q == Other(p) IN
    \E msg \in BagToSet(messages) :
        /\ msg.mtype = SysConfigMsg
        /\ msg.dst = p
        /\ msg.src = q
        \* Collision detection (mlacp_sync_update.c:57-58)
        \* "if (sysconf->node_id == MLACP(csm).node_id) MLACP(csm).node_id++"
        /\ nodeId' = [nodeId EXCEPT ![p] =
            IF msg.mnodeId = nodeId[p]
            THEN IF @ < MaxNodeId THEN @ + 1 ELSE @  \* node_id++ (line 58)
            ELSE @]
        \* Store remote node_id (mlacp_sync_update.c:64)
        /\ remoteNodeId' = [remoteNodeId EXCEPT ![p] = msg.mnodeId]
        /\ Discard(msg)
        /\ UNCHANGED <<connVars, mlacpVars, macVars, heartbeatVars,
                        warmBootVars>>

\* ============================================================================
\* MAC SYNC PROTOCOL (Family 1)
\* ============================================================================

\* --- LocalMacLearn: MAC learned locally from hardware/syncd ---
\* Abstraction of new MAC appearing in the forwarding table.
\* When learned, no age flags set (age_flag = 0).
\* (mlacp_link_handler.c:2870-2930, do_mac_update_from_syncd, new MAC path)
LocalMacLearn(p, m) ==
    /\ ~macExists[p][m]
    /\ portState[p] = PortStateUp
    /\ macExists' = [macExists EXCEPT ![p][m] = TRUE]
    /\ ageFlag' = [ageFlag EXCEPT ![p][m] = {}]   \* age_flag = 0
    /\ addToSyncd' = [addToSyncd EXCEPT ![p][m] = TRUE]
    /\ pendingLocalDel' = [pendingLocalDel EXCEPT ![p][m] = FALSE]
    \* If in EXCHANGE, send MAC_SYNC_ADD to peer
    /\ IF mlacpState[p] = MlacpExchange
       THEN Send([mtype |-> MacSyncAddMsg, src |-> p, dst |-> Other(p), mac |-> m])
       ELSE UNCHANGED messages
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, portState,
                    heartbeatVars, warmBootVars>>

\* --- LocalMacAge: MAC aged locally, set MAC_AGE_LOCAL ---
\* (mlacp_link_handler.c:1680-1736, set_mac_local_age_flag, set=1)
\* BUG (Family 1, Finding M2): If not in EXCHANGE state, age notification
\* is NOT sent to peer (mlacp_link_handler.c:1720). Peer has stale state.
LocalMacAge(p, m) ==
    /\ macExists[p][m]
    /\ ~HasLocalAge(p, m)   \* Only if LOCAL not already set (line 1711)
    \* Set MAC_AGE_LOCAL (mlacp_link_handler.c:1713)
    /\ ageFlag' = [ageFlag EXCEPT ![p][m] = @ \cup {"LOCAL"}]
    \* Send MAC_SYNC_DEL to peer ONLY if in EXCHANGE (line 1720)
    \* BUG: If not in EXCHANGE, notification is silently dropped
    /\ IF mlacpState[p] = MlacpExchange
       THEN Send([mtype |-> MacSyncDelMsg, src |-> p, dst |-> Other(p), mac |-> m])
       ELSE UNCHANGED messages
    \* If both aged, delete from chip
    /\ IF ageFlag[p][m] \cup {"LOCAL"} = {"LOCAL", "PEER"}
       THEN addToSyncd' = [addToSyncd EXCEPT ![p][m] = FALSE]
       ELSE UNCHANGED addToSyncd
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, pendingLocalDel,
                    macExists, portState, heartbeatVars, warmBootVars>>

\* --- MacUpdateFromSyncd: MAC update from mclagsyncd (existing MAC) ---
\* (mlacp_link_handler.c:2828-2868, do_mac_update_from_syncd)
\* BUG (Family 1, Finding M1): Lines 2843, 2860 check mac_msg->age_flag
\* (stack variable, always 0) instead of mac_info->age_flag (RB-tree entry).
\* This means the del_mac_from_chip check is always true (never has PEER).
MacUpdateFromSyncd(p, m) ==
    /\ macExists[p][m]
    /\ portState[p] = PortStateUp
    \* Remove MAC_AGE_LOCAL flag (mlacp_link_handler.c:2838)
    /\ ageFlag' = [ageFlag EXCEPT ![p][m] = @ \ {"LOCAL"}]
    \* BUG: checks mac_msg->age_flag (incoming, always 0) not mac_info->age_flag
    \* (mlacp_link_handler.c:2843) "if (!(mac_msg->age_flag & MAC_AGE_PEER))"
    \* mac_msg is the stack/incoming variable, which NEVER has MAC_AGE_PEER
    \* So this condition is ALWAYS true, causing del_mac_from_chip unconditionally
    /\ LET incomingAgeFlag == {}  \* mac_msg->age_flag from syncd = always 0
           storedAgeFlag == ageFlag[p][m] \ {"LOCAL"}  \* mac_info after clearing LOCAL
       IN
       \* The code checks the WRONG variable (incoming, not stored)
       IF ~("PEER" \in incomingAgeFlag)  \* Always TRUE — BUG
       THEN addToSyncd' = [addToSyncd EXCEPT ![p][m] = FALSE]
       ELSE UNCHANGED addToSyncd
    \* Send MAC_SYNC_ADD to peer if in EXCHANGE
    /\ IF mlacpState[p] = MlacpExchange
       THEN Send([mtype |-> MacSyncAddMsg, src |-> p, dst |-> Other(p), mac |-> m])
       ELSE UNCHANGED messages
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, pendingLocalDel,
                    macExists, portState, heartbeatVars, warmBootVars>>

\* --- ReceivePeerMacAdd: Receive MAC_SYNC_ADD from peer ---
\* (mlacp_sync_update.c:216-553, mlacp_fsm_update_mac_entry_from_peer)
\* Path for existing MAC with ADD operation
ReceivePeerMacAdd(p, m) ==
    LET q == Other(p)
        msg == [mtype |-> MacSyncAddMsg, src |-> q, dst |-> p, mac |-> m]
    IN
    /\ BagIn(msg, messages)
    /\ mlacpState[p] = MlacpExchange
    /\ macExists[p][m]
    \* Clear MAC_AGE_PEER flag (mlacp_sync_update.c:264)
    \* "mac_msg->age_flag &= ~MAC_AGE_PEER"
    /\ IF pendingLocalDel[p][m]
       THEN \* BUG (Family 1, Finding M3): pending_local_del + peer ADD
            \* (mlacp_sync_update.c:266-279)
            \* Clears pending_local_del, sets age_flag = MAC_AGE_LOCAL
            \* Then sends MAC_SYNC_DEL back → potential ping-pong
            /\ pendingLocalDel' = [pendingLocalDel EXCEPT ![p][m] = FALSE]  \* line 268
            /\ ageFlag' = [ageFlag EXCEPT ![p][m] = {"LOCAL"}]              \* line 270
            \* Send DEL back to peer (line 274-278)
            /\ messages' = (messages (-) SetToBag({msg}))
                           (+) SetToBag({[mtype |-> MacSyncDelMsg,
                                          src |-> p, dst |-> q, mac |-> m]})
            /\ UNCHANGED <<addToSyncd>>
       ELSE \* Normal path: clear PEER age (line 264)
            /\ ageFlag' = [ageFlag EXCEPT ![p][m] = @ \ {"PEER"}]
            /\ Discard(msg)
            /\ UNCHANGED <<pendingLocalDel, addToSyncd>>
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macExists, portState,
                    heartbeatVars, warmBootVars>>

\* --- ReceivePeerMacAddNew: Receive MAC_SYNC_ADD for new MAC ---
\* (mlacp_sync_update.c:478-553, new MAC path)
ReceivePeerMacAddNew(p, m) ==
    LET q == Other(p)
        msg == [mtype |-> MacSyncAddMsg, src |-> q, dst |-> p, mac |-> m]
    IN
    /\ BagIn(msg, messages)
    /\ mlacpState[p] = MlacpExchange
    /\ ~macExists[p][m]
    \* New MAC: create entry with MAC_AGE_LOCAL set
    \* (mlacp_sync_update.c:486-489, set_mac_local_age_flag(csm, mac_msg, 1, 0))
    /\ macExists' = [macExists EXCEPT ![p][m] = TRUE]
    /\ ageFlag' = [ageFlag EXCEPT ![p][m] = {"LOCAL"}]   \* remote MAC = local age
    /\ pendingLocalDel' = [pendingLocalDel EXCEPT ![p][m] = FALSE]
    /\ addToSyncd' = [addToSyncd EXCEPT ![p][m] = TRUE]
    /\ Discard(msg)
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, portState,
                    heartbeatVars, warmBootVars>>

\* --- ReceivePeerMacDel: Receive MAC_SYNC_DEL from peer ---
\* (mlacp_sync_update.c:449-477)
\* Sets MAC_AGE_PEER. If both aged, delete MAC.
ReceivePeerMacDel(p, m) ==
    LET q == Other(p)
        msg == [mtype |-> MacSyncDelMsg, src |-> q, dst |-> p, mac |-> m]
    IN
    /\ BagIn(msg, messages)
    /\ mlacpState[p] = MlacpExchange
    /\ macExists[p][m]
    \* Set MAC_AGE_PEER (mlacp_sync_update.c:452)
    /\ LET newFlag == ageFlag[p][m] \cup {"PEER"} IN
       IF newFlag = {"LOCAL", "PEER"}
       THEN \* Both aged → delete MAC (mlacp_sync_update.c:458-471)
            /\ macExists' = [macExists EXCEPT ![p][m] = FALSE]
            /\ ageFlag' = [ageFlag EXCEPT ![p][m] = {}]
            /\ addToSyncd' = [addToSyncd EXCEPT ![p][m] = FALSE]
            /\ pendingLocalDel' = [pendingLocalDel EXCEPT ![p][m] = FALSE]
       ELSE \* Only peer aged, keep MAC (mlacp_sync_update.c:473-476)
            /\ ageFlag' = [ageFlag EXCEPT ![p][m] = newFlag]
            /\ UNCHANGED <<macExists, addToSyncd, pendingLocalDel>>
    /\ Discard(msg)
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, portState,
                    heartbeatVars, warmBootVars>>

\* --- PortStateDown: Port channel goes down ---
\* (mlacp_link_handler.c:1739-1863, update_l2_mac_state, po_state=0)
\* For each MAC on this port:
\*   - If age_flag == MAC_AGE_PEER only: set pending_local_del (line 1795)
\*   - Otherwise: set MAC_AGE_LOCAL (line 1800)
\*   - If both aged: delete MAC (line 1806-1823)
PortChannelDown(p) ==
    /\ portState[p] = PortStateUp
    /\ portState' = [portState EXCEPT ![p] = PortStateDown]
    \* For each existing MAC on this peer
    /\ LET portDeleted(m) == macExists[p][m]
                              /\ ageFlag[p][m] \cup {"LOCAL"} = {"LOCAL", "PEER"}
                              /\ ageFlag[p][m] /= {"PEER"}
       IN
       /\ ageFlag' = [ageFlag EXCEPT ![p] =
           [m \in MAC |-> IF ~macExists[p][m] THEN ageFlag[p][m]
                          ELSE IF portDeleted(m) THEN {}  \* cleared on delete
                          ELSE IF ageFlag[p][m] = {"PEER"}
                               THEN ageFlag[p][m]
                               ELSE ageFlag[p][m] \cup {"LOCAL"}]]
       /\ pendingLocalDel' = [pendingLocalDel EXCEPT ![p] =
           [m \in MAC |-> IF macExists[p][m] /\ ageFlag[p][m] = {"PEER"}
                          THEN TRUE
                          ELSE pendingLocalDel[p][m]]]
       /\ macExists' = [macExists EXCEPT ![p] =
           [m \in MAC |-> IF portDeleted(m) THEN FALSE
                          ELSE macExists[p][m]]]
       /\ addToSyncd' = [addToSyncd EXCEPT ![p] =
           [m \in MAC |-> IF portDeleted(m) THEN FALSE
                          ELSE addToSyncd[p][m]]]
    \* Send MAC_SYNC_DEL for aged MACs if in EXCHANGE (line 1720 via set_mac_local_age_flag)
    /\ IF mlacpState[p] = MlacpExchange
       THEN LET agedMacs == {m \in MAC : macExists[p][m]
                                         /\ ageFlag[p][m] /= {"PEER"}
                                         /\ ~HasLocalAge(p, m)}
            IN SendAll({[mtype |-> MacSyncDelMsg, src |-> p,
                         dst |-> Other(p), mac |-> m] : m \in agedMacs})
       ELSE UNCHANGED messages
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, heartbeatVars, warmBootVars>>

\* --- PortStateUp: Port channel comes back up ---
\* (mlacp_link_handler.c:1864-1937, update_l2_mac_state, po_state=1)
\* BUG (Family 1, Finding M3): pending_local_del cleared on port-up (line 1874)
\* but MAC_AGE_LOCAL NOT cleared (line 1878-1880, commented out code).
\* This leaves MAC in inconsistent state.
PortChannelUp(p) ==
    /\ portState[p] = PortStateDown
    /\ portState' = [portState EXCEPT ![p] = PortStateUp]
    \* For MACs pointing to peer-link: clear pending_local_del (line 1874-1875)
    \* BUG: age flag NOT cleared (line 1878-1880, code commented out)
    /\ pendingLocalDel' = [pendingLocalDel EXCEPT ![p] =
        [m \in MAC |-> IF macExists[p][m] /\ pendingLocalDel[p][m]
                       THEN FALSE   \* mlacp_link_handler.c:1875
                       ELSE pendingLocalDel[p][m]]]
    \* BUG: The following line is COMMENTED OUT in the source code:
    \* mac_msg->age_flag = set_mac_local_age_flag(csm, mac_msg, 0, 1);
    \* (mlacp_link_handler.c:1880)
    \* So LOCAL age flag remains set, leaving MAC in stale state
    \* Delete MACs with pending_local_del that are not static
    \* (mlacp_link_handler.c:1892-1916)
    /\ LET upDeleted(m) == macExists[p][m] /\ pendingLocalDel[p][m]
       IN
       \* BUG: age flag NOT cleared for surviving MACs (line 1880 commented out)
       \* But clear ageFlag for deleted MACs (struct freed in impl)
       /\ ageFlag' = [ageFlag EXCEPT ![p] =
           [m \in MAC |-> IF upDeleted(m) THEN {}
                          ELSE ageFlag[p][m]]]
       /\ macExists' = [macExists EXCEPT ![p] =
           [m \in MAC |-> IF upDeleted(m) THEN FALSE
                          ELSE macExists[p][m]]]
       /\ addToSyncd' = [addToSyncd EXCEPT ![p] =
           [m \in MAC |-> IF upDeleted(m) THEN FALSE
                          ELSE addToSyncd[p][m]]]
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, messages,
                    heartbeatVars, warmBootVars>>

\* ============================================================================
\* SESSION DISCONNECT (Families 4, 5)
\* ============================================================================

\* --- PeerDisconnFdbHandler: FDB cleanup on normal disconnect ---
\* (mlacp_link_handler.c:2291-2347)
\* Sets MAC_AGE_PEER on all MACs. Deletes MACs with both flags or pending_local_del.
PeerDisconnFdbHandler(p) ==
    /\ LET deleted(m) == macExists[p][m]
                          /\ (ageFlag[p][m] \cup {"PEER"} = {"LOCAL", "PEER"}
                              \/ pendingLocalDel[p][m])
       IN
       /\ ageFlag' = [ageFlag EXCEPT ![p] =
           [m \in MAC |->
               IF ~macExists[p][m] THEN ageFlag[p][m]
               \* Deleted MACs: clear ageFlag (struct freed in impl)
               ELSE IF deleted(m) THEN {}
               \* Surviving MACs: add PEER age (line 2304/2330/2339)
               ELSE ageFlag[p][m] \cup {"PEER"}]]
       /\ macExists' = [macExists EXCEPT ![p] =
           [m \in MAC |->
               IF deleted(m) THEN FALSE
               ELSE macExists[p][m]]]
    /\ addToSyncd' = [addToSyncd EXCEPT ![p] =
        [m \in MAC |->
            IF macExists[p][m]
               /\ (ageFlag[p][m] \cup {"PEER"} = {"LOCAL", "PEER"}
                   \/ pendingLocalDel[p][m])
            THEN FALSE
            ELSE addToSyncd[p][m]]]
    /\ pendingLocalDel' = [pendingLocalDel EXCEPT ![p] =
        [m \in MAC |-> FALSE]]

\* --- SessionDisconnect: Full disconnect handler chain ---
\* (scheduler.c:831-858, scheduler_session_disconnect_handler)
\* Calls: mlacp_peer_disconn_handler → MLACP_STATE_INIT → iccp_csm_status_reset
\*
\* BUG (Family 5, Finding M7): warm_reboot_disconn_time set by
\* mlacp_peer_disconn_handler (line 2386) then immediately cleared
\* by iccp_csm_status_reset (iccp_csm.c:146)
SessionDisconnect(p) ==
    /\ connected[p]
    \* Step 1: mlacp_peer_disconn_handler (scheduler.c:851)
    \* (mlacp_link_handler.c:2349-2424)
    \* Step 3: iccp_csm_status_reset(csm, 0) (scheduler.c:853)
    \* BUG (Family 5, Finding M7): In warm boot path, mlacp_peer_disconn_handler
    \* sets warm_reboot_disconn_time (line 2386), then iccp_csm_status_reset
    \* immediately clears it to 0 (iccp_csm.c:146). Net effect: always FALSE.
    /\ IF peerWarmRebootTime[p]
       THEN \* Peer was warm rebooting (line 2380-2388)
            \* Step 1: set warm_reboot_disconn_time (line 2386) — but...
            \* Step 3: iccp_csm_status_reset clears it immediately (iccp_csm.c:146)
            \* Net effect: warm_reboot_disconn_time stays FALSE — BUG!
            /\ warmRebootDisconnTime' = [warmRebootDisconnTime EXCEPT ![p] = FALSE]
            \* Clear peer_warm_reboot_time (line 2383)
            /\ peerWarmRebootTime' = [peerWarmRebootTime EXCEPT ![p] = FALSE]
            \* Early return — skip FDB cleanup (line 2388)
            /\ fdbCleaned' = fdbCleaned   \* NOT cleaned — BUG consequence
            /\ UNCHANGED <<ageFlag, pendingLocalDel, macExists, addToSyncd>>
       ELSE \* Normal disconnect: do FDB cleanup
            /\ PeerDisconnFdbHandler(p)
            /\ fdbCleaned' = [fdbCleaned EXCEPT ![p] = TRUE]
            /\ UNCHANGED <<peerWarmRebootTime, warmRebootDisconnTime>>
    \* Step 2: MLACP_STATE_INIT (scheduler.c:852)
    /\ mlacpState' = [mlacpState EXCEPT ![p] = MlacpInit]
    /\ waitForSyncData' = [waitForSyncData EXCEPT ![p] = FALSE]
    /\ needToSync' = [needToSync EXCEPT ![p] = FALSE]
    \* Reset connection state
    /\ connected' = [connected EXCEPT ![p] = FALSE]
    /\ iccpOperational' = [iccpOperational EXCEPT ![p] = FALSE]
    /\ heartbeatActive' = [heartbeatActive EXCEPT ![p] = FALSE]
    /\ heartbeatTimer' = [heartbeatTimer EXCEPT ![p] = 0]
    \* Drop all pending messages from this peer
    /\ messages' = EmptyBag
    /\ UNCHANGED <<role, nodeIdVars, portState>>

\* ============================================================================
\* HEARTBEAT (Family 4: scheduler.c:74-90)
\* ============================================================================

\* --- TimerTick: Abstract heartbeat timer tick ---
\* (scheduler.c:82, time(NULL) - heartbeat_update_time comparison)
\* Heartbeat timer increments for connected peers
TimerTick(p) ==
    /\ heartbeatActive[p]
    /\ heartbeatTimer[p] < MaxTimer
    /\ heartbeatTimer' = [heartbeatTimer EXCEPT ![p] = @ + 1]
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macVars,
                    heartbeatActive, warmBootVars, networkVars>>

\* --- SendHeartbeat: Send heartbeat to peer ---
\* (mlacp_fsm.c:413-427, mlacp_sync_send_heartbeat)
\* Called from mlacp_fsm_transit (line 880), which requires
\* csm->sock_fd > 0 && csm->app_csm.current_state == APP_OPERATIONAL
\* BUG (Family 4, Finding M8): Heartbeats only sent when ICCP is operational
\* and mlacp_fsm_transit runs, but heartbeat timer starts on TCP connect.
SendHeartbeat(p) ==
    /\ connected[p]
    /\ iccpOperational[p]
    \* mlacp_fsm_transit requires APP_OPERATIONAL (mlacp_fsm.c:848)
    \* Heartbeats sent regardless of MLACP state (line 880, before state dispatch)
    /\ Send([mtype |-> HeartbeatMsg, src |-> p, dst |-> Other(p)])
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars>>

\* --- ReceiveHeartbeat: Receive heartbeat, reset timer ---
\* (mlacp_sync_update.c:1317-1325, mlacp_fsm_update_heartbeat)
\* "time(&csm->heartbeat_update_time)" — resets the timer
ReceiveHeartbeat(p) ==
    LET q == Other(p)
        msg == [mtype |-> HeartbeatMsg, src |-> q, dst |-> p]
    IN
    /\ BagIn(msg, messages)
    \* Reset heartbeat timer (mlacp_sync_update.c:1322)
    /\ heartbeatTimer' = [heartbeatTimer EXCEPT ![p] = 0]
    /\ Discard(msg)
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macVars,
                    heartbeatActive, warmBootVars>>

\* --- HeartbeatTimeout: Timer expires, disconnect session ---
\* (scheduler.c:82-86, heartbeat_check)
\* "if (time(NULL) - heartbeat_update_time > session_timeout)"
HeartbeatTimeout(p) ==
    /\ heartbeatActive[p]
    /\ heartbeatTimer[p] >= MaxTimer   \* Timeout exceeded (scheduler.c:82)
    \* Calls scheduler_session_disconnect_handler (scheduler.c:86)
    \* We model this as enabling SessionDisconnect
    /\ connected' = [connected EXCEPT ![p] = FALSE]
    /\ iccpOperational' = [iccpOperational EXCEPT ![p] = FALSE]
    /\ mlacpState' = [mlacpState EXCEPT ![p] = MlacpInit]
    /\ waitForSyncData' = [waitForSyncData EXCEPT ![p] = FALSE]
    /\ needToSync' = [needToSync EXCEPT ![p] = FALSE]
    /\ heartbeatActive' = [heartbeatActive EXCEPT ![p] = FALSE]
    /\ heartbeatTimer' = [heartbeatTimer EXCEPT ![p] = 0]
    \* iccp_csm_status_reset clears warm boot state (iccp_csm.c:146)
    /\ warmRebootDisconnTime' = [warmRebootDisconnTime EXCEPT ![p] = FALSE]
    /\ peerWarmRebootTime' = [peerWarmRebootTime EXCEPT ![p] = FALSE]
    /\ fdbCleaned' = fdbCleaned
    \* FDB cleanup via mlacp_peer_disconn_handler
    /\ PeerDisconnFdbHandler(p)
    /\ messages' = EmptyBag
    /\ UNCHANGED <<role, nodeIdVars, portState>>

\* ============================================================================
\* WARM BOOT (Family 5)
\* ============================================================================

\* --- PeerWarmBoot: Peer notifies warm boot ---
\* (mlacp_sync_update.c:1327-1340, mlacp_fsm_update_warmboot)
\* Sets peer_warm_reboot_time
PeerWarmBoot(p) ==
    LET q == Other(p)
        msg == [mtype |-> WarmBootMsg, src |-> q, dst |-> p]
    IN
    /\ BagIn(msg, messages)
    /\ peerWarmRebootTime' = [peerWarmRebootTime EXCEPT ![p] = TRUE]
    /\ Discard(msg)
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macVars,
                    heartbeatVars, warmRebootDisconnTime, fdbCleaned>>

\* --- SendWarmBoot: Peer sends warm boot notification ---
SendWarmBoot(p) ==
    /\ connected[p]
    /\ iccpOperational[p]
    /\ Send([mtype |-> WarmBootMsg, src |-> p, dst |-> Other(p)])
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars>>

\* --- WarmBootTimeout: 90s warm boot reconnection timeout ---
\* (mlacp_fsm.c:868-878)
\* If warm_reboot_disconn_time != 0 and 90s elapsed, recover to normal
\* BUG (Family 5, Finding M7): This NEVER fires because
\* iccp_csm_status_reset already cleared warm_reboot_disconn_time to 0
WarmBootTimeout(p) ==
    /\ warmRebootDisconnTime[p] = TRUE   \* line 868
    \* 90s timeout elapsed (line 872)
    /\ warmRebootDisconnTime' = [warmRebootDisconnTime EXCEPT ![p] = FALSE]
    \* Recover to normal disconnect: call mlacp_peer_disconn_handler (line 876)
    /\ PeerDisconnFdbHandler(p)
    /\ fdbCleaned' = [fdbCleaned EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, portState,
                    heartbeatVars, peerWarmRebootTime, networkVars>>

\* ============================================================================
\* FAULT INJECTION
\* ============================================================================

\* --- TcpDisconnect: TCP connection drops ---
\* Models network failure causing session disconnect
TcpDisconnect(p) ==
    /\ connected[p]
    /\ SessionDisconnect(p)

\* --- MessageLoss: Message lost in transit ---
\* Models unreliable network
MessageLoss ==
    /\ \E m \in BagToSet(messages) :
       Discard(m)
    /\ UNCHANGED <<connVars, mlacpVars, nodeIdVars, macVars,
                    heartbeatVars, warmBootVars>>

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

Next ==
    \/ \E p \in Peer :
        \* Connection management
        \/ TcpConnect(p)
        \/ IccpBecomeOperational(p)
        \* MLACP handshake (Family 2)
        \/ MlacpInitToStage1(p)
        \/ MlacpSendSyncRequest(p)
        \/ MlacpStageSendAllInfo(p)
        \/ MlacpReceiveSyncDone(p)
        \* Exchange phase (Family 2)
        \/ MlacpSendSyncRequestFromExchange(p)
        \/ MlacpReceiveSyncRequestInExchange(p)
        \* NAK handling (Families 2, 3)
        \/ MlacpSendNAK(p)
        \/ MlacpReceiveNAK(p)
        \* Node ID (Family 3)
        \/ ReceiveSysConfig(p)
        \* MAC operations (Family 1)
        \/ \E m \in MAC :
            \/ LocalMacLearn(p, m)
            \/ LocalMacAge(p, m)
            \/ MacUpdateFromSyncd(p, m)
            \/ ReceivePeerMacAdd(p, m)
            \/ ReceivePeerMacAddNew(p, m)
            \/ ReceivePeerMacDel(p, m)
        \/ PortChannelDown(p)
        \/ PortChannelUp(p)
        \* Heartbeat (Family 4)
        \/ TimerTick(p)
        \/ SendHeartbeat(p)
        \/ ReceiveHeartbeat(p)
        \/ HeartbeatTimeout(p)
        \* Warm boot (Family 5)
        \/ PeerWarmBoot(p)
        \/ SendWarmBoot(p)
        \/ WarmBootTimeout(p)
        \* Fault injection
        \/ TcpDisconnect(p)
    \* Network fault
    \/ MessageLoss

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard Safety ---

\* Both peers must agree on role assignment
RoleConsistency ==
    \A p \in Peer : role[p] /= role[Other(p)]

\* --- Extension Invariant: NoErrorState (Family 2) ---
\* MLACP FSM should never reach ERROR state during normal operation.
\* BUG (Finding M4): Violated when sync request is received during EXCHANGE.
NoErrorState ==
    \A p \in Peer : mlacpState[p] /= MlacpError

\* --- Extension Invariant: SyncRequestSafety (Family 2) ---
\* Receiving a sync request during EXCHANGE should not change current_state.
\* This is logically equivalent to NoErrorState but expressed differently.
SyncRequestSafety ==
    \A p \in Peer :
        mlacpState[p] = MlacpExchange =>
            mlacpState'[p] \in {MlacpExchange, MlacpInit}

\* --- Extension Invariant: MACConsistency (Family 1) ---
\* If a MAC has LOCAL age set on one peer, the other peer should have been
\* notified (MAC_SYNC_DEL sent). If not in EXCHANGE when aged, notification
\* is lost (Finding M2).
\* Expressed as: if LOCAL is set AND both peers were in EXCHANGE at age time
\* AND session is still up, then PEER must be set on the other peer.
\* Simplified version: checks for the wrong-variable bug symptom.
MACConsistency ==
    \A p \in Peer : \A m \in MAC :
        \* If MAC exists and was removed from syncd (del_mac_from_chip called)
        \* but the stored age flag says PEER is NOT set, that's inconsistent
        \* with the code's intent (the del should only happen when peer not aged)
        macExists[p][m] /\ ~addToSyncd[p][m] =>
            \* Either MAC is being deleted (both aged) or
            \* the wrong-variable bug caused premature deletion
            HasBothAge(p, m) \/ HasLocalAge(p, m)

\* --- Extension Invariant: NoPendingDelLeak (Family 1) ---
\* pending_local_del should not persist after port comes back up AND
\* the MAC is still in the table.
NoPendingDelLeak ==
    \A p \in Peer : \A m \in MAC :
        portState[p] = PortStateUp /\ macExists[p][m] =>
            ~pendingLocalDel[p][m]

\* --- Extension Invariant: CorrectAgeVariableCheck (Family 1) ---
\* When MacUpdateFromSyncd runs, it should check the STORED age flag
\* (mac_info->age_flag) not the incoming variable (mac_msg->age_flag).
\* The bug means del_mac_from_chip is called even when PEER age is set.
\* This invariant detects the symptom: a MAC was deleted from chip
\* (addToSyncd = FALSE) while it still has PEER age (should have been kept).
CorrectAgeVariableCheck ==
    \A p \in Peer : \A m \in MAC :
        macExists[p][m] /\ HasPeerAge(p, m) /\ ~HasLocalAge(p, m) =>
            addToSyncd[p][m]

\* --- Extension Invariant: NodeIdDivergence (Family 3, Liveness) ---
\* After SysConfig exchange, node IDs should eventually differ.
\* BUG (Finding M6): Both peers increment simultaneously, never diverging.
\* As a safety check: if both peers have exchanged SysConfig and have
\* the same nodeId, the protocol has failed.
NodeIdCollisionDetected ==
    \A p \in Peer :
        remoteNodeId[p] /= Nil /\ remoteNodeId[Other(p)] /= Nil =>
            nodeId[p] /= nodeId[Other(p)]

\* --- Extension Invariant: WarmBootFdbCleanup (Family 5) ---
\* After warm boot disconnect, FDB cleanup should eventually happen.
\* BUG (Finding M7): warm_reboot_disconn_time cleared by iccp_csm_status_reset,
\* so the timeout never fires and FDB cleanup is permanently skipped.
\* Safety version: if session disconnected and peer was warm rebooting,
\* fdbCleaned should be TRUE at some point.
WarmBootFdbConsistency ==
    \A p \in Peer :
        ~connected[p] /\ ~peerWarmRebootTime[p] /\
        ~warmRebootDisconnTime[p] =>
            fdbCleaned[p]

\* --- Extension Invariant: NoFalseHeartbeatTimeout (Family 4) ---
\* Heartbeat timeout should not fire for a peer that is alive and connected
\* but simply hasn't had ICCP become operational yet.
\* BUG (Finding M8): heartbeat timer starts on TCP connect but heartbeats
\* only exchanged after ICCP is operational.
NoFalseHeartbeatTimeout ==
    \A p \in Peer :
        connected[p] /\ connected[Other(p)] /\
        ~iccpOperational[p] =>
            heartbeatTimer[p] < MaxTimer

\* --- Structural Invariants ---

\* MLACP state valid range
MlacpStateValid ==
    \A p \in Peer :
        mlacpState[p] \in {MlacpInit, MlacpStage1, MlacpStage2,
                           MlacpExchange, MlacpError}

\* If MLACP is past INIT, connection must be up
MlacpRequiresConnection ==
    \A p \in Peer :
        mlacpState[p] \in {MlacpStage1, MlacpStage2, MlacpExchange} =>
            connected[p] /\ iccpOperational[p]

\* Node ID bounds
NodeIdBound ==
    \A p \in Peer : nodeId[p] \in 0..MaxNodeId

\* Age flags only set on existing MACs
AgeFlagOnExistingMac ==
    \A p \in Peer : \A m \in MAC :
        ~macExists[p][m] => ageFlag[p][m] = {}

\* Temporal property: node IDs eventually diverge (Family 3, Liveness)
NodeIdEventuallyDiverge ==
    <>(\A p \in Peer : remoteNodeId[p] /= Nil =>
        nodeId[p] /= nodeId[Other(p)])

\* Temporal property: warm boot FDB cleanup eventually happens (Family 5)
WarmBootEventualCleanup ==
    \A p \in Peer :
        [](peerWarmRebootTime[p] => <>(fdbCleaned[p]))

=============================================================================
