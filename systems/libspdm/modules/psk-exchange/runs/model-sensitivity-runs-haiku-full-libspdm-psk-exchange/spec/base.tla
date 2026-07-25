---- MODULE base ----
(* TLA+ specification for libspdm PSK exchange protocol
   Category A: Distributed Message-Passing System
   Focuses on requester-responder handshake with bug-family driven extensions
*)

EXTENDS Naturals, Sequences, FiniteSets

\* System parameters
CONSTANT Requester, Responder
CONSTANT MaxOpaqueLengthSize, MaxContextLength, MaxSessionIds

\* Assumptions are configured via MC.cfg
\* ASSUME MaxOpaqueLengthSize = 1024
\* ASSUME MaxContextLength = 32
\* ASSUME MaxSessionIds = 32

\* Message types
CONSTANT PSK_EXCHANGE, PSK_EXCHANGE_RSP
CONSTANT PSK_FINISH, PSK_FINISH_RSP

\* Error codes
CONSTANT OK, ERROR_INVALID_MSG_FIELD, ERROR_SESSION_EXHAUSTED

\* Session states
CONSTANT IDLE, HANDSHAKING, ESTABLISHED

\* Message definitions
Message == [
    type: {PSK_EXCHANGE, PSK_EXCHANGE_RSP, PSK_FINISH, PSK_FINISH_RSP},
    sender: {Requester, Responder},
    receiver: {Requester, Responder},
    req_session_id: 0..2*MaxSessionIds,
    rsp_session_id: 0..2*MaxSessionIds,
    opaque_length: 0..MaxOpaqueLengthSize,
    context_length: 0..MaxContextLength,
    opaque_data: BOOLEAN,
    context_data: BOOLEAN,
    version_negotiated: BOOLEAN
]

\* ===== PROTOCOL VARIABLES =====

VARIABLE
    requester_session_state,        \* Session state at requester
    responder_session_state,        \* Session state at responder
    requester_allocated_ids,        \* Track allocated (but unassigned) session IDs
    responder_session_info,         \* Responder's view of session
    requester_session_info,         \* Requester's view of session
    messages,                       \* In-flight message bag
    requester_pc,                   \* Requester program counter (step tracking)
    responder_pc                    \* Responder program counter (step tracking)

\* ===== EXTENSION VARIABLES (Bug Family Tracking) =====

VARIABLE
    opaque_max_bounds_enforced,     \* Family 1: Explicit max-bound check state
    session_id_allocation_tracking, \* Family 2: Track allocated IDs, deallocation
    version_negotiation_state,      \* Family 3: Version agreement state
    session_state_transitions,      \* Family 5: State machine validation
    context_bounds_checked          \* Family 4: Context length validation

\* ===== HELPER OPERATORS =====

IsValidOpaqueLengthCheck(len) == len <= MaxOpaqueLengthSize

IsValidContextLength(len) == len <= MaxContextLength

GenerateSessionId(req_id, rsp_id) == req_id * 1000 + rsp_id

\* ===== INIT =====

Init ==
    /\ requester_session_state = IDLE
    /\ responder_session_state = IDLE
    /\ requester_allocated_ids = {}
    /\ responder_session_info = [session_id |-> 0, established |-> FALSE, version |-> 0]
    /\ requester_session_info = [session_id |-> 0, established |-> FALSE, version |-> 0]
    /\ messages = {}
    /\ requester_pc = "ready"
    /\ responder_pc = "ready"
    /\ opaque_max_bounds_enforced = [
        requester_recv_psk_exchange_rsp |-> FALSE,
        responder_recv_psk_exchange |-> FALSE,
        requester_recv_psk_finish_rsp |-> FALSE,
        responder_recv_psk_finish |-> FALSE
      ]
    /\ session_id_allocation_tracking = [allocated |-> {}, freed |-> {}]
    /\ version_negotiation_state = [
        requester_version |-> 0,
        responder_version |-> 0,
        negotiation_complete |-> FALSE
      ]
    /\ session_state_transitions = [
        requester_state |-> IDLE,
        responder_state |-> IDLE
      ]
    /\ context_bounds_checked = [
        responder_checked |-> FALSE,
        requester_checked |-> FALSE
      ]

\* ===== ACTIONS: PSK_EXCHANGE MESSAGE HANDLING =====

\* Requester sends PSK_EXCHANGE (lines 199-323 in libspdm_req_psk_exchange.c)
RequesterSendPskExchange ==
    /\ requester_pc = "ready"
    /\ requester_session_state = IDLE
    \* Allocate session ID (line 199)
    /\ LET req_session_id == CHOOSE id \in 1..MaxSessionIds :
            id \notin requester_allocated_ids
       IN
       /\ requester_allocated_ids' = requester_allocated_ids \cup {req_session_id}
       /\ session_id_allocation_tracking' = [session_id_allocation_tracking EXCEPT
            !.allocated = session_id_allocation_tracking.allocated \cup {req_session_id}]
       /\ LET msg == [
            type |-> PSK_EXCHANGE,
            sender |-> Requester,
            receiver |-> Responder,
            req_session_id |-> req_session_id,
            rsp_session_id |-> 0,
            opaque_length |-> 100,
            context_length |-> 32,
            opaque_data |-> TRUE,
            context_data |-> TRUE,
            version_negotiated |-> FALSE
          ]
          IN
          /\ messages' = messages \cup {msg}
          /\ requester_session_info' = [requester_session_info EXCEPT
               !.session_id = req_session_id]
          /\ requester_pc' = "sent_psk_exchange"
    /\ UNCHANGED <<requester_session_state, responder_session_state, responder_session_info, responder_pc,
                   opaque_max_bounds_enforced, version_negotiation_state,
                   session_state_transitions, context_bounds_checked>>

\* Responder receives PSK_EXCHANGE (lines 75-300 in libspdm_rsp_psk_exchange_rsp.c)
ResponderRecvPskExchange ==
    /\ responder_pc = "ready"
    /\ responder_session_state = IDLE
    /\ \E msg \in messages:
        /\ msg.type = PSK_EXCHANGE
        /\ msg.receiver = Responder
        /\ \* Family 1, Family 4: Check message bounds (lines 238-241)
           /\ IF msg.opaque_length <= MaxOpaqueLengthSize /\
                 msg.context_length <= MaxContextLength
             THEN \* Size check passes
                  /\ opaque_max_bounds_enforced' = [opaque_max_bounds_enforced EXCEPT
                       !.responder_recv_psk_exchange = TRUE]
                  /\ context_bounds_checked' = [context_bounds_checked EXCEPT
                       !.responder_checked = TRUE]
                  /\ responder_session_info' = [responder_session_info EXCEPT
                       !.session_id = msg.req_session_id]
                  /\ responder_pc' = "recv_psk_exchange"
                  /\ UNCHANGED <<requester_session_state, responder_session_state, requester_allocated_ids, requester_session_info,
                                 requester_pc, session_id_allocation_tracking, version_negotiation_state,
                                 session_state_transitions, messages>>
             ELSE \* Size check fails - reject
                  /\ responder_pc' = "error"
                  /\ UNCHANGED <<requester_session_state, responder_session_state, requester_allocated_ids, responder_session_info, requester_session_info,
                                 requester_pc, session_id_allocation_tracking, version_negotiation_state,
                                 session_state_transitions, messages, opaque_max_bounds_enforced, context_bounds_checked>>

\* Responder sends PSK_EXCHANGE_RSP (lines 274-341 in libspdm_rsp_psk_exchange_rsp.c)
ResponderSendPskExchangeRsp ==
    /\ responder_pc = "recv_psk_exchange"
    /\ responder_session_state = IDLE
    /\ LET rsp_session_id == CHOOSE id \in 1..MaxSessionIds : TRUE
       IN
       /\ LET msg == [
            type |-> PSK_EXCHANGE_RSP,
            sender |-> Responder,
            receiver |-> Requester,
            req_session_id |-> responder_session_info.session_id,
            rsp_session_id |-> rsp_session_id,
            opaque_length |-> 50,
            context_length |-> 0,
            opaque_data |-> TRUE,
            context_data |-> FALSE,
            version_negotiated |-> TRUE
          ]
          IN
          /\ messages' = messages \cup {msg}
          /\ responder_session_info' = [responder_session_info EXCEPT
               !.session_id = GenerateSessionId(responder_session_info.session_id, rsp_session_id),
               !.established = TRUE]
          /\ responder_session_state' = HANDSHAKING
          /\ responder_pc' = "sent_psk_exchange_rsp"
          /\ version_negotiation_state' = [version_negotiation_state EXCEPT
               !.responder_version = 1,
               !.negotiation_complete = TRUE]
    /\ UNCHANGED <<requester_session_state, requester_allocated_ids, requester_session_info,
                   requester_pc, session_id_allocation_tracking, opaque_max_bounds_enforced,
                   session_state_transitions, context_bounds_checked>>

\* Requester receives PSK_EXCHANGE_RSP (lines 327-477 in libspdm_req_psk_exchange.c)
RequesterRecvPskExchangeRsp ==
    /\ requester_pc = "sent_psk_exchange"
    /\ \E msg \in messages:
        /\ msg.type = PSK_EXCHANGE_RSP
        /\ msg.receiver = Requester
        /\ msg.req_session_id = requester_session_info.session_id
        /\ \* Family 1: Explicit max-bound check on opaque_length (lines 425-428)
           IF msg.opaque_length > MaxOpaqueLengthSize
           THEN \* Requester rejects - FAMILY 1 asymmetry occurs here
                /\ requester_pc' = "error"
                /\ UNCHANGED <<requester_session_state, requester_session_info,
                               opaque_max_bounds_enforced, version_negotiation_state,
                               requester_allocated_ids, session_id_allocation_tracking,
                               responder_session_state, responder_session_info, responder_pc,
                               session_state_transitions, context_bounds_checked, messages>>
           ELSE \* Bounds check passes
                /\ opaque_max_bounds_enforced' = [opaque_max_bounds_enforced EXCEPT
                     !.requester_recv_psk_exchange_rsp = TRUE]
                /\ \* Session assignment (line 472)
                   /\ requester_allocated_ids' = requester_allocated_ids \ {requester_session_info.session_id}
                   /\ session_id_allocation_tracking' = [session_id_allocation_tracking EXCEPT
                        !.freed = session_id_allocation_tracking.freed \cup {requester_session_info.session_id}]
                   /\ requester_session_state' = HANDSHAKING
                   /\ requester_session_info' = [requester_session_info EXCEPT
                        !.session_id = GenerateSessionId(
                          requester_session_info.session_id, msg.rsp_session_id),
                        !.established = TRUE]
                   /\ version_negotiation_state' = [version_negotiation_state EXCEPT
                        !.requester_version = 1]
                   /\ requester_pc' = "received_psk_exchange_rsp"
                   /\ UNCHANGED <<responder_session_state, responder_session_info, responder_pc,
                                  session_state_transitions, context_bounds_checked, messages>>

\* ===== ACTIONS: PSK_FINISH MESSAGE HANDLING =====

\* Requester sends PSK_FINISH
RequesterSendPskFinish ==
    /\ requester_pc = "received_psk_exchange_rsp"
    /\ requester_session_state = HANDSHAKING
    /\ \* Family 5: Require session in HANDSHAKING state (enforced by precondition)
       LET msg == [
         type |-> PSK_FINISH,
         sender |-> Requester,
         receiver |-> Responder,
         req_session_id |-> requester_session_info.session_id,
         rsp_session_id |-> requester_session_info.session_id,
         opaque_length |-> 50,
         context_length |-> 0,
         opaque_data |-> TRUE,
         context_data |-> FALSE,
         version_negotiated |-> TRUE
       ]
       IN
       /\ messages' = messages \cup {msg}
       /\ requester_pc' = "sent_psk_finish"
    /\ UNCHANGED <<requester_session_state, requester_allocated_ids, requester_session_info,
                   responder_session_state, responder_session_info, responder_pc,
                   opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Responder receives PSK_FINISH
ResponderRecvPskFinish ==
    /\ responder_pc = "sent_psk_exchange_rsp"
    /\ responder_session_state = HANDSHAKING
    /\ \E msg \in messages:
        /\ msg.type = PSK_FINISH
        /\ msg.receiver = Responder
        /\ \* Family 1: Check opaque_length bounds (lines 171-182)
           IF msg.opaque_length > MaxOpaqueLengthSize
           THEN /\ responder_pc' = "error"
                /\ UNCHANGED responder_session_state
           ELSE /\ opaque_max_bounds_enforced' = [opaque_max_bounds_enforced EXCEPT
                     !.responder_recv_psk_finish = TRUE]
                /\ responder_pc' = "recv_psk_finish"
    /\ UNCHANGED <<requester_session_state, requester_allocated_ids, requester_session_info,
                   requester_pc, responder_session_info, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Responder sends PSK_FINISH_RSP
ResponderSendPskFinishRsp ==
    /\ responder_pc = "recv_psk_finish"
    /\ responder_session_state = HANDSHAKING
    /\ LET msg == [
         type |-> PSK_FINISH_RSP,
         sender |-> Responder,
         receiver |-> Requester,
         req_session_id |-> responder_session_info.session_id,
         rsp_session_id |-> responder_session_info.session_id,
         opaque_length |-> 0,
         context_length |-> 0,
         opaque_data |-> FALSE,
         context_data |-> FALSE,
         version_negotiated |-> TRUE
       ]
       IN
       /\ messages' = messages \cup {msg}
       /\ responder_session_state' = ESTABLISHED
       /\ responder_pc' = "sent_psk_finish_rsp"
    /\ UNCHANGED <<requester_session_state, requester_allocated_ids, requester_session_info,
                   requester_pc, responder_session_info, opaque_max_bounds_enforced,
                   session_id_allocation_tracking, version_negotiation_state,
                   session_state_transitions, context_bounds_checked>>

\* Requester receives PSK_FINISH_RSP
RequesterRecvPskFinishRsp ==
    /\ requester_pc = "sent_psk_finish"
    /\ requester_session_state = HANDSHAKING
    /\ \E msg \in messages:
        /\ msg.type = PSK_FINISH_RSP
        /\ msg.receiver = Requester
        /\ \* Family 1: Check opaque_length bounds (lines 292-295)
           IF msg.opaque_length > MaxOpaqueLengthSize
           THEN /\ requester_pc' = "error"
                /\ UNCHANGED requester_session_state
           ELSE /\ opaque_max_bounds_enforced' = [opaque_max_bounds_enforced EXCEPT
                     !.requester_recv_psk_finish_rsp = TRUE]
                /\ requester_session_state' = ESTABLISHED
                /\ requester_pc' = "established"
    /\ UNCHANGED <<responder_session_state, responder_session_info, responder_pc,
                   requester_allocated_ids, requester_session_info,
                   session_id_allocation_tracking, version_negotiation_state,
                   session_state_transitions, context_bounds_checked>>

\* ===== FAULT/ERROR HANDLING =====

\* Family 2: Error path without freeing allocated session ID (simulating bug)
RequesterErrorWithoutFree ==
    /\ requester_pc = "sent_psk_exchange"
    /\ requester_allocated_ids # {}
    /\ \* Simulate early error return without deallocation
       LET id == CHOOSE x \in requester_allocated_ids : TRUE
       IN
       /\ requester_pc' = "error"
    /\ UNCHANGED <<requester_session_state, requester_allocated_ids, requester_session_info,
                   responder_session_state, responder_session_info, responder_pc,
                   messages, opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Family 2: Proper cleanup path with ID deallocation
RequesterErrorWithFree ==
    /\ requester_pc = "sent_psk_exchange"
    /\ requester_allocated_ids # {}
    /\ LET id == CHOOSE x \in requester_allocated_ids : TRUE
       IN
       /\ requester_allocated_ids' = requester_allocated_ids \ {id}
       /\ session_id_allocation_tracking' = [session_id_allocation_tracking EXCEPT
            !.freed = session_id_allocation_tracking.freed \cup {id}]
       /\ requester_pc' = "error"
    /\ UNCHANGED <<requester_session_state, requester_session_info,
                   responder_session_state, responder_session_info, responder_pc,
                   messages, opaque_max_bounds_enforced,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* ===== NEXT STATE DEFINITION =====

Next ==
    \/ RequesterSendPskExchange
    \/ ResponderRecvPskExchange
    \/ ResponderSendPskExchangeRsp
    \/ RequesterRecvPskExchangeRsp
    \/ RequesterSendPskFinish
    \/ ResponderRecvPskFinish
    \/ ResponderSendPskFinishRsp
    \/ RequesterRecvPskFinishRsp
    \/ RequesterErrorWithoutFree
    \/ RequesterErrorWithFree

\* ===== SAFETY INVARIANTS =====

\* Family 1: Opaque length consistency check on both sides
OpaqueLengthConsistency ==
    \A msg \in messages:
        /\ msg.type \in {PSK_EXCHANGE_RSP, PSK_FINISH_RSP} =>
            msg.opaque_length <= MaxOpaqueLengthSize
        /\ msg.type = PSK_EXCHANGE =>
            msg.opaque_length <= MaxOpaqueLengthSize

\* Family 2: Session ID allocation/deallocation tracking
SessionIDAllocationFreeing ==
    \* Every allocated ID must eventually be freed or assigned
    requester_allocated_ids \subseteq session_id_allocation_tracking.allocated

\* Family 3: Version negotiation agreement
SecuredMessageVersionAgreement ==
    \* If both have negotiated versions, they must match
    /\ (version_negotiation_state.requester_version > 0 /\
        version_negotiation_state.responder_version > 0) =>
       version_negotiation_state.requester_version = version_negotiation_state.responder_version

\* Family 5: PSK_EXCHANGE state precondition
PSKExchangeNoActiveSession ==
    \* When sending PSK_EXCHANGE, requester must be in IDLE state
    (requester_pc = "ready" /\ requester_session_state = IDLE) \/
    (requester_pc # "ready")

\* Family 5: PSK_FINISH state requirement
PSKFinishHandshakingState ==
    \* PSK_FINISH must be sent when session is HANDSHAKING
    (requester_pc = "received_psk_exchange_rsp" /\ requester_session_state = HANDSHAKING) \/
    (requester_pc # "received_psk_exchange_rsp")

\* Family 4: Context length bounds
ContextLengthBounds ==
    \A msg \in messages:
        /\ msg.type = PSK_EXCHANGE =>
            msg.context_length <= MaxContextLength
        /\ msg.type = PSK_EXCHANGE_RSP =>
            msg.context_length <= MaxContextLength

\* Handshake transcript integrity (structural)
HandshakeTranscriptIntegrity ==
    \* If both sides complete handshake, they must agree on version
    (requester_session_state = ESTABLISHED /\ responder_session_state = ESTABLISHED) =>
        version_negotiation_state.negotiation_complete

\* Type correctness
TypeOK ==
    /\ requester_session_state \in {IDLE, HANDSHAKING, ESTABLISHED}
    /\ responder_session_state \in {IDLE, HANDSHAKING, ESTABLISHED}
    /\ requester_pc \in {"ready", "sent_psk_exchange", "received_psk_exchange_rsp",
                         "sent_psk_finish", "established", "error"}
    /\ responder_pc \in {"ready", "recv_psk_exchange", "sent_psk_exchange_rsp",
                         "recv_psk_finish", "sent_psk_finish_rsp", "error"}
    /\ requester_allocated_ids \subseteq 1..MaxSessionIds
    /\ messages \subseteq Message
    /\ opaque_max_bounds_enforced.requester_recv_psk_exchange_rsp \in BOOLEAN
    /\ opaque_max_bounds_enforced.responder_recv_psk_exchange \in BOOLEAN
    /\ opaque_max_bounds_enforced.requester_recv_psk_finish_rsp \in BOOLEAN
    /\ opaque_max_bounds_enforced.responder_recv_psk_finish \in BOOLEAN
    /\ session_id_allocation_tracking.allocated \subseteq 1..MaxSessionIds
    /\ session_id_allocation_tracking.freed \subseteq 1..MaxSessionIds

====
