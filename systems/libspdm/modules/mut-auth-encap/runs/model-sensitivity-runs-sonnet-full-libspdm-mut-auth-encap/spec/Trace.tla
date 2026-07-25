---- MODULE Trace ----
\* =============================================================================
\* SPDM Encapsulated Mutual Authentication - Trace Validation Spec
\*
\* Replays implementation traces from libspdm against the base spec.
\* Category A (Distributed/Message-Passing): single linear trace with cursor l.
\*
\* Each action wrapper:
\*   1. Matches a trace event by name
\*   2. Calls the base spec action (which constrains primed variables)
\*   3. Validates post-state: primed spec variables must match trace-captured values
\*   4. Advances cursor l' = l + 1
\* =============================================================================
EXTENDS base, Naturals, Sequences, TLC, IOUtils, Json

\* -----------------------------------------------------------------------------
\* Trace loading
\* -----------------------------------------------------------------------------

\* JsonFile: path to the trace file (.ndjson).
\* Override with IOEnv.JSON for per-run selection.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* -----------------------------------------------------------------------------
\* Cursor variable
\* -----------------------------------------------------------------------------

VARIABLES l   \* trace cursor; TraceLog[l] is the current event

\* -----------------------------------------------------------------------------
\* Mapping: trace field values -> spec constants
\* -----------------------------------------------------------------------------

\* Map response_state string to spec constant
TraceResponseState(s) ==
    CASE s = "NORMAL"           -> RS_NORMAL
      [] s = "PROCESSING_ENCAP" -> RS_PROCESSING_ENCAP
      [] OTHER                  -> RS_NORMAL

\* Map op_code integer to spec constant (SPDM numeric values)
TraceOpCode(v) ==
    CASE v = 0  -> OP_NONE
      [] v = 1  -> OP_GET_DIGESTS         \* SPDM_GET_DIGESTS
      [] v = 2  -> OP_GET_CERTIFICATE     \* SPDM_GET_CERTIFICATE
      [] v = 17 -> OP_CHALLENGE           \* SPDM_CHALLENGE (0x11)
      [] OTHER  -> OP_NONE

\* Map variant string to spec constant
TraceVariant(s) ==
    CASE s = "NO_ENCAP"           -> VAR_NO_ENCAP
      [] s = "WITH_ENCAP_REQUEST" -> VAR_WITH_ENCAP_REQUEST
      [] s = "WITH_GET_DIGESTS"   -> VAR_WITH_GET_DIGESTS
      [] s = "BASIC_PK"           -> VAR_BASIC_PK
      [] s = "BASIC_CERT"         -> VAR_BASIC_CERT
      [] OTHER                    -> VAR_NO_ENCAP

\* -----------------------------------------------------------------------------
\* Event predicate
\* -----------------------------------------------------------------------------

IsEvent(name) == TraceLog[l].event = name

\* -----------------------------------------------------------------------------
\* Post-state validator (action predicate: checks primed spec variables)
\*
\* After any action, the trace event's *_after fields must match the spec's
\* post-state. Using primed variables ensures we validate what the action
\* produced, not what was there before.
\* -----------------------------------------------------------------------------
ValidateEncapState(e) ==
    /\ cur_op'        = TraceOpCode(e.cur_op_after)
    /\ request_id'    = e.request_id_after
    /\ response_state' = TraceResponseState(e.response_state_after)

\* -----------------------------------------------------------------------------
\* Bootstrap: TraceInit
\* Matches the first "init_encap_state" trace event. Sets all spec variables
\* from the captured initial state (may differ from base Init for non-default
\* starting conditions).
\* -----------------------------------------------------------------------------
TraceInit ==
    /\ l = 1
    /\ IsEvent("init_encap_state")
    /\ LET e == TraceLog[1]
       IN
       /\ variant        = TraceVariant(e.variant)
       /\ op_sequence    = VariantOpSequence(TraceVariant(e.variant))
       /\ cur_op         = TraceOpCode(e.cur_op)
       /\ request_id     = e.request_id
       /\ response_state = TraceResponseState(e.response_state)
       \* resp_authenticated may already be TRUE at init time:
       \* req_challenge.c:380 sets AUTHENTICATED before libspdm_encapsulated_request (line 389).
       \* The harness captures this in the init event's resp_authenticated field.
       /\ resp_authenticated     = e.resp_authenticated
       /\ mutually_authenticated = FALSE
       /\ slot_id_ok    = FALSE
       /\ slot_mask_ok  = FALSE
       /\ cert_hash_ok  = FALSE
       /\ encap_error   = FALSE
       /\ cert_chain_received = FALSE

\* -----------------------------------------------------------------------------
\* Action wrappers
\* -----------------------------------------------------------------------------

\* TraceInitEncapState: cursor-advance for the init event consumed by TraceInit.
\* The spec variables are already set; just advance l.
TraceInitEncapState ==
    /\ l = 1
    /\ IsEvent("init_encap_state")
    /\ l' = l + 1
    /\ UNCHANGED vars

\* TraceVerifyResponder: Requester authenticates Responder.
\* req_challenge.c:380 sets connection_state = AUTHENTICATED.
TraceVerifyResponder ==
    /\ IsEvent("verify_responder")
    /\ VerifyResponder
    \* Post-state: encap fields unchanged; resp_authenticated' = TRUE (set by VerifyResponder)
    /\ LET e == TraceLog[l] IN ValidateEncapState(e)
    /\ l' = l + 1

\* TraceGetEncapsulatedRequest: Requester sends GET_ENCAPSULATED_REQUEST.
\* rsp_encap_response.c:269-373
TraceGetEncapsulatedRequest ==
    /\ IsEvent("get_encapsulated_request")
    /\ GetEncapsulatedRequest
    /\ LET e == TraceLog[l] IN ValidateEncapState(e)
    /\ l' = l + 1

\* TraceDeliverEncapResponseDigests: Requester delivers DELIVER with DIGESTS.
\* rsp_encap_response.c:375-493 + libspdm_process_encap_response_digest
TraceDeliverEncapResponseDigests ==
    /\ IsEvent("deliver_encap_digests")
    /\ DeliverEncapResponseDigests
    /\ LET e == TraceLog[l] IN ValidateEncapState(e)
    /\ l' = l + 1

\* TraceDeliverEncapResponseCertificate: Requester delivers DELIVER with CERTIFICATE.
\* rsp_encap_get_certificate.c:297-334 (full chain received)
TraceDeliverEncapResponseCertificate ==
    /\ IsEvent("deliver_encap_certificate")
    /\ DeliverEncapResponseCertificate
    /\ LET e == TraceLog[l] IN
           /\ ValidateEncapState(e)
           /\ cert_chain_received' = TRUE
    /\ l' = l + 1

\* TraceDeliverEncapResponseChallengeAuth: Requester delivers CHALLENGE_AUTH.
\* rsp_encap_challenge.c:80-268 (success path only)
TraceDeliverEncapResponseChallengeAuth ==
    /\ IsEvent("deliver_encap_challenge_auth")
    /\ DeliverEncapResponseChallengeAuth
    /\ LET e == TraceLog[l] IN
           /\ ValidateEncapState(e)
           /\ mutually_authenticated' = TRUE
           /\ slot_id_ok'   = TRUE
           /\ slot_mask_ok' = TRUE
           /\ cert_hash_ok' = TRUE
    /\ l' = l + 1

\* TraceEncapResponseNotReady: Requester sends ERROR(ResponseNotReady).
\* rsp_encap_response.c:149-152 -> clean termination
TraceEncapResponseNotReady ==
    /\ IsEvent("encap_not_ready")
    /\ EncapResponseNotReady
    /\ LET e == TraceLog[l] IN ValidateEncapState(e)
    /\ l' = l + 1

\* TraceEncapError: Non-NOT_READY error; partial reset (Family 4 bug path).
\* rsp_encap_response.c:467-470 or rsp_encap_response.c:359-363
TraceEncapError ==
    /\ IsEvent("encap_error")
    /\ EncapError
    /\ LET e == TraceLog[l] IN
           /\ ValidateEncapState(e)
           /\ encap_error' = TRUE
    /\ l' = l + 1

\* -----------------------------------------------------------------------------
\* No silent actions needed.
\* libspdm is single-threaded synchronous: every state transition has a trace event.
\* -----------------------------------------------------------------------------

\* -----------------------------------------------------------------------------
\* TraceNext
\* -----------------------------------------------------------------------------
TraceNext ==
    /\ l <= Len(TraceLog)
    /\ \/ TraceInitEncapState
       \/ TraceVerifyResponder
       \/ TraceGetEncapsulatedRequest
       \/ TraceDeliverEncapResponseDigests
       \/ TraceDeliverEncapResponseCertificate
       \/ TraceDeliverEncapResponseChallengeAuth
       \/ TraceEncapResponseNotReady
       \/ TraceEncapError

\* -----------------------------------------------------------------------------
\* TraceMatched: temporal property - entire trace must be consumed.
\* Required in Trace.cfg; without it TLC reports "no errors" even when l never advances.
\* -----------------------------------------------------------------------------
TraceMatched == <>(l > Len(TraceLog))

\* -----------------------------------------------------------------------------
\* TraceSpec
\* -----------------------------------------------------------------------------
TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>> /\ WF_<<vars,l>>(TraceNext)

====
