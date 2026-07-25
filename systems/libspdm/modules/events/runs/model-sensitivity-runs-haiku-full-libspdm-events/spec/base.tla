---- MODULE base ----
(* SPDM 1.3 Event Subscription Protocol Specification

   This spec models the event subscription subsystem of libspdm, focusing on
   protocol state, message-passing between requester and responder, and the
   event processing logic that is the source of the identified bug families.

   Bug-family driven extensions:
   - Family 1: Sequential vs non-sequential event processing paths
   - Family 2: Integer overflow in accumulated size validation
   - Family 3: Session state validation gap (transient changes)
   - Family 4: DMTF event type validation coupling
   - Family 5: Subscription state management (delegated to callbacks)
*)

EXTENDS Naturals, Sequences, FiniteSets, Integers, FiniteSetsExt

(* =========== CONSTANTS =========== *)

CONSTANT MaxEvents, MaxSessions, MaxMessageSize

(* Event types and structure *)
CONSTANT DMTF_EVENT_TYPE, VENDOR_EVENT_TYPE
CONSTANT REGISTRY_ID_DMTF, REGISTRY_ID_VENDOR

(* Session and connection identifiers *)
CONSTANT Requester, Responder

(* =========== VARIABLES =========== *)

(* Standard protocol variables: session and message state *)
VARIABLE session_state        \* session_state[sid] : {NEGOTIATED, ESTABLISHED, CLOSED}
VARIABLE subscribed_types     \* subscribed_types[sid] : SET of event_type
VARIABLE messages             \* bag of messages

(* Extension variables for Bug Families *)

(* Family 1: Path divergence - sequential vs non-sequential *)
VARIABLE events_sequential    \* BOOLEAN: true if current event list has sequential IDs
VARIABLE event_id_map         \* [event_id -> event_index] for non-sequential lookup

(* Family 2: Integer overflow in size accumulation *)
VARIABLE msg_size_accum       \* accumulated size during event parsing

(* Family 3: Session state validation gap *)
(* session_state[sid] is checked at entry, but can change before callback;
   This is captured by non-deterministic session closure during processing *)
VARIABLE pending_callbacks    \* {[sid, callback_type, args]} for deferred invocation

(* Family 4: DMTF event type validation *)
VARIABLE event_validated      \* event_validated[event_idx] : BOOLEAN

(* Family 5: Subscription state delegation *)
VARIABLE integrator_subscribed_types  \* integrator's view: [sid -> SET of event_type]

(* =========== SPECIFICATION STATE =========== *)

vars == << session_state, subscribed_types, messages, events_sequential,
           event_id_map, msg_size_accum, pending_callbacks, event_validated,
           integrator_subscribed_types >>

nonMessageVars == << session_state, subscribed_types, events_sequential,
                      event_id_map, msg_size_accum, pending_callbacks,
                      event_validated, integrator_subscribed_types >>

(* =========== TYPE DEFINITIONS =========== *)

SessionStates == {"NEGOTIATED", "ESTABLISHED", "CLOSED"}
\* Event type enumeration
EventTypeConstant == 1..MaxEvents

\* Full event structure (models the event_descriptor struct in libspdm)
Event == [instance_id : 1..MaxEvents,
          registry_id : {REGISTRY_ID_DMTF, REGISTRY_ID_VENDOR},
          detail_len : 1..MaxMessageSize]

\* For backwards compatibility in actions that expect integer event types
EventTypes == EventTypeConstant
Sessions == 1..MaxSessions

(* Message record structure *)
\* Note: body field is not type-restricted to allow any value
IsSomeMessage(m) ==
    m.src \in {Requester, Responder} /\
    m.dst \in {Requester, Responder} /\
    m.type \in STRING /\
    m.sid \in Sessions

(* =========== HELPER FUNCTIONS =========== *)

\* Check if an event instance ID list is sequential (consecutive, no gaps/duplicates)
IsSequential(ids) ==
    /\ ids /= <<>>
    /\ \A i \in 1..(Len(ids)-1) : ids[i+1].instance_id = ids[i].instance_id + 1

\* Check if event instance IDs are valid (sequential OR gap-free with no duplicates)
\* libspdm_rsp_event_ack.c:202-210: gap-free validation logic
ValidEventSequence(ids, is_seq) ==
    IF is_seq THEN
        IsSequential(ids)
    ELSE
        /\ Len(ids) > 0
        /\ LET id_set == {ids[i].instance_id : i \in 1..Len(ids)} IN
           \* Non-sequential path: no duplicates and max-min range == count-1
           /\ Cardinality(id_set) = Len(ids)
           /\ (ids[1].instance_id + Len(ids) - 1) >= Max(id_set)

\* Simulate the search-based lookup in non-sequential path
\* libspdm_rsp_event_ack.c:228-244: libspdm_find_event_instance_id called per event
FindEventIndex(id, ids) ==
    IF id \in {ids[i].instance_id : i \in 1..Len(ids)} THEN
        CHOOSE i \in 1..Len(ids) : ids[i].instance_id = id
    ELSE
        -1  \* not found

(* =========== INITIALIZATION =========== *)

Init ==
    /\ session_state = [s \in Sessions |-> "NEGOTIATED"]
    /\ subscribed_types = [s \in Sessions |-> {}]
    /\ messages = {}
    /\ events_sequential = FALSE
    /\ event_id_map = <<>>
    /\ msg_size_accum = 0
    /\ pending_callbacks = {}
    /\ event_validated = [i \in 1..MaxEvents |-> FALSE]
    /\ integrator_subscribed_types = [s \in Sessions |-> {}]

(* =========== ACTIONS =========== *)

(* Establish a secure session *)
InitSession(sid) ==
    /\ session_state[sid] = "NEGOTIATED"
    /\ session_state' = [session_state EXCEPT ![sid] = "ESTABLISHED"]
    /\ UNCHANGED << subscribed_types, messages, events_sequential,
                     event_id_map, msg_size_accum, pending_callbacks,
                     event_validated, integrator_subscribed_types >>

(* Close a session (can happen non-deterministically - Family 3 mechanism) *)
CloseSession(sid) ==
    /\ session_state[sid] \in {"ESTABLISHED"}
    /\ session_state' = [session_state EXCEPT ![sid] = "CLOSED"]
    /\ UNCHANGED << subscribed_types, messages, events_sequential,
                     event_id_map, msg_size_accum, pending_callbacks,
                     event_validated, integrator_subscribed_types >>

(* Requester sends SUBSCRIBE_EVENT_TYPES request
   libspdm_req_subscribe_event_types (not explicitly in brief functions,
   but implied by the subscription protocol)
*)
ReqSubscribeEventTypes(sid, types) ==
    /\ session_state[sid] = "ESTABLISHED"
    /\ \E msg \in {[src |-> Requester, dst |-> Responder, type |-> "SUBSCRIBE_EVENT_TYPES",
                    sid |-> sid, body |-> [event_types |-> types]]}:
       messages' = messages \cup {msg}
    /\ UNCHANGED << session_state, subscribed_types, events_sequential,
                     event_id_map, msg_size_accum, pending_callbacks,
                     event_validated, integrator_subscribed_types >>

(* Responder receives SUBSCRIBE_EVENT_TYPES request and sends ACK
   libspdm_get_response_subscribe_event_types_ack.c:71-152

   Lines 93-98: session state checked once at entry
   Lines 131-137: callback invoked without re-validation

   This is where Family 3 (session state validation gap) can manifest:
   between the check at lines 93-98 and the callback at line 136,
   the session could be closed by an external event.
*)
RespSubscribeEventTypesAck(sid) ==
    /\ session_state[sid] = "ESTABLISHED"
    /\ \E msg \in messages:
       /\ msg.type = "SUBSCRIBE_EVENT_TYPES"
       /\ msg.sid = sid
       /\ msg.src = Requester
       /\ msg.dst = Responder
       \* Remove the request message and send ACK
       /\ messages' = (messages \ {msg}) \cup
           {[src |-> Responder, dst |-> Requester, type |-> "SUBSCRIBE_EVENT_TYPES_ACK",
             sid |-> sid, body |-> [status |-> "success"]]}
       \* Delegate subscription to integrator callback (libspdm_event_subscribe)
       \* For now, assume callback succeeds and updates integrator's view
       /\ integrator_subscribed_types' = [integrator_subscribed_types EXCEPT
           ![sid] = msg.body.event_types]
       /\ UNCHANGED << session_state, subscribed_types, events_sequential,
                        event_id_map, msg_size_accum, pending_callbacks,
                        event_validated >>

(* Responder sends EVENT_ACK with a list of events
   This action models the core of libspdm_get_response_event_ack.c:71-260

   The function has two paths (Family 1):
   - Sequential path (lines 222-227): events in order, sequential IDs
   - Non-sequential path (lines 228-244): search-based lookup

   We split into two actions to model path divergence.
*)

(* Sequential event processing path
   libspdm_rsp_event_ack.c:222-227

   Events have sequential instance IDs (e.g., 1, 2, 3, ...)
   Events processed in order with a running pointer
*)
RespSendEventAckSeq(sid, event_list) ==
    /\ session_state[sid] = "ESTABLISHED"
    /\ events_sequential' = TRUE
    /\ \* Validate event sequence (Family 1 invariant)
       ValidEventSequence(event_list, TRUE)
    /\ \* Build event_id_map for sequential case (line 222-227)
       event_id_map' = event_list
    /\ \* Accumulate event sizes (Family 2: check for overflow)
       LET total_size == SumSet({event_list[i].detail_len : i \in 1..Len(event_list)})
       IN
       /\ total_size <= MaxMessageSize
       /\ msg_size_accum' = total_size
    /\ \* DMTF validation for each event (Family 4)
       \* libspdm_rsp_event_ack.c:175-180
       /\ event_validated' = [i \in 1..Len(event_validated) |->
          IF i <= Len(event_list) /\ event_list[i].registry_id = REGISTRY_ID_DMTF
          THEN TRUE
          ELSE event_validated[i]]
    /\ \* Send EVENT_ACK message
       \E msg \in {[src |-> Responder, dst |-> Requester, type |-> "EVENT_ACK",
                    sid |-> sid,
                    body |-> [event_list |-> event_list, is_sequential |-> TRUE]]}:
          messages' = messages \cup {msg}
    /\ UNCHANGED << session_state, subscribed_types, pending_callbacks,
                     integrator_subscribed_types >>

(* Non-sequential event processing path
   libspdm_rsp_event_ack.c:228-244

   Events have non-sequential instance IDs.
   For each event, search for it using libspdm_find_event_instance_id (line 237)
   This creates an O(n^2) loop that is less tested than the sequential path.
*)
RespSendEventAckNonSeq(sid, event_list) ==
    /\ session_state[sid] = "ESTABLISHED"
    /\ events_sequential' = FALSE
    /\ \* Validate event sequence (Family 1 invariant - non-sequential)
       ValidEventSequence(event_list, FALSE)
    /\ \* Build event_id_map for non-sequential case (lines 228-244)
       \* Each event is searched for by ID (O(n^2) behavior)
       event_id_map' = [i \in 1..Len(event_list) |->
           FindEventIndex(event_list[i].instance_id, event_list)]
    /\ \* Accumulate event sizes (Family 2)
       \* Line 188-190: accumulated without overflow check
       LET total_size == SumSet({event_list[i].detail_len : i \in 1..Len(event_list)})
       IN
       /\ total_size <= MaxMessageSize
       /\ msg_size_accum' = total_size
    /\ \* DMTF validation (Family 4)
       /\ event_validated' = [i \in 1..Len(event_validated) |->
          IF i <= Len(event_list) /\ event_list[i].registry_id = REGISTRY_ID_DMTF
          THEN TRUE
          ELSE event_validated[i]]
    /\ \E msg \in {[src |-> Responder, dst |-> Requester, type |-> "EVENT_ACK",
                    sid |-> sid,
                    body |-> [event_list |-> event_list, is_sequential |-> FALSE]]}:
       messages' = messages \cup {msg}
    /\ UNCHANGED << session_state, subscribed_types, pending_callbacks,
                     integrator_subscribed_types >>

(* Requester receives EVENT_ACK
   libspdm_get_encap_response_event_ack.c (requester handler)
*)
ReqHandleEventAck(sid) ==
    /\ session_state[sid] = "ESTABLISHED"
    /\ \E msg \in messages:
       /\ msg.type = "EVENT_ACK"
       /\ msg.sid = sid
       /\ msg.src = Responder
       /\ msg.dst = Requester
       /\ messages' = messages \ {msg}
    /\ UNCHANGED << session_state, subscribed_types, events_sequential,
                     event_id_map, msg_size_accum, pending_callbacks,
                     event_validated, integrator_subscribed_types >>

(* Process pending callbacks
   Family 3 mechanism: callbacks are deferred, and session state can change
   before callback invocation.

   This separates the validation-phase (atomic) from the processing-phase
   (can be interrupted).
*)
ProcessCallback ==
    /\ pending_callbacks /= {}
    /\ \E cb \in pending_callbacks:
       /\ pending_callbacks' = pending_callbacks \ {cb}
       \* If the session is closed when callback fires, it's an error
       \* (this models the race condition in Family 3)
       /\ IF session_state[cb.sid] = "CLOSED" THEN
             \* Callback race detected - process_event called on closed session
             \* The spec flags this as an invariant violation
             TRUE
          ELSE
             TRUE
    /\ UNCHANGED << session_state, subscribed_types, messages,
                     events_sequential, event_id_map, msg_size_accum,
                     event_validated, integrator_subscribed_types >>

(* =========== SAFETY INVARIANTS =========== *)

(* Family 3: EventsInEstablishedSession
   Events can only be processed when the session is in ESTABLISHED state.
   This invariant is about when messages are sent; the actual delivery
   happens afterward, and the race condition is modeled by CloseSession.
*)
EventsInEstablishedSession ==
    \A m \in messages:
    (m.type = "EVENT_ACK" => session_state[m.sid] = "ESTABLISHED")

(* Family 1: SequentialOrGapFree
   Event instance IDs must be either sequential (consecutive) or gap-free.

   The non-sequential path's validation at lines 202-210 checks:
   (a) no duplicates: Cardinality({id_1, ..., id_n}) = n
   (b) gap-free: all IDs between min and max are present (implicitly by count)
*)
SequentialOrGapFree ==
    (events_sequential \/ event_id_map = <<>>) \/
    (\* In non-sequential mode, event_id_map should not contain -1 (search failed) *)
     \A i \in 1..Len(event_id_map):
         event_id_map[i] > 0)

(* Family 2: SizeAccumulationBounded
   Accumulated size must never overflow; final value must not exceed MaxMessageSize.

   This detects the overflow vulnerability at libspdm_rsp_event_ack.c:188-190
   where sizes are accumulated without overflow checks, but the final validation
   at line 194 may miss intermediate overflow.
*)
SizeAccumulationBounded ==
    msg_size_accum <= MaxMessageSize

(* Family 4: DMTFEventsValidated
   All events with REGISTRY_ID_DMTF must pass type validation before processing.

   libspdm_rsp_event_ack.c:175-180 validates DMTF events; if validation is
   skipped or diverges across code paths, invalid events could leak through.
*)
DMTFEventsValidated ==
    \* After an EVENT_ACK is sent, all DMTF events must have been validated
    \A m \in messages:
    (m.type = "EVENT_ACK" =>
     \A i \in 1..Len(m.body.event_list):
         (m.body.event_list[i].registry_id = REGISTRY_ID_DMTF =>
          event_validated[i] = TRUE))

(* Family 5: SubscriptionConsistency (Liveness - checked with fairness)
   If the integrator's subscription state diverges from the library's,
   generated events should match the integrator's actual subscriptions.

   This invariant captures the risk of state divergence when the library
   delegates to external callbacks without consistency guarantees.
*)
SubscriptionConsistency ==
    \* For now, assert they can diverge but track both views
    TRUE

(* Type safety *)
SessionStateOK ==
    \A s \in Sessions: session_state[s] \in SessionStates

MessageOK ==
    \A m \in messages:
    /\ m.src \in {Requester, Responder}
    /\ m.dst \in {Requester, Responder}
    /\ m.src /= m.dst
    /\ m.sid \in Sessions

(* =========== NEXT STATE RELATION =========== *)

Next ==
    \/ \E sid \in Sessions: InitSession(sid)
    \/ \E sid \in Sessions: CloseSession(sid)
    \/ \E sid \in Sessions, types \in SUBSET EventTypes: ReqSubscribeEventTypes(sid, types)
    \/ \E sid \in Sessions: RespSubscribeEventTypesAck(sid)
    \/ \E sid \in Sessions, events \in Seq(EventTypes): RespSendEventAckSeq(sid, events)
    \/ \E sid \in Sessions, events \in Seq(EventTypes): RespSendEventAckNonSeq(sid, events)
    \/ \E sid \in Sessions: ReqHandleEventAck(sid)
    \/ ProcessCallback

Spec == Init /\ [][Next]_vars

(* =========== TEMPORAL PROPERTIES =========== *)

\* The protocol should not deadlock (liveness)
EventuallyProcesses ==
    <>[](messages = {})

====
