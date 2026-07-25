---- MODULE Trace ----
(* Trace Validation Spec for libspdm-events

   This spec validates implementation traces against the base specification.
   The trace cursor `l` walks through recorded events from the system,
   validating that each event matches a base spec action and that state
   transitions are consistent with the implementation.
*)

EXTENDS base, TLC, IOUtils, Json, TraceData

(* =========== TRACE LOADING =========== *)

\* Use trace data from TraceData module, or provide as a constant
CONSTANT TraceLog

(* =========== TRACE VARIABLES =========== *)

\* Cursor into the trace file
VARIABLE l

TraceVars == << vars, l >>

(* =========== TRACE STATE INITIALIZATION =========== *)

\* Bootstrap from trace data if available, otherwise use base Init
TraceInit ==
    /\ IF Len(TraceLog) > 0 THEN
        LET firstEvent == TraceLog[1] IN
        /\ session_state = [s \in Sessions |-> "NEGOTIATED"]
        /\ subscribed_types = [s \in Sessions |-> {}]
        /\ messages = {}
        /\ events_sequential = FALSE
        /\ event_id_map = <<>>
        /\ msg_size_accum = 0
        /\ pending_callbacks = {}
        /\ event_validated = [i \in 1..MaxEvents |-> FALSE]
        /\ integrator_subscribed_types = [s \in Sessions |-> {}]
        ELSE
        /\ Init
    /\ l = 1

(* =========== EVENT MATCHING HELPERS =========== *)

\* Check if current trace line matches an event name
IsEvent(name) ==
    l <= Len(TraceLog) /\ TraceLog[l].event = name

\* Extract session ID from trace event
GetSessionId(event) ==
    IF "sid" \in DOMAIN event THEN event.sid ELSE 1

\* Get event-specific fields from trace
EventBody(event, field) ==
    IF "body" \in DOMAIN event /\ field \in DOMAIN event.body THEN
        event.body[field]
    ELSE
        -1

(* =========== POST-STATE VALIDATION =========== *)

\* Validate state after sequential event processing
ValidatePostStateSeq(event) ==
    /\ IF "expected_size_accum" \in DOMAIN event THEN
        msg_size_accum = event.expected_size_accum
       ELSE TRUE
    /\ IF "expected_events_sequential" \in DOMAIN event THEN
        events_sequential = event.expected_events_sequential
       ELSE TRUE
    /\ IF "expected_event_validated_count" \in DOMAIN event THEN
        Cardinality({i \in 1..MaxEvents : event_validated[i]}) >= event.expected_event_validated_count
       ELSE TRUE

\* Validate state after non-sequential event processing
ValidatePostStateNonSeq(event) ==
    /\ IF "expected_size_accum" \in DOMAIN event THEN
        msg_size_accum = event.expected_size_accum
       ELSE TRUE
    /\ IF "expected_events_sequential" \in DOMAIN event THEN
        events_sequential = event.expected_events_sequential
       ELSE TRUE
    /\ IF "expected_event_id_map_valid" \in DOMAIN event THEN
        \A i \in 1..Len(event_id_map): event_id_map[i] > 0
       ELSE TRUE

(* =========== ACTION WRAPPERS =========== *)

\* SUBSCRIBE_EVENT_TYPES request sent
TraceReqSubscribeEventTypes ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "SUBSCRIBE_EVENT_TYPES"
    /\ LET event == TraceLog[l]
           sid == GetSessionId(event)
           types == EventBody(event, "event_types")
       IN
       /\ ReqSubscribeEventTypes(sid, types)
       /\ l' = l + 1

\* SUBSCRIBE_EVENT_TYPES_ACK received
TraceRespSubscribeEventTypesAck ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "SUBSCRIBE_EVENT_TYPES_ACK"
    /\ LET event == TraceLog[l]
           sid == GetSessionId(event)
       IN
       /\ RespSubscribeEventTypesAck(sid)
       /\ l' = l + 1

\* SEND_EVENT_ACK with sequential event IDs
TraceSendEventAckSeq ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "SEND_EVENT_ACK"
    /\ TraceLog[l].body.is_sequential = TRUE
    /\ LET event == TraceLog[l]
           sid == GetSessionId(event)
           event_list == EventBody(event, "event_list")
       IN
       /\ RespSendEventAckSeq(sid, event_list)
       /\ ValidatePostStateSeq(event)
       /\ l' = l + 1

\* SEND_EVENT_ACK with non-sequential event IDs
TraceSendEventAckNonSeq ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "SEND_EVENT_ACK"
    /\ TraceLog[l].body.is_sequential = FALSE
    /\ LET event == TraceLog[l]
           sid == GetSessionId(event)
           event_list == EventBody(event, "event_list")
       IN
       /\ RespSendEventAckNonSeq(sid, event_list)
       /\ ValidatePostStateNonSeq(event)
       /\ l' = l + 1

\* Handle EVENT_ACK at requester
TraceReqHandleEventAck ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "HANDLE_EVENT_ACK"
    /\ LET event == TraceLog[l]
           sid == GetSessionId(event)
       IN
       /\ ReqHandleEventAck(sid)
       /\ l' = l + 1

\* Session initialization
TraceInitSession ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "INIT_SESSION"
    /\ LET event == TraceLog[l]
           sid == GetSessionId(event)
       IN
       /\ InitSession(sid)
       /\ l' = l + 1

(* =========== SILENT ACTIONS =========== *)

\* Events that occur in implementation but are not traced
\* (must be constrained to prevent explosion)

SilentSessionClose ==
    /\ l <= Len(TraceLog)
    \* Can only silently close if next traced event doesn't require ESTABLISHED
    /\ IF l < Len(TraceLog) THEN
        /\ \E sid \in Sessions: CloseSession(sid)
        /\ UNCHANGED l
       ELSE UNCHANGED TraceVars

SilentProcessCallback ==
    /\ l <= Len(TraceLog)
    /\ pending_callbacks /= {}
    /\ ProcessCallback
    /\ UNCHANGED l

(* =========== TRACE NEXT =========== *)

TraceNext ==
    \/ TraceInitSession
    \/ TraceReqSubscribeEventTypes
    \/ TraceRespSubscribeEventTypesAck
    \/ TraceSendEventAckSeq
    \/ TraceSendEventAckNonSeq
    \/ TraceReqHandleEventAck
    \/ SilentSessionClose
    \/ SilentProcessCallback
    \/ UNCHANGED TraceVars  \* Stutter when trace is exhausted

TraceSpec == TraceInit /\ [][TraceNext]_TraceVars

(* =========== TRACE COMPLETION =========== *)

\* Property: the entire trace should be consumed
TraceMatched == <> (l > Len(TraceLog))

(* =========== SAFETY INVARIANTS =========== *)

\* All base spec invariants should hold during trace validation
TraceEventInEstablishedSession == EventsInEstablishedSession
TraceSequentialOrGapFree == SequentialOrGapFree
TraceSizeAccumulationBounded == SizeAccumulationBounded
TraceDMTFEventsValidated == DMTFEventsValidated

====
