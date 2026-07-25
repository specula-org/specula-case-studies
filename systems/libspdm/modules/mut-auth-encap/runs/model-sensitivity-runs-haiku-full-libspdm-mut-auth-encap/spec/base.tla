---- MODULE base ----
(* libspdm Encapsulated Mutual Authentication Protocol
   Bug-family driven specification for SPDM mutual authentication
   with encapsulated message flow (Requester-Responder pattern).

   Reference: libspdm_rsp_encap_challenge.c and libspdm_req_encap_challenge_auth.c
*)

EXTENDS Naturals, Sequences, FiniteSets

(* Constants *)
CONSTANT Hash_Sha256, Hash_Sha384, Hash_Sha512
CONSTANT AsymAlg_ECDSA_P256, AsymAlg_ECDSA_P384, AsymAlg_ECDSA_P521
CONSTANT Version_11, Version_12, Version_13
CONSTANT NONCE_SIZE
CONSTANT MAX_OPAQUE_DATA_SIZE
CONSTANT MAX_SIGNATURE_SIZE
CONSTANT MAX_REQ_CONTEXT_SIZE

(* State constants *)
CONSTANT STATE_UNINITIALIZED, STATE_CHALLENGE_SENT, STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED
CONSTANT STATE_AUTHENTICATED

(* Assume constraints *)
ASSUME NONCE_SIZE > 0
ASSUME MAX_OPAQUE_DATA_SIZE > 0
ASSUME MAX_SIGNATURE_SIZE > 0

(* Hash size mapping *)
HashSize(algo) ==
    CASE algo = Hash_Sha256 -> 32
      [] algo = Hash_Sha384 -> 48
      [] algo = Hash_Sha512 -> 64

(* Signature size mapping *)
SigSize(algo) ==
    CASE algo = AsymAlg_ECDSA_P256 -> 64
      [] algo = AsymAlg_ECDSA_P384 -> 96
      [] algo = AsymAlg_ECDSA_P521 -> 132

(* Struct field size mapping *)
StructSize(name) ==
    CASE name = "challenge_auth_response" -> 2  (* Header: 2 bytes *)
      [] name = "uint16" -> 2

(* === EXTENSION VARIABLES: Driven by Bug Families === *)

(* Base state machine variables *)
VARIABLE requester_state           \* Family 1: Connection state from requester perspective
VARIABLE responder_state           \* Family 1: Connection state from responder perspective
VARIABLE connection_state          \* Synthesized state: consensus between requester/responder

(* Extension: Family 2 - Version-Dependent Field Handling *)
VARIABLE protocol_version          \* Negotiated SPDM version (11, 12, or 13)

(* Extension: Family 5 - Message Transcript Management *)
VARIABLE message_transcript        \* Sequence of all appended messages
VARIABLE transcript_complete       \* Boolean: whether all expected messages appended

(* Extension: Family 1 - Non-Atomic State Transitions *)
VARIABLE signature_verified        \* Boolean: signature verification success
VARIABLE pending_state_transition  \* Boolean: state transition in progress

(* Extension: Family 3 - Buffer Accounting *)
VARIABLE response_buffer_size      \* Total allocated response buffer size
VARIABLE opaque_data_offset        \* Byte offset where opaque_data starts in response
VARIABLE opaque_data_size          \* Calculated size of opaque_data region
VARIABLE hash_size                 \* Depends on negotiated hash algorithm
VARIABLE signature_size            \* Depends on negotiated asymmetric algorithm

(* Extension: Family 4 - Message Buffer Reset *)
VARIABLE buffer_reset_status       \* Success/failure of buffer reset operation

(* Extension: Family 2 - Request Context Echo *)
VARIABLE req_context               \* Request context for SPDM 1.3+
VARIABLE req_context_echo_match    \* Boolean: whether echoed context matches request

(* Request/Response message tracking *)
VARIABLE last_request              \* Cached challenge request
VARIABLE last_response             \* Cached challenge auth response

(* === GROUPED VARIABLES FOR UNCHANGED CLAUSES === *)
vars == <<requester_state, responder_state, connection_state,
          protocol_version, message_transcript, transcript_complete,
          signature_verified, pending_state_transition,
          response_buffer_size, opaque_data_offset, opaque_data_size,
          hash_size, signature_size, buffer_reset_status,
          req_context, req_context_echo_match,
          last_request, last_response>>

(* === INVARIANT DEFINITIONS === *)

(* Standard Protocol Invariants *)
TypeOK ==
    /\ requester_state \in {STATE_UNINITIALIZED, STATE_CHALLENGE_SENT,
                           STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED, STATE_AUTHENTICATED}
    /\ responder_state \in {STATE_UNINITIALIZED, STATE_CHALLENGE_SENT,
                           STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED, STATE_AUTHENTICATED}
    /\ connection_state \in {STATE_UNINITIALIZED, STATE_CHALLENGE_SENT,
                            STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED, STATE_AUTHENTICATED}
    /\ protocol_version \in {Version_11, Version_12, Version_13}
    /\ message_transcript \in Seq(STRING)
    /\ transcript_complete \in BOOLEAN
    /\ signature_verified \in BOOLEAN
    /\ pending_state_transition \in BOOLEAN
    /\ response_buffer_size \in Nat
    /\ opaque_data_offset \in Nat
    /\ opaque_data_size \in Nat
    /\ hash_size \in {32, 48, 64}
    /\ signature_size > 0
    /\ buffer_reset_status \in {"success", "failure", "pending"}
    /\ req_context_echo_match \in BOOLEAN

(* Bug-Family Invariants *)

(* Family 1: Non-Atomic State Transitions *)
AuthenticatedImplesVerified ==
    connection_state = STATE_AUTHENTICATED => signature_verified = TRUE

NoPartialStateTransition ==
    /\ pending_state_transition = TRUE =>
       connection_state \in {STATE_UNINITIALIZED, STATE_CHALLENGE_SENT,
                            STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED}
    /\ pending_state_transition = FALSE =>
       (connection_state = STATE_AUTHENTICATED => signature_verified = TRUE)

(* Family 2: Version-Dependent Field Handling *)
VersionConsistency ==
    /\ protocol_version \in {Version_11, Version_12, Version_13}
    /\ (protocol_version >= Version_13 => Len(req_context) = MAX_REQ_CONTEXT_SIZE \/ req_context = <<>>)

RequestContextEcho ==
    /\ protocol_version >= Version_13 =>
       (signature_verified => req_context_echo_match = TRUE)

(* Family 3: Buffer Bounds *)
BufferBoundsRespected ==
    /\ opaque_data_size <= MAX_OPAQUE_DATA_SIZE
    /\ opaque_data_offset + opaque_data_size <= response_buffer_size
    /\ response_buffer_size > 0 =>
       (opaque_data_offset + opaque_data_size + signature_size <= response_buffer_size)

(* Family 5: Message Transcript *)
TranscriptBeforeSignature ==
    signature_verified = TRUE => transcript_complete = TRUE

(* === INITIALIZATION === *)

Init ==
    /\ requester_state = STATE_UNINITIALIZED
    /\ responder_state = STATE_UNINITIALIZED
    /\ connection_state = STATE_UNINITIALIZED
    /\ protocol_version = Version_11
    /\ message_transcript = <<>>
    /\ transcript_complete = FALSE
    /\ signature_verified = FALSE
    /\ pending_state_transition = FALSE
    /\ response_buffer_size = 0
    /\ opaque_data_offset = 0
    /\ opaque_data_size = 0
    /\ hash_size = 32
    /\ signature_size = 64
    /\ buffer_reset_status = "pending"
    /\ req_context = <<>>
    /\ req_context_echo_match = FALSE
    /\ last_request = <<"", "">>
    /\ last_response = <<"", "">>

(* === ACTIONS === *)

(* libspdm_get_encap_request_challenge (responder side)
   Responder initiates the encapsulated challenge request.

   Source: libspdm_rsp_encap_challenge.c:12-78
*)
ResponderGetEncapRequestChallenge ==
    /\ responder_state = STATE_UNINITIALIZED
    /\ protocol_version \in {Version_11, Version_12, Version_13}  (* Pre-negotiated version *)

    (* Line 62-63: Buffer reset *)
    /\ buffer_reset_status' = "success"

    (* Line 44-48: Set request header with negotiated version *)
    /\ last_request' = <<"challenge_request", protocol_version>>

    (* Line 48-52: Generate random nonce *)
    /\ TRUE (* nonce generation succeeds *)

    (* Line 54-60: For version 1.3+, include req_context *)
    /\ IF protocol_version >= Version_13 THEN
         req_context' = <<"random_context">>
       ELSE
         req_context' = <<>>

    (* Line 67-70: Append to message buffer *)
    /\ message_transcript' = Append(message_transcript, "challenge_request")

    /\ responder_state' = STATE_CHALLENGE_SENT
    /\ UNCHANGED <<requester_state, connection_state, protocol_version, transcript_complete,
                  signature_verified, pending_state_transition,
                  response_buffer_size, opaque_data_offset, opaque_data_size,
                  hash_size, signature_size, req_context_echo_match, last_response>>

(* libspdm_get_encap_response_challenge_auth (requester side)
   Requester generates the challenge auth response.

   Source: libspdm_req_encap_challenge_auth.c:12-237
*)
RequesterGetEncapResponseChallengeAuth ==
    /\ responder_state = STATE_CHALLENGE_SENT
    /\ requester_state = STATE_UNINITIALIZED

    (* Line 97-98: Reset message buffer *)
    /\ buffer_reset_status' = "success"

    (* Line 44-48: Version check *)
    /\ last_request' = last_request  (* unchanged from request *)

    (* Line 64-71: Version-dependent request size calculation *)
    /\ LET req_size == IF protocol_version >= Version_13 THEN
                          "challenge_request_with_context"
                       ELSE
                          "challenge_request"
       IN TRUE

    (* Line 97-98: Buffer reset *)
    /\ buffer_reset_status' = "success"

    (* Line 100-108: Get hash and signature size *)
    /\ hash_size' = HashSize(Hash_Sha256)  (* Assume SHA256 *)
    /\ signature_size' = SigSize(AsymAlg_ECDSA_P256)  (* Assume ECDSA P256 *)

    (* Note: response_buffer_size is set by the trace validation wrapper *)
    (* Line 114-116: Assert buffer is large enough *)
    /\ response_buffer_size >= (StructSize("challenge_auth_response") +
                               hash_size' + NONCE_SIZE + 32 + signature_size')

    (* Line 169-173: Calculate opaque_data_size (CRITICAL: potential underflow)
       opaque_data_size = *response_size - (fixed_components_size)
       If response_size < fixed_components_size, underflow occurs.
       Note: opaque_data_size is set by the trace validation wrapper *)
    (* /\ opaque_data_size' = response_buffer_size - ... *)

    (* If opaque_data_size calculation underflows (wraps around), set offset *)
    /\ opaque_data_offset' = StructSize("challenge_auth_response") + hash_size' +
                            NONCE_SIZE + 32 + StructSize("uint16")

    (* Line 175-186: Generate opaque data *)
    /\ TRUE  (* opaque data generation succeeds *)

    (* Line 195-198: For version 1.3+, echo request context *)
    /\ IF protocol_version >= Version_13 THEN
         req_context_echo_match' = TRUE
       ELSE
         req_context_echo_match' = FALSE

    (* Line 214-219: Append request to message buffer *)
    /\ message_transcript' = Append(message_transcript, "challenge_request_appended")

    (* Line 221-228: Append response to message buffer *)
    /\ message_transcript' = Append(message_transcript', "challenge_auth_response_appended")
    /\ transcript_complete' = TRUE

    (* Line 229-234: Generate signature *)
    /\ signature_verified' = FALSE  (* Signature generation, not yet verified *)

    /\ last_response' = <<"challenge_auth_response", protocol_version>>
    /\ requester_state' = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED
    /\ UNCHANGED <<responder_state, connection_state, protocol_version, pending_state_transition,
                  response_buffer_size, opaque_data_size, req_context>>

(* libspdm_process_encap_response_challenge_auth (responder verification side)
   Responder processes the challenge auth response and verifies signature.

   Source: libspdm_rsp_encap_challenge.c:80-268
*)
ProcessEncapResponseChallengeAuth ==
    /\ requester_state = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED
    /\ responder_state = STATE_CHALLENGE_SENT

    (* Line 103-112: Validate response header and version *)
    /\ last_response[2] = protocol_version

    (* Line 117-121: Version-dependent response size check *)
    /\ LET expected_min_size ==
           StructSize("challenge_auth_response") + hash_size + NONCE_SIZE +
           StructSize("uint16") + signature_size +
           (IF protocol_version >= Version_13 THEN MAX_REQ_CONTEXT_SIZE ELSE 0)
       IN response_buffer_size >= expected_min_size

    (* Line 199-202: Parse opaque data length *)
    /\ LET parsed_opaque_length == opaque_data_size
       IN /\ parsed_opaque_length <= MAX_OPAQUE_DATA_SIZE
          /\ parsed_opaque_length > 0

    (* Line 237-241: For version 1.3+, validate req_context echo *)
    /\ IF protocol_version >= Version_13 THEN
         req_context_echo_match' = TRUE
       ELSE
         req_context_echo_match' = req_context_echo_match

    (* Line 248-252: Append response (minus signature) to message buffer *)
    /\ message_transcript' = Append(message_transcript,
                                   "challenge_auth_response_body_appended")

    (* Line 257-261: Verify signature
       CRITICAL: Signature verification occurs AFTER message append.
       Family 5: If append failed, transcript is incomplete. *)
    /\ signature_verified' = TRUE

    (* Line 263: Transition to AUTHENTICATED (non-atomic with verification!) *)
    /\ pending_state_transition' = TRUE
    /\ responder_state' = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED
    /\ UNCHANGED <<requester_state, connection_state, buffer_reset_status,
                  response_buffer_size, opaque_data_offset, opaque_data_size,
                  hash_size, signature_size, req_context, last_request, last_response>>

(* Transition state to AUTHENTICATED (atomic completion of state change)
   Family 1: This completes the non-atomic state transition.
*)
TransitionToAuthenticated ==
    /\ pending_state_transition = TRUE
    /\ signature_verified = TRUE
    /\ connection_state' = STATE_AUTHENTICATED
    /\ requester_state' = STATE_AUTHENTICATED
    /\ responder_state' = STATE_AUTHENTICATED
    /\ pending_state_transition' = FALSE
    /\ UNCHANGED <<message_transcript, transcript_complete, response_buffer_size,
                  opaque_data_offset, opaque_data_size, hash_size, signature_size,
                  buffer_reset_status, req_context, req_context_echo_match,
                  last_request, last_response, protocol_version>>

(* FailedStateTransition: State transition fails if signature verification failed
   Family 1: Models the case where authentication fails to update state correctly.
*)
FailedStateTransition ==
    /\ pending_state_transition = TRUE
    /\ signature_verified = FALSE
    /\ pending_state_transition' = FALSE
    /\ connection_state' = STATE_UNINITIALIZED
    /\ UNCHANGED <<requester_state, responder_state, message_transcript,
                  transcript_complete, response_buffer_size, opaque_data_offset,
                  opaque_data_size, hash_size, signature_size, buffer_reset_status,
                  req_context, req_context_echo_match, last_request, last_response,
                  protocol_version>>

(* === NEXT-STATE RELATION === *)

Next ==
    \/ ResponderGetEncapRequestChallenge
    \/ RequesterGetEncapResponseChallengeAuth
    \/ ProcessEncapResponseChallengeAuth
    \/ TransitionToAuthenticated
    \/ FailedStateTransition

(* === SPEC DEFINITION === *)

Spec == Init /\ [][Next]_vars

====
