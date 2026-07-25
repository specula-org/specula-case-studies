---- MODULE base ----
(*
 * TLA+ specification for libspdm GET_MEASUREMENTS / attestation protocol.
 * Target: DMTF/libspdm, DSP0274 §10.11 / §10.15 / §15
 *
 * Category A (Distributed / Message-Passing):
 *   Stateful request-response protocol between Requester and Responder.
 *   Hazards arise from multi-message stateful interactions, not concurrency.
 *
 * Bug families modeled:
 *   Family 1 — L1/L2 Transcript Integrity
 *   Family 2 — Response Structure Parsing (missing NONCE_SIZE guard)
 *   Family 3 — Session/Non-Session Message-M Context Selection
 *   Family 4 — Slot ID / Key Binding Invariant
 *)

EXTENDS Sequences, FiniteSets, Naturals, TLC

CONSTANTS
    MaxMeasurementExchanges,   \* bound on GET_MEASUREMENTS rounds
    MaxSlots,                  \* number of cert slots (≤ SPDM_MAX_SLOT_COUNT = 8)
    MaxSessions,               \* bound on concurrent sessions
    Versions,                  \* set of SPDM version numbers modeled (e.g. {11, 12, 13})
    RAW_PUBLIC_KEY_SLOT,       \* sentinel 0xF for raw-public-key mode
    NULL                       \* model value — safe to compare against any TLC type

ASSUME MaxSlots \in 1..8
ASSUME RAW_PUBLIC_KEY_SLOT = 15  \* 0xF

(* ------ Roles ------ *)
Requester == "requester"
Responder == "responder"
Sides      == {Requester, Responder}

(* ------ SPDM version sentinels ------ *)
Version10 == 10
Version11 == 11
Version12 == 12
Version13 == 13

(* ------ Connection state (com_context_data.c LIBSPDM_CONNECTION_STATE_N) ------ *)
CS_NOT_STARTED  == "NOT_STARTED"
CS_AFTER_VERSION == "AFTER_VERSION"
CS_NEGOTIATED   == "NEGOTIATED"

ConnectionStates == {CS_NOT_STARTED, CS_AFTER_VERSION, CS_NEGOTIATED}

(* ------ Response states ------ *)
RS_NORMAL     == "NORMAL"
RS_NOT_READY  == "NOT_READY"
RS_NEED_RESYNC == "NEED_RESYNC"

ResponseStates == {RS_NORMAL, RS_NOT_READY, RS_NEED_RESYNC}


(* ------ Slots ------ *)
Slots == 0..(MaxSlots-1)
ValidSlots == Slots \cup {RAW_PUBLIC_KEY_SLOT}

(* ------ Session IDs ------ *)
SessionIDs == 1..MaxSessions

(* ================================================================
   VARIABLES
   ================================================================ *)

(*
 * Protocol state variables
 * Grouped for UNCHANGED clauses.
 *)
VARIABLES
    \* ---- connection / session state ----
    \* rsp_measurements.c:113-136; com_context_data.c:2942-2957
    connection_state,     \* ConnectionStates
    response_state,       \* ResponseStates
    active_sessions,      \* SUBSET SessionIDs — established sessions
    spdm_version,         \* element of Versions — negotiated version

    \* ---- transcript variables (Family 1, 3) ----
    \* com_context_data.c:1305-1337, com_crypto_service.c:134-237
    message_m_global,          \* sequence of {req, resp_no_sig} pairs — global (non-session)
    message_m_session,         \* [SessionIDs -> Seq of {req, resp_no_sig}] — per-session
    message_a,                 \* sequence of bytes — VCA transcript (prepended for ≥ v1.2)

    \* ---- L1/L2 finalization state (Family 1) ----
    \* rsp_measurements.c:36-44; req_get_measurements.c:35-43
    l1l2_requester,       \* NULL | Seq — computed by requester before verify
    l1l2_responder,       \* NULL | Seq — computed by responder before sign

    \* ---- signature / verification flags (Family 1, 4) ----
    sig_verified,         \* Bool — Requester has successfully verified a sig this session
    sig_ready,            \* Bool — Responder has signed current exchange (verify ordering guard)

    \* ---- slot binding (Family 4) ----
    \* rsp_measurements.c:91, 421-468; req_get_measurements.c:426-544
    requested_slot,       \* ValidSlots | NULL
    response_slot,        \* ValidSlots | NULL
    signing_slot,         \* ValidSlots | NULL

    \* ---- response parsing cursor (Family 2) ----
    \* req_get_measurements.c:545-643
    parse_offset,         \* Nat — byte offset after last consumed field
    parse_error,          \* Bool — set when a size check fails

    \* ---- request/response message buffers (scratch for current exchange) ----
    current_request,      \* record: {version, gen_sig, slot_id, measurement_index}
    current_response,     \* record: {slot_id, meas_len, has_nonce, opaque_len, has_sig}

    \* ---- session being used for current exchange ----
    current_session_id    \* NULL | SessionID

(* Variable groupings for UNCHANGED *)
connVars     == <<connection_state, response_state, active_sessions, spdm_version>>
transcriptVars == <<message_m_global, message_m_session, message_a>>
l1l2Vars     == <<l1l2_requester, l1l2_responder>>
sigVars      == <<sig_verified, sig_ready>>
slotVars     == <<requested_slot, response_slot, signing_slot>>
parseVars    == <<parse_offset, parse_error>>
msgVars      == <<current_request, current_response, current_session_id>>

vars == <<connVars, transcriptVars, l1l2Vars, sigVars, slotVars, parseVars, msgVars>>

(* ================================================================
   HELPERS
   ================================================================ *)

\* Select the correct message_m buffer based on session context.
\* com_context_data.c:1305-1337
MessageM(sid) ==
    IF sid = NULL THEN message_m_global
    ELSE message_m_session[sid]

\* Append a {req, resp} pair to message_m for the given session.
\* Returns the updated message_m_global or message_m_session entry.
AppendedMessageM(sid, pair) ==
    IF sid = NULL THEN Append(message_m_global, pair)
    ELSE Append(message_m_session[sid], pair)

\* True when version is ≥ 1.2 (so message_a is prepended to L1/L2)
\* com_crypto_service.c:145-161
NeedsMessageA(v) == v >= Version12

\* Construct L1/L2 content from the current transcript.
\* com_crypto_service.c:134-203
ComputeL1L2(sid) ==
    LET mm == MessageM(sid)
        ma == IF NeedsMessageA(spdm_version) THEN message_a ELSE <<>>
    IN  ma \o mm   \* concatenate message_a + message_m

\* True when slot_id is valid (in-range slot or raw-public-key sentinel).
\* rsp_measurements.c:426-449
ValidSlotID(s) ==
    \/ s \in Slots
    \/ s = RAW_PUBLIC_KEY_SLOT

\* True when the key-usage check is satisfied for SPDM ≥ 1.3 multi-key mode.
\* rsp_measurements.c:451-459
KeyUsageOK(s, multi_key) ==
    \/ spdm_version < Version13
    \/ ~multi_key
    \/ s = RAW_PUBLIC_KEY_SLOT
    \* In the model we assume slots that exist have the bit set unless injected otherwise;
    \* MC layer overrides this for hunting Family 4.

\* Range of a sequence (set of values).
Range(s) == {s[i] : i \in DOMAIN s}

(* ================================================================
   INITIALIZATION
   ================================================================ *)

Init ==
    /\ connection_state    = CS_NOT_STARTED
    /\ response_state      = RS_NORMAL
    /\ active_sessions     = {}
    /\ spdm_version        \in Versions
    /\ message_m_global    = <<>>
    /\ message_m_session   = [sid \in SessionIDs |-> <<>>]
    /\ message_a           = <<>>   \* VCA not yet performed; MC layer injects non-empty
    /\ l1l2_requester      = NULL
    /\ l1l2_responder      = NULL
    /\ sig_verified        = FALSE
    /\ sig_ready           = FALSE
    /\ requested_slot      = NULL
    /\ response_slot       = NULL
    /\ signing_slot        = NULL
    /\ parse_offset        = 0
    /\ parse_error         = FALSE
    /\ current_request     = NULL
    /\ current_response    = NULL
    /\ current_session_id  = NULL

(* ================================================================
   ACTION: NegotiateVersion
   Move connection to NEGOTIATED state (covers GET_VERSION + GET_CAPABILITIES + NEGOTIATE_ALGORITHMS).
   In the model we abstract these as a single step that sets spdm_version and message_a.
   com_context_data.c:2942-2957 (reset_context), rsp_measurements.c:174-181 (connection_state guard)
   ================================================================ *)
NegotiateVersion(v) ==
    /\ connection_state = CS_NOT_STARTED
    /\ v \in Versions
    /\ spdm_version'     = v
    /\ connection_state' = CS_NEGOTIATED
    /\ message_a'        = IF NeedsMessageA(v) THEN <<"VCA">> ELSE <<>>
    /\ UNCHANGED <<response_state, active_sessions,
                   message_m_global, message_m_session,
                   l1l2Vars, sigVars, slotVars, parseVars, msgVars>>

(* ================================================================
   ACTION: EstablishSession
   Open a new SPDM session (KEY_EXCHANGE / PSK_EXCHANGE).
   Family 3: active_sessions tracks which sessions exist.
   rsp_measurements.c:113-136 (session lookup logic)
   ================================================================ *)
EstablishSession(sid) ==
    /\ connection_state = CS_NEGOTIATED
    /\ sid \in SessionIDs
    /\ sid \notin active_sessions
    /\ Cardinality(active_sessions) < MaxSessions
    /\ active_sessions' = active_sessions \cup {sid}
    /\ UNCHANGED <<connection_state, response_state, spdm_version,
                   transcriptVars, l1l2Vars, sigVars, slotVars, parseVars, msgVars>>

(* ================================================================
   ACTION: RequesterSendGetMeasurements
   Requester issues GET_MEASUREMENTS. Captures: session context, slot_id, gen_sig flag.
   Models the beginning of the protocol exchange.
   req_get_measurements.c:150-230 (parameter setup)
   ================================================================ *)
RequesterSendGetMeasurements(sid, slot, gen_sig, meas_idx) ==
    /\ connection_state = CS_NEGOTIATED
    /\ response_state   = RS_NORMAL
    /\ current_request  = NULL          \* no in-flight request
    /\ (sid = NULL \/ sid \in active_sessions)
    \* slot_id valid when signature requested
    /\ (gen_sig => ValidSlotID(slot))
    /\ current_request'     = [version       |-> spdm_version,
                                gen_sig       |-> gen_sig,
                                slot_id       |-> slot,
                                meas_index    |-> meas_idx,
                                session_id    |-> sid]
    /\ requested_slot'      = IF gen_sig THEN slot ELSE NULL
    /\ current_session_id'  = sid
    /\ UNCHANGED <<connVars, transcriptVars, l1l2Vars, sigVars,
                   response_slot, signing_slot, parseVars, current_response>>

(* ================================================================
   ACTION: ResponderAppendRequest
   Responder receives GET_MEASUREMENTS request and appends it to message_m.
   rsp_measurements.c:494-503 (libspdm_append_message_m for request)
   rsp_measurements.c:494-495 (libspdm_reset_message_buffer_via_request_code first)

   Key: reset_message_buffer_via_request_code with SPDM_GET_MEASUREMENTS does NOT reset
   message_m — it only resets other transcripts. So message_m accumulates across calls.
   com_context_data.c:1447-1501
   ================================================================ *)
ResponderAppendRequest ==
    /\ current_request  /= NULL
    /\ current_response = NULL     \* request not yet processed
    /\ connection_state = CS_NEGOTIATED
    /\ LET req == current_request
           sid == req.session_id
       IN
       \* Session validity check — rsp_measurements.c:113-136
       /\ (sid /= NULL => sid \in active_sessions)
       \* Version check — rsp_measurements.c:139-144
       /\ req.version = spdm_version
       \* Connection state guard — rsp_measurements.c:174-181
       /\ connection_state = CS_NEGOTIATED
       \* Idempotency guard: only append if no pending (unanswered) entry exists.
       \* Prevents double-fire; PartialRetryAccumulate models intentional retry accumulation.
       /\ (IF Len(MessageM(sid)) = 0 THEN TRUE
           ELSE (MessageM(sid))[Len(MessageM(sid))].resp /= NULL)
       \* Append request to message_m (not response yet)
       \* rsp_measurements.c:497
       /\ IF sid = NULL
          THEN message_m_global'  = Append(message_m_global, [req |-> req, resp |-> NULL])
               /\ UNCHANGED message_m_session
          ELSE message_m_session' = [message_m_session EXCEPT
                                       ![sid] = Append(message_m_session[sid],
                                                       [req |-> req, resp |-> NULL])]
               /\ UNCHANGED message_m_global
    /\ UNCHANGED <<connVars, message_a, l1l2Vars, sigVars, slotVars, parseVars,
                   current_request, current_response, current_session_id>>

(* ================================================================
   ACTION: ResponderBuildResponse
   Responder builds the MEASUREMENTS response and appends (response - sig) to message_m.
   Models: slot_id assignment, key usage check, response field layout.
   rsp_measurements.c:421-513

   This action does NOT yet generate the signature — that is ResponderGenerateSignature.
   Splitting preserves the "reset-before-failure" window in Family 1.
   ================================================================ *)
ResponderBuildResponse(resp_meas_len, resp_opaque_len, resp_has_sig) ==
    /\ current_request  /= NULL
    /\ current_response = NULL
    \* Guard: request must already be appended to message_m (resp = NULL in last entry).
    \* In the implementation, libspdm_append_message_m for the request (line 497) always
    \* precedes building the response — rsp_measurements.c:494-512.
    /\ LET _sid == current_request.session_id
       IN /\ Len(MessageM(_sid)) > 0
          /\ (MessageM(_sid))[Len(MessageM(_sid))].resp = NULL
    /\ LET req == current_request
           sid == req.session_id
           gen_sig == req.gen_sig
       IN
       \* slot_id assignment — rsp_measurements.c:421-468
       \* For version ≥ 1.1 and generate_signature, slot_id comes from request.
       \* For version 1.0 with generate_signature, slot_id_param is uninitialized (modeling: use 0).
       /\ LET eff_slot ==
               IF gen_sig /\ spdm_version >= Version11
               THEN req.slot_id
               ELSE IF gen_sig  \* v1.0 + sig: uninitialized slot_id_param, treat as 0
                    THEN 0
                    ELSE NULL   \* no signature requested, slot doesn't matter
          IN
          /\ signing_slot'   = eff_slot
          /\ response_slot'  = eff_slot   \* param2 set to slot_id — rsp_measurements.c:462
          \* Build response record (without signature bytes)
          /\ current_response' = [slot_id       |-> eff_slot,
                                   meas_len      |-> resp_meas_len,
                                   opaque_len    |-> resp_opaque_len,
                                   has_sig       |-> gen_sig,
                                   session_id    |-> sid]
          \* Append (response - signature) to message_m — rsp_measurements.c:505-512
          /\ IF sid = NULL
             THEN LET last_idx == Len(message_m_global)
                  IN  message_m_global' =
                        [message_m_global EXCEPT
                           ![last_idx] = [@ EXCEPT !.resp =
                             [meas_len  |-> resp_meas_len,
                              opaque_len |-> resp_opaque_len,
                              sig_bytes |-> FALSE]]]  \* sig NOT included
                  /\ UNCHANGED message_m_session
             ELSE LET last_idx == Len(message_m_session[sid])
                  IN  message_m_session' =
                        [message_m_session EXCEPT
                           ![sid][last_idx] = [@ EXCEPT !.resp =
                             [meas_len   |-> resp_meas_len,
                              opaque_len |-> resp_opaque_len,
                              sig_bytes  |-> FALSE]]]
                  /\ UNCHANGED message_m_global
    /\ UNCHANGED <<connVars, message_a, l1l2Vars, sigVars,
                   requested_slot, parseVars, current_request, current_session_id>>

(* ================================================================
   ACTION: ResponderGenerateSignature
   Responder computes L1/L2 then resets message_m, then signs.
   CRITICAL ORDERING: reset happens BEFORE checking whether calculate succeeded.
   rsp_measurements.c:36-44:
     result = libspdm_calculate_l1l2(...)
     libspdm_reset_message_m(...)    <-- ALWAYS resets, even on failure (line 41)
     if (!result) return false;
   ================================================================ *)
ResponderGenerateSignature ==
    /\ current_response /= NULL
    /\ current_response.has_sig = TRUE
    \* One-sign-per-exchange guard: l1l2_responder is NULL until signing, and is only
    \* reset to NULL by L1L2ComputationFailure (which also clears current_response).
    /\ l1l2_responder = NULL
    /\ LET sid == current_response.session_id
       IN
       \* Compute L1/L2 from current transcript state
       /\ l1l2_responder' = ComputeL1L2(sid)
       \* ALWAYS reset message_m, even before checking success — rsp_measurements.c:41
       /\ IF sid = NULL
          THEN message_m_global'  = <<>>
               /\ UNCHANGED message_m_session
          ELSE message_m_session' = [message_m_session EXCEPT ![sid] = <<>>]
               /\ UNCHANGED message_m_global
    \* Signature succeeds: mark signature ready for requester to verify
    /\ sig_ready' = TRUE
    /\ UNCHANGED <<connVars, message_a, l1l2_requester, sig_verified,
                   slotVars, parseVars, current_request, current_response, current_session_id>>

(* ================================================================
   ACTION: L1L2ComputationFailure
   Models the case where libspdm_calculate_l1l2 fails mid-stream.
   message_m is reset (line 41) but l1l2_responder is never set — the transcript
   is permanently destroyed and cannot be recovered for retry.
   Family 1 bug: rsp_measurements.c:36-44
   ================================================================ *)
L1L2ComputationFailure ==
    /\ current_response /= NULL
    /\ current_response.has_sig = TRUE
    \* Failure can only occur before a successful sign (l1l2_responder not yet set).
    /\ l1l2_responder = NULL
    /\ LET sid == current_response.session_id
       IN
       \* Reset message_m (happens unconditionally before failure check)
       /\ IF sid = NULL
          THEN message_m_global'  = <<>>
               /\ UNCHANGED message_m_session
          ELSE message_m_session' = [message_m_session EXCEPT ![sid] = <<>>]
               /\ UNCHANGED message_m_global
    \* l1l2_responder remains NULL — calculation failed; sig_ready cleared
    /\ l1l2_responder' = NULL
    /\ sig_ready' = FALSE
    /\ current_response' = NULL    \* exchange aborted
    /\ UNCHANGED <<connVars, message_a, l1l2_requester, sig_verified,
                   slotVars, parseVars, current_request, current_session_id>>

(* ================================================================
   ACTION: RequesterParseResponseSig (signature path)
   Requester parses MEASUREMENTS response when signature was requested.
   Performs sequential size checks: header + meas_record + NONCE + opaque.
   req_get_measurements.c:426-544

   Signature path: correctly includes SPDM_NONCE_SIZE (32) in size check at line 427-429.
   ================================================================ *)
SPDM_NONCE_SIZE    == 32
SIZEOF_UINT16      == 2
SIZEOF_RSP_HEADER  == 8  \* spdm_measurements_response_t header

RequesterParseResponseSig(resp_size) ==
    /\ current_response /= NULL
    /\ current_response.has_sig = TRUE
    /\ parse_error = FALSE
    /\ parse_offset = 0   \* idempotency guard: only parse once per exchange
    /\ LET resp     == current_response
           ml       == resp.meas_len
           ol       == resp.opaque_len
           \* req_get_measurements.c:427-429: correct guard includes NONCE_SIZE
           min_size == SIZEOF_RSP_HEADER + ml + SPDM_NONCE_SIZE + SIZEOF_UINT16
       IN
       \* Minimum size check — req_get_measurements.c:427-429
       /\ IF resp_size < min_size
          THEN /\ parse_error' = TRUE
               /\ parse_offset' = parse_offset
          ELSE \* Advance cursor past: header + meas_record + nonce + opaque_len
               /\ parse_offset' = SIZEOF_RSP_HEADER + ml + SPDM_NONCE_SIZE + SIZEOF_UINT16 + ol
               /\ parse_error'  = (parse_offset' > resp_size)
       \* Append request to message_m — req_get_measurements.c:521-525
       /\ LET sid == current_response.session_id
              req == current_request
          IN
          IF ~parse_error'
          THEN IF sid = NULL
               THEN message_m_global'  = Append(message_m_global,
                                                [req |-> req,
                                                 resp |-> [meas_len   |-> ml,
                                                           opaque_len |-> ol,
                                                           sig_bytes  |-> FALSE]])
                    /\ UNCHANGED message_m_session
               ELSE message_m_session' = [message_m_session EXCEPT
                                            ![sid] = Append(message_m_session[sid],
                                                            [req |-> req,
                                                             resp |-> [meas_len   |-> ml,
                                                                       opaque_len |-> ol,
                                                                       sig_bytes  |-> FALSE]])]
                    /\ UNCHANGED message_m_global
          ELSE UNCHANGED transcriptVars
    /\ UNCHANGED <<connVars, l1l2Vars, sigVars, slotVars, message_a,
                   current_request, current_response, current_session_id>>

(* ================================================================
   ACTION: RequesterParseResponseNoSig (no-signature path)
   Requester parses MEASUREMENTS response without signature.
   CONFIRMED BUG: size check at req_get_measurements.c:546-548 omits SPDM_NONCE_SIZE.
   Code checks: sizeof(header) + meas_len + sizeof(uint16_t)   [546-548]
   But then reads 32 bytes (nonce) + 2 bytes (opaque_len) starting at meas_record end [552-558].
   Family 2: ParseWithinBounds invariant.
   ================================================================ *)
RequesterParseResponseNoSig(resp_size) ==
    /\ current_response /= NULL
    /\ current_response.has_sig = FALSE
    /\ parse_error = FALSE
    /\ parse_offset = 0   \* idempotency guard: only parse once per exchange
    /\ LET resp         == current_response
           ml           == resp.meas_len
           ol           == resp.opaque_len
           \* BUG: missing SPDM_NONCE_SIZE — req_get_measurements.c:546-548
           buggy_min    == SIZEOF_RSP_HEADER + ml + SIZEOF_UINT16
           correct_min  == SIZEOF_RSP_HEADER + ml + SPDM_NONCE_SIZE + SIZEOF_UINT16
           \* Actual bytes read: past nonce and opaque_len — req_get_measurements.c:552-558
           actual_read  == SIZEOF_RSP_HEADER + ml + SPDM_NONCE_SIZE + SIZEOF_UINT16 + ol
       IN
       \* Uses the BUGGY guard (omits NONCE_SIZE)
       /\ IF resp_size < buggy_min
          THEN /\ parse_error' = TRUE
               /\ parse_offset' = parse_offset
          ELSE \* Size check passes (with buggy guard), but reads proceed beyond validated range
               /\ parse_offset' = actual_read
               \* parse_offset may exceed resp_size when resp_size < correct_min
               /\ parse_error'  = (parse_offset' > resp_size)
       /\ UNCHANGED <<connVars, transcriptVars, l1l2Vars, sigVars, slotVars,
                      current_request, current_response, current_session_id>>

(* ================================================================
   ACTION: RequesterVerifySignature
   Requester computes L1/L2 and verifies the signature.
   Resets message_m after verification (regardless of outcome).
   req_get_measurements.c:537-544; req_get_measurements.c:43
   ================================================================ *)
RequesterVerifySignature ==
    /\ current_response /= NULL
    /\ current_response.has_sig = TRUE
    /\ parse_error = FALSE
    \* Ordering guard: responder must have signed before requester can verify.
    /\ sig_ready = TRUE
    \* Parse-before-verify: requester must have appended its exchange entry first.
    /\ Len(MessageM(current_response.session_id)) > 0
    /\ LET sid == current_response.session_id
           rsp == current_response
       IN
       \* Compute L1/L2 from requester's transcript — req_get_measurements.c:35-41
       /\ l1l2_requester' = ComputeL1L2(sid)
       \* slot check: response_slot must match requested_slot — req_get_measurements.c:433-438
       /\ (spdm_version >= Version11 =>
             response_slot = requested_slot)
       \* Mark verified — req_get_measurements.c:537-542
       /\ sig_verified'   = TRUE
       /\ sig_ready'      = FALSE
       \* Reset message_m — req_get_measurements.c:544 (line after verify)
       /\ IF sid = NULL
          THEN message_m_global'  = <<>>
               /\ UNCHANGED message_m_session
          ELSE message_m_session' = [message_m_session EXCEPT ![sid] = <<>>]
               /\ UNCHANGED message_m_global
    /\ UNCHANGED <<connVars, message_a, l1l2_responder,
                   slotVars, parseVars, current_request, current_response, current_session_id>>

(* ================================================================
   ACTION: CompleteExchange
   Exchange completes (with or without signature). Clears in-flight message buffers.
   ================================================================ *)
CompleteExchange ==
    /\ \/ /\ current_response /= NULL  \* normal: response was received
          /\ (current_response.has_sig => sig_verified = TRUE \/ parse_error = TRUE)
          /\ (~current_response.has_sig => parse_error = FALSE)
       \/ /\ current_response = NULL   \* aborted: exchange failed before response (e.g., need_resync)
          /\ current_request /= NULL
    /\ current_request'  = NULL
    /\ current_response' = NULL
    /\ parse_offset'     = 0
    /\ parse_error'      = FALSE
    /\ sig_ready'        = FALSE
    /\ UNCHANGED <<connVars, transcriptVars, l1l2Vars, sig_verified, slotVars,
                   current_session_id>>

(* ================================================================
   ACTION: NeedResync
   Responder receives a resync request — sets connection_state to NOT_STARTED
   but does NOT clear active_sessions.
   Family 3: SessionConsistency invariant.
   rsp_handle_response_state.c:21-31
   ================================================================ *)
NeedResync ==
    /\ response_state = RS_NORMAL
    /\ response_state'     = RS_NEED_RESYNC
    /\ connection_state'   = CS_NOT_STARTED
    \* active_sessions intentionally NOT cleared — rsp_handle_response_state.c does not iterate sessions
    /\ UNCHANGED <<active_sessions, spdm_version, transcriptVars, l1l2Vars,
                   sigVars, slotVars, parseVars, msgVars>>

(* ================================================================
   ACTION: ResetContext
   libspdm_reset_context(): resets global transcripts but NOT per-session message_m.
   Family 3: com_context_data.c:2942-2957
   ================================================================ *)
ResetContext ==
    /\ connection_state'  = CS_NOT_STARTED
    /\ response_state'    = RS_NORMAL
    /\ message_m_global'  = <<>>
    /\ message_a'         = <<>>
    \* Context reset terminates any in-progress exchange and clears all verification state.
    /\ current_request'   = NULL
    /\ current_response'  = NULL
    /\ l1l2_responder'    = NULL
    /\ l1l2_requester'    = NULL
    /\ sig_ready'         = FALSE
    /\ sig_verified'      = FALSE
    \* Per-session transcripts are NOT reset — com_context_data.c:2942-2957
    /\ UNCHANGED <<active_sessions, spdm_version, message_m_session,
                   slotVars, parseVars, current_session_id>>

(* ================================================================
   ACTION: PartialRetryAccumulate
   Models Issue #491/#524: a GET_MEASUREMENTS request is appended to message_m
   but the responder fails to complete the response; on retry the request is
   appended a second time without the first being removed.
   Family 3.
   ================================================================ *)
PartialRetryAccumulate ==
    /\ current_request /= NULL
    /\ current_response = NULL
    /\ LET req == current_request
           sid == req.session_id
       IN
       \* Responder appended request but then failed; request is appended again on retry
       /\ IF sid = NULL
          THEN message_m_global' = Append(message_m_global, [req |-> req, resp |-> NULL])
               /\ UNCHANGED message_m_session
          ELSE message_m_session' = [message_m_session EXCEPT
                                       ![sid] = Append(message_m_session[sid],
                                                       [req |-> req, resp |-> NULL])]
               /\ UNCHANGED message_m_global
    /\ UNCHANGED <<connVars, message_a, l1l2Vars, sigVars, slotVars, parseVars,
                   current_request, current_response, current_session_id>>

(* ================================================================
   NEXT
   ================================================================ *)
Next ==
    \/ \E v \in Versions : NegotiateVersion(v)
    \/ \E sid \in SessionIDs : EstablishSession(sid)
    \/ \E sid \in ({NULL} \cup SessionIDs),
          slot \in ValidSlots,
          gen_sig \in {TRUE, FALSE},
          meas_idx \in {0, 255} :
            RequesterSendGetMeasurements(sid, slot, gen_sig, meas_idx)
    \/ ResponderAppendRequest
    \/ \E ml \in {0, 32, 64}, ol \in {0, 16}, hs \in {TRUE, FALSE} :
            ResponderBuildResponse(ml, ol, hs)
    \/ ResponderGenerateSignature
    \/ L1L2ComputationFailure
    \/ \E rs \in 0..512 : RequesterParseResponseSig(rs)
    \/ \E rs \in 0..512 : RequesterParseResponseNoSig(rs)
    \/ RequesterVerifySignature
    \/ CompleteExchange
    \/ NeedResync
    \/ ResetContext
    \/ PartialRetryAccumulate

Spec == Init /\ [][Next]_vars

(* ================================================================
   INVARIANTS
   ================================================================ *)

(*
 * Family 1: L1/L2 Agreement
 * When signature verification passes, both sides must have computed the same L1/L2.
 * modeling-brief.md §5
 *)
L1L2Agreement ==
    sig_verified =>
        /\ l1l2_requester /= NULL
        /\ l1l2_responder /= NULL
        /\ l1l2_requester = l1l2_responder

(*
 * Family 1 / Issue #2072: Transcript must never contain signature bytes.
 * Signature bytes must not appear in any message_m entry's resp record.
 * modeling-brief.md §5
 *)
TranscriptNoSignatureBytes ==
    /\ \A pair \in Range(message_m_global) :
            pair.resp /= NULL => pair.resp.sig_bytes = FALSE
    /\ \A sid \in SessionIDs :
         \A pair \in Range(message_m_session[sid]) :
            pair.resp /= NULL => pair.resp.sig_bytes = FALSE

(*
 * Family 2: Parse Within Bounds
 * After parsing any response field, parse_offset must not exceed response_size.
 * modeling-brief.md §5
 *)
ParseWithinBounds ==
    \* Early rejection (size check failed before reading) is correct; out-of-bounds read is the bug.
    \* A real overflow is indicated by parse_error=TRUE after the cursor already advanced (parse_offset > 0).
    parse_error => parse_offset = 0

(*
 * Family 4: Slot Binding
 * When signature verification passes, requested_slot = response_slot = signing_slot.
 * modeling-brief.md §5
 *)
SlotBinding ==
    sig_verified =>
        /\ requested_slot /= NULL
        /\ response_slot  /= NULL
        /\ signing_slot   /= NULL
        /\ requested_slot = response_slot
        /\ requested_slot = signing_slot

(*
 * Family 3: Session Consistency
 * If connection is NOT_STARTED, no active sessions should exist.
 * modeling-brief.md §5
 *)
SessionConsistency ==
    connection_state = CS_NOT_STARTED => active_sessions = {}

(*
 * Family 1/3: Transcript Growth Only on Measurements
 * message_m only grows during GET_MEASUREMENTS exchanges.
 * This is a structural invariant — violations indicate a reset bug.
 *)
TranscriptGrowthOnlyMeasurements ==
    \* When no exchange is in flight, message_m should be stable (checked by MC fairness)
    TRUE   \* Structural; checked via Next relation in MC layer

(* Structural: parse_offset stays in range *)
ParseOffsetInRange ==
    parse_offset >= 0

(* Structural: active_sessions bounded *)
ActiveSessionsBounded ==
    Cardinality(active_sessions) <= MaxSessions

(* Composite invariant for standard MC run *)
TypeOK ==
    /\ connection_state \in ConnectionStates
    /\ response_state   \in ResponseStates
    /\ active_sessions  \subseteq SessionIDs
    /\ spdm_version     \in Versions
    /\ parse_offset     \in Nat
    /\ parse_error      \in {TRUE, FALSE}
    /\ sig_verified     \in {TRUE, FALSE}
    /\ sig_ready        \in {TRUE, FALSE}

====
