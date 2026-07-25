---- MODULE MC ----
\* Model checking wrapper for libspdm SPDM 1.3 event subscription spec.
\*
\* Adds counter-bounded fault-injection wrappers. Normal reactive actions
\* pass through unchanged. Fault actions (version mismatch injection,
\* SUBSCRIBE_NONE override, encap initiation, session termination) are
\* bounded so TLC can exhaustively explore the state space.

EXTENDS base, Naturals

\* ---- Fault injection counter record ----
\* One counter per bounded (non-deterministic) action.

VARIABLE faultVars

FaultVarsInit == faultVars = [
    versionMismatch  |-> 0,  \* HandleSendEventVersionMismatch firings
    subscribeNone    |-> 0,  \* HandleSubscribeEventTypes(TRUE) firings
    encapInit        |-> 0,  \* InitEncapSendEvent firings
    sessionTerminate |-> 0,  \* TerminateSession firings
    keyExchangeAll   |-> 0   \* HandleKeyExchange(TRUE) firings
]

\* ---- Bound constants (override in cfg) ----
CONSTANTS
    VersionMismatchLimit,   \* max times a version-mismatch SEND_EVENT can be injected
    SubscribeNoneLimit,     \* max SUBSCRIBE_EVENT_TYPES(param1=0) messages
    EncapInitLimit,         \* max times responder initiates encap SEND_EVENT flow
    SessionTerminateLimit,  \* max session terminations
    KeyExchangeAllLimit     \* max KEY_EXCHANGE with EVENT_ALL_POLICY

\* ---- MCInit ----

MCInit == Init /\ FaultVarsInit

\* ---- Bounded fault-injection wrappers ----
\*
\* Rule: only actions that *introduce* non-determinism are bounded.
\* Reactive handlers (HandleFinish, HandleSendEventVersionMatch,
\* HandleEncapSendEvent, ProcessEncapEventAck, HandleSendEventComplete,
\* HandleSubscribeEventTypes(FALSE)) are unbounded.

\* Family 1 fault: inject a version-mismatch SEND_EVENT while PROCESSING_ENCAP
\* Models the scenario where a Requester-as-Notifier sends SEND_EVENT with a
\* version that doesn't match the negotiated connection version.
MCHandleSendEventVersionMismatch ==
    /\ faultVars.versionMismatch < VersionMismatchLimit
    /\ HandleSendEventVersionMismatch
    /\ faultVars' = [faultVars EXCEPT !.versionMismatch = @ + 1]

\* Family 2 fault: Requester sends SUBSCRIBE_EVENT_TYPES with param1=0 (NONE)
\* Overrides EVENT_ALL_POLICY subscription set at KEY_EXCHANGE.
MCHandleSubscribeNone ==
    /\ faultVars.subscribeNone < SubscribeNoneLimit
    /\ HandleSubscribeEventTypes(TRUE)
    /\ faultVars' = [faultVars EXCEPT !.subscribeNone = @ + 1]

\* Family 3 fault: Responder initiates encap SEND_EVENT (may be when sub=NONE)
MCInitEncapSendEvent ==
    /\ faultVars.encapInit < EncapInitLimit
    /\ InitEncapSendEvent
    /\ faultVars' = [faultVars EXCEPT !.encapInit = @ + 1]

\* Session lifecycle bound: keep session re-establishment bounded
MCHandleKeyExchangeWithEventAll ==
    /\ faultVars.keyExchangeAll < KeyExchangeAllLimit
    /\ HandleKeyExchange(TRUE)
    /\ faultVars' = [faultVars EXCEPT !.keyExchangeAll = @ + 1]

MCTerminateSession ==
    /\ faultVars.sessionTerminate < SessionTerminateLimit
    /\ TerminateSession
    /\ faultVars' = [faultVars EXCEPT !.sessionTerminate = @ + 1]

\* ---- Unbounded reactive actions (pass through, UNCHANGED faultVars) ----

MCHandleKeyExchangeNoEventAll ==
    /\ HandleKeyExchange(FALSE)
    /\ UNCHANGED faultVars

MCHandleFinish ==
    /\ HandleFinish
    /\ UNCHANGED faultVars

MCHandleSubscribeList ==
    /\ HandleSubscribeEventTypes(FALSE)
    /\ UNCHANGED faultVars

MCHandleSendEventVersionMatch ==
    /\ HandleSendEventVersionMatch
    /\ UNCHANGED faultVars

MCHandleSendEventComplete ==
    /\ HandleSendEventComplete
    /\ UNCHANGED faultVars

MCHandleEncapSendEvent ==
    /\ HandleEncapSendEvent
    /\ UNCHANGED faultVars

MCProcessEncapEventAck ==
    /\ ProcessEncapEventAck
    /\ UNCHANGED faultVars

\* ---- MCNext ----

MCNext ==
    \* Reactive / unbounded
    \/ MCHandleKeyExchangeNoEventAll
    \/ MCHandleFinish
    \/ MCHandleSubscribeList
    \/ MCHandleSendEventVersionMatch
    \/ MCHandleSendEventComplete
    \/ MCHandleEncapSendEvent
    \/ MCProcessEncapEventAck
    \* Bounded fault injection
    \/ MCHandleSendEventVersionMismatch
    \/ MCHandleSubscribeNone
    \/ MCInitEncapSendEvent
    \/ MCHandleKeyExchangeWithEventAll
    \/ MCTerminateSession

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ---- View (exclude counters from symmetry; state compression) ----

MCView == vars

\* ---- Message buffer constraint (prevent unbounded in-flight accumulation) ----
\* Single-threaded: at most one direct SEND_EVENT and one encap flow at a time.
\* This is structurally enforced by the guards, but stated explicitly here.
MCBufferConstraint ==
    /\ (direct_send_active = TRUE => encap_event_in_flight \in BOOLEAN)

\* ---- Structural invariants (always on; catch modeling errors early) ----

MCProcessingEncapImpliesEncapInFlight ==
    response_state = PROCESSING_ENCAP => encap_event_in_flight = TRUE

MCEncapInFlightSessionValid ==
    encap_event_in_flight = TRUE => session_state = ESTABLISHED

MCEventAllPolicyImpliesSubscribeAll ==
    (event_all_policy = TRUE /\ subscribe_types_sent = FALSE)
        => subscription_state = SUB_ALL

\* ---- Extension invariants (bug-family specific — commented out for convergence runs) ----
\* Uncomment these in MC_hunt_*.cfg files for targeted bug-hunting after spec converges.

\* FAMILY 1 — RequestInFlightGuard
MCRequestInFlightGuard ==
    (direct_send_active = TRUE /\ last_send_event_response = RESP_VERSION_MISMATCH)
        => last_mismatch_response_state = NORMAL

\* FAMILY 1 — NoDualInFlightConflict
MCNoDualInFlightConflict ==
    (direct_send_active = TRUE /\ encap_event_in_flight = TRUE)
        => last_send_event_response = RESP_REQUEST_IN_FLIGHT

\* FAMILY 2 — EventAllOverriddenToNone
MCEventAllOverriddenToNone ==
    ~(event_all_policy = TRUE /\ subscription_state = SUB_NONE)

\* FAMILY 2+3 — SubscribeNoneBlocksEvents
MCSubscribeNoneBlocksEvents ==
    subscription_state = SUB_NONE => encap_event_in_flight = FALSE

====
