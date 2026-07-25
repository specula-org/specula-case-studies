---- MODULE base ----
\* libspdm SPDM 1.3 Event Subscription — Base Spec
\*
\* Category A (Distributed / Message-Passing): single-threaded, event-driven;
\* one in-flight request per session; response_state serializes operations.
\*
\* Bug Families modeled:
\*   Family 1 — libspdm_rsp_event_ack.c: response_state check AFTER version checks
\*              (every other handler checks response_state FIRST)
\*   Family 2 — libspdm_rsp_subscribe_event_types_ack.c: SUBSCRIBE_NONE unconditionally
\*              overrides EVENT_ALL_POLICY subscription set at KEY_EXCHANGE
\*   Family 3 — libspdm_rsp_encap_send_event.c: encap SEND_EVENT generated without
\*              checking subscription_state; can deliver to unsubscribed recipient

EXTENDS Naturals, FiniteSets, TLC

\* ---- Constants ----

\* Session states (libspdm_session_state_t)
CONSTANTS
    NOT_STARTED,    \* session not yet initiated
    HANDSHAKE,      \* KEY_EXCHANGE sent, session being established
    ESTABLISHED     \* FINISH complete; session fully active

\* Response states (libspdm_response_state_t from libspdm_common_context_data.h)
CONSTANTS
    NORMAL,           \* LIBSPDM_RESPONSE_STATE_NORMAL
    PROCESSING_ENCAP  \* LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP

\* Subscription states (eventlib.h:44-79)
CONSTANTS
    SUB_NONE,   \* LIBSPDM_EVENT_SUBSCRIBE_NONE
    SUB_ALL,    \* LIBSPDM_EVENT_SUBSCRIBE_ALL
    SUB_LIST    \* LIBSPDM_EVENT_SUBSCRIBE_LIST

\* Error response codes relevant to this model
CONSTANTS
    RESP_OK,                 \* EVENT_ACK success
    RESP_VERSION_MISMATCH,   \* SPDM_ERROR_CODE_VERSION_MISMATCH
    RESP_REQUEST_IN_FLIGHT,  \* SPDM_ERROR_CODE_REQUEST_IN_FLIGHT
    RESP_NONE                \* no response yet

\* ---- Variables ----

VARIABLES
    \* --- Session lifecycle ---
    session_state,       \* session_state ∈ {NOT_STARTED, HANDSHAKE, ESTABLISHED}
                         \*   libspdm_session_state_t per session_info->secured_message_context

    \* --- Responder response state machine ---
    response_state,      \* response_state ∈ {NORMAL, PROCESSING_ENCAP}
                         \*   libspdm_context_t::response_state

    \* --- Event subscription (managed by integrator HAL via libspdm_event_subscribe) ---
    subscription_state,  \* subscription_state ∈ {SUB_NONE, SUB_ALL, SUB_LIST}
                         \*   tracks what libspdm_event_subscribe last set; Family 2

    event_all_policy,    \* event_all_policy ∈ BOOLEAN
                         \*   TRUE if KEY_EXCHANGE included SESSION_POLICY_EVENT_ALL_POLICY
                         \*   libspdm_rsp_key_exchange.c:800-801; Family 2

    subscribe_types_sent, \* subscribe_types_sent ∈ BOOLEAN
                          \*   TRUE once SUBSCRIBE_EVENT_TYPES has been sent this session
                          \*   needed for EventAllPolicyImpliesSubscribeAll invariant; Family 2

    \* --- Encap flow (Responder-as-Notifier) ---
    encap_event_in_flight, \* encap_event_in_flight ∈ BOOLEAN
                            \*   TRUE while libspdm_init_send_event_encap_state has been called
                            \*   and ProcessEncapEventAck has not yet cleared it; Family 1, 3
                            \*   libspdm_rsp_encap_response.c:246-266

    \* --- Direct SEND_EVENT flow (Requester-as-Notifier) ---
    direct_send_active,             \* direct_send_active ∈ BOOLEAN
                                     \*   TRUE while requester's SEND_EVENT is being handled; Family 1
    last_send_event_response,       \* last_send_event_response ∈ {RESP_OK, RESP_VERSION_MISMATCH,
                                     \*                            RESP_REQUEST_IN_FLIGHT, RESP_NONE}
                                     \*   records what response the last direct SEND_EVENT received;
                                     \*   used by RequestInFlightGuard invariant; Family 1
    last_mismatch_response_state    \* response_state at the time HandleSendEventVersionMismatch last fired;
                                     \*   Family 1: distinguishes "mismatch during encap" (bug) from
                                     \*   "mismatch then encap starts" (valid); ∈ {NORMAL, PROCESSING_ENCAP}

\* Variable groups for UNCHANGED
sessionVars      == <<session_state>>
respStateVars    == <<response_state>>
subscriptionVars == <<subscription_state, event_all_policy, subscribe_types_sent>>
encapVars        == <<encap_event_in_flight>>
directVars       == <<direct_send_active, last_send_event_response, last_mismatch_response_state>>

vars == <<session_state, response_state, subscription_state, event_all_policy,
          subscribe_types_sent, encap_event_in_flight,
          direct_send_active, last_send_event_response, last_mismatch_response_state>>

\* ---- Type invariant ----

TypeOK ==
    /\ session_state \in {NOT_STARTED, HANDSHAKE, ESTABLISHED}
    /\ response_state \in {NORMAL, PROCESSING_ENCAP}
    /\ subscription_state \in {SUB_NONE, SUB_ALL, SUB_LIST}
    /\ event_all_policy \in BOOLEAN
    /\ subscribe_types_sent \in BOOLEAN
    /\ encap_event_in_flight \in BOOLEAN
    /\ direct_send_active \in BOOLEAN
    /\ last_send_event_response \in {RESP_OK, RESP_VERSION_MISMATCH,
                                     RESP_REQUEST_IN_FLIGHT, RESP_NONE}
    /\ last_mismatch_response_state \in {NORMAL, PROCESSING_ENCAP}

\* ---- Init ----

Init ==
    /\ session_state = NOT_STARTED
    /\ response_state = NORMAL
    /\ subscription_state = SUB_NONE
    /\ event_all_policy = FALSE
    /\ subscribe_types_sent = FALSE
    /\ encap_event_in_flight = FALSE
    /\ direct_send_active = FALSE
    /\ last_send_event_response = RESP_NONE
    /\ last_mismatch_response_state = NORMAL

\* ========================================================================
\* Actions
\* ========================================================================

\* ------------------------------------------------------------------------
\* HandleKeyExchange(with_event_all)
\* libspdm_get_response_key_exchange() — library/spdm_responder_lib/libspdm_rsp_key_exchange.c
\*
\* Transitions session from NOT_STARTED → HANDSHAKE.
\* If session_policy includes EVENT_ALL_POLICY, calls libspdm_event_subscribe with
\* SUBSCRIBE_ALL (libspdm_rsp_key_exchange.c:798-810).
\* Note: subscription is set while session is still in HANDSHAKE, before ESTABLISHED
\* (libspdm_rsp_key_exchange.c:817 sets HANDSHAKING after this block).
\* ------------------------------------------------------------------------
HandleKeyExchange(with_event_all) ==
    \* Precondition: session not yet started
    /\ session_state = NOT_STARTED
    \* libspdm_rsp_key_exchange.c:817 — transitions to HANDSHAKING after response built
    /\ session_state' = HANDSHAKE
    \* libspdm_rsp_key_exchange.c:798-810 — if spdm_version >= 1.3 and EVENT_ALL_POLICY bit set,
    \* call libspdm_event_subscribe(... LIBSPDM_EVENT_SUBSCRIBE_ALL ...)
    /\ IF with_event_all
       THEN /\ subscription_state' = SUB_ALL   \* libspdm_rsp_key_exchange.c:803
            /\ event_all_policy' = TRUE
       ELSE /\ subscription_state' = SUB_NONE  \* no subscribe call made
            /\ event_all_policy' = FALSE
    /\ subscribe_types_sent' = FALSE
    /\ UNCHANGED <<response_state, encap_event_in_flight,
                   direct_send_active, last_send_event_response, last_mismatch_response_state>>

\* ------------------------------------------------------------------------
\* HandleFinish
\* libspdm_get_response_finish() — FINISH handshake completes the session.
\* Transitions session from HANDSHAKE → ESTABLISHED.
\* Not detailed in brief; modeled minimally to gate post-session actions.
\* ------------------------------------------------------------------------
HandleFinish ==
    /\ session_state = HANDSHAKE
    /\ session_state' = ESTABLISHED
    /\ UNCHANGED <<response_state, subscription_state, event_all_policy,
                   subscribe_types_sent, encap_event_in_flight,
                   direct_send_active, last_send_event_response, last_mismatch_response_state>>

\* ------------------------------------------------------------------------
\* HandleSubscribeEventTypes(subscribe_none)
\* libspdm_get_response_subscribe_event_types_ack()
\*   — library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c
\*
\* response_state is checked FIRST at line 35-39 (correct order).
\* subscribe_event_group_count == 0 → SUBSCRIBE_NONE with no guard for existing
\* subscription (libspdm_rsp_subscribe_event_types_ack.c:121-129).
\* Family 2: SUBSCRIBE_NONE silently overrides EVENT_ALL_POLICY-set SUBSCRIBE_ALL.
\* ------------------------------------------------------------------------
HandleSubscribeEventTypes(subscribe_none) ==
    \* libspdm_rsp_subscribe_event_types_ack.c:35-39 — response_state checked FIRST (correct)
    /\ response_state = NORMAL
    /\ session_state = ESTABLISHED
    \* libspdm_rsp_subscribe_event_types_ack.c:121-129:
    \*   subscribe_event_group_count == 0 → LIBSPDM_EVENT_SUBSCRIBE_NONE
    \*   subscribe_event_group_count != 0 → LIBSPDM_EVENT_SUBSCRIBE_LIST
    \*   No check of prior subscription_state or event_all_policy (Family 2 bug)
    /\ subscription_state' =
           IF subscribe_none
           THEN SUB_NONE   \* libspdm_rsp_subscribe_event_types_ack.c:122
           ELSE SUB_LIST   \* libspdm_rsp_subscribe_event_types_ack.c:126
    /\ subscribe_types_sent' = TRUE
    /\ UNCHANGED <<session_state, response_state, event_all_policy,
                   encap_event_in_flight, direct_send_active, last_send_event_response, last_mismatch_response_state>>

\* ------------------------------------------------------------------------
\* HandleSendEventVersionMatch
\* libspdm_get_response_event_ack() — library/spdm_responder_lib/libspdm_rsp_event_ack.c
\*
\* Code path: request version MATCHES connection version.
\* In this path versions pass at line 44, then response_state is checked at line 49.
\* When response_state = PROCESSING_ENCAP, handle_response_state returns REQUEST_IN_FLIGHT
\* (libspdm_rsp_handle_response_state.c:53-56).
\* This path is CORRECT even with the check-order bug.
\* ------------------------------------------------------------------------
HandleSendEventVersionMatch ==
    /\ session_state = ESTABLISHED
    /\ direct_send_active = FALSE
    \* libspdm_rsp_event_ack.c:37: connection version check passes (>= 1.3)
    \* libspdm_rsp_event_ack.c:44-48: version matches — no error, continues
    \* libspdm_rsp_event_ack.c:49-54: response_state check (reached after version checks)
    /\ last_send_event_response' =
           IF response_state = PROCESSING_ENCAP
           THEN RESP_REQUEST_IN_FLIGHT  \* libspdm_rsp_handle_response_state.c:53-56
           ELSE RESP_OK                 \* normal processing
    /\ direct_send_active' = TRUE
    /\ UNCHANGED <<session_state, response_state, subscriptionVars,
                   encap_event_in_flight, last_mismatch_response_state>>

\* ------------------------------------------------------------------------
\* HandleSendEventVersionMismatch
\* libspdm_get_response_event_ack() — library/spdm_responder_lib/libspdm_rsp_event_ack.c
\*
\* Code path: request version DOES NOT MATCH connection version.
\* BUG (Family 1): version mismatch check at line 44-48 fires BEFORE response_state
\* check at line 49. When response_state = PROCESSING_ENCAP, the handler returns
\* VERSION_MISMATCH instead of REQUEST_IN_FLIGHT.
\* Expected: PROCESSING_ENCAP must always produce REQUEST_IN_FLIGHT regardless of version.
\* Actual: version mismatch short-circuits and returns VERSION_MISMATCH.
\* Every other event handler (e.g., libspdm_rsp_subscribe_event_types_ack.c:35-39)
\* checks response_state FIRST so the PROCESSING_ENCAP case is always caught.
\* ------------------------------------------------------------------------
HandleSendEventVersionMismatch ==
    /\ session_state = ESTABLISHED
    /\ direct_send_active = FALSE
    \* libspdm_rsp_event_ack.c:37: version >= 1.3 passes
    \* libspdm_rsp_event_ack.c:44-48: version MISMATCH → returns VERSION_MISMATCH
    \* BUG: response_state check at line 49 is never reached
    \* If response_state = PROCESSING_ENCAP here, the correct response would be
    \* REQUEST_IN_FLIGHT (per libspdm_rsp_handle_response_state.c:53-56) but is
    \* instead VERSION_MISMATCH
    /\ last_send_event_response' = RESP_VERSION_MISMATCH
    /\ last_mismatch_response_state' = response_state  \* record response_state AT handler call time
    /\ direct_send_active' = TRUE
    /\ UNCHANGED <<session_state, response_state, subscriptionVars, encap_event_in_flight>>

\* Clears the in-flight state after response is received
HandleSendEventComplete ==
    /\ direct_send_active = TRUE
    /\ direct_send_active' = FALSE
    /\ UNCHANGED <<session_state, response_state, subscriptionVars,
                   encap_event_in_flight, last_send_event_response, last_mismatch_response_state>>

\* ------------------------------------------------------------------------
\* InitEncapSendEvent
\* libspdm_init_send_event_encap_state()
\*   — library/spdm_responder_lib/libspdm_rsp_encap_response.c:246-266
\*
\* Integrator calls this to initiate an encapsulated SEND_EVENT from Responder.
\* Sets response_state = PROCESSING_ENCAP (line 259).
\* BUG (Family 3): takes no subscription_state parameter; no check that the
\* session has an active subscription before entering encap flow.
\* ------------------------------------------------------------------------
InitEncapSendEvent ==
    /\ session_state = ESTABLISHED
    /\ response_state = NORMAL
    /\ encap_event_in_flight = FALSE
    \* libspdm_rsp_encap_response.c:259 — unconditionally sets PROCESSING_ENCAP
    \* No check of subscription_state (Family 3 bug)
    /\ response_state' = PROCESSING_ENCAP
    /\ encap_event_in_flight' = TRUE
    /\ UNCHANGED <<sessionVars, subscriptionVars, directVars>>

\* ------------------------------------------------------------------------
\* HandleEncapSendEvent
\* libspdm_get_encap_request_send_event()
\*   — library/spdm_responder_lib/libspdm_rsp_encap_send_event.c:11-65
\*
\* Generates the encap SEND_EVENT request for the Requester-as-Recipient.
\* BUG (Family 3): libspdm_generate_event_list() called at line 51-54 without
\* checking subscription_state. If subscription is NONE, events are still sent.
\* ------------------------------------------------------------------------
HandleEncapSendEvent ==
    /\ encap_event_in_flight = TRUE
    /\ response_state = PROCESSING_ENCAP
    /\ session_state = ESTABLISHED
    \* libspdm_rsp_encap_send_event.c:51-54: generates event list, NO subscription check
    \* Event is delivered regardless of subscription_state
    \* (Family 3 bug: subscription_state may be SUB_NONE here)
    /\ UNCHANGED vars   \* event content is abstracted; observable: subscription_state unchanged

\* ------------------------------------------------------------------------
\* ProcessEncapEventAck
\* libspdm_process_encap_response_event_ack()
\*   — library/spdm_responder_lib/libspdm_rsp_encap_send_event.c:67-120
\*
\* Responder processes EVENT_ACK from Requester; clears encap flow state.
\* Sets need_continue = FALSE (line 117) — encap exchange is complete.
\* Clearing response_state to NORMAL happens in the encap dispatch caller.
\* ------------------------------------------------------------------------
ProcessEncapEventAck ==
    /\ encap_event_in_flight = TRUE
    /\ response_state = PROCESSING_ENCAP
    \* libspdm_rsp_encap_send_event.c:117: need_continue = FALSE → encap done
    \* Caller clears response_state back to NORMAL
    /\ response_state' = NORMAL
    /\ encap_event_in_flight' = FALSE
    /\ UNCHANGED <<sessionVars, subscriptionVars, directVars>>

\* ------------------------------------------------------------------------
\* TerminateSession
\* Session termination — resets all session-scoped state
\* ------------------------------------------------------------------------
TerminateSession ==
    /\ session_state = ESTABLISHED
    /\ session_state' = NOT_STARTED
    /\ response_state' = NORMAL
    /\ subscription_state' = SUB_NONE
    /\ event_all_policy' = FALSE
    /\ subscribe_types_sent' = FALSE
    /\ encap_event_in_flight' = FALSE
    /\ direct_send_active' = FALSE
    /\ last_send_event_response' = RESP_NONE
    /\ last_mismatch_response_state' = NORMAL

\* ---- Next ----

Next ==
    \/ HandleKeyExchange(TRUE)
    \/ HandleKeyExchange(FALSE)
    \/ HandleFinish
    \/ HandleSubscribeEventTypes(TRUE)   \* SUBSCRIBE_NONE
    \/ HandleSubscribeEventTypes(FALSE)  \* SUBSCRIBE_LIST
    \/ HandleSendEventVersionMatch
    \/ HandleSendEventVersionMismatch
    \/ HandleSendEventComplete
    \/ InitEncapSendEvent
    \/ HandleEncapSendEvent
    \/ ProcessEncapEventAck
    \/ TerminateSession

Spec == Init /\ [][Next]_vars

\* ========================================================================
\* Invariants
\* ========================================================================

\* --- Standard structural invariant ---

\* response_state = PROCESSING_ENCAP only when encap flow is active
ProcessingEncapImpliesEncapInFlight ==
    response_state = PROCESSING_ENCAP => encap_event_in_flight = TRUE

\* Encap flow only possible in ESTABLISHED session
EncapInFlightSessionValid ==
    encap_event_in_flight = TRUE => session_state = ESTABLISHED

\* ---- Extension invariant: Family 1 ----
\* Bug: HandleSendEventVersionMismatch can return VERSION_MISMATCH when
\* response_state = PROCESSING_ENCAP. The correct response is always REQUEST_IN_FLIGHT.
\*
\* Uses last_mismatch_response_state to record what response_state was AT THE TIME
\* the handler fired — avoids false positives where version mismatch is handled
\* correctly (NORMAL) and encap only starts afterward.
\* Violation: handler was called when PROCESSING_ENCAP was already active.
RequestInFlightGuard ==
    (direct_send_active = TRUE /\ last_send_event_response = RESP_VERSION_MISMATCH)
        => last_mismatch_response_state = NORMAL

\* ---- Extension invariant: Family 2 ----
\* Bug: SUBSCRIBE_EVENT_TYPES with param1=0 sets subscription_state = NONE unconditionally,
\* overriding EVENT_ALL_POLICY subscription set at KEY_EXCHANGE.
\*
\* (a) Before any SUBSCRIBE_EVENT_TYPES is sent, EVENT_ALL_POLICY implies SUBSCRIBE_ALL.
EventAllPolicyImpliesSubscribeAll ==
    (event_all_policy = TRUE /\ subscribe_types_sent = FALSE)
        => subscription_state = SUB_ALL

\* (b) SUBSCRIBE_NONE must not block events if EVENT_ALL_POLICY was the only source of
\* subscription (i.e., session established with ALL, then overridden to NONE).
\* This is the hypothesis under test: modeled as a reachability question.
EventAllOverriddenToNone ==
    ~(event_all_policy = TRUE /\ subscription_state = SUB_NONE)

\* ---- Extension invariant: Family 2 + 3 ----
\* No event should be delivered (encap or direct) for a session with subscription_state = NONE.
\* Family 3 bug: InitEncapSendEvent + HandleEncapSendEvent proceed without checking subscription.
\* Violation: encap_event_in_flight = TRUE while subscription_state = NONE.
SubscribeNoneBlocksEvents ==
    subscription_state = SUB_NONE => encap_event_in_flight = FALSE

\* ---- Extension invariant: Family 1 ----
\* Direct SEND_EVENT and encap SEND_EVENT cannot simultaneously be in flight when
\* response_state = PROCESSING_ENCAP; PROCESSING_ENCAP should block direct SEND_EVENT.
NoDualInFlightConflict ==
    (direct_send_active = TRUE /\ encap_event_in_flight = TRUE)
        => last_send_event_response = RESP_REQUEST_IN_FLIGHT

====
