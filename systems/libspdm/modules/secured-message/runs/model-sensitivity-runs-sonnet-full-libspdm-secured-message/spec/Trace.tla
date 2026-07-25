------------------------------ MODULE Trace --------------------------------
(*
 * Trace validation spec for SecuredMessage.
 * Category A (Distributed / Message-Passing): uses a single linear trace cursor l.
 *
 * Replays NDJSON traces emitted by the libspdm instrumentation harness against
 * the base spec to verify that every observed state transition is consistent with
 * SecuredMessage.
 *
 * Trace file format: NDJSON, one event per line, schema defined in instrumentation-spec.md.
 * Default file: ../traces/trace.ndjson (override with IOEnv.JSON).
 *)
EXTENDS SecuredMessage, Integers, Sequences, TLC, Json, IOUtils

-------------------------------------------------------------------------
\* TRACE LOADING

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* Total number of events in the trace.
TraceLen == Len(TraceLog)

-------------------------------------------------------------------------
\* CURSOR VARIABLE

\* l: 1-based index into TraceLog; advances by 1 on each consumed event.
\* faultDummy: dummy variable satisfying UNCHANGED faultVars in base spec action stubs.
VARIABLES l, faultDummy

\* Current logline.
logline == TraceLog[l]

-------------------------------------------------------------------------
\* ROLE AND DIRECTION MAPPING
\* Maps implementation string identifiers to spec constants.

RoleMap == [s \in {"requester", "responder"} |->
    IF s = "requester" THEN Requester ELSE Responder]

DirMap == [s \in {"request", "response"} |->
    IF s = "request" THEN RequestDir ELSE ResponseDir]

MtypeMap == [s \in {"MSG_DATA", "MSG_KEY_UPDATE", "MSG_KEY_UPDATE_ACK",
                     "MSG_VERIFY_NEW_KEY", "MSG_VERIFY_ACK", "MSG_RESPONSE_NOT_READY"} |->
    IF s = "MSG_DATA"                THEN MSG_DATA
    ELSE IF s = "MSG_KEY_UPDATE"     THEN MSG_KEY_UPDATE
    ELSE IF s = "MSG_KEY_UPDATE_ACK" THEN MSG_KEY_UPDATE_ACK
    ELSE IF s = "MSG_VERIFY_NEW_KEY" THEN MSG_VERIFY_NEW_KEY
    ELSE IF s = "MSG_VERIFY_ACK"     THEN MSG_VERIFY_ACK
    ELSE MSG_RESPONSE_NOT_READY]

UpdatePhaseMap == [s \in {"Idle", "PendingAck", "PendingVerify"} |->
    IF s = "Idle" THEN Idle
    ELSE IF s = "PendingAck" THEN PendingAck
    ELSE PendingVerify]

\* Map a logline "role" field to a spec endpoint constant.
TraceEndpoint(ll) == RoleMap[ll.node]

\* Map a logline "dir" field to a spec direction constant.
TraceDir(ll) == DirMap[ll.dir]

-------------------------------------------------------------------------
\* EVENT PREDICATES

IsEvent(name)          == logline.event = name
IsNodeEvent(name, e)   == logline.event = name /\ TraceEndpoint(logline) = e
IsDirEvent(name, d)    == logline.event = name /\ TraceDir(logline) = d
IsNodeDirEvent(name, e, d) ==
    logline.event = name /\ TraceEndpoint(logline) = e /\ TraceDir(logline) = d

-------------------------------------------------------------------------
\* POST-STATE VALIDATION
\*
\* Each wrapper calls ValidatePostState after the base spec action fires.
\* Fields validated are those that the action modifies AND that the harness captures.
\* See instrumentation-spec.md for the exact field list per event.

\* Validate seq counters for endpoint e and direction d (post-state check).
ValidateSeq(e, d) ==
    /\ seq'[e][d] = logline.state.seq
    /\ (logline.state.backup_valid => backup_seq'[e][d] = logline.state.backup_seq)

\* Validate key epoch state for endpoint e and direction d (post-state check).
ValidateEpoch(e, d) ==
    /\ active_epoch'[e][d] = logline.state.active_epoch
    /\ backup_valid'[e][d] = logline.state.backup_valid
    /\ (logline.state.backup_valid => backup_epoch'[e][d] = logline.state.backup_epoch)

\* Validate update-phase state (post-state check).
\* initiator_committed is only present for requester-side events.
ValidateUpdatePhase ==
    /\ update_phase' = UpdatePhaseMap[logline.state.update_phase]
    /\ ("initiator_committed" \in DOMAIN logline.state =>
            initiator_committed' = logline.state.initiator_committed)

-------------------------------------------------------------------------
\* BOOTSTRAP / TRACE INIT

TraceInit ==
    /\ Init
    /\ l = 1
    /\ faultDummy = 0

-------------------------------------------------------------------------
\* ACTION WRAPPERS

(*
 * TraceEncodeAdvanceSeq – matches event "encode_advance_seq".
 * Fires when the encoder increments the sequence number for direction d.
 * libspdm_secmes_encode_decode.c:171–183
 *)
TraceEncodeAdvanceSeq ==
    /\ l <= TraceLen
    /\ IsEvent("encode_advance_seq")
    /\ LET e == TraceEndpoint(logline)
           d == TraceDir(logline)
       IN
       /\ EncodeAdvanceSeq(d)
       /\ ValidateSeq(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceEncodeSuccess – matches event "encode_success".
 * Fires after AEAD encrypt succeeds; message enters network.
 * libspdm_secmes_encode_decode.c:186–232
 *)
TraceEncodeSuccess ==
    /\ l <= TraceLen
    /\ IsEvent("encode_success")
    /\ LET d == TraceDir(logline)
           e == Sender(d)
           m == [mtype |-> MSG_DATA, dir |-> d,
                 epoch |-> logline.msg.epoch,
                 seq   |-> logline.msg.seq,
                 session_id_ok |-> TRUE,
                 aead_ok       |-> TRUE,
                 all_keys      |-> FALSE]
       IN
       /\ EncodeSuccess(d)
       /\ ValidateSeq(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceDecodeIncrementSeq – matches event "decode_increment_seq".
 * Fires when the decoder increments seq before any check.
 * libspdm_secmes_encode_decode.c:414–426
 * The trace may record msg.epoch from the decoder's perspective (active key epoch),
 * not the sender's.  Find the message in msgs by (mtype, dir, seq) to handle the mismatch.
 *)
TraceDecodeIncrementSeq ==
    /\ l <= TraceLen
    /\ IsEvent("decode_increment_seq")
    /\ LET e == TraceEndpoint(logline)
           d == TraceDir(logline)
           m == CHOOSE m \in DOMAIN msgs :
                    m.mtype = MSG_DATA /\ m.dir = d /\ m.seq = logline.msg.seq
       IN
       /\ DecodeIncrementSeq(m)
       /\ ValidateSeq(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceDecodeSuccess – matches event "decode_success".
 * Fires when session_id + AEAD both pass.
 * libspdm_secmes_encode_decode.c:538–548
 *)
TraceDecodeSuccess ==
    /\ l <= TraceLen
    /\ IsEvent("decode_success")
    /\ LET e == TraceEndpoint(logline)
           d == TraceDir(logline)
           m == [mtype |-> MSG_DATA, dir |-> d,
                 epoch |-> logline.msg.epoch,
                 seq   |-> logline.msg.seq,
                 session_id_ok |-> TRUE,
                 aead_ok       |-> TRUE,
                 all_keys      |-> FALSE]
       IN
       /\ DecodeSuccess(m)
       /\ ValidateSeq(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceDecodeSessionIdFail – matches event "decode_session_id_fail".
 * libspdm_secmes_encode_decode.c:444–453
 * Abstraction gap: the message in msgs was encoded with session_id_ok=TRUE; the
 * failure is discovered at decode time.  Find the message by (mtype, dir, epoch, seq)
 * and discard it directly rather than requiring session_id_ok=FALSE in msgs.
 *)
TraceDecodeSessionIdFail ==
    /\ l <= TraceLen
    /\ IsEvent("decode_session_id_fail")
    /\ LET e == TraceEndpoint(logline)
           d == TraceDir(logline)
       IN
       /\ \E m \in DOMAIN msgs :
              /\ m.mtype = MSG_DATA
              /\ m.dir   = d
              /\ m.epoch = logline.msg.epoch
              /\ m.seq   = logline.msg.seq
              /\ msgs'   = msgs (-) SetToBag({m})
       /\ UNCHANGED <<seqVars, keyVars, updateVars>>
       /\ ValidateSeq(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceDecodeAEADFail – matches event "decode_aead_fail".
 * libspdm_secmes_encode_decode.c:523–533 (no backup path)
 * Abstraction gap: message in msgs has aead_ok=TRUE (as encoded); failure is
 * discovered at decode time.  Find message by (mtype, dir, epoch, seq) and discard.
 *)
TraceDecodeAEADFail ==
    /\ l <= TraceLen
    /\ IsEvent("decode_aead_fail")
    /\ LET e == TraceEndpoint(logline)
           d == TraceDir(logline)
       IN
       /\ \E m \in DOMAIN msgs :
              /\ m.mtype = MSG_DATA
              /\ m.dir   = d
              /\ m.epoch = logline.msg.epoch
              /\ m.seq   = logline.msg.seq
              /\ msgs'   = msgs (-) SetToBag({m})
       /\ UNCHANGED <<seqVars, keyVars, updateVars>>
       /\ ValidateSeq(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceDecodeAEADFailWithBackup – matches event "decode_aead_fail_backup".
 * libspdm_secmes_encode_decode.c:523–533, backup_valid → TRY_DISCARD returned
 * The message in msgs was encoded with aead_ok=TRUE and may have a different epoch;
 * find it by (mtype, dir, seq) and discard directly (backup_valid guard applied here).
 *)
TraceDecodeAEADFailWithBackup ==
    /\ l <= TraceLen
    /\ IsEvent("decode_aead_fail_backup")
    /\ LET e == TraceEndpoint(logline)
           d == TraceDir(logline)
       IN
       /\ backup_valid[e][d]
       /\ \E m \in DOMAIN msgs :
              /\ m.mtype = MSG_DATA
              /\ m.dir   = d
              /\ m.seq   = logline.msg.seq
              /\ msgs'   = msgs (-) SetToBag({m})
       /\ UNCHANGED <<seqVars, keyVars, updateVars>>
       /\ ValidateSeq(e, d)
       /\ ValidateEpoch(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceCreateUpdateResponderKey – matches event "create_update_responder_key".
 * libspdm_secmes_session.c:335–465 (create_update, RESPONDER action)
 *)
TraceCreateUpdateResponderKey ==
    /\ l <= TraceLen
    /\ IsEvent("create_update_responder_key")
    /\ CreateUpdateResponderKey
    /\ LET e == Requester
           d == ResponseDir
       IN ValidateEpoch(e, d)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceSendKeyUpdateRequest – matches event "send_key_update_request".
 * libspdm_req_key_update.c:77–140
 *)
TraceSendKeyUpdateRequest ==
    /\ l <= TraceLen
    /\ IsEvent("send_key_update_request")
    /\ LET all_keys == logline.msg.all_keys IN
       /\ SendKeyUpdateRequest(all_keys)
       /\ ValidateUpdatePhase
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceResponderReceiveKeyUpdate – matches event "responder_receive_key_update".
 * libspdm_rsp_key_update_ack.c:12–241
 * Key-update messages carry seq that differs from the spec's counter; find by
 * epoch+all_keys.  Validate req-dir fields from state.active_epoch/backup_valid and
 * rsp-dir epoch from state.rsp_active_epoch (skipping backup_epoch not in trace state).
 *)
TraceResponderReceiveKeyUpdate ==
    /\ l <= TraceLen
    /\ IsEvent("responder_receive_key_update")
    /\ LET d == RequestDir
           m == CHOOSE m \in DOMAIN msgs :
                    m.mtype = MSG_KEY_UPDATE /\ m.dir = d /\
                    m.epoch = logline.msg.epoch /\ m.all_keys = logline.msg.all_keys
       IN
       /\ ResponderReceiveKeyUpdate(m)
       \* RequestDir: validate epoch and backup_valid; skip backup_epoch (not in trace state)
       /\ active_epoch'[Responder][RequestDir] = logline.state.active_epoch
       /\ backup_valid'[Responder][RequestDir] = logline.state.backup_valid
       \* ResponseDir: validate epoch only (using rsp_active_epoch field)
       /\ active_epoch'[Responder][ResponseDir] = logline.state.rsp_active_epoch
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceRequesterReceiveKeyUpdateAck – matches event "requester_receive_key_update_ack".
 * libspdm_req_key_update.c:171–216 (create+activate requester key immediately)
 * ACK seq may differ from spec counter; find ACK by (mtype, dir, epoch).
 * State captures active_epoch[Requester][RequestDir] and backup_valid for RequestDir.
 *)
TraceRequesterReceiveKeyUpdateAck ==
    /\ l <= TraceLen
    /\ IsEvent("requester_receive_key_update_ack")
    /\ LET m == CHOOSE m \in DOMAIN msgs :
                    m.mtype = MSG_KEY_UPDATE_ACK /\ m.dir = ResponseDir /\
                    m.epoch = logline.msg.epoch /\ m.all_keys = logline.msg.all_keys
       IN
       /\ RequesterReceiveKeyUpdateAck(m)
       /\ ValidateEpoch(Requester, RequestDir)
       /\ ValidateUpdatePhase
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceResponderReceiveVerifyNewKey – matches event "responder_receive_verify_new_key".
 * libspdm_rsp_key_update_ack.c:194–216
 * VERIFY_NEW_KEY seq may differ from spec (seq=1 in spec, seq=0 in trace); find by epoch.
 *)
TraceResponderReceiveVerifyNewKey ==
    /\ l <= TraceLen
    /\ IsEvent("responder_receive_verify_new_key")
    /\ LET m == CHOOSE m \in DOMAIN msgs :
                    m.mtype = MSG_VERIFY_NEW_KEY /\ m.dir = RequestDir /\
                    m.epoch = logline.msg.epoch
       IN
       /\ ResponderReceiveVerifyNewKey(m)
       /\ ValidateEpoch(Responder, RequestDir)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceResponderTryDiscardKeyUpdate – matches event "responder_try_discard_key_update".
 * libspdm_rsp_receive_send.c:197–264 (rollback path triggered by TRY_DISCARD)
 * TRY_DISCARD may be triggered by either a failed VERIFY_NEW_KEY (F2, update_phase=PendingVerify)
 * or a failed DATA message (F4, update_phase=Idle).  Apply rollback state directly to handle
 * both cases; only discard a VERIFY_NEW_KEY message from msgs if one is present.
 *)
TraceResponderTryDiscardKeyUpdate ==
    /\ l <= TraceLen
    /\ IsEvent("responder_try_discard_key_update")
    /\ LET e  == Responder
           rd == RequestDir
       IN
       /\ backup_valid[e][rd]
       /\ seq'          = [seq          EXCEPT ![e][rd] = backup_seq[e][rd]]
       /\ active_epoch' = [active_epoch EXCEPT ![e][rd] = backup_epoch[e][rd]]
       /\ backup_valid' = [backup_valid EXCEPT ![e][rd] = FALSE]
       /\ backup_epoch' = [backup_epoch EXCEPT ![e][rd] = 0]
       /\ backup_seq'   = [backup_seq   EXCEPT ![e][rd] = 0]
       /\ (IF update_phase = PendingVerify
           THEN update_phase' = Idle
           ELSE UNCHANGED update_phase)
       /\ (IF \E m \in DOMAIN msgs : m.mtype = MSG_VERIFY_NEW_KEY /\ m.dir = rd
           THEN \E m \in DOMAIN msgs : m.mtype = MSG_VERIFY_NEW_KEY /\ m.dir = rd
                /\ msgs' = msgs (-) SetToBag({m})
           ELSE UNCHANGED msgs)
       /\ UNCHANGED <<update_all_keys, initiator_committed, is_encap>>
       /\ ValidateEpoch(e, rd)
       /\ ValidateSeq(e, rd)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceRequesterReceiveVerifyAck – matches event "requester_receive_verify_ack".
 * libspdm_req_key_update.c:290–314
 * VERIFY_ACK seq may differ from spec; find by (mtype, dir, epoch).
 *)
TraceRequesterReceiveVerifyAck ==
    /\ l <= TraceLen
    /\ IsEvent("requester_receive_verify_ack")
    /\ LET m == CHOOSE m \in DOMAIN msgs :
                    m.mtype = MSG_VERIFY_ACK /\ m.dir = ResponseDir
       IN
       /\ RequesterReceiveVerifyAck(m)
       /\ ValidateUpdatePhase
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceEncapCreateAndActivateRspKey – matches event "encap_create_activate_rsp_key".
 * libspdm_rsp_encap_key_update.c:79–98
 *)
TraceEncapCreateAndActivateRspKey ==
    /\ l <= TraceLen
    /\ IsEvent("encap_create_activate_rsp_key")
    /\ EncapCreateAndActivateRspKey
    /\ ValidateEpoch(Responder, ResponseDir)
    /\ ValidateUpdatePhase
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

(*
 * TraceRequesterHandleResponseNotReady – matches event "requester_handle_response_not_ready".
 * libspdm_req_send_receive.c:218–313
 *)
TraceRequesterHandleResponseNotReady ==
    /\ l <= TraceLen
    /\ IsEvent("requester_handle_response_not_ready")
    /\ LET m == [mtype |-> MSG_RESPONSE_NOT_READY, dir |-> ResponseDir,
                 epoch |-> logline.msg.epoch,
                 seq   |-> logline.msg.seq,
                 session_id_ok |-> TRUE,
                 aead_ok       |-> TRUE,
                 all_keys      |-> FALSE]
       IN
       /\ RequesterHandleResponseNotReady(m)
       /\ ValidateSeq(Requester, RequestDir)
       /\ ValidateEpoch(Requester, RequestDir)
    /\ l' = l + 1
    /\ UNCHANGED faultDummy

-------------------------------------------------------------------------
\* SILENT ACTIONS
\* Handle spec state changes that produce no trace event.
\* Tightly constrained: only fire when the next trace event requires this state.

\* SilentEncodeAdvanceSeq: encoder incremented seq but the trace only records the encode_success.
\* Fire only when next event is "encode_success" and seq[Sender(d)][d] equals pre-increment value.
SilentEncodeAdvanceSeq ==
    /\ l <= TraceLen
    /\ logline.event = "encode_success"
    /\ LET d == TraceDir(logline)
           e == Sender(d)
       IN
       /\ seq[e][d] + 1 = logline.msg.seq    \* seq not yet incremented
       /\ EncodeAdvanceSeq(d)
    /\ UNCHANGED l
    /\ UNCHANGED faultDummy

\* SilentSeqSync: a seq counter was reset or synced by the implementation (e.g. key-update
\* reset, test-harness sync) without a corresponding trace event.  Fires before any
\* encode_advance_seq or decode_increment_seq when the spec's seq counter doesn't match
\* the expected pre-step value from the trace.
\* Only fires when backup_valid=FALSE (key-update-setup case handled by SilentResponderCreateUpdateRequesterKey).
SilentSeqSync ==
    /\ l <= TraceLen
    /\ \/ logline.event = "encode_advance_seq"
       \/ logline.event = "decode_increment_seq"
    /\ LET e == TraceEndpoint(logline)
           d == TraceDir(logline)
       IN
       /\ logline.state.backup_valid = FALSE
       /\ logline.state.seq >= 1
       /\ seq[e][d] /= logline.state.seq - 1
       /\ seq' = [seq EXCEPT ![e][d] = logline.state.seq - 1]
    /\ UNCHANGED <<backup_seq, keyVars, updateVars, netVars>>
    /\ UNCHANGED l
    /\ UNCHANGED faultDummy

\* SilentResponderCreateUpdateRequesterKey: responder silently created a new req-direction key
\* (e.g. as part of test setup not captured in the trace). Fires before decode_increment_seq
\* when the trace shows backup_valid=True for that direction but the spec does not.
SilentResponderCreateUpdateRequesterKey ==
    /\ l <= TraceLen
    /\ logline.event = "decode_increment_seq"
    /\ TraceEndpoint(logline) = Responder
    /\ TraceDir(logline) = RequestDir
    /\ logline.state.backup_valid = TRUE
    /\ backup_valid[Responder][RequestDir] = FALSE  \* spec doesn't have backup yet
    /\ active_epoch[Responder][RequestDir] < MaxEpoch
    /\ active_epoch' = [active_epoch EXCEPT ![Responder][RequestDir] = active_epoch[Responder][RequestDir] + 1]
    /\ backup_epoch' = [backup_epoch EXCEPT ![Responder][RequestDir] = active_epoch[Responder][RequestDir]]
    /\ backup_seq'   = [backup_seq   EXCEPT ![Responder][RequestDir] = logline.state.backup_seq]
    /\ seq'          = [seq          EXCEPT ![Responder][RequestDir] = 0]
    /\ backup_valid' = [backup_valid EXCEPT ![Responder][RequestDir] = TRUE]
    /\ UNCHANGED <<update_phase, update_all_keys, initiator_committed, is_encap, msgs>>
    /\ UNCHANGED l
    /\ UNCHANGED faultDummy

-------------------------------------------------------------------------
\* TRACE NEXT

TraceNext ==
    /\ l <= TraceLen
    /\
        \/ TraceEncodeAdvanceSeq
        \/ TraceEncodeSuccess
        \/ TraceDecodeIncrementSeq
        \/ TraceDecodeSuccess
        \/ TraceDecodeSessionIdFail
        \/ TraceDecodeAEADFail
        \/ TraceDecodeAEADFailWithBackup
        \/ TraceCreateUpdateResponderKey
        \/ TraceSendKeyUpdateRequest
        \/ TraceResponderReceiveKeyUpdate
        \/ TraceRequesterReceiveKeyUpdateAck
        \/ TraceResponderReceiveVerifyNewKey
        \/ TraceResponderTryDiscardKeyUpdate
        \/ TraceRequesterReceiveVerifyAck
        \/ TraceEncapCreateAndActivateRspKey
        \/ TraceRequesterHandleResponseNotReady
        \* Silent actions (no l advance)
        \/ SilentEncodeAdvanceSeq
        \/ SilentSeqSync
        \/ SilentResponderCreateUpdateRequesterKey

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l, faultDummy>>
             /\ WF_<<vars, l, faultDummy>>(TraceNext)

\* TraceMatched: temporal property that the entire trace was consumed.
TraceMatched == <>(l > TraceLen)

==========================================================================
