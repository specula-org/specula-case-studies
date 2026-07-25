---- MODULE Trace ----
(*
 * Trace validation spec for libspdm GET_MEASUREMENTS.
 * Category A (Distributed / Message-Passing): single-file linear trace.
 *
 * Drives TLC through a recorded NDJSON execution trace from the
 * instrumented libspdm implementation. Verifies that the base spec
 * can reproduce every observed state transition.
 *
 * Trace file location: ../traces/trace.ndjson (override with IOEnv.JSON)
 *)

EXTENDS base, Json, IOUtils, Sequences, FiniteSets, Naturals, TLC

(* ================================================================
   TRACE LOADING
   ================================================================ *)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

(* Cursor into the trace — advances by 1 on each consumed event *)
VARIABLE l

(* ================================================================
   EVENT PREDICATES
   ================================================================ *)

IsEvent(name) ==
    l <= Len(TraceLog) /\ TraceLog[l].event = name

\* Current logline accessor
logline == TraceLog[l]

(* ================================================================
   VERSION MAPPING
   ================================================================ *)
\* Map trace version string "1.1" / "1.2" / "1.3" to model constants
VersionFromTrace(v) ==
    IF v = "1.0" THEN 10
    ELSE IF v = "1.1" THEN 11
    ELSE IF v = "1.2" THEN 12
    ELSE 13

\* Map trace slot field to model slot (NULL when absent / no-sig).
\* Slot IDs in traces are integers (0..15) or the string "none".
\* NULL is a model value — safe to compare against any TLC type without exceptions.
SlotFromTrace(s) ==
    IF s = NULL THEN NULL ELSE s

\* Map trace session_id field (0 means non-session)
SessionFromTrace(sid) ==
    IF sid = 0 THEN NULL ELSE sid

(* ================================================================
   POST-STATE VALIDATION
   Checks spec variables against trace-captured post-state fields.
   ================================================================ *)

ValidatePostState_NegotiateVersion ==
    /\ spdm_version'  = VersionFromTrace(logline.post.spdm_version)
    /\ connection_state' = CS_NEGOTIATED

ValidatePostState_EstablishSession ==
    /\ logline.post.session_id \in active_sessions'

ValidatePostState_RequesterSendGetMeasurements ==
    /\ current_request'.gen_sig = logline.post.gen_sig
    /\ current_request'.slot_id = IF logline.post.gen_sig THEN logline.post.slot_id ELSE NULL
    /\ current_session_id'       = SessionFromTrace(logline.post.session_id)

ValidatePostState_ResponderAppendRequest ==
    \* Verify the latest entry in the appropriate message_m buffer was added
    /\ LET sid == SessionFromTrace(logline.post.session_id)
       IN  IF sid = NULL
           THEN Len(message_m_global') = logline.post.message_m_global_len
           ELSE Len(message_m_session'[sid]) = logline.post.message_m_session_len

ValidatePostState_ResponderBuildResponse ==
    \* Only validate response_slot when sig was requested; for no-sig case,
    \* the implementation keeps the default slot (0) but spec uses NULL.
    /\ (logline.data.has_sig =>
            response_slot' = SlotFromTrace(logline.post.response_slot))

ValidatePostState_ResponderGenerateSignature ==
    /\ l1l2_responder' /= NULL
    \* message_m was reset
    /\ LET sid == SessionFromTrace(logline.post.session_id)
       IN  IF sid = NULL
           THEN message_m_global' = <<>>
           ELSE message_m_session'[sid] = <<>>

ValidatePostState_L1L2ComputationFailure ==
    /\ l1l2_responder' = NULL

ValidatePostState_RequesterParseResponseSig ==
    /\ parse_error' = FALSE
    /\ parse_offset' = logline.post.parse_offset

ValidatePostState_RequesterParseResponseNoSig ==
    /\ parse_offset' = logline.post.parse_offset
    \* parse_error may be TRUE if the missing-NONCE_SIZE bug triggered
    /\ parse_error'  = logline.post.parse_error

ValidatePostState_RequesterVerifySignature ==
    /\ sig_verified'   = TRUE
    /\ l1l2_requester' /= NULL
    /\ LET sid == SessionFromTrace(logline.post.session_id)
       IN  IF sid = NULL
           THEN message_m_global' = <<>>
           ELSE message_m_session'[sid] = <<>>

ValidatePostState_CompleteExchange ==
    /\ current_request'  = NULL
    /\ current_response' = NULL
    /\ parse_offset'      = 0

ValidatePostState_NeedResync ==
    /\ connection_state' = CS_NOT_STARTED

ValidatePostState_ResetContext ==
    /\ connection_state' = CS_NOT_STARTED
    /\ message_m_global' = <<>>

(* ================================================================
   TRACE ACTION WRAPPERS
   Each wrapper: match event → call base action → validate post-state → l' = l + 1
   ================================================================ *)

TraceNegotiateVersion ==
    /\ IsEvent("negotiate_version")
    /\ NegotiateVersion(VersionFromTrace(logline.data.version))
    /\ ValidatePostState_NegotiateVersion
    /\ l' = l + 1

TraceEstablishSession ==
    /\ IsEvent("establish_session")
    /\ EstablishSession(logline.data.session_id)
    /\ ValidatePostState_EstablishSession
    /\ l' = l + 1

TraceRequesterSendGetMeasurements ==
    /\ IsEvent("requester_send_get_measurements")
    /\ RequesterSendGetMeasurements(
            SessionFromTrace(logline.data.session_id),
            IF logline.data.gen_sig THEN logline.data.slot_id ELSE NULL,
            logline.data.gen_sig,
            logline.data.meas_index)
    /\ ValidatePostState_RequesterSendGetMeasurements
    /\ l' = l + 1

TraceResponderAppendRequest ==
    /\ IsEvent("responder_append_request")
    /\ ResponderAppendRequest
    /\ ValidatePostState_ResponderAppendRequest
    /\ l' = l + 1

TraceResponderBuildResponse ==
    /\ IsEvent("responder_build_response")
    /\ ResponderBuildResponse(
            logline.data.meas_len,
            logline.data.opaque_len,
            logline.data.has_sig)
    /\ ValidatePostState_ResponderBuildResponse
    /\ l' = l + 1

TraceResponderGenerateSignature ==
    /\ IsEvent("responder_generate_signature")
    /\ ResponderGenerateSignature
    /\ ValidatePostState_ResponderGenerateSignature
    /\ l' = l + 1

TraceL1L2ComputationFailure ==
    /\ IsEvent("l1l2_computation_failure")
    /\ L1L2ComputationFailure
    /\ ValidatePostState_L1L2ComputationFailure
    /\ l' = l + 1

TraceRequesterParseResponseSig ==
    /\ IsEvent("requester_parse_response_sig")
    /\ RequesterParseResponseSig(logline.data.response_size)
    /\ ValidatePostState_RequesterParseResponseSig
    /\ l' = l + 1

TraceRequesterParseResponseNoSig ==
    /\ IsEvent("requester_parse_response_nosig")
    /\ RequesterParseResponseNoSig(logline.data.response_size)
    /\ ValidatePostState_RequesterParseResponseNoSig
    /\ l' = l + 1

TraceRequesterVerifySignature ==
    /\ IsEvent("requester_verify_signature")
    /\ RequesterVerifySignature
    /\ ValidatePostState_RequesterVerifySignature
    /\ l' = l + 1

TraceCompleteExchange ==
    /\ IsEvent("complete_exchange")
    /\ CompleteExchange
    /\ ValidatePostState_CompleteExchange
    /\ l' = l + 1

TraceNeedResync ==
    /\ IsEvent("need_resync")
    /\ NeedResync
    /\ ValidatePostState_NeedResync
    /\ l' = l + 1

TraceResetContext ==
    /\ IsEvent("reset_context")
    /\ ResetContext
    /\ ValidatePostState_ResetContext
    /\ l' = l + 1

(* ================================================================
   SILENT ACTIONS
   Handle impl state transitions that do not produce trace events.
   All are tightly constrained to avoid state space explosion.
   ================================================================ *)

\* Silent: partial retry (may occur without a distinct trace event)
SilentPartialRetryAccumulate ==
    /\ l <= Len(TraceLog)
    /\ current_request  /= NULL
    /\ current_response = NULL
    \* Only fire if the NEXT event is another request append (double-append scenario)
    /\ IsEvent("responder_append_request")
    /\ PartialRetryAccumulate
    /\ UNCHANGED l

(* ================================================================
   TRACE INIT
   Bootstrap state — may differ from base Init.
   Trace starts after the connection has been pre-established (version negotiated).
   ================================================================ *)
TraceInit ==
    /\ Init
    /\ l = 1
    \* If trace starts mid-session, bootstrap from first event
    \* MC layer may inject a non-empty message_a here

(* ================================================================
   TRACE NEXT
   ================================================================ *)
TraceNext ==
    \/ TraceNegotiateVersion
    \/ TraceEstablishSession
    \/ TraceRequesterSendGetMeasurements
    \/ TraceResponderAppendRequest
    \/ TraceResponderBuildResponse
    \/ TraceResponderGenerateSignature
    \/ TraceL1L2ComputationFailure
    \/ TraceRequesterParseResponseSig
    \/ TraceRequesterParseResponseNoSig
    \/ TraceRequesterVerifySignature
    \/ TraceCompleteExchange
    \/ TraceNeedResync
    \/ TraceResetContext

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>> /\ WF_l(TraceNext)

(* ================================================================
   TRACE MATCHED — temporal property verifying full trace consumed
   ================================================================ *)
TraceMatched == <>(l > Len(TraceLog))

====
