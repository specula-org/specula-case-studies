---- MODULE Trace ----
\* Trace Validation Spec for libspdm-session-lifecycle
\* Replays implementation traces against the base spec

EXTENDS Naturals, Sequences, FiniteSets, TLC, Json, base

\* Sentinel value for invalid/missing data
NULL == "NULL"

\* ==== Trace Loading ====

\* Default trace file location (overridable via JSON environment variable)
JsonFile == "../traces/session-lifecycle.ndjson"

\* Deserialize NDJSON trace into sequence of events
TraceLog == ndJsonDeserialize(JsonFile)

\* Filter by event tag (optional)
FilteredTrace == TraceLog

\* ==== Cursor Variable ====

VARIABLE l  \* Current position in trace (0..Len(TraceLog))

\* ==== Role/Type Mapping ====

\* String-to-constant mapping for implementation events
MapRole(impl_role) ==
    CASE impl_role = "requester" -> Requester
    []   impl_role = "responder" -> Responder
    []   OTHER -> NULL

MapOperation(impl_op) ==
    IF impl_op = "update_key" THEN UPDATE_KEY
    ELSE IF impl_op = "update_all_keys" THEN UPDATE_ALL_KEYS
    ELSE IF impl_op = "verify_new_key" THEN VERIFY_NEW_KEY
    ELSE NULL

MapSessionState(impl_state) ==
    CASE impl_state = "idle" -> IDLE
    []   impl_state = "established" -> ESTABLISHED
    []   impl_state = "ending" -> ENDING
    []   impl_state = "freed" -> FREED
    []   OTHER -> NULL

\* ==== Event Predicates ====

IsEvent(name) ==
    l <= Len(TraceLog) /\ TraceLog[l].event = name

IsNodeEvent(name, role) ==
    IsEvent(name) /\ TraceLog[l].sender = role

IsMsgEvent(name, from, to) ==
    IsEvent(name) /\ TraceLog[l].sender = from /\ TraceLog[l].receiver = to

GetLogline == IF l <= Len(TraceLog) THEN TraceLog[l] ELSE NULL

\* ==== Post-State Validation ====

\* Check if spec state matches trace after action (returns TRUE if valid)
ValidatePostState(event) ==
    LET sid == event.session_id
        log == event
    IN
    CASE log.event = "initialize_session" ->
            (session_state'[sid] = ESTABLISHED /\ heartbeat_enabled'[sid] = TRUE)
    []   log.event = "send_heartbeat" ->
            (session_state'[sid] = ESTABLISHED /\ heartbeat_enabled'[sid] = TRUE)
    []   log.event = "initiate_key_update" ->
            (prev_key_update_operation'[sid] = MapOperation(log.operation) /\ responder_key_created'[sid] = TRUE)
    []   log.event = "handle_key_update" ->
            IF log.operation \in {"update_key", "update_all_keys"} THEN
                (prev_key_update_operation'[sid] = MapOperation(log.operation) /\
                 requester_key_created'[sid] = TRUE /\ responder_key_created'[sid] = TRUE)
            ELSE TRUE
    []   log.event = "send_key_update_verify" ->
            (prev_key_update_operation'[sid] = VERIFY_NEW_KEY /\ responder_key_active'[sid] = TRUE)
    []   log.event = "handle_key_update_verify" ->
            (prev_key_update_operation'[sid] = NONE /\ requester_key_active'[sid] = TRUE)
    []   log.event = "initiate_end_session" ->
            (session_state'[sid] = ENDING)
    []   log.event = "respond_to_end_session" ->
            (session_state'[sid] = ENDING)
    []   log.event = "send_end_session_ack" ->
            (session_freed_by_responder'[sid] = TRUE)
    []   log.event = "receive_end_session_ack" ->
            (session_freed_by_requester'[sid] = TRUE)
    []   log.event = "finalize_session_cleanup" ->
            (session_state'[sid] = FREED)
    []   OTHER -> TRUE

\* ==== Action Wrappers ====
\* All trace actions ensure complete variable declarations by inheriting base action updates

\* Wrapper to ensure consistent variable declarations across all trace actions
\* The base actions define their own variable updates, but we wrap them to ensure
\* the disjunction is well-formed with respect to variable declarations.

\* InitializeSession event
TraceInitializeSession(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("initialize_session")
    /\ logline.sender = "requester"
    /\ session_state[sid] = IDLE
    /\ session_state' = [session_state EXCEPT ![sid] = ESTABLISHED]
    /\ heartbeat_enabled' = [heartbeat_enabled EXCEPT ![sid] = TRUE]
    /\ UNCHANGED <<session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, messages, pending_ack, msg_counter>>
    /\ l' = l + 1

\* RespondToSessionInit event
TraceRespondToSessionInit(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("respond_to_session_init")
    /\ logline.sender = "responder"
    /\ session_state[sid] = ESTABLISHED
    /\ heartbeat_enabled[sid] = TRUE
    /\ UNCHANGED <<session_state, heartbeat_enabled, session_freed_by_requester,
                    session_freed_by_responder, prev_key_update_operation,
                    requester_key_created, responder_key_created, requester_key_active,
                    responder_key_active, messages, pending_ack, msg_counter>>
    /\ l' = l + 1

\* SendHeartbeat event
TraceSendHeartbeat(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("send_heartbeat")
    /\ logline.sender = "requester"
    /\ session_state[sid] = ESTABLISHED
    /\ heartbeat_enabled[sid]
    /\ msg_counter' = msg_counter + 1
    /\ messages' = messages \cup {[type |-> "heartbeat", sender |-> Requester, receiver |-> Responder,
                                    session_id |-> sid, msg_id |-> msg_counter']}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack>>
    /\ l' = l + 1

\* ReceiveHeartbeat event
TraceReceiveHeartbeat(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("receive_heartbeat")
    /\ logline.sender = "responder"
    /\ \E msg \in messages :
         /\ msg.type = "heartbeat"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         /\ heartbeat_enabled[sid] = TRUE
         /\ messages' = messages \ {msg}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>
    /\ l' = l + 1

\* InitiateKeyUpdate event
TraceInitiateKeyUpdate(logline) ==
    LET sid == logline.session_id
        op == MapOperation(logline.message.operation)
    IN
    /\ IsEvent("initiate_key_update")
    /\ logline.sender = "requester"
    /\ op \in {UPDATE_KEY, UPDATE_ALL_KEYS}
    /\ session_state[sid] = ESTABLISHED
    /\ prev_key_update_operation[sid] = NONE
    /\ msg_counter' = msg_counter + 1
    /\ responder_key_created' = [responder_key_created EXCEPT ![sid] = TRUE]
    /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = op]
    /\ messages' = messages \cup {[type |-> "key_update", sender |-> Requester, receiver |-> Responder,
                                   session_id |-> sid, operation |-> op, msg_id |-> msg_counter']}
    /\ pending_ack' = pending_ack \cup {[type |-> "key_update_ack", session_id |-> sid]}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    requester_key_created, requester_key_active, responder_key_active, heartbeat_enabled>>
    /\ l' = l + 1

\* HandleKeyUpdate event
TraceHandleKeyUpdate(logline) ==
    LET sid == logline.session_id
        op == MapOperation(logline.message.operation)
    IN
    /\ IsEvent("handle_key_update")
    /\ logline.sender = "responder"
    /\ op \in {UPDATE_KEY, UPDATE_ALL_KEYS}
    /\ session_state[sid] = ESTABLISHED
    /\ \E msg \in messages :
         /\ msg.type = "key_update"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         /\ msg.operation = op
         /\ IF prev_key_update_operation[sid] = NONE THEN
              /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = op]
              /\ requester_key_created' = [requester_key_created EXCEPT ![sid] = TRUE]
              /\ responder_key_created' = [responder_key_created EXCEPT ![sid] = TRUE]
              /\ UNCHANGED <<requester_key_active, responder_key_active>>
            ELSE
              /\ UNCHANGED <<prev_key_update_operation, requester_key_created,
                              responder_key_created, requester_key_active, responder_key_active>>
         /\ messages' = messages \ {msg}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>
    /\ l' = l + 1

\* SendKeyUpdateVerify event
TraceSendKeyUpdateVerify(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("send_key_update_verify")
    /\ logline.sender = "requester"
    /\ session_state[sid] = ESTABLISHED
    /\ prev_key_update_operation[sid] \in {UPDATE_KEY, UPDATE_ALL_KEYS}
    /\ msg_counter' = msg_counter + 1
    /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = VERIFY_NEW_KEY]
    /\ responder_key_active' = [responder_key_active EXCEPT ![sid] = TRUE]
    /\ messages' = messages \cup {[type |-> "key_update_verify", sender |-> Requester, receiver |-> Responder,
                                   session_id |-> sid, msg_id |-> msg_counter']}
    /\ pending_ack' = pending_ack \cup {[type |-> "key_update_verify_ack", session_id |-> sid]}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    requester_key_created, responder_key_created, requester_key_active, heartbeat_enabled>>
    /\ l' = l + 1

\* HandleKeyUpdateVerify event
TraceHandleKeyUpdateVerify(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("handle_key_update_verify")
    /\ logline.sender = "responder"
    /\ session_state[sid] = ESTABLISHED
    /\ prev_key_update_operation[sid] = VERIFY_NEW_KEY
    /\ \E msg \in messages :
         /\ msg.type = "key_update_verify"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         /\ requester_key_active' = [requester_key_active EXCEPT ![sid] = TRUE]
         /\ requester_key_created' = [requester_key_created EXCEPT ![sid] = TRUE]
         /\ messages' = messages \ {msg}
    /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = NONE]
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    responder_key_created, responder_key_active,
                    heartbeat_enabled, pending_ack, msg_counter>>
    /\ l' = l + 1

\* InitiateEndSession event
TraceInitiateEndSession(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("initiate_end_session")
    /\ logline.sender = "requester"
    /\ session_state[sid] = ESTABLISHED
    /\ session_state' = [session_state EXCEPT ![sid] = ENDING]
    /\ messages' = messages \cup {[type |-> "end_session", sender |-> Requester, receiver |-> Responder,
                                   session_id |-> sid]}
    /\ UNCHANGED <<session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>
    /\ l' = l + 1

\* RespondToEndSession event
TraceRespondToEndSession(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("respond_to_end_session")
    /\ logline.sender = "responder"
    /\ session_state[sid] = ENDING
    /\ \E msg \in messages :
         /\ msg.type = "end_session"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         /\ messages' = messages \ {msg}
    /\ session_freed_by_responder' = [session_freed_by_responder EXCEPT ![sid] = TRUE]
    /\ UNCHANGED <<session_state, session_freed_by_requester,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>
    /\ l' = l + 1

\* SendEndSessionAck event
TraceSendEndSessionAck(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("send_end_session_ack")
    /\ logline.sender = "responder"
    /\ session_state[sid] = ENDING
    /\ messages' = messages \cup {[type |-> "end_session_ack", sender |-> Responder, receiver |-> Requester,
                                   session_id |-> sid]}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>
    /\ l' = l + 1

\* ReceiveEndSessionAck event
TraceReceiveEndSessionAck(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("receive_end_session_ack")
    /\ logline.sender = "requester"
    /\ \E msg \in messages :
         /\ msg.type = "end_session_ack"
         /\ msg.session_id = sid
         /\ msg.receiver = Requester
         /\ messages' = messages \ {msg}
    /\ session_freed_by_requester' = [session_freed_by_requester EXCEPT ![sid] = TRUE]
    /\ UNCHANGED <<session_state, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>
    /\ l' = l + 1

\* FinalizeSessionCleanup event
TraceFinalizeSessionCleanup(logline) ==
    LET sid == logline.session_id IN
    /\ IsEvent("finalize_session_cleanup")
    /\ session_state[sid] = ENDING
    /\ session_state' = [session_state EXCEPT ![sid] = FREED]
    /\ UNCHANGED <<session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, messages, pending_ack, msg_counter>>
    /\ l' = l + 1

\* ==== Silent Actions ====
\* Fire base spec actions without consuming a trace event
\* Constrained to prevent state space explosion

SilentReceiveHeartbeat ==
    \E sid \in SessionIds :
        /\ l <= Len(TraceLog)
        /\ ReceiveHeartbeat(sid)
        /\ UNCHANGED l

SilentDropMessage ==
    \E msg \in messages :
        /\ l <= Len(TraceLog)
        /\ DropMessage(msg)
        /\ UNCHANGED l

\* ==== Trace Init ====

TraceInit ==
    /\ l = 1
    /\ session_state = [sid \in SessionIds |-> IDLE]
    /\ session_freed_by_requester = [sid \in SessionIds |-> FALSE]
    /\ session_freed_by_responder = [sid \in SessionIds |-> FALSE]
    /\ prev_key_update_operation = [sid \in SessionIds |-> NONE]
    /\ requester_key_created = [sid \in SessionIds |-> FALSE]
    /\ responder_key_created = [sid \in SessionIds |-> FALSE]
    /\ requester_key_active = [sid \in SessionIds |-> FALSE]
    /\ responder_key_active = [sid \in SessionIds |-> FALSE]
    /\ heartbeat_enabled = [sid \in SessionIds |-> FALSE]
    /\ messages = {}
    /\ pending_ack = {}
    /\ msg_counter = 0

\* ==== Trace Next ====

\* Execute next trace action based on event type
DoTraceAction(logline) ==
    \/ TraceInitializeSession(logline)
    \/ TraceRespondToSessionInit(logline)
    \/ TraceSendHeartbeat(logline)
    \/ TraceReceiveHeartbeat(logline)
    \/ TraceInitiateKeyUpdate(logline)
    \/ TraceHandleKeyUpdate(logline)
    \/ TraceSendKeyUpdateVerify(logline)
    \/ TraceHandleKeyUpdateVerify(logline)
    \/ TraceInitiateEndSession(logline)
    \/ TraceRespondToEndSession(logline)
    \/ TraceSendEndSessionAck(logline)
    \/ TraceReceiveEndSessionAck(logline)
    \/ TraceFinalizeSessionCleanup(logline)

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ DoTraceAction(TraceLog[l])

\* ==== Completion Check ====

TraceMatched == <>(l > Len(TraceLog))

====
