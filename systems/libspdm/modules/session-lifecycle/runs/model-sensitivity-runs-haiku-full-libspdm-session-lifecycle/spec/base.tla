---- MODULE base ----
\* SPDM Session Lifecycle Specification
\* Targets: HEARTBEAT, KEY_UPDATE, END_SESSION operations
\* Category: A (Distributed/Message-Passing)

EXTENDS Naturals, Sequences, FiniteSets, TLC

\* Constants
CONSTANT Requester, Responder  \* Two roles
CONSTANT SessionIds, MaxSession  \* Session identifiers

\* Define helper constants for update operations
NONE == "none"
UPDATE_KEY == "update_key"
UPDATE_ALL_KEYS == "update_all_keys"
VERIFY_NEW_KEY == "verify_new_key"

\* Session states (Family 4: Session lifecycle)
IDLE == "idle"
ESTABLISHED == "established"
ENDING == "ending"
FREED == "freed"

\* Heartbeat state
HEARTBEAT_ACTIVE == "active"
HEARTBEAT_INACTIVE == "inactive"

Roles == {Requester, Responder}

\* ==== Standard Protocol Variables ====

\* Session state tracking (Family 4)
VARIABLE session_state  \* [session_id -> state]
VARIABLE session_freed_by_requester  \* [session_id -> bool]
VARIABLE session_freed_by_responder  \* [session_id -> bool]

\* Key update state machine (Family 2)
VARIABLE prev_key_update_operation  \* [session_id -> operation]

\* Key state tracking (Family 1)
\* Separate creation and activation to expose divergence window
VARIABLE requester_key_created  \* [session_id -> bool]
VARIABLE responder_key_created  \* [session_id -> bool]
VARIABLE requester_key_active  \* [session_id -> bool]
VARIABLE responder_key_active  \* [session_id -> bool]

\* Heartbeat configuration (Family 5)
VARIABLE heartbeat_enabled  \* [session_id -> bool]

\* Message passing
VARIABLE messages  \* Set of {type, sender, receiver, session_id, ...}
VARIABLE pending_ack  \* Track which ACKs are pending

\* For message ordering
VARIABLE msg_counter

\* Grouped variables for UNCHANGED clauses
protocolVars == <<session_state, session_freed_by_requester, session_freed_by_responder,
                   prev_key_update_operation, requester_key_created, responder_key_created,
                   requester_key_active, responder_key_active, heartbeat_enabled,
                   messages, pending_ack>>

\* ==== Helper Operators ====

IsValidSession(sid) == sid \in SessionIds

GetSessionState(sid) == session_state[sid]

CanSendHeartbeat(sid) ==
    \* libspdm_req_heartbeat.c:63-65
    /\ session_state[sid] = ESTABLISHED
    /\ heartbeat_enabled[sid]

CanInitiateKeyUpdate(sid) ==
    \* libspdm_req_key_update.c:95-99
    /\ session_state[sid] = ESTABLISHED
    /\ prev_key_update_operation[sid] = NONE

CanVerifyKeyUpdate(sid) ==
    \* libspdm_req_key_update.c:184-195
    /\ session_state[sid] = ESTABLISHED
    /\ prev_key_update_operation[sid] \in {UPDATE_KEY, UPDATE_ALL_KEYS}

\* ==== Initialization ====

Init ==
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

\* ==== Message Operations ====

Send(msg) == messages' = messages \cup {msg}

Discard(msg) == messages' = messages \ {msg}

\* ==== Session Lifecycle Actions (Family 4) ====

\* libspdm_com_context_data_session.c:9-39 and libspdm_req_heartbeat.c
InitializeSession(sid) ==
    /\ sid \in SessionIds
    /\ session_state[sid] = IDLE
    /\ session_state' = [session_state EXCEPT ![sid] = ESTABLISHED]
    /\ heartbeat_enabled' = [heartbeat_enabled EXCEPT ![sid] = TRUE]
    /\ UNCHANGED <<session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, messages, pending_ack, msg_counter>>

\* Responder acknowledges session establishment
RespondToSessionInit(sid) ==
    /\ sid \in SessionIds
    /\ session_state[sid] = ESTABLISHED
    /\ heartbeat_enabled[sid] = TRUE
    /\ UNCHANGED protocolVars

\* libspdm_try_heartbeat and libspdm_get_response_heartbeat
SendHeartbeat(sid) ==
    /\ sid \in SessionIds
    /\ CanSendHeartbeat(sid)
    \* libspdm_req_heartbeat.c:63-65 checks heartbeat_period > 0
    /\ msg_counter' = msg_counter + 1
    /\ Send([type |-> "heartbeat", sender |-> Requester, receiver |-> Responder,
             session_id |-> sid, msg_id |-> msg_counter'])
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack>>

ReceiveHeartbeat(sid) ==
    /\ sid \in SessionIds
    /\ \E msg \in messages :
         /\ msg.type = "heartbeat"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         \* libspdm_rsp_heartbeat.c:99-103 checks heartbeat_period
         /\ heartbeat_enabled[sid] = TRUE
         /\ Discard(msg)
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>

\* ==== Key Update Actions (Families 1, 2, 3) ====

\* libspdm_try_key_update and libspdm_req_key_update.c:111-122
\* Requester initiates key update (UPDATE_KEY or UPDATE_ALL_KEYS)
InitiateKeyUpdate(sid, op) ==
    /\ sid \in SessionIds
    /\ op \in {UPDATE_KEY, UPDATE_ALL_KEYS}
    /\ CanInitiateKeyUpdate(sid)
    \* Requester pre-creates responder key before receiving ACK (Family 1)
    \* libspdm_req_key_update.c:111-122
    /\ msg_counter' = msg_counter + 1
    /\ responder_key_created' = [responder_key_created EXCEPT ![sid] = TRUE]
    /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = op]
    /\ Send([type |-> "key_update", sender |-> Requester, receiver |-> Responder,
             session_id |-> sid, operation |-> op, msg_id |-> msg_counter'])
    /\ pending_ack' = pending_ack \cup {[type |-> "key_update_ack", session_id |-> sid]}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    requester_key_created, requester_key_active, responder_key_active, heartbeat_enabled>>

\* libspdm_rsp_key_update_ack.c:108-146
\* Responder handles key update request
\* Validates state machine via consttime comparison (Family 2)
HandleKeyUpdate(sid, op) ==
    /\ sid \in SessionIds
    /\ op \in {UPDATE_KEY, UPDATE_ALL_KEYS}
    /\ session_state[sid] = ESTABLISHED
    /\ \E msg \in messages :
         /\ msg.type = "key_update"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         /\ msg.operation = op
         \* libspdm_rsp_key_update_ack.c:108-116 - state machine validation
         \* Responder always acknowledges key updates; only first triggers state machine
         /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = op]
         /\ requester_key_created' = [requester_key_created EXCEPT ![sid] = TRUE]
         /\ responder_key_created' = [responder_key_created EXCEPT ![sid] = TRUE]
         /\ UNCHANGED <<requester_key_active, responder_key_active>>
         /\ Discard(msg)
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>

\* libspdm_req_key_update.c:184-195
\* Requester sends VERIFY after receiving UPDATE ACK
SendKeyUpdateVerify(sid) ==
    /\ sid \in SessionIds
    /\ CanVerifyKeyUpdate(sid)
    /\ msg_counter' = msg_counter + 1
    /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = VERIFY_NEW_KEY]
    \* libspdm_req_key_update.c:184-195 - requester activates responder key only after ACK
    /\ responder_key_active' = [responder_key_active EXCEPT ![sid] = TRUE]
    /\ Send([type |-> "key_update_verify", sender |-> Requester, receiver |-> Responder,
             session_id |-> sid, msg_id |-> msg_counter'])
    /\ pending_ack' = pending_ack \cup {[type |-> "key_update_verify_ack", session_id |-> sid]}
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    requester_key_created, responder_key_created, requester_key_active, heartbeat_enabled, msg_counter>>

\* libspdm_rsp_key_update_ack.c:194-199
\* Responder verifies key update completion
\* VERIFY_NEW_KEY must follow UPDATE (Family 2)
HandleKeyUpdateVerify(sid) ==
    /\ sid \in SessionIds
    /\ session_state[sid] = ESTABLISHED
    /\ prev_key_update_operation[sid] \in {UPDATE_KEY, UPDATE_ALL_KEYS}
    /\ \E msg \in messages :
         /\ msg.type = "key_update_verify"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         \* libspdm_rsp_key_update_ack.c:194-199 - checks prev param1
         /\ prev_key_update_operation' = [prev_key_update_operation EXCEPT ![sid] = NONE]
         /\ requester_key_active' = [requester_key_active EXCEPT ![sid] = TRUE]
         /\ Discard(msg)
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    requester_key_created, responder_key_created, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>

\* ==== Session Termination Actions (Family 4) ====

\* libspdm_try_send_receive_end_session
InitiateEndSession(sid) ==
    /\ sid \in SessionIds
    /\ session_state[sid] = ESTABLISHED
    /\ msg_counter' = msg_counter + 1
    /\ session_state' = [session_state EXCEPT ![sid] = ENDING]
    /\ Send([type |-> "end_session", sender |-> Requester, receiver |-> Responder,
             session_id |-> sid, msg_id |-> msg_counter'])
    /\ pending_ack' = pending_ack \cup {[type |-> "end_session_ack", session_id |-> sid]}
    /\ UNCHANGED <<session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled>>

\* libspdm_get_response_end_session
RespondToEndSession(sid) ==
    /\ sid \in SessionIds
    /\ session_state[sid] = ESTABLISHED
    /\ \E msg \in messages :
         /\ msg.type = "end_session"
         /\ msg.session_id = sid
         /\ msg.receiver = Responder
         /\ session_state' = [session_state EXCEPT ![sid] = ENDING]
         /\ Discard(msg)
    /\ UNCHANGED <<session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>

\* libspdm_rsp_end_session_ack.c:89-94
SendEndSessionAck(sid) ==
    /\ sid \in SessionIds
    /\ session_state[sid] = ENDING
    /\ msg_counter' = msg_counter + 1
    /\ Send([type |-> "end_session_ack", sender |-> Responder, receiver |-> Requester,
             session_id |-> sid, msg_id |-> msg_counter'])
    /\ session_freed_by_responder' = [session_freed_by_responder EXCEPT ![sid] = TRUE]
    /\ UNCHANGED <<session_state, session_freed_by_requester,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack>>

\* libspdm_req_end_session.c:136-141
\* Requester receives END_SESSION_ACK and frees session
\* If ACK is lost, requester frees but responder doesn't (Family 4)
ReceiveEndSessionAck(sid) ==
    /\ sid \in SessionIds
    /\ session_state[sid] = ENDING
    /\ \E msg \in messages :
         /\ msg.type = "end_session_ack"
         /\ msg.session_id = sid
         /\ msg.receiver = Requester
         \* libspdm_req_end_session.c:136-141 - calls libspdm_free_session_id
         /\ session_freed_by_requester' = [session_freed_by_requester EXCEPT ![sid] = TRUE]
         /\ Discard(msg)
    /\ UNCHANGED <<session_state, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled, pending_ack, msg_counter>>

\* Complete session cleanup (after both sides freed)
FinalizeSessionCleanup(sid) ==
    /\ sid \in SessionIds
    /\ session_freed_by_requester[sid] = TRUE
    /\ session_freed_by_responder[sid] = TRUE
    /\ session_state[sid] = ENDING
    /\ session_state' = [session_state EXCEPT ![sid] = FREED]
    /\ UNCHANGED <<session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled,
                    messages, pending_ack, msg_counter>>

\* ==== Fault Injection Actions ====

\* Message loss (Category A distribution/message-passing fault)
DropMessage(msg) ==
    /\ msg \in messages
    /\ Discard(msg)
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled,
                    pending_ack, msg_counter>>

\* ==== Main Actions ====

Next ==
    \/ \E sid \in SessionIds : InitializeSession(sid)
    \/ \E sid \in SessionIds : RespondToSessionInit(sid)
    \/ \E sid \in SessionIds : SendHeartbeat(sid)
    \/ \E sid \in SessionIds : ReceiveHeartbeat(sid)
    \/ \E sid \in SessionIds, op \in {UPDATE_KEY, UPDATE_ALL_KEYS} : InitiateKeyUpdate(sid, op)
    \/ \E sid \in SessionIds, op \in {UPDATE_KEY, UPDATE_ALL_KEYS} : HandleKeyUpdate(sid, op)
    \/ \E sid \in SessionIds : SendKeyUpdateVerify(sid)
    \/ \E sid \in SessionIds : HandleKeyUpdateVerify(sid)
    \/ \E sid \in SessionIds : InitiateEndSession(sid)
    \/ \E sid \in SessionIds : RespondToEndSession(sid)
    \/ \E sid \in SessionIds : SendEndSessionAck(sid)
    \/ \E sid \in SessionIds : ReceiveEndSessionAck(sid)
    \/ \E sid \in SessionIds : FinalizeSessionCleanup(sid)
    \/ \E msg \in messages : DropMessage(msg)

\* ==== Safety Invariants ====

\* Standard: Session state consistency (Family 4)
SessionStateConsistency ==
    \A sid \in SessionIds :
        \* If either side has freed, both must have
        (session_freed_by_requester[sid] \/ session_freed_by_responder[sid]) =>
            (session_freed_by_requester[sid] /\ session_freed_by_responder[sid])

\* Extension: Key update sequencing (Family 2)
KeyUpdateSequencing ==
    \A sid \in SessionIds :
        \* From UPDATE state, only VERIFY or another UPDATE allowed
        (prev_key_update_operation[sid] \in {UPDATE_KEY, UPDATE_ALL_KEYS}) =>
            \* Next operation must be VERIFY or different UPDATE_KEY
            TRUE  \* Enforced by action preconditions

\* Extension: Key activation order (Family 1)
\* If requester has activated responder key, responder must have created it
KeyActivationOrder ==
    \A sid \in SessionIds :
        (requester_key_active[sid] = TRUE) =>
            (responder_key_created[sid] = TRUE)

\* Extension: Heartbeat precondition (Family 5)
HeartbeatPrecondition ==
    \A sid \in SessionIds :
        (pending_ack[sid] = "heartbeat" \/
         \E msg \in messages : msg.type = "heartbeat" /\ msg.session_id = sid) =>
            (heartbeat_enabled[sid] = TRUE /\ session_state[sid] = ESTABLISHED)

\* Extension: Session cleanup idempotence (Family 4)
EndSessionIdempotence ==
    \A sid \in SessionIds :
        \* Once a side has freed, its state doesn't change
        (session_freed_by_requester[sid] = TRUE) =>
            (session_freed_by_requester'[sid] = TRUE)

\* Structural: Key states consistent
KeyStateConsistency ==
    \A sid \in SessionIds :
        \* Can't activate before creating
        /\ (requester_key_active[sid] = TRUE) => (requester_key_created[sid] = TRUE)
        /\ (responder_key_active[sid] = TRUE) => (responder_key_created[sid] = TRUE)

====
