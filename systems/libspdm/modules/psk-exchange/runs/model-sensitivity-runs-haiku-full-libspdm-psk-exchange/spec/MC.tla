---- MODULE MC ----
(* Model checking spec for libspdm PSK exchange
   Wraps base spec with counter-bounded fault-injection actions
   and reduction strategies
*)

EXTENDS base

\* Counter variables for fault injection
VARIABLE faultVars

FaultCountersType == [
    psk_exchange_errors: 0..100,
    opaque_length_oversize: 0..100,
    version_mismatch: 0..100,
    state_machine_violation: 0..100,
    context_length_violation: 0..100,
    session_id_leak: 0..100,
    message_loss: 0..100,
    message_reorder: 0..100
]

\* ===== COUNTER-BOUNDED FAULT WRAPPERS =====

\* Family 1: Opaque length overfill (inject message with oversized opaque_length)
MCOversizeOpaqueLength ==
    /\ faultVars.opaque_length_oversize < 3
    /\ \E msg \in messages:
        /\ msg.type = PSK_EXCHANGE_RSP
        /\ LET bad_msg == [msg EXCEPT !.opaque_length = MaxOpaqueLengthSize + 1]
           IN
           /\ messages' = (messages \ {msg}) \cup {bad_msg}
           /\ faultVars' = [faultVars EXCEPT
                !.opaque_length_oversize = faultVars.opaque_length_oversize + 1]
    /\ UNCHANGED <<requester_session_state, responder_session_state, requester_allocated_ids,
                   responder_session_info, requester_session_info, requester_pc, responder_pc,
                   opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Family 2: Session ID allocation leak (force error without deallocation)
MCSessionIdLeak ==
    /\ faultVars.session_id_leak < 2
    /\ requester_pc = "sent_psk_exchange"
    /\ requester_allocated_ids # {}
    /\ \* Force error path that doesn't deallocate
       LET id == CHOOSE x \in requester_allocated_ids : TRUE
       IN
       /\ requester_pc' = "error"
       /\ \* BUGGY: do NOT deallocate - simulating the leak
          faultVars' = [faultVars EXCEPT !.session_id_leak = faultVars.session_id_leak + 1]
    /\ UNCHANGED <<requester_session_state, requester_allocated_ids, requester_session_info,
                   responder_session_state, responder_session_info, responder_pc,
                   messages, opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Family 3: Version mismatch injection (send incompatible versions)
MCVersionMismatch ==
    /\ faultVars.version_mismatch < 2
    /\ responder_pc = "sent_psk_exchange_rsp"
    /\ \E msg \in messages:
        /\ msg.type = PSK_EXCHANGE_RSP
        /\ msg.sender = Responder
        /\ LET bad_msg == [msg EXCEPT !.version_negotiated = FALSE]
           IN
           /\ messages' = (messages \ {msg}) \cup {bad_msg}
           /\ faultVars' = [faultVars EXCEPT !.version_mismatch = faultVars.version_mismatch + 1]
    /\ UNCHANGED <<requester_session_state, responder_session_state, requester_allocated_ids,
                   responder_session_info, requester_session_info, requester_pc, responder_pc,
                   opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Family 4: Context length violation
MCContextLengthViolation ==
    /\ faultVars.context_length_violation < 2
    /\ \E msg \in messages:
        /\ msg.type = PSK_EXCHANGE_RSP
        /\ msg.context_length > MaxContextLength
        /\ faultVars' = [faultVars EXCEPT !.context_length_violation = faultVars.context_length_violation + 1]
    /\ UNCHANGED <<requester_session_state, responder_session_state, requester_allocated_ids,
                   responder_session_info, requester_session_info, requester_pc, responder_pc,
                   messages, opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Family 5: State machine violation (send PSK_EXCHANGE when not IDLE)
MCStateMachineViolation ==
    /\ faultVars.state_machine_violation < 2
    /\ requester_session_state # IDLE
    /\ \* Try to send another PSK_EXCHANGE (violating state precondition)
       LET msg == [
         type |-> PSK_EXCHANGE,
         sender |-> Requester,
         receiver |-> Responder,
         req_session_id |-> 1,
         rsp_session_id |-> 0,
         opaque_length |-> 100,
         context_length |-> 32,
         opaque_data |-> TRUE,
         context_data |-> TRUE,
         version_negotiated |-> FALSE
       ]
       IN
       /\ messages' = messages \cup {msg}
       /\ faultVars' = [faultVars EXCEPT !.state_machine_violation = faultVars.state_machine_violation + 1]
    /\ UNCHANGED <<requester_session_state, responder_session_state, requester_allocated_ids,
                   responder_session_info, requester_session_info, requester_pc, responder_pc,
                   opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* Message loss (discard a message)
MCMessageLoss ==
    /\ faultVars.message_loss < 3
    /\ messages # {}
    /\ \E msg \in messages:
        /\ messages' = messages \ {msg}
        /\ faultVars' = [faultVars EXCEPT !.message_loss = faultVars.message_loss + 1]
    /\ UNCHANGED <<requester_session_state, responder_session_state, requester_allocated_ids,
                   responder_session_info, requester_session_info, requester_pc, responder_pc,
                   opaque_max_bounds_enforced, session_id_allocation_tracking,
                   version_negotiation_state, session_state_transitions, context_bounds_checked>>

\* ===== DERIVED ACTIONS (From base spec, with UNCHANGED faultVars) =====

MCRequesterSendPskExchange == RequesterSendPskExchange /\ UNCHANGED faultVars
MCResponderRecvPskExchange == ResponderRecvPskExchange /\ UNCHANGED faultVars
MCResponderSendPskExchangeRsp == ResponderSendPskExchangeRsp /\ UNCHANGED faultVars
MCRequesterRecvPskExchangeRsp == RequesterRecvPskExchangeRsp /\ UNCHANGED faultVars
MCRequesterSendPskFinish == RequesterSendPskFinish /\ UNCHANGED faultVars
MCResponderRecvPskFinish == ResponderRecvPskFinish /\ UNCHANGED faultVars
MCResponderSendPskFinishRsp == ResponderSendPskFinishRsp /\ UNCHANGED faultVars
MCRequesterRecvPskFinishRsp == RequesterRecvPskFinishRsp /\ UNCHANGED faultVars

\* ===== INIT AND NEXT FOR MODEL CHECKING =====

MCInit == Init /\ faultVars = [
    psk_exchange_errors |-> 0,
    opaque_length_oversize |-> 0,
    version_mismatch |-> 0,
    state_machine_violation |-> 0,
    context_length_violation |-> 0,
    session_id_leak |-> 0,
    message_loss |-> 0,
    message_reorder |-> 0
]

MCNext ==
    \/ MCRequesterSendPskExchange
    \/ MCResponderRecvPskExchange
    \/ MCResponderSendPskExchangeRsp
    \/ MCRequesterRecvPskExchangeRsp
    \/ MCRequesterSendPskFinish
    \/ MCResponderRecvPskFinish
    \/ MCResponderSendPskFinishRsp
    \/ MCRequesterRecvPskFinishRsp
    \/ MCOversizeOpaqueLength
    \/ MCSessionIdLeak
    \/ MCVersionMismatch
    \/ MCContextLengthViolation
    \/ MCStateMachineViolation
    \/ MCMessageLoss

\* ===== VIEW (exclude counters) =====

VIEW == <<requester_session_state, responder_session_state, requester_allocated_ids,
           responder_session_info, requester_session_info, messages,
           requester_pc, responder_pc, opaque_max_bounds_enforced,
           session_id_allocation_tracking, version_negotiation_state,
           session_state_transitions, context_bounds_checked>>

====
