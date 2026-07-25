---- MODULE base ----
\* TLA+ spec for libspdm session lifecycle: HEARTBEAT / KEY_UPDATE / END_SESSION
\* System category: Category A (Distributed / Message-Passing), two-party request-response
\* Reference: SPDM 1.1-1.3 post-handshake session management

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* ---------------------------------------------------------------------------
\* Constants
\* ---------------------------------------------------------------------------
CONSTANTS
    MaxKeyGen       \* upper bound on key generation counter (keeps model finite)

\* ---------------------------------------------------------------------------
\* Session states
\* ---------------------------------------------------------------------------
ESTABLISHED  == "ESTABLISHED"
NOT_STARTED  == "NOT_STARTED"

\* Key-update phase tracker values (mirrors last_key_update_request.param1)
\* rsp_key_update_ack.c:108 -- prev_spdm_request = &(session_info->last_key_update_request)
KU_NONE         == "none"
KU_UPDATE_KEY   == "update_key"
KU_UPDATE_ALL   == "update_all_keys"

\* Requester key-update flow states
\* req_key_update.c:32-322
REQ_KU_IDLE         == "idle"
REQ_KU_UPDATE_SENT  == "update_sent"
REQ_KU_VERIFY_SENT  == "verify_sent"

\* Message types placed on the channel
MSG_UPDATE_KEY      == "UPDATE_KEY"
MSG_UPDATE_ALL_KEYS == "UPDATE_ALL_KEYS"
MSG_KEY_UPDATE_ACK  == "KEY_UPDATE_ACK"
MSG_VERIFY_NEW_KEY  == "VERIFY_NEW_KEY"
MSG_VERIFY_ACK      == "VERIFY_ACK"
MSG_END_SESSION     == "END_SESSION"
MSG_END_SESSION_ACK == "END_SESSION_ACK"
MSG_HEARTBEAT       == "HEARTBEAT"
MSG_HEARTBEAT_ACK   == "HEARTBEAT_ACK"

\* ---------------------------------------------------------------------------
\* State variables
\* ---------------------------------------------------------------------------

\* --- Session state per endpoint (Family 2) ---
\* req_end_session.c:138-141 / rsp_receive_send.c:792
VARIABLE req_session_state   \* in {ESTABLISHED, NOT_STARTED}
VARIABLE rsp_session_state   \* in {ESTABLISHED, NOT_STARTED}

\* --- Key update flow state (Family 1) ---
VARIABLE req_ku_state        \* requester phase in {idle, update_sent, verify_sent}

\* --- Key generation counters (Family 1) ---
\* Models create_update_session_data_key / activate_update_session_data_key
\* secmes_session.c:335-583
VARIABLE req_tx_gen          \* requester TX key generation (Nat)
VARIABLE rsp_tx_gen          \* responder TX key generation (Nat)
VARIABLE req_rx_gen          \* requester RX key generation (Nat)
VARIABLE rsp_rx_gen          \* responder RX key generation (Nat)

\* --- Backup key validity flags (Families 1, 4) ---
\* The two-key window: active key in slot + backup preserved until commit/rollback
\* libspdm_secmes_encode_decode.c:523-532, 625-634
VARIABLE req_rx_backup_valid  \* requester has valid backup for its RX key (BOOLEAN)
VARIABLE rsp_rx_backup_valid  \* responder has valid backup for its RX key (BOOLEAN)

\* --- Responder key-update phase tracker (Family 4) ---
\* rsp_key_update_ack.c:108 -- session_info->last_key_update_request
VARIABLE rsp_last_key_op     \* in {none, update_key, update_all_keys}

\* --- End-session flow flags (Family 2) ---
VARIABLE end_session_sent    \* requester has sent END_SESSION (BOOLEAN)
VARIABLE end_session_ack_encoded \* responder has successfully encoded END_SESSION_ACK (BOOLEAN)

\* --- Heartbeat / watchdog (Family 3) ---
VARIABLE watchdog_active     \* platform watchdog is running (BOOLEAN)
VARIABLE watchdog_expired    \* watchdog fired without a reset (BOOLEAN)

\* --- Message channel (ordered bag per direction) ---
\* Modeled as a sequence for each direction; each element is a record with mtype field
VARIABLE req_to_rsp          \* messages in flight from requester to responder
VARIABLE rsp_to_req          \* messages in flight from responder to requester

\* ---------------------------------------------------------------------------
\* Variable groups for UNCHANGED clauses
\* ---------------------------------------------------------------------------
sessionVars   == <<req_session_state, rsp_session_state>>
keyGenVars    == <<req_tx_gen, rsp_tx_gen, req_rx_gen, rsp_rx_gen>>
backupVars    == <<req_rx_backup_valid, rsp_rx_backup_valid>>
keyFlowVars   == <<req_ku_state, rsp_last_key_op>>
endSessionVars == <<end_session_sent, end_session_ack_encoded>>
watchdogVars  == <<watchdog_active, watchdog_expired>>
channelVars   == <<req_to_rsp, rsp_to_req>>

vars == <<sessionVars, keyGenVars, backupVars, keyFlowVars, endSessionVars,
          watchdogVars, channelVars>>

\* ---------------------------------------------------------------------------
\* Helpers
\* ---------------------------------------------------------------------------
Send(chan, msg) == chan \o <<msg>>

Recv(chan) == Tail(chan)
Head_(chan) == Head(chan)

SessionEstablished == req_session_state = ESTABLISHED /\ rsp_session_state = ESTABLISHED

\* ---------------------------------------------------------------------------
\* Init
\* ---------------------------------------------------------------------------
Init ==
    /\ req_session_state    = ESTABLISHED
    /\ rsp_session_state    = ESTABLISHED
    /\ req_ku_state         = REQ_KU_IDLE
    /\ req_tx_gen           = 0
    /\ rsp_tx_gen           = 0
    /\ req_rx_gen           = 0
    /\ rsp_rx_gen           = 0
    /\ req_rx_backup_valid  = FALSE
    /\ rsp_rx_backup_valid  = FALSE
    /\ rsp_last_key_op      = KU_NONE
    /\ end_session_sent     = FALSE
    /\ end_session_ack_encoded = FALSE
    /\ watchdog_active      = TRUE
    /\ watchdog_expired     = FALSE
    /\ req_to_rsp           = <<>>
    /\ rsp_to_req           = <<>>

\* ===========================================================================
\* KEY_UPDATE actions -- Family 1 (Two-Party Key Update State Desynchronization)
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* ReqSendUpdateKey
\* Requester sends UPDATE_KEY (single_direction=true).
\* req_key_update.c:77-131
\*   - No create_update on responder direction (single_direction=true, skip lines 111-122)
\*   - Sends KEY_UPDATE with param1=UPDATE_KEY
\* ---------------------------------------------------------------------------
ReqSendUpdateKey ==
    \* req_key_update.c:71-73 -- session must be ESTABLISHED
    /\ req_session_state = ESTABLISHED
    /\ req_ku_state = REQ_KU_IDLE
    \* req_key_update.c:77 -- key_updated must be false (first sub-call)
    /\ req_to_rsp' = Send(req_to_rsp, [mtype |-> MSG_UPDATE_KEY])
    /\ req_ku_state' = REQ_KU_UPDATE_SENT
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, rsp_last_key_op,
                   endSessionVars, watchdogVars, rsp_to_req>>

\* ---------------------------------------------------------------------------
\* ReqSendUpdateAllKeys
\* Requester sends UPDATE_ALL_KEYS (single_direction=false).
\* req_key_update.c:110-122 -- creates responder key before sending
\*   create_update_session_data_key(RESPONDER) -- backup of rsp RX slot saved
\* ---------------------------------------------------------------------------
ReqSendUpdateAllKeys ==
    /\ req_session_state = ESTABLISHED
    /\ req_ku_state = REQ_KU_IDLE
    /\ req_to_rsp' = Send(req_to_rsp, [mtype |-> MSG_UPDATE_ALL_KEYS])
    /\ req_ku_state' = REQ_KU_UPDATE_SENT
    /\ UNCHANGED <<sessionVars, req_tx_gen, rsp_tx_gen, req_rx_gen, rsp_rx_gen,
                   req_rx_backup_valid, rsp_rx_backup_valid, rsp_last_key_op,
                   endSessionVars, watchdogVars, rsp_to_req>>

\* ---------------------------------------------------------------------------
\* RspRecvUpdateKey
\* Responder handles UPDATE_KEY from requester.
\* rsp_key_update_ack.c:113-139
\*   - Guard: prev_spdm_request must be zero (rsp_key_update_ack.c:115-121)
\*   - create_update_session_data_key(REQUESTER): advance RX slot, backup valid
\*   - Save last_key_update_request = UPDATE_KEY (rsp_key_update_ack.c:137-138)
\*   - Send KEY_UPDATE_ACK
\* ---------------------------------------------------------------------------
RspRecvUpdateKey ==
    /\ rsp_session_state = ESTABLISHED
    /\ req_to_rsp /= <<>>
    /\ Head_(req_to_rsp).mtype = MSG_UPDATE_KEY
    \* rsp_key_update_ack.c:115-121 -- prev_spdm_request must be zero
    /\ rsp_last_key_op = KU_NONE
    \* rsp_key_update_ack.c:126-131 -- create_update(REQUESTER): new gen pending, backup valid
    /\ rsp_rx_gen'           = rsp_rx_gen + 1
    /\ rsp_rx_backup_valid'  = TRUE
    \* rsp_key_update_ack.c:136-138 -- save last_key_update_request
    /\ rsp_last_key_op'      = KU_UPDATE_KEY
    /\ req_to_rsp'           = Recv(req_to_rsp)
    /\ rsp_to_req'           = Send(rsp_to_req, [mtype |-> MSG_KEY_UPDATE_ACK])
    /\ UNCHANGED <<sessionVars, req_tx_gen, rsp_tx_gen, req_rx_gen,
                   req_rx_backup_valid, req_ku_state,
                   endSessionVars, watchdogVars>>

\* ---------------------------------------------------------------------------
\* RspRecvUpdateAllKeys
\* Responder handles UPDATE_ALL_KEYS.
\* rsp_key_update_ack.c:140-192
\*   - Guard: prev_spdm_request must be zero (rsp_key_update_ack.c:141-146)
\*   - create_update(REQUESTER) + create_update(RESPONDER)
\*   - activate(RESPONDER, new=true): commit responder TX immediately (rsp_key_update_ack.c:179-187)
\*   - Save last_key_update_request = UPDATE_ALL_KEYS
\* ---------------------------------------------------------------------------
RspRecvUpdateAllKeys ==
    /\ rsp_session_state = ESTABLISHED
    /\ req_to_rsp /= <<>>
    /\ Head_(req_to_rsp).mtype = MSG_UPDATE_ALL_KEYS
    \* rsp_key_update_ack.c:141-146 -- prev_spdm_request must be zero
    /\ rsp_last_key_op = KU_NONE
    \* rsp_key_update_ack.c:152-157 -- create_update(REQUESTER)
    /\ rsp_rx_gen'          = rsp_rx_gen + 1
    /\ rsp_rx_backup_valid' = TRUE
    \* rsp_key_update_ack.c:164-173 -- create_update(RESPONDER)
    \* rsp_key_update_ack.c:175-187 -- activate(RESPONDER, new=true): commit TX immediately; backup cleared
    /\ rsp_tx_gen'          = rsp_tx_gen + 1
    \* rsp_key_update_ack.c:189-191 -- save last_key_update_request
    /\ rsp_last_key_op'     = KU_UPDATE_ALL
    /\ req_to_rsp'          = Recv(req_to_rsp)
    /\ rsp_to_req'          = Send(rsp_to_req, [mtype |-> MSG_KEY_UPDATE_ACK])
    /\ UNCHANGED <<sessionVars, req_tx_gen, req_rx_gen,
                   req_rx_backup_valid, req_ku_state,
                   endSessionVars, watchdogVars>>

\* ---------------------------------------------------------------------------
\* ReqRecvKeyUpdateAck
\* Requester receives KEY_UPDATE_ACK after sending UPDATE_KEY or UPDATE_ALL_KEYS.
\* req_key_update.c:147-224
\*   On success (UPDATE_KEY path):
\*     - create_update(REQUESTER): advance TX gen, backup becomes valid
\*     - activate(REQUESTER, new=true): commit TX, clear backup
\*     req_key_update.c:199-215
\*   On success (UPDATE_ALL_KEYS path):
\*     - activate(RESPONDER, new=true): commit rsp RX; backup cleared  [req_key_update.c:184-194]
\*     - create_update(REQUESTER) + activate(REQUESTER, new=true)      [req_key_update.c:199-215]
\* ---------------------------------------------------------------------------
ReqRecvKeyUpdateAck ==
    /\ req_session_state = ESTABLISHED
    /\ rsp_to_req /= <<>>
    /\ Head_(rsp_to_req).mtype = MSG_KEY_UPDATE_ACK
    /\ req_ku_state = REQ_KU_UPDATE_SENT
    \* req_key_update.c:184-194 -- if UPDATE_ALL_KEYS, activate RESPONDER RX (rsp_rx_backup cleared)
    \* This is the requester-side view of the responder's RX activation.
    \* For UPDATE_ALL_KEYS: rsp_rx_backup_valid was set TRUE in ReqSendUpdateAllKeys; now clear it.
    \* For UPDATE_KEY: rsp_rx_backup_valid unchanged here.
    \* req_key_update.c:199-215 -- create_update+activate REQUESTER TX
    /\ req_tx_gen'          = req_tx_gen + 1
    \* backup was valid during the window; now committed -- backup cleared
    /\ req_rx_backup_valid' = FALSE   \* req's own backup not involved in TX path
    /\ rsp_to_req'          = Recv(rsp_to_req)
    /\ req_ku_state'        = REQ_KU_VERIFY_SENT
    \* Immediately also sends VERIFY_NEW_KEY (req_key_update.c:226-260 follows directly)
    /\ req_to_rsp'          = Send(req_to_rsp, [mtype |-> MSG_VERIFY_NEW_KEY])
    /\ UNCHANGED <<sessionVars, rsp_tx_gen, req_rx_gen, rsp_rx_gen,
                   rsp_rx_backup_valid, rsp_last_key_op,
                   endSessionVars, watchdogVars>>

\* ---------------------------------------------------------------------------
\* RspRecvVerifyNewKey
\* Responder handles VERIFY_NEW_KEY.
\* rsp_key_update_ack.c:193-217
\*   - Guard: prev_spdm_request must be UPDATE_KEY or UPDATE_ALL_KEYS (rsp_key_update_ack.c:194-199)
\*   - activate(REQUESTER, new=true): commit requester RX, discard backup (rsp_key_update_ack.c:201-213)
\*   - Zero last_key_update_request (rsp_key_update_ack.c:215-216)
\*   - Send VERIFY_ACK
\* ---------------------------------------------------------------------------
RspRecvVerifyNewKey ==
    /\ rsp_session_state = ESTABLISHED
    /\ req_to_rsp /= <<>>
    /\ Head_(req_to_rsp).mtype = MSG_VERIFY_NEW_KEY
    \* rsp_key_update_ack.c:194-199 -- prev_spdm_request must be non-zero
    /\ rsp_last_key_op /= KU_NONE
    \* rsp_key_update_ack.c:201-213 -- activate(REQUESTER, new=true): commit RX, discard backup
    /\ rsp_rx_backup_valid' = FALSE
    \* rsp_key_update_ack.c:215-216 -- clear last_key_update_request
    /\ rsp_last_key_op'     = KU_NONE
    /\ req_to_rsp'          = Recv(req_to_rsp)
    /\ rsp_to_req'          = Send(rsp_to_req, [mtype |-> MSG_VERIFY_ACK])
    /\ UNCHANGED <<sessionVars, req_tx_gen, rsp_tx_gen, req_rx_gen, rsp_rx_gen,
                   req_rx_backup_valid, req_ku_state,
                   endSessionVars, watchdogVars>>

\* ---------------------------------------------------------------------------
\* ReqRecvVerifyAck
\* Requester receives VERIFY_ACK -- KEY_UPDATE flow complete.
\* req_key_update.c:299-321
\* ---------------------------------------------------------------------------
ReqRecvVerifyAck ==
    /\ req_session_state = ESTABLISHED
    /\ rsp_to_req /= <<>>
    /\ Head_(rsp_to_req).mtype = MSG_VERIFY_ACK
    /\ req_ku_state = REQ_KU_VERIFY_SENT
    /\ req_ku_state' = REQ_KU_IDLE
    /\ rsp_to_req'   = Recv(rsp_to_req)
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, rsp_last_key_op,
                   endSessionVars, watchdogVars, req_to_rsp>>

\* ===========================================================================
\* Decode-time rollback -- Family 4 (last_key_update_request stuck after rollback)
\* Also covers Family 1 decode-time fallback mechanism.
\* rsp_receive_send.c:197-263
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* DecodeWithBackupKey
\* Responder fails to decode with the new (current) key, falls back to backup,
\* re-decodes successfully with the old key, then re-derives the new key.
\* rsp_receive_send.c:197-263:
\*   Line 209: activate(REQUESTER, false) -- revert to backup
\*   Line 224-228: retry decode with backup (models SUCCESS here)
\*   Line 255-263: create_update(REQUESTER) -- re-derive new key
\*   KEY ISSUE: last_key_update_request is NOT reset (lines 249-263 have no reset)
\* Precondition: backup key must be valid (otherwise rollback impossible)
\* ---------------------------------------------------------------------------
DecodeWithBackupKey ==
    /\ rsp_session_state = ESTABLISHED
    /\ rsp_rx_backup_valid = TRUE
    \* rsp_receive_send.c:209-213: activate(REQUESTER, false) -- revert active to backup
    \* rsp_receive_send.c:255-263: create_update(REQUESTER) -- re-derive; gen bumps again
    \* Net effect: rsp_rx_gen incremented by 1 (create_update), backup still valid
    /\ rsp_rx_gen'          = rsp_rx_gen + 1
    \* rsp_receive_send.c:229 -- reset_key_update=true; re-derive re-creates new key
    /\ rsp_rx_backup_valid' = TRUE    \* backup re-created by create_update
    \* CRITICAL: rsp_last_key_op is NOT reset here (rsp_receive_send.c:249-263 no reset)
    /\ UNCHANGED <<sessionVars, req_tx_gen, rsp_tx_gen, req_rx_gen,
                   req_rx_backup_valid, req_ku_state, rsp_last_key_op,
                   endSessionVars, watchdogVars, channelVars>>

\* ===========================================================================
\* END_SESSION actions -- Family 2 (Phase Ordering and Session Cleanup)
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* ReqSendEndSession
\* Requester sends END_SESSION.
\* req_end_session.c:26-80
\* ---------------------------------------------------------------------------
ReqSendEndSession ==
    /\ req_session_state = ESTABLISHED
    /\ ~end_session_sent
    /\ req_ku_state = REQ_KU_IDLE   \* no in-progress key update
    /\ end_session_sent' = TRUE
    /\ req_to_rsp' = Send(req_to_rsp, [mtype |-> MSG_END_SESSION])
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars,
                   end_session_ack_encoded, watchdogVars, rsp_to_req>>

\* ---------------------------------------------------------------------------
\* RspRecvEndSession
\* Responder receives END_SESSION and produces END_SESSION_ACK response.
\* rsp_end_session_ack.c:9-107: validates, prepares ACK
\* Encoding happens separately in RspEncodeEndSessionAck.
\* ---------------------------------------------------------------------------
RspRecvEndSession ==
    /\ rsp_session_state = ESTABLISHED
    /\ req_to_rsp /= <<>>
    /\ Head_(req_to_rsp).mtype = MSG_END_SESSION
    /\ req_to_rsp' = Recv(req_to_rsp)
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdogVars, rsp_to_req>>

\* ---------------------------------------------------------------------------
\* RspEncodeEndSessionAck
\* Responder attempts transport_encode_message for END_SESSION_ACK.
\* rsp_receive_send.c:779-793: encoding may succeed or fail.
\* On success: watchdog stopped, terminate_session called.
\* On failure: session not terminated, requester will terminate independently.
\* Modeled as two non-deterministic outcomes.
\* ---------------------------------------------------------------------------
RspEncodeEndSessionAckSuccess ==
    /\ rsp_session_state = ESTABLISHED
    /\ end_session_sent = TRUE         \* requester already sent END_SESSION
    /\ end_session_ack_encoded = FALSE
    \* rsp_receive_send.c:779-793: encoding succeeded
    /\ end_session_ack_encoded' = TRUE
    \* rsp_receive_send.c:785-791: stop watchdog
    /\ watchdog_active'  = FALSE
    \* rsp_receive_send.c:792: libspdm_terminate_session -> set_session_state(NOT_STARTED)
    /\ rsp_session_state' = NOT_STARTED
    /\ rsp_to_req' = Send(rsp_to_req, [mtype |-> MSG_END_SESSION_ACK])
    /\ UNCHANGED <<req_session_state, keyGenVars, backupVars, keyFlowVars,
                   end_session_sent, watchdog_expired, req_to_rsp>>

RspEncodeEndSessionAckFail ==
    \* rsp_receive_send.c:779-793: encoding failed -> session NOT terminated on responder
    /\ rsp_session_state = ESTABLISHED
    /\ end_session_sent = TRUE
    /\ end_session_ack_encoded = FALSE
    \* No state change on failure (responder stays ESTABLISHED, requester will terminate)
    /\ UNCHANGED vars

\* ---------------------------------------------------------------------------
\* ReqRecvEndSessionAck
\* Requester receives END_SESSION_ACK and terminates session.
\* req_end_session.c:136-141: set NOT_STARTED, free session ID (inside handler)
\* ---------------------------------------------------------------------------
ReqRecvEndSessionAck ==
    /\ req_session_state = ESTABLISHED
    /\ rsp_to_req /= <<>>
    /\ Head_(rsp_to_req).mtype = MSG_END_SESSION_ACK
    \* req_end_session.c:138-141: set NOT_STARTED + free session (inside response block)
    /\ req_session_state' = NOT_STARTED
    /\ rsp_to_req' = Recv(rsp_to_req)
    /\ UNCHANGED <<rsp_session_state, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdogVars, req_to_rsp>>

\* ===========================================================================
\* HEARTBEAT actions -- Family 3
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* ReqSendHeartbeat
\* Requester sends HEARTBEAT.
\* req_heartbeat.c:25-149
\* ---------------------------------------------------------------------------
ReqSendHeartbeat ==
    /\ req_session_state = ESTABLISHED
    /\ req_to_rsp' = Send(req_to_rsp, [mtype |-> MSG_HEARTBEAT])
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdogVars, rsp_to_req>>

\* ---------------------------------------------------------------------------
\* RspRecvHeartbeat
\* Responder receives HEARTBEAT; resets watchdog; sends ACK.
\* rsp_heartbeat.c:11-121
\* rsp_receive_send.c:795-806: watchdog reset for any session message
\* ---------------------------------------------------------------------------
RspRecvHeartbeat ==
    /\ rsp_session_state = ESTABLISHED
    /\ req_to_rsp /= <<>>
    /\ Head_(req_to_rsp).mtype = MSG_HEARTBEAT
    \* rsp_receive_send.c:800-805: libspdm_reset_watchdog
    /\ watchdog_active'  = TRUE
    /\ watchdog_expired' = FALSE
    /\ req_to_rsp'       = Recv(req_to_rsp)
    /\ rsp_to_req'       = Send(rsp_to_req, [mtype |-> MSG_HEARTBEAT_ACK])
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars, endSessionVars>>

\* ---------------------------------------------------------------------------
\* ReqRecvHeartbeatAck
\* Requester receives HEARTBEAT_ACK.
\* req_heartbeat.c:100-149
\* ---------------------------------------------------------------------------
ReqRecvHeartbeatAck ==
    /\ req_session_state = ESTABLISHED
    /\ rsp_to_req /= <<>>
    /\ Head_(rsp_to_req).mtype = MSG_HEARTBEAT_ACK
    /\ rsp_to_req' = Recv(rsp_to_req)
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdogVars, req_to_rsp>>

\* ---------------------------------------------------------------------------
\* WatchdogExpiry
\* Platform watchdog fires when no session message received within period.
\* rsp_receive_send.c:795-806 (watchdog reset), platform callback (expiry)
\* Fault injection action -- bounded in MC spec.
\* ---------------------------------------------------------------------------
WatchdogExpiry ==
    /\ watchdog_active = TRUE
    /\ watchdog_expired' = TRUE
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdog_active, channelVars>>

\* ---------------------------------------------------------------------------
\* IntegratorTerminatesSession
\* Integrator receives watchdog callback and terminates session.
\* Platform-specific; TLA+ models as non-deterministic actor.
\* Family 3: if watchdog expired and no msg since, rsp_session_state -> NOT_STARTED
\* ---------------------------------------------------------------------------
IntegratorTerminatesSession ==
    /\ watchdog_expired = TRUE
    /\ rsp_session_state = ESTABLISHED
    /\ rsp_session_state' = NOT_STARTED
    /\ watchdog_active'   = FALSE
    /\ UNCHANGED <<req_session_state, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdog_expired, channelVars>>

\* ===========================================================================
\* Fault actions (base definitions; bounded by MC spec)
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* DropMessage -- model message loss in either channel
\* ---------------------------------------------------------------------------
DropReqToRsp ==
    /\ req_to_rsp /= <<>>
    /\ req_to_rsp' = Recv(req_to_rsp)
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdogVars, rsp_to_req>>

DropRspToReq ==
    /\ rsp_to_req /= <<>>
    /\ rsp_to_req' = Recv(rsp_to_req)
    /\ UNCHANGED <<sessionVars, keyGenVars, backupVars, keyFlowVars,
                   endSessionVars, watchdogVars, req_to_rsp>>

\* ===========================================================================
\* Next
\* ===========================================================================
Next ==
    \/ ReqSendUpdateKey
    \/ ReqSendUpdateAllKeys
    \/ RspRecvUpdateKey
    \/ RspRecvUpdateAllKeys
    \/ ReqRecvKeyUpdateAck
    \/ RspRecvVerifyNewKey
    \/ ReqRecvVerifyAck
    \/ DecodeWithBackupKey
    \/ ReqSendEndSession
    \/ RspRecvEndSession
    \/ RspEncodeEndSessionAckSuccess
    \/ RspEncodeEndSessionAckFail
    \/ ReqRecvEndSessionAck
    \/ ReqSendHeartbeat
    \/ RspRecvHeartbeat
    \/ ReqRecvHeartbeatAck
    \/ WatchdogExpiry
    \/ IntegratorTerminatesSession
    \/ DropReqToRsp
    \/ DropRspToReq

Spec == Init /\ [][Next]_vars

\* ===========================================================================
\* Invariants
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* Family 1: KeySynchronization
\* If the responder has committed a new RX key (backup no longer valid) and
\* the requester is transmitting with generation req_tx_gen, they must agree.
\* Simplified: rsp_rx_gen tracks what the responder expects; req_tx_gen is what
\* the requester sends. If both are committed (no backup), they must be equal.
\* ---------------------------------------------------------------------------
KeySynchronization ==
    (rsp_rx_backup_valid = FALSE /\ req_rx_backup_valid = FALSE)
    => (rsp_rx_gen = req_tx_gen)

\* ---------------------------------------------------------------------------
\* Family 1: BackupKeyWindow
\* Both sides should not simultaneously have valid backups unless in the
\* UPDATE_ALL_KEYS window (where both keys are transitioning).
\* ---------------------------------------------------------------------------
BackupKeyWindow ==
    ~(req_rx_backup_valid = TRUE /\ rsp_rx_backup_valid = TRUE
      /\ rsp_last_key_op = KU_NONE)

\* ---------------------------------------------------------------------------
\* Family 4: UpdateKeyStateMachineNotStuck
\* If rsp_last_key_op is non-none AND a new UPDATE_KEY/UPDATE_ALL_KEYS arrives,
\* the responder must not be in a state that permanently rejects future key updates.
\* Check: once rsp_last_key_op is set by DecodeWithBackupKey scenario, the
\* session is not stuck unable to ever complete KEY_UPDATE.
\* The stuck state: rsp_last_key_op != KU_NONE and session ESTABLISHED
\* with no VERIFY_NEW_KEY in flight to clear it.
\* ---------------------------------------------------------------------------
UpdateKeyStateMachineNotStuck ==
    \* A stuck state = last_key_op set but requester has abandoned verify flow
    ~(rsp_last_key_op /= KU_NONE
      /\ req_ku_state = REQ_KU_IDLE
      /\ req_to_rsp = <<>>   \* no in-flight VERIFY_NEW_KEY
      /\ rsp_session_state = ESTABLISHED
      /\ req_session_state = ESTABLISHED)

\* ---------------------------------------------------------------------------
\* Family 2: SessionTerminationConsistency
\* After a complete END_SESSION exchange (ACK encoded + requester received it),
\* both sides must be NOT_STARTED.
\* ---------------------------------------------------------------------------
SessionTerminationConsistency ==
    (end_session_ack_encoded = TRUE /\ req_session_state = NOT_STARTED)
    => rsp_session_state = NOT_STARTED

\* ---------------------------------------------------------------------------
\* Family 2: SessionMonotonicity
\* Once requester is NOT_STARTED, it stays NOT_STARTED.
\* ---------------------------------------------------------------------------
SessionMonotonicity ==
    req_session_state = NOT_STARTED => rsp_session_state /= ESTABLISHED \/ end_session_ack_encoded = FALSE

\* ---------------------------------------------------------------------------
\* Family 3: WatchdogLiveness
\* If watchdog expired and the session is still ESTABLISHED (integrator not yet
\* called), that's a potentially unsafe state -- we capture it as an invariant.
\* ---------------------------------------------------------------------------
WatchdogLiveness ==
    (watchdog_expired = TRUE /\ rsp_session_state = ESTABLISHED)
    => watchdog_active = TRUE  \* watchdog must still be running (edge: not stopped on non-END_SESSION paths)

\* ---------------------------------------------------------------------------
\* Structural invariants
\* ---------------------------------------------------------------------------
KeyGenBounded ==
    /\ req_tx_gen <= MaxKeyGen
    /\ rsp_tx_gen <= MaxKeyGen
    /\ req_rx_gen <= MaxKeyGen
    /\ rsp_rx_gen <= MaxKeyGen

ValidSessionStates ==
    /\ req_session_state \in {ESTABLISHED, NOT_STARTED}
    /\ rsp_session_state \in {ESTABLISHED, NOT_STARTED}

ValidKeyStates ==
    /\ req_ku_state \in {REQ_KU_IDLE, REQ_KU_UPDATE_SENT, REQ_KU_VERIFY_SENT}
    /\ rsp_last_key_op \in {KU_NONE, KU_UPDATE_KEY, KU_UPDATE_ALL}

====
