--------------------------- MODULE base ---------------------------
(* SPDM GET_MEASUREMENTS Protocol Specification
 * Target: libspdm (DMTF SPDM Reference Implementation)
 * Category: A (Distributed / Message-Passing)
 *
 * This spec models the SPDM GET_MEASUREMENTS attestation protocol
 * with focus on version-dependent message handling and state validation.
 *)

EXTENDS Naturals, Sequences, FiniteSets, TLC

\* ============================================================================
\* Constants
\* ============================================================================

CONSTANT SPDM_VERSION_10, SPDM_VERSION_11, SPDM_VERSION_12, SPDM_VERSION_13
CONSTANT MAX_SLOT_COUNT  \* e.g., 8 in libspdm
CONSTANT SESSION_ID_MAX  \* e.g., 16 bit session ID
CONSTANT NULL_SESSION_ID  \* special value for unsecured session

\* ============================================================================
\* Assumptions
\* ============================================================================

ASSUME SPDM_VERSION_10 = 16 /\ SPDM_VERSION_11 = 17 /\
       SPDM_VERSION_12 = 18 /\ SPDM_VERSION_13 = 19

ASSUME MAX_SLOT_COUNT \in 1..16
ASSUME SESSION_ID_MAX \in 1..65536
ASSUME NULL_SESSION_ID = 0

\* ============================================================================
\* Helper Functions and Sets
\* ============================================================================

ValidSpdmVersions == {SPDM_VERSION_10, SPDM_VERSION_11, SPDM_VERSION_12, SPDM_VERSION_13}

IsValidVersion(v) == v \in ValidSpdmVersions

\* Whether this version supports slot_id_param in request
VersionSupportsSlotParam(v) == v \in {SPDM_VERSION_11, SPDM_VERSION_12, SPDM_VERSION_13}

\* Whether this version supports requester context
VersionSupportsContext(v) == v = SPDM_VERSION_13

\* Whether this version validates opaque data structure
VersionValidatesOpaqueData(v) == v \in {SPDM_VERSION_12, SPDM_VERSION_13}

\* ============================================================================
\* Protocol State Variables
\* ============================================================================

\* Role in this protocol endpoint
VARIABLE role  \* "requester" or "responder"

\* Negotiated SPDM version (from version negotiation)
VARIABLE spdm_version

\* Session state: "UNSECURED" | "SESSION_ESTABLISHED" | "SESSION_CLOSED"
VARIABLE session_state
VARIABLE session_id

\* Capabilities: what this endpoint supports
VARIABLE capabilities

\* ============================================================================
\* Message Variables (Category A: message passing)
\* ============================================================================

\* Outgoing requests (from requester to responder)
VARIABLE req_message

\* Outgoing responses (from responder to requester)
VARIABLE resp_message

\* ============================================================================
\* Extension Variables: Family 1 (Version-Dependent Message Format)
\* ============================================================================

\* What version format the requester sent (may not match negotiated spdm_version)
VARIABLE request_format_version

\* What version format responder should send response in
VARIABLE response_format_version

\* ============================================================================
\* Extension Variables: Family 2 (Session State Validation)
\* ============================================================================

\* Whether session validation has been performed for this measurement request
VARIABLE session_validated

\* Whether capabilities have been checked for this measurement request
VARIABLE capabilities_verified

\* ============================================================================
\* Extension Variables: Family 3 (Non-Atomic Signature Generation)
\* ============================================================================

\* Message M buffer (transcript for signature) state: "empty" | "has_request" | "has_request_and_response" | "signature_computed"
VARIABLE message_m_state

\* Number of append operations to message M
VARIABLE transcript_appended_count

\* Whether message M was reset after signature generation
VARIABLE message_m_reset_done

\* Accumulated signature (if computed)
VARIABLE computed_signature

\* ============================================================================
\* Extension Variables: Family 4 (Opaque Data Validation)
\* ============================================================================

\* Whether opaque data validation is enabled based on version
VARIABLE opaque_data_validation_enabled

\* Whether opaque data structure was validated (if present)
VARIABLE opaque_data_validated

\* ============================================================================
\* Extension Variables: Family 5 (Requester Context Binding)
\* ============================================================================

\* Requester context sent in request (8 bytes, or NULL for v<1.3)
VARIABLE requester_context_sent

\* Requester context received in response
VARIABLE requester_context_received

\* Whether context has been validated to match
VARIABLE requester_context_validated

\* ============================================================================
\* Extension Variables: Family 6 (Signature Slot ID Consistency)
\* ============================================================================

\* Slot ID used for signature generation
VARIABLE slot_id_used

\* Whether slot ID has been validated
VARIABLE slot_id_validated

\* Certificate chain available for each slot
VARIABLE cert_chain_available

\* Whether public key provision is available
VARIABLE public_key_available

\* ============================================================================
\* All Variables Declaration
\* ============================================================================

vars == <<role, spdm_version, session_state, session_id, capabilities,
          req_message, resp_message,
          request_format_version, response_format_version,
          session_validated, capabilities_verified,
          message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
          opaque_data_validation_enabled, opaque_data_validated,
          requester_context_sent, requester_context_received, requester_context_validated,
          slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

protocolVars == <<role, spdm_version, session_state, session_id, capabilities, req_message, resp_message>>

extensionVars == <<request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Initialization
\* ============================================================================

Init ==
    /\ role \in {"requester", "responder"}
    /\ spdm_version = SPDM_VERSION_10  \* Start with v1.0, can be negotiated higher
    /\ session_state = "UNSECURED"
    /\ session_id = NULL_SESSION_ID
    /\ capabilities = {}
    /\ req_message = [type |-> "IDLE"]
    /\ resp_message = [type |-> "IDLE"]
    /\ request_format_version = SPDM_VERSION_10
    /\ response_format_version = SPDM_VERSION_10
    /\ session_validated = FALSE
    /\ capabilities_verified = FALSE
    /\ message_m_state = "empty"
    /\ transcript_appended_count = 0
    /\ message_m_reset_done = FALSE
    /\ computed_signature = FALSE
    /\ opaque_data_validation_enabled = FALSE
    /\ opaque_data_validated = FALSE
    /\ requester_context_sent = 0  \* 0 means NULL
    /\ requester_context_received = 0
    /\ requester_context_validated = FALSE
    /\ slot_id_used = 255  \* 255 means "not yet selected"
    /\ slot_id_validated = FALSE
    /\ cert_chain_available = [i \in 0..MAX_SLOT_COUNT |-> FALSE]
    /\ public_key_available = FALSE

\* ============================================================================
\* Actions: Version Negotiation
\* ============================================================================

\* Requester initiates version negotiation and selects version
NegotiateVersionRequester(v) ==
    /\ role = "requester"
    /\ IsValidVersion(v)
    /\ v >= spdm_version  \* Can only negotiate up or stay same
    /\ spdm_version' = v
    /\ request_format_version' = v  \* Request will use negotiated version
    /\ UNCHANGED <<role, session_state, session_id, capabilities, resp_message,
                   response_format_version, session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>
    /\ UNCHANGED req_message

\* Responder negotiates version from requester request
NegotiateVersionResponder(v) ==
    /\ role = "responder"
    /\ IsValidVersion(v)
    /\ v <= spdm_version  \* Responder accepts v or lower
    /\ spdm_version' = v  \* [ libspdm_rsp_measurements.c:79 version negotiation ]
    /\ response_format_version' = v
    /\ UNCHANGED <<role, session_state, session_id, capabilities, req_message, resp_message,
                   request_format_version, session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Session Management
\* ============================================================================

\* Establish a secured session (e.g., after KEY_EXCHANGE_RSP)
EstablishSession(sid) ==
    /\ session_id = NULL_SESSION_ID
    /\ sid /= NULL_SESSION_ID
    /\ session_state' = "SESSION_ESTABLISHED"  \* [ libspdm_rsp_measurements.c:128-130 session check ]
    /\ session_id' = sid
    /\ UNCHANGED <<role, spdm_version, capabilities, req_message, resp_message,
                   request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Requester - Build GET_MEASUREMENTS Request
\* ============================================================================

\* Requester builds and sends GET_MEASUREMENTS request
\* Includes version-dependent fields
\* [ libspdm_req_get_measurements.c:168-335 ]
BuildGetMeasurementsRequest(sig_requested, context) ==
    /\ role = "requester"
    /\ req_message = [type |-> "IDLE"]  \* No pending request
    /\ LET req == [type |-> "GET_MEASUREMENTS",
                   version |-> request_format_version,
                   signature_requested |-> sig_requested,
                   slot_id_param |-> IF VersionSupportsSlotParam(request_format_version) THEN 0 ELSE 255,
                   requester_context |-> IF VersionSupportsContext(request_format_version) THEN context ELSE 0]
       IN /\ req_message' = req
          /\ requester_context_sent' = IF VersionSupportsContext(request_format_version) THEN context ELSE 0
          \* [ libspdm_req_get_measurements.c:322-335 requester context handling ]
    /\ message_m_state' = "empty"  \* Reset for new measurement
    /\ transcript_appended_count' = 0
    /\ message_m_reset_done' = FALSE
    /\ session_validated' = FALSE
    /\ capabilities_verified' = FALSE
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   response_format_version,
                   message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>
    /\ UNCHANGED resp_message

\* ============================================================================
\* Actions: Responder - Receive and Validate Request
\* ============================================================================

\* Responder receives GET_MEASUREMENTS request and validates it
\* [ libspdm_rsp_measurements.c:113-166 validation sequence ]
ReceiveGetMeasurementsRequest ==
    /\ role = "responder"
    /\ req_message.type = "GET_MEASUREMENTS"
    /\ response_format_version' = spdm_version  \* Response uses negotiated version
    /\ request_format_version' = req_message.version  \* Track what was sent

    \* Version consistency check (Family 1)
    \* [ libspdm_rsp_measurements.c:79 version check ]
    /\ req_message.version = spdm_version  \* Must match negotiated version

    \* Validate slot_id_param if present in version
    \* [ libspdm_rsp_measurements.c:185-206 slot_id validation ]
    /\ IF VersionSupportsSlotParam(request_format_version)
       THEN req_message.slot_id_param \in 0..(MAX_SLOT_COUNT-1) \cup {15}  \* 15 means "public key provision"
       ELSE TRUE

    \* Session validation (Family 2)
    \* [ libspdm_rsp_measurements.c:113-130 session checks ]
    /\ session_validated' = (session_state = "SESSION_ESTABLISHED") \/ (session_id = NULL_SESSION_ID)

    \* Capability validation (Family 2)
    \* [ libspdm_rsp_measurements.c:159-166 capability checks ]
    /\ capabilities_verified' =
       IF req_message.signature_requested
       THEN "MEAS_CAP_SIG" \in capabilities
       ELSE "MEAS_CAP_NO_SIG" \in capabilities

    \* Opaque data validation setup (Family 4)
    \* [ libspdm_com_opaque_data.c:277 version-dependent validation ]
    /\ opaque_data_validation_enabled' = VersionValidatesOpaqueData(spdm_version)

    \* UNCHANGED other variables
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>
    /\ UNCHANGED resp_message

\* ============================================================================
\* Actions: Responder - Append Request to Transcript
\* ============================================================================

\* Responder appends request to message M buffer (first step of signature transcript)
\* [ libspdm_rsp_measurements.c:494-497 ]
AppendRequestToTranscript ==
    /\ role = "responder"
    /\ req_message.type = "GET_MEASUREMENTS"
    /\ message_m_state = "empty"
    /\ message_m_state' = "has_request"  \* Move to intermediate state (Family 3)
    /\ transcript_appended_count' = transcript_appended_count + 1
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, resp_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Responder - Append Response to Transcript
\* ============================================================================

\* Responder appends response (without signature yet) to message M
\* [ libspdm_rsp_measurements.c:505-506 ]
AppendResponseToTranscript ==
    /\ role = "responder"
    /\ message_m_state = "has_request"
    /\ message_m_state' = "has_request_and_response"  \* Non-atomic point (Family 3)
    /\ transcript_appended_count' = transcript_appended_count + 1
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, resp_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Responder - Validate Slot ID for Signature
\* ============================================================================

\* Responder validates slot_id used for signature and selects key source
\* [ libspdm_rsp_measurements.c:421-449 slot validation ]
ValidateSlotIDForSignature(slot) ==
    /\ role = "responder"
    /\ req_message.signature_requested = TRUE
    /\ req_message.type = "GET_MEASUREMENTS"
    /\ message_m_state = "has_request_and_response"

    \* Validate slot ID value (Family 6)
    /\ slot \in 0..(MAX_SLOT_COUNT-1) \cup {15}
    /\ slot_id_used' = slot

    \* Check if we have the appropriate key source
    \* If slot < MAX_SLOT_COUNT: need certificate chain
    \* If slot = 15: need public key provision
    /\ IF slot = 15
       THEN public_key_available = TRUE
       ELSE cert_chain_available[slot] = TRUE

    /\ slot_id_validated' = TRUE  \* (Family 6)

    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, resp_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Responder - Compute Signature (Family 3: Non-Atomic)
\* ============================================================================

\* Responder computes signature over message M (L1/L2 transcript)
\* This is separate from reset to expose crash window
\* [ libspdm_rsp_measurements.c:517-527 signature generation ]
ComputeSignature ==
    /\ role = "responder"
    /\ req_message.signature_requested = TRUE
    /\ message_m_state = "has_request_and_response"
    /\ slot_id_validated = TRUE
    /\ computed_signature' = TRUE  \* Abstraction: signature is computed
    /\ message_m_state' = "signature_computed"  \* (Family 3: non-atomic point)
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, resp_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   transcript_appended_count, message_m_reset_done,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Responder - Reset Transcript After Signature (Family 3)
\* ============================================================================

\* Responder resets message M after signature generation
\* [ libspdm_rsp_measurements.c:529 ]
ResetTranscriptAfterSignature ==
    /\ role = "responder"
    /\ (message_m_state = "signature_computed" \/ message_m_state = "has_request_and_response")
    /\ message_m_state' = "empty"
    /\ message_m_reset_done' = TRUE
    /\ transcript_appended_count' = 0
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, resp_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Responder - Build and Send Response (Family 5: Context Handling)
\* ============================================================================

\* Responder builds and sends GET_MEASUREMENTS response
\* [ libspdm_rsp_measurements.c:79-533 ]
SendGetMeasurementsResponse(context_echo) ==
    /\ role = "responder"
    /\ req_message.type = "GET_MEASUREMENTS"
    /\ resp_message = [type |-> "IDLE"]  \* No pending response

    \* For v1.3+: echo back the requester context
    \* [ libspdm_rsp_measurements.c:487-492 context echo ]
    /\ IF VersionSupportsContext(response_format_version)
       THEN requester_context_received' = context_echo
       ELSE requester_context_received' = 0

    /\ resp_message' = [type |-> "MEASUREMENTS",
                        version |-> response_format_version,
                        signature_included |-> req_message.signature_requested,
                        requester_context |-> context_echo]

    \* Reset state for next measurement request
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Requester - Validate Context Echo (Family 5)
\* ============================================================================

\* Requester validates that response context matches sent context (v1.3+)
\* [ libspdm_req_get_measurements.c:511-517 context validation ]
ValidateContextEcho ==
    /\ role = "requester"
    /\ resp_message.type = "MEASUREMENTS"

    /\ IF VersionSupportsContext(request_format_version)
       THEN \* Must validate context before appending to transcript (Family 5)
            /\ requester_context_sent /= 0  \* Non-zero context was sent
            /\ resp_message.requester_context = requester_context_sent  \* Echo must match
            /\ requester_context_validated' = TRUE
       ELSE \* v < 1.3: no context field
            /\ requester_context_validated' = FALSE

    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, resp_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* ============================================================================
\* Actions: Requester - Verify Signature (Family 6: Slot Consistency)
\* ============================================================================

\* Requester verifies signature over L1/L2 transcript using slot_id
\* [ libspdm_req_get_measurements.c:11-94 signature verification ]
VerifyMeasurementSignature(slot) ==
    /\ role = "requester"
    /\ resp_message.type = "MEASUREMENTS"
    /\ resp_message.signature_included = TRUE

    \* Validate slot ID (Family 6)
    /\ slot \in 0..(MAX_SLOT_COUNT-1) \cup {15}
    /\ slot_id_used' = slot

    \* Requester must look up key from same source as responder
    \* [ libspdm_req_get_measurements.c:66-93 key lookup ]
    /\ IF slot = 15
       THEN public_key_available = TRUE  \* Public key provision path
       ELSE cert_chain_available[slot] = TRUE  \* Certificate chain path

    /\ slot_id_validated' = TRUE
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                   req_message, resp_message, request_format_version, response_format_version,
                   session_validated, capabilities_verified,
                   message_m_state, transcript_appended_count, message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   cert_chain_available, public_key_available>>

\* ============================================================================
\* Helpers: Fault Injection (for MC layer to wrap with bounds)
\* ============================================================================

\* Crash: reset endpoint state to initial (except persistent data)
\* Used to test crash-recovery windows in Family 3
Crash ==
    /\ \* Transient state is lost
       message_m_state' = "empty"
    /\ message_m_reset_done' = FALSE
    /\ \* Persistent state remains (but could be partial)
       UNCHANGED <<role, spdm_version, session_state, session_id, capabilities,
                  req_message, resp_message, request_format_version, response_format_version,
                  session_validated, capabilities_verified,
                  transcript_appended_count, computed_signature,
                  opaque_data_validation_enabled, opaque_data_validated,
                  requester_context_sent, requester_context_received, requester_context_validated,
                  slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* Message loss: drop response before requester receives it
MessageLoss ==
    /\ resp_message.type = "MEASUREMENTS"
    /\ resp_message' = [type |-> "IDLE"]
    /\ UNCHANGED <<role, spdm_version, session_state, session_id, capabilities, req_message,
                   request_format_version, response_format_version,
                   session_validated, capabilities_verified, message_m_state, transcript_appended_count,
                   message_m_reset_done, computed_signature,
                   opaque_data_validation_enabled, opaque_data_validated,
                   requester_context_sent, requester_context_received, requester_context_validated,
                   slot_id_used, slot_id_validated, cert_chain_available, public_key_available>>

\* Network reorder: version mismatch between request and response
\* (simulates version negotiation failure between request and response)
VersionMismatch ==
    /\ role = "responder"
    /\ req_message.type = "GET_MEASUREMENTS"
    /\ response_format_version /= req_message.version
    /\ \* Responder detects mismatch and rejects
       UNCHANGED vars

\* ============================================================================
\* Next State
\* ============================================================================

Next ==
    \* Requester actions
    \/ \E v \in ValidSpdmVersions : NegotiateVersionRequester(v)
    \/ \E sig \in {TRUE, FALSE} : \E ctx \in {0, 1} : BuildGetMeasurementsRequest(sig, ctx)
    \/ ValidateContextEcho
    \/ \E slot \in 0..(MAX_SLOT_COUNT-1) \cup {15} : VerifyMeasurementSignature(slot)

    \* Responder actions
    \/ \E v \in ValidSpdmVersions : NegotiateVersionResponder(v)
    \/ \E sid \in 1..SESSION_ID_MAX : EstablishSession(sid)
    \/ ReceiveGetMeasurementsRequest
    \/ AppendRequestToTranscript
    \/ AppendResponseToTranscript
    \/ \E slot \in 0..(MAX_SLOT_COUNT-1) \cup {15} : ValidateSlotIDForSignature(slot)
    \/ ComputeSignature
    \/ ResetTranscriptAfterSignature
    \/ \E ctx \in {0, 1} : SendGetMeasurementsResponse(ctx)

    \* Fault injection
    \/ Crash
    \/ MessageLoss
    \/ VersionMismatch

\* ============================================================================
\* Invariants: Core Safety Properties
\* ============================================================================

\* A version was negotiated (not stuck in initial state)
VersionNegotiated == spdm_version \in ValidSpdmVersions

\* Message format versions don't exceed negotiated version (Family 1)
VersionConsistency ==
    /\ request_format_version <= spdm_version
    /\ response_format_version <= spdm_version

\* If session is required, it's properly established (Family 2)
SessionValidatedBeforeMeasurement ==
    /\ req_message.type = "GET_MEASUREMENTS" =>
       (session_validated = TRUE \/ session_state = "UNSECURED")

\* Capabilities validated before measurement collection (Family 2)
CapabilitiesValidatedBeforeMeasurement ==
    /\ req_message.type = "GET_MEASUREMENTS" =>
       capabilities_verified = TRUE

\* Transcript is reset after signature (Family 3)
TranscriptResetAfterSignature ==
    /\ computed_signature = TRUE =>
       <>(message_m_reset_done = TRUE)

\* Signature covers full transcript (Family 3)
SignatureCoversFullTranscript ==
    /\ computed_signature = TRUE =>
       (transcript_appended_count >= 2)  \* At least request + response

\* If opaque data validation is required, it was performed (Family 4)
OpaqueDataValidation ==
    /\ opaque_data_validation_enabled = TRUE =>
       (opaque_data_validated = TRUE)

\* Context is echoed correctly (Family 5)
ContextEchoedCorrectly ==
    /\ VersionSupportsContext(spdm_version) /\ (requester_context_sent /= 0) =>
       (requester_context_received = requester_context_sent)

\* Context validated before response finalized (Family 5)
ContextValidatedBeforeResponseAppend ==
    /\ resp_message.type = "MEASUREMENTS" =>
       (requester_context_validated = TRUE \/ ~VersionSupportsContext(spdm_version))

\* Slot ID used consistently between responder and requester (Family 6)
SlotIDConsistency ==
    /\ resp_message.type = "MEASUREMENTS" /\ resp_message.signature_included =>
       (slot_id_validated = TRUE)

\* ============================================================================
\* Invariants: Structural Sanity Checks
\* ============================================================================

TranscriptStateConsistent ==
    /\ message_m_state \in {"empty", "has_request", "has_request_and_response", "signature_computed"}

SlotIDValid ==
    /\ slot_id_used = 255 \/ slot_id_used \in 0..(MAX_SLOT_COUNT-1) \cup {15}

MessageQueueConsistent ==
    /\ req_message.type \in {"IDLE", "GET_MEASUREMENTS"}
    /\ resp_message.type \in {"IDLE", "MEASUREMENTS"}

=============================================================================
