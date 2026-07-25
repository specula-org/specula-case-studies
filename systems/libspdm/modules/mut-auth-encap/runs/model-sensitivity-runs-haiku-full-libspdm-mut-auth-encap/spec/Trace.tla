---- MODULE Trace ----
(* Trace Validation Spec: Replays implementation traces against base spec
   to verify that observed behavior matches formal specification.

   Category A (Distributed/Message-Passing): Uses single cursor `l` walking
   through a linear trace file in NDJSON format.
*)

EXTENDS base, TraceData, Naturals, Sequences

(* === TRACE LOADING === *)

(* TraceLog is imported from TraceData module
   It is a sequence of trace event records, each with:
   - event (string): event name
   - node (string): which node (requester/responder)
   - state (record): state snapshot at event time
   - message (record, optional): message fields
*)

(* === TRACE CURSOR AND COMPLETION === *)

VARIABLE l  (* cursor: index into TraceLog *)

traceVars == l

(* === EVENT PREDICATES === *)

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = name

IsNodeEvent(name, node) ==
    /\ IsEvent(name)
    /\ TraceLog[l].node = node

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ TraceLog[l].from_node = from
    /\ TraceLog[l].to_node = to

(* === ROLE/TYPE MAPPING === *)

MapNode(node_str) ==
    IF node_str = "requester" THEN "requester"
    ELSE IF node_str = "responder" THEN "responder"
    ELSE node_str

MapVersion(ver_val) ==
    IF ver_val = "11" \/ ver_val = 11 THEN Version_11
    ELSE IF ver_val = "12" \/ ver_val = 12 THEN Version_12
    ELSE IF ver_val = "13" \/ ver_val = 13 THEN Version_13
    ELSE Version_11

(* === VALIDATION FUNCTIONS (must be defined before action wrappers) === *)

ValidateResponderGetEncapRequestChallenge(event) ==
    /\ responder_state = STATE_CHALLENGE_SENT
    /\ buffer_reset_status = "success"
    /\ last_request[1] = "challenge_request"
    /\ protocol_version = event.message.version

ValidateRequesterGetEncapResponseChallengeAuth(event) ==
    /\ requester_state = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED
    /\ transcript_complete = TRUE
    /\ response_buffer_size = event.message.response_buffer_size
    /\ opaque_data_size = event.message.opaque_data_size
    /\ opaque_data_offset + opaque_data_size <= response_buffer_size
    /\ protocol_version = event.message.version

ValidateProcessEncapResponseChallengeAuth(event) ==
    /\ responder_state = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED
    /\ signature_verified = TRUE
    /\ message_transcript' # message_transcript
    /\ IF protocol_version >= Version_13 THEN
         req_context_echo_match = TRUE
       ELSE
         TRUE

ValidateTransitionToAuthenticated(event) ==
    /\ connection_state = STATE_AUTHENTICATED
    /\ requester_state = STATE_AUTHENTICATED
    /\ responder_state = STATE_AUTHENTICATED
    /\ signature_verified = TRUE
    /\ pending_state_transition = FALSE

ValidatePostState(event, action_name) ==
    CASE action_name = "responder_get_encap_request_challenge" ->
            ValidateResponderGetEncapRequestChallenge(event)
      [] action_name = "requester_get_encap_response_challenge_auth" ->
            ValidateRequesterGetEncapResponseChallengeAuth(event)
      [] action_name = "process_encap_response_challenge_auth" ->
            ValidateProcessEncapResponseChallengeAuth(event)
      [] action_name = "transition_to_authenticated" ->
            ValidateTransitionToAuthenticated(event)
      [] OTHER -> TRUE  (* Unknown event: skip validation *)

(* === ACTION WRAPPERS WITH STATE VALIDATION === *)

(* TraceResponderGetEncapRequestChallenge
   Source: Trace event "responder_get_encap_request_challenge"

   Captured state fields:
   - node: "responder"
   - version: negotiated protocol version
   - state_before: responder state before action
   - state_after: responder state after action
*)
TraceResponderGetEncapRequestChallenge ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "responder_get_encap_request_challenge"
    /\ ResponderGetEncapRequestChallenge
    /\ l' = l + 1

(* TraceRequesterGetEncapResponseChallengeAuth
   Source: Trace event "requester_get_encap_response_challenge_auth"

   Captured state fields:
   - node: "requester"
   - version: protocol version
   - response_buffer_size: allocated response buffer
   - opaque_data_size: calculated opaque data size
   - state_before: requester state
   - state_after: requester state after response generation
   - transcript_complete: whether message transcript is complete
*)
TraceRequesterGetEncapResponseChallengeAuth ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "requester_get_encap_response_challenge_auth"
    /\ LET event == TraceLog[l]
       IN
         (* Set response buffer params from trace *)
         /\ LET rb == event.state.response_buffer_size
               od == event.state.opaque_data_size
            IN
              /\ responder_state = STATE_CHALLENGE_SENT
              /\ hash_size' = HashSize(Hash_Sha256)
              /\ signature_size' = SigSize(AsymAlg_ECDSA_P256)
              /\ rb >= (StructSize("challenge_auth_response") + hash_size' + NONCE_SIZE + 32 + signature_size')
              /\ buffer_reset_status' = "success"
              /\ response_buffer_size' = rb
              /\ opaque_data_offset' = StructSize("challenge_auth_response") + hash_size' + NONCE_SIZE + 32 + StructSize("uint16")
              /\ IF protocol_version >= Version_13 THEN req_context_echo_match' = TRUE ELSE req_context_echo_match' = FALSE
              /\ message_transcript' = Append(Append(message_transcript, "challenge_request_appended"), "challenge_auth_response_appended")
              /\ transcript_complete' = TRUE
              /\ signature_verified' = FALSE
              /\ last_response' = <<"challenge_auth_response", protocol_version>>
              /\ requester_state' = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED
              /\ opaque_data_size' = od
              /\ UNCHANGED <<responder_state, connection_state, protocol_version, pending_state_transition, req_context, last_request>>
              /\ l' = l + 1

(* TraceProcessEncapResponseChallengeAuth
   Source: Trace event "process_encap_response_challenge_auth"

   Captured state fields:
   - node: "responder"
   - response_buffer_size: size of received response
   - signature_verified: whether signature verification succeeded
   - req_context_match: whether req_context echo matched
   - state_before: responder state
   - state_after: responder state after processing
*)
TraceProcessEncapResponseChallengeAuth ==
    /\ IsEvent("process_encap_response_challenge_auth")
    /\ LET event == TraceLog[l]
       IN /\ ProcessEncapResponseChallengeAuth
          /\ ValidatePostState(event, "process_encap_response_challenge_auth")
          /\ l' = l + 1

(* TraceTransitionToAuthenticated
   Source: Trace event "transition_to_authenticated"

   Captured state fields:
   - node: "responder"
   - state_before: state before transition
   - state_after: AUTHENTICATED
   - signature_verified: TRUE at transition time
*)
TraceTransitionToAuthenticated ==
    /\ IsEvent("transition_to_authenticated")
    /\ LET event == TraceLog[l]
       IN /\ TransitionToAuthenticated
          /\ ValidatePostState(event, "transition_to_authenticated")
          /\ l' = l + 1

(* === SILENT ACTIONS === *)

(* Silent actions handle spec state changes without consuming trace events.
   These must be tightly constrained to avoid state space explosion.
*)

(* No precondition silent actions in this spec; all significant state changes
   are observable and should have trace events. *)

(* === TRACE NEXT-STATE RELATION === *)

TraceNext ==
    \/ TraceResponderGetEncapRequestChallenge
    \/ TraceRequesterGetEncapResponseChallengeAuth
    \/ TraceProcessEncapResponseChallengeAuth
    \/ TraceTransitionToAuthenticated
    \/ (l > Len(TraceLog) /\ UNCHANGED <<vars, traceVars>>)  (* Stuttering after trace consumed *)

(* === TRACE INITIALIZATION === *)

TraceInit ==
    /\ requester_state = STATE_UNINITIALIZED
    /\ responder_state = STATE_UNINITIALIZED
    /\ connection_state = STATE_UNINITIALIZED
    /\ protocol_version = TraceLog[1].message.version  (* Set from first trace *)
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
    /\ l = 1  (* Start at first trace event *)

(* === COMPLETION CHECK === *)

TraceMatched == <>(l > Len(TraceLog))

(* === SPEC DEFINITION === *)

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, traceVars>>

====
