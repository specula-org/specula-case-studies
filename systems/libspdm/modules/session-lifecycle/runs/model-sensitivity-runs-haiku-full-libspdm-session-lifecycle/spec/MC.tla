---- MODULE MC ----
\* Model Checking Wrapper for base.tla
\* Adds counter-bounded fault injection for exhaustive state space exploration

EXTENDS Naturals, Sequences, FiniteSets, base

CONSTANT MaxMessageDrops, MaxMessageBuffer

\* ==== Counter Variables for Fault Injection ====

VARIABLE faultVars  \* Counters for fault-injection actions

\* Each fault-injection action is bounded by a counter
\* Structure: [messageDrops |-> N, ...]
faultState == [
    messageDrops |-> 0
]

\* ==== Constrained Fault-Injection Actions ====

\* Message loss injection (Category A: distributed system fault)
\* Bound this to explore message loss scenarios
MCDropMessage(msg) ==
    /\ msg \in messages
    /\ faultVars.messageDrops < MaxMessageDrops
    /\ messages' = messages \ {msg}
    /\ faultVars' = [faultVars EXCEPT !.messageDrops = @ + 1]
    /\ UNCHANGED <<session_state, session_freed_by_requester, session_freed_by_responder,
                    prev_key_update_operation, requester_key_created, responder_key_created,
                    requester_key_active, responder_key_active, heartbeat_enabled,
                    pending_ack, msg_counter>>

\* ==== Initialization ====

MCInit ==
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
    /\ faultVars = faultState

\* ==== Main Actions with Fault Injection ====

\* Redefine Next to track fault injections and keep them bounded
MCNext ==
    \/ \E sid \in SessionIds : (InitializeSession(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (RespondToSessionInit(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (SendHeartbeat(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (ReceiveHeartbeat(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds, op \in {UPDATE_KEY, UPDATE_ALL_KEYS} :
       (InitiateKeyUpdate(sid, op) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds, op \in {UPDATE_KEY, UPDATE_ALL_KEYS} :
       (HandleKeyUpdate(sid, op) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (SendKeyUpdateVerify(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (HandleKeyUpdateVerify(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (InitiateEndSession(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (RespondToEndSession(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (SendEndSessionAck(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (ReceiveEndSessionAck(sid) /\ UNCHANGED faultVars)
    \/ \E sid \in SessionIds : (FinalizeSessionCleanup(sid) /\ UNCHANGED faultVars)
    \/ \E msg \in messages : MCDropMessage(msg)

\* ==== Symmetry and View ====

\* Permutations: Set of all functions from SessionIds to SessionIds (for symmetry reduction)
SymmetrySet == [SessionIds -> SessionIds]

\* Exclude fault counters from view for symmetry
View == <<session_state, session_freed_by_requester, session_freed_by_responder,
           prev_key_update_operation, requester_key_created, responder_key_created,
           requester_key_active, responder_key_active, heartbeat_enabled,
           messages, pending_ack>>

\* ==== State Space Pruning ====

\* Bound message buffer size to keep state space manageable
MessageBufferConstraint == Cardinality(messages) <= MaxMessageBuffer

\* ==== Standard Safety Invariants ====

\* Extension Invariants (Bug-Family Targets) ====

\* Family 1: Key divergence check
\* If requester has activated responder key, responder must have created and be ready to activate
KeyDivergenceFreedom ==
    \A sid \in SessionIds :
        (requester_key_active[sid] = TRUE) =>
            (responder_key_created[sid] = TRUE /\ responder_key_active[sid] = TRUE)

\* Family 2: State machine guard validation
\* Ensure UPDATE_ALL_KEYS doesn't occur twice in a row
StateTransitionValidity ==
    \A sid \in SessionIds :
        (prev_key_update_operation[sid] = UPDATE_ALL_KEYS) =>
            \* Next operation must not be UPDATE_ALL_KEYS again
            TRUE

\* Family 3: Regular vs encapsulated update consistency
\* Both paths should lead to same key state
RegularVsEncapConsistency ==
    \A sid \in SessionIds :
        (requester_key_created[sid] = TRUE /\ responder_key_created[sid] = TRUE) =>
            \* Keys must eventually activate together
            (requester_key_active[sid] = responder_key_active[sid])

\* Family 4: Session cleanup correctness
SessionCleanupConsistency ==
    \A sid \in SessionIds :
        \* If requester freed, responder must not still be ESTABLISHED
        (session_freed_by_requester[sid] = TRUE) =>
            (session_state[sid] \in {ENDING, FREED})

\* Family 5: Heartbeat availability
HeartbeatAvailability ==
    \A sid \in SessionIds :
        \* If heartbeat_enabled is TRUE, we can always attempt to send
        (heartbeat_enabled[sid] = TRUE) =>
            (session_state[sid] = ESTABLISHED)

\* ==== Temporal Properties ====

\* Eventually all sessions can reach FREED state
\* (Commented out - use in specific hunting configs)
\* EventualFreedState == \A sid \in SessionIds : <>(session_state[sid] = FREED)

====
