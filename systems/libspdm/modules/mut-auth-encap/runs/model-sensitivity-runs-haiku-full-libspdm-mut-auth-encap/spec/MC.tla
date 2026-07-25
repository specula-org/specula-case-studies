---- MODULE MC ----
(* Model Checking wrapper for base spec with counter-bounded fault injection.
   Enables exhaustive state space exploration by bounding non-deterministic
   actions and adding symmetry reduction.
*)

EXTENDS base, Naturals, Sequences

(* Counter-bounded actions track fault injection frequency *)
VARIABLE faultCounters

faultCounterVars == faultCounters

(* === CONSTANT TUNING FOR MODEL CHECKING === *)
CONSTANT MaxBufferResetFailures
CONSTANT MaxOpaqueDataFailures
CONSTANT MaxSignatureFailures
CONSTANT MaxVersionMismatches
CONSTANT MaxMessageAppendFailures
CONSTANT MaxBufferUnderflows
CONSTANT MaxStateTransitions

ASSUME MaxBufferResetFailures \in 0..5
ASSUME MaxOpaqueDataFailures \in 0..5
ASSUME MaxSignatureFailures \in 0..5
ASSUME MaxVersionMismatches \in 0..3
ASSUME MaxMessageAppendFailures \in 0..5
ASSUME MaxBufferUnderflows \in 0..3
ASSUME MaxStateTransitions \in 1..10

(* === FAULT INJECTION ACTIONS (Counter-Bounded) === *)

(* Family 4: Message Buffer Reset Failure
   Source: libspdm_rsp_encap_challenge.c:62-63, libspdm_req_encap_challenge_auth.c:97-98

   Fault: libspdm_reset_message_buffer_via_request_code() fails to reset buffer.
   Effect: Message buffer contains stale data from previous operations.
*)
MCBufferResetFailure ==
    /\ faultCounters.buffer_reset_failures < MaxBufferResetFailures
    /\ buffer_reset_status' = "failure"
    /\ message_transcript' = message_transcript  (* Stale transcript *)
    /\ faultCounters' = [faultCounters EXCEPT
        !.buffer_reset_failures = @ + 1]
    /\ UNCHANGED <<requester_state, responder_state, connection_state,
                   protocol_version, transcript_complete, signature_verified,
                   pending_state_transition, response_buffer_size, opaque_data_offset,
                   opaque_data_size, hash_size, signature_size, req_context,
                   req_context_echo_match, last_request, last_response>>

(* Family 6: Opaque Data Generation Failure
   Source: libspdm_req_encap_challenge_auth.c:175-186

   Fault: libspdm_encap_challenge_opaque_data() callback fails.
   Effect: Opaque data generation fails; response has partial data.
*)
MCOpaqueDataGenerationFailure ==
    /\ requester_state = STATE_UNINITIALIZED
    /\ faultCounters.opaque_data_failures < MaxOpaqueDataFailures
    /\ opaque_data_size' = 0  (* Failure: no opaque data *)
    /\ message_transcript' = message_transcript
    /\ requester_state' = STATE_UNINITIALIZED  (* State unchanged on failure *)
    /\ faultCounters' = [faultCounters EXCEPT
        !.opaque_data_failures = @ + 1]
    /\ UNCHANGED <<responder_state, connection_state, protocol_version,
                   transcript_complete, signature_verified, pending_state_transition,
                   response_buffer_size, opaque_data_offset, hash_size, signature_size,
                   buffer_reset_status, req_context, req_context_echo_match,
                   last_request, last_response>>

(* Family 1: Signature Verification Failure
   Source: libspdm_req_encap_challenge_auth.c:229-234, libspdm_rsp_encap_challenge.c:257-261

   Fault: libspdm_generate_challenge_auth_signature() or
          libspdm_verify_challenge_auth_signature() fails.
   Effect: Signature verification returns false; state transition should not occur.
*)
MCSignatureVerificationFailure ==
    /\ (requester_state = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED \/
        responder_state = STATE_CHALLENGE_SENT)
    /\ faultCounters.signature_failures < MaxSignatureFailures
    /\ signature_verified' = FALSE
    /\ pending_state_transition' = FALSE  (* Should not transition *)
    /\ faultCounters' = [faultCounters EXCEPT
        !.signature_failures = @ + 1]
    /\ UNCHANGED <<requester_state, responder_state, connection_state,
                   protocol_version, message_transcript, transcript_complete,
                   response_buffer_size, opaque_data_offset, opaque_data_size,
                   hash_size, signature_size, buffer_reset_status, req_context,
                   req_context_echo_match, last_request, last_response>>

(* Family 2: Version Mismatch
   Source: libspdm_req_encap_challenge_auth.c:44-48

   Fault: Negotiated version changes or request has mismatched version.
   Effect: Protocol_version field inconsistency; message parsing fails.
*)
MCVersionMismatch ==
    /\ faultCounters.version_mismatches < MaxVersionMismatches
    /\ LET old_version == protocol_version
           new_version == IF old_version = Version_11 THEN Version_12
                         ELSE IF old_version = Version_12 THEN Version_13
                         ELSE Version_11
       IN protocol_version' = new_version
    /\ req_context_echo_match' = FALSE  (* Mismatch invalidates echo *)
    /\ faultCounters' = [faultCounters EXCEPT
        !.version_mismatches = @ + 1]
    /\ UNCHANGED <<requester_state, responder_state, connection_state,
                   message_transcript, transcript_complete, signature_verified,
                   pending_state_transition, response_buffer_size, opaque_data_offset,
                   opaque_data_size, hash_size, signature_size, buffer_reset_status,
                   req_context, last_request, last_response>>

(* Family 5: Message Append Failure
   Source: libspdm_req_encap_challenge_auth.c:214-228, libspdm_rsp_encap_challenge.c:248-252

   Fault: libspdm_append_message_mut_c() returns error.
   Effect: Message transcript incomplete; signature verification proceeds with incomplete log.
*)
MCMessageAppendFailure ==
    /\ faultCounters.message_append_failures < MaxMessageAppendFailures
    /\ message_transcript' = message_transcript  (* Append silently fails; no-op *)
    /\ transcript_complete' = FALSE  (* Transcript remains incomplete *)
    /\ faultCounters' = [faultCounters EXCEPT
        !.message_append_failures = @ + 1]
    /\ UNCHANGED <<requester_state, responder_state, connection_state,
                   protocol_version, signature_verified, pending_state_transition,
                   response_buffer_size, opaque_data_offset, opaque_data_size,
                   hash_size, signature_size, buffer_reset_status, req_context,
                   req_context_echo_match, last_request, last_response>>

(* Family 3: Buffer Arithmetic Underflow
   Source: libspdm_req_encap_challenge_auth.c:169-173

   Fault: opaque_data_size calculation underflows due to insufficient response buffer.
   Effect: opaque_data_size becomes very large (wraps); buffer overrun risk.
*)
MCBufferUnderflow ==
    /\ requester_state = STATE_UNINITIALIZED
    /\ faultCounters.buffer_underflows < MaxBufferUnderflows
    /\ LET calculated_opaque == response_buffer_size -
                              (StructSize("challenge_auth_response") + hash_size +
                               NONCE_SIZE + 32 + StructSize("uint16") + signature_size)
       IN IF calculated_opaque > response_buffer_size THEN
            opaque_data_size' = calculated_opaque  (* Underflow preserved *)
          ELSE
            opaque_data_size' = opaque_data_size
    /\ faultCounters' = [faultCounters EXCEPT
        !.buffer_underflows = @ + 1]
    /\ UNCHANGED <<requester_state, responder_state, connection_state,
                   protocol_version, message_transcript, transcript_complete,
                   signature_verified, pending_state_transition,
                   response_buffer_size, opaque_data_offset, hash_size, signature_size,
                   buffer_reset_status, req_context, req_context_echo_match,
                   last_request, last_response>>

(* === WRAPPED BASE SPEC ACTIONS === *)

(* Deterministic actions pass through with unchanged faultCounters *)
MCResponderGetEncapRequestChallenge ==
    /\ ResponderGetEncapRequestChallenge
    /\ UNCHANGED faultCounterVars

MCRequesterGetEncapResponseChallengeAuth ==
    /\ RequesterGetEncapResponseChallengeAuth
    /\ UNCHANGED faultCounterVars

MCProcessEncapResponseChallengeAuth ==
    /\ ProcessEncapResponseChallengeAuth
    /\ UNCHANGED faultCounterVars

MCTransitionToAuthenticated ==
    /\ TransitionToAuthenticated
    /\ faultCounters.state_transitions < MaxStateTransitions
    /\ faultCounters' = [faultCounters EXCEPT
        !.state_transitions = @ + 1]

MCFailedStateTransition ==
    /\ FailedStateTransition
    /\ UNCHANGED faultCounterVars

(* === INITIALIZATION === *)

MCInit ==
    /\ Init
    /\ faultCounters = [
           buffer_reset_failures |-> 0,
           opaque_data_failures |-> 0,
           signature_failures |-> 0,
           version_mismatches |-> 0,
           message_append_failures |-> 0,
           buffer_underflows |-> 0,
           state_transitions |-> 0
       ]

(* === NEXT-STATE RELATION WITH FAULT INJECTION === *)

MCNext ==
    \/ MCResponderGetEncapRequestChallenge
    \/ MCRequesterGetEncapResponseChallengeAuth
    \/ MCProcessEncapResponseChallengeAuth
    \/ MCTransitionToAuthenticated
    \/ MCFailedStateTransition
    \/ MCBufferResetFailure
    \/ MCOpaqueDataGenerationFailure
    \/ MCSignatureVerificationFailure
    \/ MCVersionMismatch
    \/ MCMessageAppendFailure
    \/ MCBufferUnderflow

(* === SPEC DEFINITION === *)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultCounterVars>>

====
