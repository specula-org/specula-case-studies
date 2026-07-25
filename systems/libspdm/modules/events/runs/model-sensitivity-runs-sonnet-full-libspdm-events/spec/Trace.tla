---- MODULE Trace ----
\* Trace validation spec for libspdm SPDM 1.3 event subscription.
\*
\* Category A (Distributed / Message-Passing): single linear trace cursor `l`.
\* Drives TLC through a recorded NDJSON execution trace, verifying that the
\* base spec can reproduce every observed state transition.
\*
\* Trace file location: ../traces/<name>.ndjson
\* Override with env var: JSON=path/to/trace.ndjson tlc Trace.tla

EXTENDS base, Sequences, Naturals, TLC, IOUtils, Json

\* ---- faultVarsTrace: dummy variable (no fault injection in trace validation) ----
VARIABLE faultVarsTrace

\* ---- Trace loading ----

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* ---- Cursor ----

VARIABLE l   \* cursor index into TraceLog; l=1 is first event

logline == TraceLog[l]

\* ---- Event name predicates ----

IsEvent(name) == logline.event = name

\* ---- String-to-constant mapping ----
\* Harness emits string values; map to spec constants.

StrToSessionState(s) ==
    CASE s = "NOT_STARTED"  -> NOT_STARTED
    []   s = "HANDSHAKE"    -> HANDSHAKE
    []   s = "ESTABLISHED"  -> ESTABLISHED
    []   OTHER              -> Assert(FALSE, <<"Unknown session_state", s>>)

StrToResponseState(s) ==
    CASE s = "NORMAL"           -> NORMAL
    []   s = "PROCESSING_ENCAP" -> PROCESSING_ENCAP
    []   OTHER                  -> Assert(FALSE, <<"Unknown response_state", s>>)

StrToSubscriptionState(s) ==
    CASE s = "SUB_NONE" -> SUB_NONE
    []   s = "SUB_ALL"  -> SUB_ALL
    []   s = "SUB_LIST" -> SUB_LIST
    []   OTHER          -> Assert(FALSE, <<"Unknown subscription_state", s>>)

StrToRespCode(s) ==
    CASE s = "OK"                  -> RESP_OK
    []   s = "VERSION_MISMATCH"    -> RESP_VERSION_MISMATCH
    []   s = "REQUEST_IN_FLIGHT"   -> RESP_REQUEST_IN_FLIGHT
    []   s = "NONE"                -> RESP_NONE
    []   OTHER                     -> Assert(FALSE, <<"Unknown response_code", s>>)

\* ---- Post-state validation helpers ----
\* Each action wrapper calls ValidatePostState with the fields captured in logline.
\* Fields map to spec variables via the instrumentation-spec.md section 2.

ValidateSessionState ==
    session_state' = StrToSessionState(logline.post.session_state)

ValidateResponseState ==
    response_state' = StrToResponseState(logline.post.response_state)

ValidateSubscriptionState ==
    subscription_state' = StrToSubscriptionState(logline.post.subscription_state)

ValidateEventAllPolicy ==
    event_all_policy' = logline.post.event_all_policy

ValidateSubscribeTypesSent ==
    subscribe_types_sent' = logline.post.subscribe_types_sent

ValidateEncapInFlight ==
    encap_event_in_flight' = logline.post.encap_event_in_flight

ValidateDirectSendActive ==
    direct_send_active' = logline.post.direct_send_active

ValidateLastSendEventResponse ==
    last_send_event_response' = StrToRespCode(logline.post.last_send_event_response)

\* ---- TraceInit ----
\* Bootstrap from trace's first event pre-state.
\* In libspdm, the initial state is always the same as Init; no special bootstrap needed.

TraceInit ==
    /\ Init
    /\ l = 1

\* ---- Action wrappers ----
\* Each wrapper: (1) matches the event name, (2) calls the base spec action,
\* (3) validates post-state fields, (4) advances cursor.

TraceHandleKeyExchange ==
    /\ IsEvent("HandleKeyExchange")
    /\ HandleKeyExchange(logline.params.with_event_all)
    /\ ValidateSessionState
    /\ ValidateSubscriptionState
    /\ ValidateEventAllPolicy
    /\ ValidateSubscribeTypesSent
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceHandleFinish ==
    /\ IsEvent("HandleFinish")
    /\ HandleFinish
    /\ ValidateSessionState
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceHandleSubscribeEventTypes ==
    /\ IsEvent("HandleSubscribeEventTypes")
    /\ HandleSubscribeEventTypes(logline.params.subscribe_none)
    /\ ValidateSubscriptionState
    /\ ValidateSubscribeTypesSent
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceHandleSendEventVersionMatch ==
    /\ IsEvent("HandleSendEventVersionMatch")
    /\ HandleSendEventVersionMatch
    /\ ValidateDirectSendActive
    /\ ValidateLastSendEventResponse
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceHandleSendEventVersionMismatch ==
    /\ IsEvent("HandleSendEventVersionMismatch")
    /\ HandleSendEventVersionMismatch
    /\ ValidateDirectSendActive
    /\ ValidateLastSendEventResponse
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceHandleSendEventComplete ==
    /\ IsEvent("HandleSendEventComplete")
    /\ HandleSendEventComplete
    /\ ValidateDirectSendActive
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceInitEncapSendEvent ==
    /\ IsEvent("InitEncapSendEvent")
    /\ InitEncapSendEvent
    /\ ValidateResponseState
    /\ ValidateEncapInFlight
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceHandleEncapSendEvent ==
    /\ IsEvent("HandleEncapSendEvent")
    /\ HandleEncapSendEvent
    /\ ValidateEncapInFlight
    /\ ValidateResponseState
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceProcessEncapEventAck ==
    /\ IsEvent("ProcessEncapEventAck")
    /\ ProcessEncapEventAck
    /\ ValidateResponseState
    /\ ValidateEncapInFlight
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

TraceTerminateSession ==
    /\ IsEvent("TerminateSession")
    /\ TerminateSession
    /\ ValidateSessionState
    /\ ValidateResponseState
    /\ ValidateSubscriptionState
    /\ l' = l + 1
    /\ UNCHANGED faultVarsTrace

\* ---- Silent actions ----
\* Silent actions fire without consuming a trace event.
\* No silent actions are needed for this spec: the implementation is
\* single-threaded and every relevant state transition produces a trace event.
\* If a future harness omits some transitions, add constrained silents here.

\* (No silent actions needed for current instrumentation design.)

FaultVarsTraceInit == faultVarsTrace = "none"

\* ---- TraceNext ----

\* Terminal stutter: once the trace is fully consumed, allow infinite stuttering
\* so TLC does not report a false deadlock after the last event.
TraceTerminal ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<vars, l, faultVarsTrace>>

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceHandleKeyExchange
          \/ TraceHandleFinish
          \/ TraceHandleSubscribeEventTypes
          \/ TraceHandleSendEventVersionMatch
          \/ TraceHandleSendEventVersionMismatch
          \/ TraceHandleSendEventComplete
          \/ TraceInitEncapSendEvent
          \/ TraceHandleEncapSendEvent
          \/ TraceProcessEncapEventAck
          \/ TraceTerminateSession
    \/ TraceTerminal

TraceSpec == TraceInit /\ FaultVarsTraceInit /\ [][TraceNext]_<<vars, l, faultVarsTrace>>
             /\ WF_<<vars, l, faultVarsTrace>>(TraceNext)

\* ---- TraceMatched ----
\* Temporal property: the entire trace must be consumed.
\* TLC reports error if l never advances past Len(TraceLog).

TraceMatched == <>(l > Len(TraceLog))

====
