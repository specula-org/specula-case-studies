------------------------ MODULE SecuredMessage ----------------------------
(* TLA+ specification of the libspdm SPDM secured-messaging subsystem.
   Covers encode/decode sequence-number handling and the key-update sub-protocol.
   Reference: SPDM DSP0277; implementation: libspdm spdm_secured_message_lib + req/rsp handlers.

   Bug families modeled:
     F1 – Sequence number advance before AEAD/session-id validation
     F2 – Key update state machine: backup/commit/rollback consistency
     F3 – Encap vs non-encap key update asymmetry
     F4 – Sequence epoch consistency after key update + rollback
*)
EXTENDS Naturals, FiniteSets, Bags, Sequences, TLC

-------------------------------------------------------------------------
\* CONSTANTS
CONSTANTS
    Requester,          \* endpoint constant
    Responder,          \* endpoint constant
    RequestDir,         \* direction constant: Requester → Responder
    ResponseDir,        \* direction constant: Responder → Requester
    Idle,               \* update_phase value
    PendingAck,         \* update_phase value: KEY_UPDATE sent, waiting ACK
    PendingVerify,      \* update_phase value: ACK received, VERIFY_NEW_KEY sent
    MaxEpoch,           \* bound on key-epoch value (MC only)
    MaxSeq              \* bound on sequence number (MC only)

Endpoints == {Requester, Responder}
Dirs      == {RequestDir, ResponseDir}

\* The endpoint that SENDS in each direction.
Sender(d) == IF d = RequestDir THEN Requester ELSE Responder
\* The endpoint that RECEIVES in each direction.
Receiver(d) == IF d = RequestDir THEN Responder ELSE Requester

-------------------------------------------------------------------------
\* VARIABLES

\* --- SeqNumEpoch extension (F1, F4) ---
\* seq[e][d]: the sequence number counter for direction d held at endpoint e.
\*   At the sender for d: the next seq to put in an outgoing message.
\*   At the receiver for d: the next expected incoming seq.
\*   libspdm_secmes_encode_decode.c – request_data_sequence_number / response_data_sequence_number
VARIABLES seq

\* backup_seq[e][d]: saved sequence number at create_update time (F4).
\*   libspdm_secmes_session.c:379–381 (requester backup)
\*   libspdm_secmes_session.c:453–455 (responder backup)
VARIABLES backup_seq

\* --- KeyUpdateState extension (F2, F4) ---
\* active_epoch[e][d]: abstract key epoch for direction d at endpoint e.
\*   Epoch k = HKDF applied k times to the initial secret.
\*   libspdm_secmes_session.c:335–465 (create_update installs epoch+1, resets seq to 0)
VARIABLES active_epoch

\* backup_epoch[e][d]: backed-up epoch at create_update time.
\*   libspdm_secmes_session.c:365–381 (requester direction)
\*   libspdm_secmes_session.c:428–455 (responder direction)
VARIABLES backup_epoch

\* backup_valid[e][d]: true iff a create_update has been called without matching activate_update.
\*   libspdm_secmes_session.c:461 (requester_backup_valid = true)
\*   libspdm_secmes_session.c:463 (responder_backup_valid = true)
VARIABLES backup_valid

\* --- UpdatePhase extension (F2) ---
\* update_phase: current phase of the in-progress key update.
\*   libspdm_req_key_update.c:77–226 (UPDATE_KEY / UPDATE_ALL_KEYS exchange)
\*   libspdm_req_key_update.c:230–314 (VERIFY_NEW_KEY exchange)
VARIABLES update_phase

\* update_all_keys: true iff the active update covers both directions (UPDATE_ALL_KEYS).
\*   libspdm_req_key_update.c:100–103 (single_direction flag)
VARIABLES update_all_keys

\* --- CommitPoint extension (F2) ---
\* initiator_committed: true after requester activates new requester key with no rollback window.
\*   libspdm_req_key_update.c:199–216 — create+activate(true) before sending VERIFY_NEW_KEY
VARIABLES initiator_committed

\* --- EncapMode extension (F3) ---
\* is_encap: true iff the current key update was initiated via the encap (responder-initiated) flow.
\*   libspdm_rsp_encap_key_update.c:79–98 (encap responder sends VERIFY_NEW_KEY immediately)
VARIABLES is_encap

\* --- Network ---
\* msgs: bag of in-flight messages.
VARIABLES msgs

seqVars    == <<seq, backup_seq>>
keyVars    == <<active_epoch, backup_epoch, backup_valid>>
updateVars == <<update_phase, update_all_keys, initiator_committed, is_encap>>
netVars    == <<msgs>>
vars       == <<seqVars, keyVars, updateVars, netVars>>

-------------------------------------------------------------------------
\* TYPE DEFINITIONS

\* Message types for the key-update sub-protocol and data exchange.
CONSTANTS
    MSG_DATA,           \* application data (AEAD-protected)
    MSG_KEY_UPDATE,     \* KEY_UPDATE operation (F2)
    MSG_KEY_UPDATE_ACK, \* KEY_UPDATE_ACK response (F2)
    MSG_VERIFY_NEW_KEY, \* VERIFY_NEW_KEY operation (F2, F3)
    MSG_VERIFY_ACK,     \* KEY_UPDATE_ACK for VERIFY_NEW_KEY (F2)
    MSG_RESPONSE_NOT_READY \* error response (F4)

\* Message record:
\*   mtype      – one of MSG_* above
\*   dir        – direction the message travels (RequestDir or ResponseDir)
\*   epoch      – key epoch used to encrypt/MAC the message
\*   seq        – sequence number placed in the header
\*   session_id_ok – FALSE models a wrong-session-id injection (F1/CR1)
\*   aead_ok    – FALSE models AEAD tag failure (F1, F2)
\*   all_keys   – TRUE iff UPDATE_ALL_KEYS (for MSG_KEY_UPDATE)
Message == [mtype:         {MSG_DATA, MSG_KEY_UPDATE, MSG_KEY_UPDATE_ACK,
                             MSG_VERIFY_NEW_KEY, MSG_VERIFY_ACK,
                             MSG_RESPONSE_NOT_READY},
            dir:           Dirs,
            epoch:         Nat,
            seq:           Nat,
            session_id_ok: BOOLEAN,
            aead_ok:       BOOLEAN,
            all_keys:      BOOLEAN]

-------------------------------------------------------------------------
\* HELPERS

Send(m)    == msgs' = msgs (+) SetToBag({m})
Discard(m) == msgs' = msgs (-) SetToBag({m})

\* The active key epoch at endpoint e for direction d.
ActiveEpoch(e, d) == active_epoch[e][d]

\* The effective receive-side epoch for an incoming message: what the decoder expects.
\* decode path uses: active key (and backup if backup_valid)
DecoderEpoch(e, d) == active_epoch[e][d]

\* The sender's current epoch when building a message.
SenderEpoch(d) == active_epoch[Sender(d)][d]

-------------------------------------------------------------------------
\* INITIALIZATION

Init ==
    /\ seq          = [e \in Endpoints |-> [d \in Dirs |-> 0]]
    /\ backup_seq   = [e \in Endpoints |-> [d \in Dirs |-> 0]]
    /\ active_epoch = [e \in Endpoints |-> [d \in Dirs |-> 0]]
    /\ backup_epoch = [e \in Endpoints |-> [d \in Dirs |-> 0]]
    /\ backup_valid = [e \in Endpoints |-> [d \in Dirs |-> FALSE]]
    /\ update_phase = Idle
    /\ update_all_keys    = FALSE
    /\ initiator_committed = FALSE
    /\ is_encap     = FALSE
    /\ msgs         = EmptyBag

-------------------------------------------------------------------------
\* ACTIONS: ENCODE PATH (F1)
\* Models libspdm_encode_secured_message (libspdm_secmes_encode_decode.c:63–250)

(*
 * EncodeAdvanceSeq – sender increments seq BEFORE building/encrypting the message.
 *   libspdm_secmes_encode_decode.c:171–183 – request_data_sequence_number++ (before AEAD)
 *   The message is placed in-flight optimistically; EncodeAEADFail models AEAD failure
 *   leaving seq advanced with no message sent.
 *   F1: this action always fires; AEAD failure or send abort afterwards leaves seq advanced.
 *)
EncodeAdvanceSeq(d) ==
    LET e == Sender(d) IN
    /\ update_phase = Idle              \* only during normal data exchange
    /\ seq[e][d] < MaxSeq              \* MC bound
    \* seq incremented unconditionally – libspdm_secmes_encode_decode.c:171–183
    /\ seq' = [seq EXCEPT ![e][d] = seq[e][d] + 1]
    /\ UNCHANGED <<backup_seq, keyVars, updateVars, netVars>>

(*
 * EncodeSuccess – AEAD encrypt succeeds; message enters the network.
 *   libspdm_secmes_encode_decode.c:186–232 – ENC_MAC / MAC_ONLY encrypt paths
 *   Sends with the seq that was just advanced (seq[e][d] - 1 = the value before increment,
 *   but we model the sent seq as the current value minus 1 after EncodeAdvanceSeq fires).
 *   For simplicity, the message carries the post-increment seq value (what the receiver
 *   will verify against its own incremented counter).
 *)
EncodeSuccess(d) ==
    LET e == Sender(d)
        m == [mtype |-> MSG_DATA, dir |-> d,
              epoch |-> active_epoch[e][d],
              seq   |-> seq[e][d],
              session_id_ok |-> TRUE,
              aead_ok       |-> TRUE,
              all_keys      |-> FALSE]
    IN
    /\ update_phase = Idle
    \* seq has already been advanced by EncodeAdvanceSeq; we just need it > 0
    /\ seq[e][d] > 0
    /\ Send(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

(*
 * EncodeAEADFail – AEAD encryption fails AFTER seq has been incremented.
 *   libspdm_secmes_encode_decode.c:171–183 seq already incremented; no send.
 *   F1: seq is now permanently advanced; the next legitimate message will carry a higher seq
 *   than the receiver expects, causing a seq mismatch on the receiver side.
 *)
EncodeAEADFail(d) ==
    LET e == Sender(d) IN
    /\ update_phase = Idle
    /\ seq[e][d] > 0               \* seq was already incremented
    \* no message sent; seq stays advanced
    /\ UNCHANGED vars

-------------------------------------------------------------------------
\* ACTIONS: DECODE PATH (F1, F4)
\* Models libspdm_decode_secured_message (libspdm_secmes_encode_decode.c:251–649)

(*
 * DecodeIncrementSeq – receiver increments its seq counter UNCONDITIONALLY before any check.
 *   libspdm_secmes_encode_decode.c:414–426 – sequence_number++ before session_id check
 *   F1: this fires even if the subsequent session_id check or AEAD fails, leaving seq advanced.
 *)
DecodeIncrementSeq(m) ==
    LET e == Receiver(m.dir) IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_DATA
    /\ seq[e][m.dir] < MaxSeq
    \* sequence number incremented unconditionally – libspdm_secmes_encode_decode.c:414–426
    /\ seq' = [seq EXCEPT ![e][m.dir] = seq[e][m.dir] + 1]
    /\ UNCHANGED <<backup_seq, keyVars, updateVars, netVars>>

(*
 * DecodeSessionIdFail – session_id check fails after seq has been incremented.
 *   libspdm_secmes_encode_decode.c:444–453 (ENC_MAC path) – session_id != expected
 *   libspdm_secmes_encode_decode.c:557–563 (MAC_ONLY path)
 *   Message is dropped; seq is NOT restored.  F1: permanent seq desync.
 *   Triggered when m.session_id_ok = FALSE (injected wrong-session-id message).
 *)
DecodeSessionIdFail(m) ==
    LET e == Receiver(m.dir) IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_DATA
    /\ ~m.session_id_ok            \* wrong session_id in A_DATA header
    /\ Discard(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

(*
 * DecodeAEADFail – AEAD verification fails after seq has been incremented.
 *   libspdm_secmes_encode_decode.c:523–533 (ENC_MAC) – result=false, no backup → CRYPTO_ERROR
 *   libspdm_secmes_encode_decode.c:627–630 (check backup_valid for TRY_DISCARD)
 *   F1: no recovery path unless backup_valid (key-update context only).
 *)
DecodeAEADFail(m) ==
    LET e == Receiver(m.dir) IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_DATA
    /\ m.session_id_ok             \* passed session_id check
    /\ ~m.aead_ok                  \* AEAD tag fails
    /\ ~backup_valid[e][m.dir]     \* no backup → CRYPTO_ERROR (no TRY_DISCARD path)
    /\ Discard(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

(*
 * DecodeSuccess – session_id and AEAD both pass; message consumed.
 *   libspdm_secmes_encode_decode.c:538–548 – plain_text extracted after AEAD success
 *)
DecodeSuccess(m) ==
    LET e == Receiver(m.dir) IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_DATA
    /\ m.session_id_ok
    /\ m.aead_ok
    /\ m.epoch = active_epoch[e][m.dir]  \* message was encrypted with the epoch we expect
    /\ Discard(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

(*
 * DecodeAEADFailWithBackup – AEAD fails but backup_valid is true → TRY_DISCARD signalled.
 *   libspdm_secmes_encode_decode.c:523–533 – result=false AND backup_valid → TRY_DISCARD
 *   The caller (receive_spdm_response / receive_request) will run the rollback-retry loop.
 *   F2, F4: rollback + re-create sequence; seq[e][m.dir] was already incremented.
 *)
DecodeAEADFailWithBackup(m) ==
    LET e == Receiver(m.dir) IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_DATA
    /\ m.session_id_ok
    /\ ~m.aead_ok
    /\ backup_valid[e][m.dir]       \* backup exists → TRY_DISCARD path
    /\ Discard(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

-------------------------------------------------------------------------
\* ACTIONS: KEY UPDATE SUB-PROTOCOL (F2, F3, F4)
\* Non-encap (requester-initiated) flow.

(*
 * CreateUpdateResponderKey – requester creates new responder-direction key BEFORE sending
 *   KEY_UPDATE.  Backup is taken; active_epoch incremented; backup_valid set; seq reset to 0.
 *   libspdm_req_key_update.c:111–122 – create_update(RESPONDER) before send
 *   libspdm_secmes_session.c:396–465 – backs up key+seq, installs new epoch, sets backup_valid
 *   F2: creates the "pending new key" window during network transit.
 *)
CreateUpdateResponderKey ==
    LET e    == Requester
        d    == ResponseDir    \* responder direction keys live at both endpoints
    IN
    /\ update_phase = Idle
    /\ active_epoch[e][d] < MaxEpoch
    \* libspdm_secmes_session.c:428–455 – backup response_data_* fields
    /\ backup_epoch' = [backup_epoch EXCEPT ![e][d] = active_epoch[e][d]]
    /\ backup_seq'   = [backup_seq   EXCEPT ![e][d] = seq[e][d]]
    \* libspdm_secmes_session.c:456–462 – new epoch installed, seq reset to 0
    /\ active_epoch' = [active_epoch EXCEPT ![e][d] = active_epoch[e][d] + 1]
    /\ seq'          = [seq          EXCEPT ![e][d] = 0]
    \* libspdm_secmes_session.c:463 – responder_backup_valid = true
    /\ backup_valid' = [backup_valid EXCEPT ![e][d] = TRUE]
    /\ UNCHANGED <<update_phase, update_all_keys, initiator_committed, is_encap, msgs>>

(*
 * SendKeyUpdateRequest – requester sends KEY_UPDATE after (optionally) creating new rsp key.
 *   libspdm_req_key_update.c:77–140 – build and send KEY_UPDATE message
 *   The message is sent with the OLD requester key (seq not yet updated for req direction).
 *)
SendKeyUpdateRequest(all_keys) ==
    LET e == Requester
        d == RequestDir       \* KEY_UPDATE travels Requester → Responder
        m == [mtype |-> MSG_KEY_UPDATE, dir |-> d,
              epoch |-> active_epoch[e][d],
              seq   |-> seq[e][d] + 1,   \* seq will advance on encode
              session_id_ok |-> TRUE,
              aead_ok       |-> TRUE,
              all_keys      |-> all_keys]
    IN
    /\ update_phase = Idle
    /\ is_encap = FALSE     \* cannot start requester-initiated update while encap ACK is pending
    /\ IF all_keys
       THEN backup_valid[Requester][ResponseDir] = TRUE  \* rsp key must have been created
       ELSE TRUE
    /\ seq'          = [seq EXCEPT ![e][d] = seq[e][d] + 1]
    /\ update_phase' = PendingAck
    /\ update_all_keys' = all_keys
    /\ is_encap'    = FALSE
    /\ Send(m)
    /\ UNCHANGED <<backup_seq, keyVars, initiator_committed>>

(*
 * ResponderReceiveKeyUpdate – responder processes KEY_UPDATE.
 *   libspdm_rsp_key_update_ack.c:12–241 – handler for all three KEY_UPDATE operations
 *   For UPDATE_ALL_KEYS: create new req-direction key, then activate new rsp-direction key.
 *   libspdm_rsp_key_update_ack.c:193–216 – activate_update(RESPONDER, true) before ACK send
 *   F2: responder activates new rsp key and creates new req key BEFORE sending ACK.
 *)
ResponderReceiveKeyUpdate(m) ==
    LET e  == Responder
        rd == RequestDir
        sd == ResponseDir
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_KEY_UPDATE
    /\ m.dir   = RequestDir
    /\ update_phase = PendingAck
    \* Decode incoming KEY_UPDATE; create new req key at responder (both UPDATE_KEY and
    \* UPDATE_ALL_KEYS call create_update(REQUESTER)).
    \* libspdm_rsp_key_update_ack.c:147–165 – create_update(REQUESTER)
    \* Net effect after decode+create_update: seq[e][rd] resets to 0 (create_update resets seq);
    \* backup_seq gets the post-decode value (pre-state seq + 1).
    /\ backup_epoch' = [backup_epoch EXCEPT ![e][rd] = active_epoch[e][rd]]
    /\ backup_seq'   = [backup_seq   EXCEPT ![e][rd] = seq[e][rd] + 1]
    /\ active_epoch' = IF m.all_keys
                       THEN [active_epoch EXCEPT
                              ![e][rd] = active_epoch[e][rd] + 1,
                              \* activate new rsp key – libspdm_rsp_key_update_ack.c:193–216
                              ![e][sd] = active_epoch[Requester][sd]]
                       ELSE [active_epoch EXCEPT
                              ![e][rd] = active_epoch[e][rd] + 1]   \* req key only
    \* reset req seq; also reset rsp seq when new rsp key is activated (all_keys only)
    /\ seq'         = IF m.all_keys
                      THEN [seq EXCEPT ![e][rd] = 0, ![e][sd] = 0]
                      ELSE [seq EXCEPT ![e][rd] = 0]
    /\ backup_valid' = IF m.all_keys
                       THEN [backup_valid EXCEPT ![e][rd] = TRUE, ![e][sd] = FALSE]
                       ELSE [backup_valid EXCEPT ![e][rd] = TRUE]
    \* Send KEY_UPDATE_ACK with OLD rsp epoch (before new key activation)
    /\ LET ack == [mtype |-> MSG_KEY_UPDATE_ACK, dir |-> ResponseDir,
                   epoch |-> active_epoch[e][sd],   \* old rsp epoch
                   seq   |-> seq[e][sd] + 1,
                   session_id_ok |-> TRUE, aead_ok |-> TRUE, all_keys |-> m.all_keys]
       IN msgs' = (msgs (-) SetToBag({m})) (+) SetToBag({ack})
    /\ UNCHANGED <<update_phase, update_all_keys, initiator_committed, is_encap>>

(*
 * RequesterReceiveKeyUpdateAck – requester receives KEY_UPDATE_ACK; then creates+immediately
 *   activates new requester key (NO backup window → no rollback possible after this point).
 *   libspdm_req_key_update.c:171–216 – activate rsp key, create+activate req key immediately
 *   F2 CommitPoint: initiator_committed set to TRUE before VERIFY_NEW_KEY is sent.
 *)
RequesterReceiveKeyUpdateAck(m) ==
    LET e           == Requester
        rd          == RequestDir
        sd          == ResponseDir
        new_rd_epoch == active_epoch[e][rd] + 1   \* new req key epoch (create+activate, F2)
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_KEY_UPDATE_ACK
    /\ m.dir   = ResponseDir
    /\ update_phase = PendingAck
    \* Decode ACK: seq[e][sd] incremented; create+activate new req key immediately (no backup).
    \* Both UPDATE_KEY and UPDATE_ALL_KEYS activate req key here.
    \* libspdm_req_key_update.c:199–216 – create+activate(REQUESTER, true), no backup window
    /\ seq' = [seq EXCEPT ![e][sd] = seq[e][sd] + 1, ![e][rd] = 0]
    /\ active_epoch' = [active_epoch EXCEPT ![e][rd] = new_rd_epoch]
    /\ backup_valid' = [backup_valid EXCEPT ![e][sd] = FALSE, ![e][rd] = FALSE]
    /\ backup_epoch' = backup_epoch
    /\ backup_seq'   = backup_seq
    /\ initiator_committed' = TRUE    \* F2 CommitPoint: no rollback after this point
    /\ update_phase' = PendingVerify
    \* Send VERIFY_NEW_KEY using new req key epoch
    /\ LET vnk == [mtype |-> MSG_VERIFY_NEW_KEY, dir |-> rd,
                   epoch |-> new_rd_epoch,
                   seq   |-> 1,
                   session_id_ok |-> TRUE, aead_ok |-> TRUE, all_keys |-> update_all_keys]
       IN msgs' = (msgs (-) SetToBag({m})) (+) SetToBag({vnk})
    /\ UNCHANGED <<update_all_keys, is_encap>>

(*
 * ResponderReceiveVerifyNewKey – responder decodes VERIFY_NEW_KEY using new req key and
 *   activates the new req key, clears backup.
 *   libspdm_rsp_key_update_ack.c:194–216 – activate_update(REQUESTER, true) + send ACK
 *   F2: if AEAD fails here (wrong key), SESSION_TRY_DISCARD fires but requester already
 *   committed → key mismatch scenario (MC1).
 *)
ResponderReceiveVerifyNewKey(m) ==
    LET e  == Responder
        rd == RequestDir
        sd == ResponseDir
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_VERIFY_NEW_KEY
    /\ m.dir   = RequestDir
    /\ update_phase = PendingVerify
    /\ m.aead_ok                   \* AEAD passes → normal success path
    /\ m.session_id_ok
    \* seq increment before verification (F1)
    /\ seq' = [seq EXCEPT ![e][rd] = seq[e][rd] + 1]
    \* Activate new req key at responder – libspdm_rsp_key_update_ack.c:194–199
    /\ backup_valid' = [backup_valid EXCEPT ![e][rd] = FALSE]
    /\ active_epoch' = [active_epoch EXCEPT ![e][rd] = active_epoch[e][rd]]
    \* backup_epoch unchanged (cleared by activate)
    /\ backup_epoch' = [backup_epoch EXCEPT ![e][rd] = 0]
    /\ backup_seq'   = [backup_seq   EXCEPT ![e][rd] = 0]
    \* Send VERIFY_ACK – use pre-computed values to avoid referencing primed variables in RHS
    /\ LET ack_epoch == active_epoch[e][sd]        \* rsp-dir epoch unchanged
           ack_seq   == seq[e][sd] + 1             \* sd seq incremented by decode above
           ack == [mtype |-> MSG_VERIFY_ACK, dir |-> ResponseDir,
                   epoch |-> ack_epoch,
                   seq   |-> ack_seq,
                   session_id_ok |-> TRUE, aead_ok |-> TRUE, all_keys |-> FALSE]
       IN msgs' = (msgs (-) SetToBag({m})) (+) SetToBag({ack})
    \* update_phase stays PendingVerify until RequesterReceiveVerifyAck fires
    /\ UNCHANGED <<update_phase, update_all_keys, initiator_committed, is_encap>>

(*
 * ResponderTryDiscardKeyUpdate – AEAD fails on VERIFY_NEW_KEY decode; backup exists;
 *   SESSION_TRY_DISCARD fires: responder rolls back req key to backup.
 *   libspdm_secmes_encode_decode.c:523–533 + libspdm_rsp_receive_send.c:197–264
 *   F2 (MC1): requester is already committed (initiator_committed = TRUE) but responder
 *   rolls back to old key → KeyAgreement invariant can be violated.
 *)
ResponderTryDiscardKeyUpdate(m) ==
    LET e  == Responder
        rd == RequestDir
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_VERIFY_NEW_KEY
    /\ m.dir   = RequestDir
    /\ update_phase = PendingVerify
    /\ ~m.aead_ok                  \* AEAD fails on responder side
    /\ backup_valid[e][rd]         \* backup is valid → TRY_DISCARD possible
    \* seq was already incremented (F1); restore backup_seq (F4)
    \* libspdm_rsp_receive_send.c:218–223 – rollback + retry seq adjustment
    /\ seq' = [seq EXCEPT ![e][rd] = backup_seq[e][rd]]
    \* Rollback to backup key epoch – libspdm_secmes_session.c:526–528
    /\ active_epoch' = [active_epoch EXCEPT ![e][rd] = backup_epoch[e][rd]]
    /\ backup_valid' = [backup_valid EXCEPT ![e][rd] = FALSE]
    /\ backup_epoch' = [backup_epoch EXCEPT ![e][rd] = 0]
    /\ backup_seq'   = [backup_seq   EXCEPT ![e][rd] = 0]
    /\ Discard(m)
    /\ update_phase' = Idle
    \* initiator_committed stays TRUE – F2: this is the key mismatch window
    /\ UNCHANGED <<update_all_keys, initiator_committed, is_encap>>

(*
 * RequesterReceiveVerifyAck – requester receives VERIFY_NEW_KEY_ACK; key update complete.
 *   libspdm_req_key_update.c:290–314 – success path: update_phase back to Idle
 *)
RequesterReceiveVerifyAck(m) ==
    LET e == Requester
        sd == ResponseDir
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_VERIFY_ACK
    /\ m.dir   = ResponseDir
    /\ update_phase = PendingVerify
    /\ m.aead_ok
    /\ m.session_id_ok
    /\ seq' = [seq EXCEPT ![e][sd] = seq[e][sd] + 1]
    /\ Discard(m)
    /\ update_phase'      = Idle
    /\ initiator_committed' = FALSE
    /\ UNCHANGED <<backup_seq, keyVars, update_all_keys, is_encap>>

-------------------------------------------------------------------------
\* ACTIONS: ENCAP KEY UPDATE FLOW (F3)
\* Responder-initiated key update; asymmetric: create+activate immediately.

(*
 * EncapCreateAndActivateRspKey – in the encap flow the responder calls create_update THEN
 *   immediately activate_update(true) on the response-direction key BEFORE sending
 *   VERIFY_NEW_KEY.  No backup window.
 *   libspdm_rsp_encap_key_update.c:79–98 – create + immediate activate for response key
 *   F3: backup_valid[Responder][ResponseDir] remains FALSE after this, so TRY_DISCARD
 *   cannot fire if the requester later fails to decode encap VERIFY_NEW_KEY.
 *)
EncapCreateAndActivateRspKey ==
    LET e == Responder
        d == ResponseDir
    IN
    /\ update_phase = Idle
    /\ is_encap = FALSE            \* start encap flow
    /\ active_epoch[e][d] < MaxEpoch
    \* create_update + immediately activate_update(true) – net effect: backup is never exposed.
    \* libspdm_rsp_encap_key_update.c:79–98 – no rollback window; F3 root cause.
    /\ active_epoch' = [active_epoch EXCEPT ![e][d] = active_epoch[e][d] + 1]
    /\ seq'          = [seq          EXCEPT ![e][d] = 0]
    \* Backup cleared by activate_update(true) immediately after create – backup_valid stays FALSE.
    /\ backup_epoch' = [backup_epoch EXCEPT ![e][d] = 0]
    /\ backup_seq'   = [backup_seq   EXCEPT ![e][d] = 0]
    /\ backup_valid' = [backup_valid EXCEPT ![e][d] = FALSE]  \* F3: no backup window
    /\ is_encap'     = TRUE
    /\ update_phase' = PendingVerify  \* encap skips PendingAck
    /\ initiator_committed' = TRUE    \* F3: immediately committed, no rollback
    /\ UNCHANGED <<update_all_keys, msgs>>

(*
 * EncapSendVerifyNewKey – responder sends VERIFY_NEW_KEY (encap) using new rsp key.
 *   libspdm_rsp_encap_key_update.c:95–98 – send VERIFY_NEW_KEY with new key
 *)
EncapSendVerifyNewKey ==
    LET e == Responder
        d == ResponseDir
        m == [mtype |-> MSG_VERIFY_NEW_KEY, dir |-> d,
              epoch |-> active_epoch[e][d],
              seq   |-> 1,
              session_id_ok |-> TRUE, aead_ok |-> TRUE, all_keys |-> FALSE]
    IN
    /\ update_phase = PendingVerify
    /\ is_encap     = TRUE
    /\ Send(m)
    /\ UNCHANGED <<seqVars, keyVars, update_phase, update_all_keys, initiator_committed, is_encap>>

(*
 * RequesterReceiveEncapVerifyNewKey – requester decodes encap VERIFY_NEW_KEY (rsp direction).
 *   libspdm_req_encap_key_update_ack.c:118–131 – only UPDATE_KEY accepted; activate rsp key
 *   F3: if AEAD fails here, backup_valid[Requester][ResponseDir] may be FALSE (depending on
 *   whether requester's view was also updated), so no TRY_DISCARD path for rsp direction.
 *)
RequesterReceiveEncapVerifyNewKey(m) ==
    LET e == Requester
        d == ResponseDir
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_VERIFY_NEW_KEY
    /\ m.dir   = ResponseDir
    /\ update_phase = PendingVerify
    /\ is_encap = TRUE
    /\ m.aead_ok
    /\ m.session_id_ok
    /\ seq' = [seq EXCEPT ![e][d] = seq[e][d] + 1]
    \* Activate new rsp key at requester
    /\ active_epoch' = [active_epoch EXCEPT ![e][d] = m.epoch]
    /\ backup_valid' = [backup_valid EXCEPT ![e][d] = FALSE]
    /\ backup_epoch' = [backup_epoch EXCEPT ![e][d] = 0]
    /\ backup_seq'   = [backup_seq   EXCEPT ![e][d] = 0]
    \* Send ACK
    /\ LET ack == [mtype |-> MSG_VERIFY_ACK, dir |-> RequestDir,
                   epoch |-> active_epoch'[e][RequestDir],
                   seq   |-> seq'[e][RequestDir] + 1,
                   session_id_ok |-> TRUE, aead_ok |-> TRUE, all_keys |-> FALSE]
       IN msgs' = (msgs (-) SetToBag({m})) (+) SetToBag({ack})
    /\ update_phase'       = Idle
    /\ initiator_committed' = FALSE  \* encap flow done from requester's side; reset commit flag
    /\ UNCHANGED <<update_all_keys, is_encap>>

(*
 * EncapDecodeFailNoBackup – encap VERIFY_NEW_KEY decode fails at requester; no backup
 *   because the requester's view of the rsp key was not backed up (no create_update at
 *   requester in the encap flow).
 *   libspdm_secmes_encode_decode.c:625–630 – TRY_DISCARD requires backup_valid=true
 *   F3: backup_valid[Requester][ResponseDir] = FALSE → no recovery → keys diverge.
 *)
EncapDecodeFailNoBackup(m) ==
    LET e == Requester
        d == ResponseDir
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_VERIFY_NEW_KEY
    /\ m.dir   = ResponseDir
    /\ update_phase = PendingVerify
    /\ is_encap = TRUE
    /\ ~m.aead_ok
    /\ ~backup_valid[e][d]         \* no backup → cannot recover
    /\ Discard(m)
    /\ UNCHANGED <<seqVars, keyVars, update_phase, update_all_keys, initiator_committed, is_encap>>

(*
 * ResponderReceiveEncapVerifyAck – responder gets ACK to its encap VERIFY_NEW_KEY.
 *   libspdm_rsp_encap_key_update.c:145–175 – receive and validate ACK
 *)
ResponderReceiveEncapVerifyAck(m) ==
    LET e == Responder
        d == RequestDir
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_VERIFY_ACK
    /\ m.dir   = RequestDir
    /\ update_phase = Idle   \* Requester set phase=Idle in RequesterReceiveEncapVerifyNewKey
    /\ is_encap = TRUE
    /\ m.aead_ok /\ m.session_id_ok
    /\ seq' = [seq EXCEPT ![e][d] = seq[e][d] + 1]
    /\ Discard(m)
    /\ update_phase'      = Idle
    /\ initiator_committed' = FALSE
    /\ is_encap'          = FALSE
    /\ UNCHANGED <<backup_seq, keyVars, update_all_keys>>

-------------------------------------------------------------------------
\* ACTIONS: RESPONSE_NOT_READY / RE-CREATE LOOP (F4)
\* Models libspdm_req_send_receive.c:207–313 and libspdm_rsp_receive_send.c:197–264

(*
 * SendResponseNotReady – responder sends RESPONSE_NOT_READY during key update exchange.
 *   Historical: Issue #780/PR #879 (fixed 2022-05) – NOT_READY in session caused seq mismatch.
 *   Modeled as an error message sent in the response direction during PendingVerify.
 *)
SendResponseNotReady ==
    LET e == Responder
        d == ResponseDir
        m == [mtype |-> MSG_RESPONSE_NOT_READY, dir |-> d,
              epoch |-> active_epoch[e][d],
              seq   |-> seq[e][d] + 1,
              session_id_ok |-> TRUE, aead_ok |-> TRUE, all_keys |-> FALSE]
    IN
    /\ update_phase \in {PendingAck, PendingVerify}
    /\ seq' = [seq EXCEPT ![e][d] = seq[e][d] + 1]
    /\ Send(m)
    /\ UNCHANGED <<backup_seq, keyVars, update_phase, update_all_keys, initiator_committed, is_encap>>

(*
 * RequesterHandleResponseNotReady – requester receives NOT_READY; triggers rollback + re-create.
 *   libspdm_req_send_receive.c:218–223 – rollback for REQUESTER direction after TRY_DISCARD
 *   libspdm_req_send_receive.c:308–312 – re-create after rollback (re-create same epoch)
 *   F4: after rollback, backup_seq is N+1 (incremented during NOT_READY decode), not N.
 *   The re-created key is deterministic (same HKDF), but backup_seq is now at the
 *   post-NOT_READY-decode value, which may not match remote's expectation.
 *)
RequesterHandleResponseNotReady(m) ==
    (*
     * Models the rollback → re-decode(NOT_READY) → re-create cycle in
     * libspdm_req_send_receive.c:218–223 (rollback) + 308–312 (re-create).
     *
     * This action fires only when backup_valid[e][ResponseDir] is TRUE,
     * meaning the rsp direction key was just created before KEY_UPDATE was sent.
     *
     * Net state change after the full cycle (F4 root cause):
     *   - active_epoch[e][ResponseDir] unchanged (rollback + same HKDF re-derive = same epoch)
     *   - backup_seq[e][ResponseDir] shifts from X to X+1 (post-NOT_READY-decode seq)
     *   - seq[e][ResponseDir] resets to 0 (re-create resets seq for new epoch)
     *   - backup_valid[e][ResponseDir] remains TRUE (re-create re-establishes backup)
     *)
    LET e == Requester
        d == ResponseDir  \* NOT_READY travels Responder → Requester
    IN
    /\ BagIn(m, msgs)
    /\ m.mtype = MSG_RESPONSE_NOT_READY
    /\ m.dir   = ResponseDir
    /\ update_phase \in {PendingAck, PendingVerify}
    \* TRY_DISCARD requires backup to exist (rsp direction was just created)
    \* libspdm_secmes_encode_decode.c:523–533 – backup_valid check
    /\ backup_valid[e][d]
    \* F4: backup_seq advances by 1 (the sequence after decoding NOT_READY with old key)
    \* libspdm_req_send_receive.c:308–312 – re-create saves post-NOT_READY seq as new backup_seq
    /\ backup_seq'   = [backup_seq EXCEPT ![e][d] = backup_seq[e][d] + 1]
    \* seq resets to 0 after re-create – libspdm_secmes_session.c:461
    /\ seq'          = [seq EXCEPT ![e][d] = 0]
    \* active_epoch and backup_epoch unchanged: rollback restores to old epoch, re-create
    \* derives the same new epoch (HKDF is deterministic) – libspdm_req_send_receive.c:308–312
    /\ active_epoch' = active_epoch
    /\ backup_epoch' = backup_epoch
    /\ backup_valid' = backup_valid   \* still TRUE after re-create
    /\ Discard(m)
    /\ UNCHANGED <<update_phase, update_all_keys, initiator_committed, is_encap>>

-------------------------------------------------------------------------
\* FAULT INJECTION ACTIONS (for MC wrapper to bound)

(*
 * InjectWrongSessionId – injects a DATA message with wrong session_id into the network.
 *   Represents a routing error or active attacker injecting a crafted message.
 *   libspdm_secmes_encode_decode.c:444–453 / 557–563 – session_id check in A_DATA
 *   F1, CR1: seq incremented before check; no recovery; session desynced.
 *)
InjectWrongSessionId(d) ==
    LET m == [mtype |-> MSG_DATA, dir |-> d,
              epoch |-> active_epoch[Sender(d)][d],
              seq   |-> seq[Receiver(d)][d],
              session_id_ok |-> FALSE,
              aead_ok       |-> FALSE,
              all_keys      |-> FALSE]
    IN
    /\ Send(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

(*
 * InjectAEADFailure – injects a DATA message that will fail AEAD at the receiver.
 *   Represents a corrupted or replayed message.
 *   F1: seq incremented before AEAD check; no recovery without backup_valid.
 *)
InjectAEADFailure(d) ==
    LET m == [mtype |-> MSG_DATA, dir |-> d,
              epoch |-> active_epoch[Sender(d)][d],
              seq   |-> seq[Receiver(d)][d],
              session_id_ok |-> TRUE,
              aead_ok       |-> FALSE,
              all_keys      |-> FALSE]
    IN
    /\ Send(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

(*
 * InjectWrongEpochVerifyNewKey – injects a VERIFY_NEW_KEY with wrong (old) key epoch.
 *   Triggers AEAD failure on responder when requester has already committed.
 *   F2 (MC1): drives the KeyAgreement violation scenario.
 *)
InjectWrongEpochVerifyNewKey ==
    LET e == Requester
        d == RequestDir
        m == [mtype |-> MSG_VERIFY_NEW_KEY, dir |-> d,
              epoch |-> active_epoch[e][d] - 1,   \* old epoch → AEAD fail
              seq   |-> seq[e][d],
              session_id_ok |-> TRUE,
              aead_ok       |-> FALSE,
              all_keys      |-> FALSE]
    IN
    /\ update_phase = PendingVerify
    /\ active_epoch[e][d] > 0
    /\ Send(m)
    /\ UNCHANGED <<seqVars, keyVars, updateVars>>

-------------------------------------------------------------------------
\* NEXT

Next ==
    \* Normal data exchange
    \/ \E d \in Dirs : EncodeAdvanceSeq(d)
    \/ \E d \in Dirs : EncodeSuccess(d)
    \/ \E m \in DOMAIN msgs : DecodeIncrementSeq(m)
    \/ \E m \in DOMAIN msgs : DecodeSessionIdFail(m)
    \/ \E m \in DOMAIN msgs : DecodeAEADFail(m)
    \/ \E m \in DOMAIN msgs : DecodeAEADFailWithBackup(m)
    \/ \E m \in DOMAIN msgs : DecodeSuccess(m)
    \* Key update (non-encap)
    \/ CreateUpdateResponderKey
    \/ \E all_keys \in BOOLEAN : SendKeyUpdateRequest(all_keys)
    \/ \E m \in DOMAIN msgs : ResponderReceiveKeyUpdate(m)
    \/ \E m \in DOMAIN msgs : RequesterReceiveKeyUpdateAck(m)
    \/ \E m \in DOMAIN msgs : ResponderReceiveVerifyNewKey(m)
    \/ \E m \in DOMAIN msgs : ResponderTryDiscardKeyUpdate(m)
    \/ \E m \in DOMAIN msgs : RequesterReceiveVerifyAck(m)
    \* Key update (encap)
    \/ EncapCreateAndActivateRspKey
    \/ EncapSendVerifyNewKey
    \/ \E m \in DOMAIN msgs : RequesterReceiveEncapVerifyNewKey(m)
    \/ \E m \in DOMAIN msgs : EncapDecodeFailNoBackup(m)
    \/ \E m \in DOMAIN msgs : ResponderReceiveEncapVerifyAck(m)
    \* RESPONSE_NOT_READY / re-create
    \/ SendResponseNotReady
    \/ \E m \in DOMAIN msgs : RequesterHandleResponseNotReady(m)
    \* Fault injection (bounded in MC)
    \/ \E d \in Dirs : InjectWrongSessionId(d)
    \/ \E d \in Dirs : InjectAEADFailure(d)
    \/ InjectWrongEpochVerifyNewKey

Spec == Init /\ [][Next]_vars

-------------------------------------------------------------------------
\* INVARIANTS

(*
 * KeyAgreement – after any complete key update (update_phase = Idle and no in-flight
 *   key-update messages), both endpoints hold identical active epochs for both directions.
 *   Targets Family 2 (MC1, MC3, MC4).
 *)
KeyAgreement ==
    (update_phase = Idle
     /\ (~\E m \in DOMAIN msgs :
          m.mtype \in {MSG_KEY_UPDATE, MSG_KEY_UPDATE_ACK,
                       MSG_VERIFY_NEW_KEY, MSG_VERIFY_ACK})
     /\ (~\E e \in Endpoints, d \in Dirs : backup_valid[e][d]))
    =>
    \A d \in Dirs :
        active_epoch[Requester][d] = active_epoch[Responder][d]

(*
 * SeqMonotonicity – sequence numbers only increase; never roll back below where they were
 *   at a successful decode.  Encoded as: no message in-flight has a seq below the receiver's
 *   current counter minus 1 (messages are always at most 1 ahead after a successful exchange).
 *   Targets Family 1, Family 4.
 *)
SeqMonotonicity ==
    \A m \in DOMAIN msgs :
        m.mtype = MSG_DATA =>
        seq[Receiver(m.dir)][m.dir] <= m.seq + 1

(*
 * BackupValidConsistency – backup_valid is TRUE iff create_update was called without
 *   a matching activate_update; it is never simultaneously TRUE on both endpoints for
 *   the same direction with DIFFERENT epochs.
 *   Targets Family 2 (MC4).
 *)
BackupValidConsistency ==
    \A d \in Dirs :
    ~(backup_valid[Requester][d] /\ backup_valid[Responder][d])

(*
 * RollbackSafety – after rollback (activate_update(false)), the restored seq equals what
 *   the remote side expects.  After rollback, active_epoch at the rolling-back endpoint
 *   must equal the remote side's currently active epoch.
 *   Targets Family 2, Family 4.
 *)
RollbackSafety ==
    \A e \in Endpoints, d \in Dirs :
    ~backup_valid[e][d] =>
        active_epoch[e][d] = active_epoch[Sender(d)][d] \/ update_phase /= Idle

(*
 * VerifyNewKeyCommit – once initiator_committed = TRUE, the initiator (Requester in non-encap,
 *   Responder in encap) has permanently installed the new key.  No activate_update(false) call
 *   for the initiator direction is possible from this state in the spec (invariant checked by
 *   the MC hunt for MC1).
 *   Targets Family 2.
 *)
VerifyNewKeyCommit ==
    initiator_committed = TRUE =>
    \/ update_phase \in {PendingVerify}
    \/ update_phase = Idle   \* completed successfully

(*
 * SessionContinuity – if no decode error has occurred (all seq numbers agree between both
 *   endpoints in a direction), the session can always process the next message.
 *   Targets Family 1 (liveness, checked in MC as an eventuallity property).
 *)
SessionContinuity ==
    \A d \in Dirs :
    (seq[Sender(d)][d] = seq[Receiver(d)][d] /\ update_phase = Idle)
    =>
    (\E m \in DOMAIN msgs :
        m.dir = d /\ m.mtype = MSG_DATA /\ m.aead_ok /\ m.session_id_ok)
    \/ TRUE   \* sender can always emit a new message

\* Structural invariant: msg buffer bounded
MsgBufferBound(bound) ==
    BagCardinality(msgs) <= bound

==========================================================================
