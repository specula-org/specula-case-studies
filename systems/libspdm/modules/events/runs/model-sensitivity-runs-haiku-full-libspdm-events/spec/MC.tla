---- MODULE MC ----
(* Model Checking wrapper for libspdm-events base spec

   Counter-bounded fault injection actions enable exhaustive state space search.
   This layer adds:
   - Fault counters to bound non-deterministic actions
   - Symmetry reduction
   - Structural invariants
   - Bug-family-specific hunting configs (see MC_hunt_*.cfg files)
*)

EXTENDS base

(* =========== ADDITIONAL CONSTANTS =========== *)

CONSTANT SessionClosureLimit, SizeOverflowLimit, SeqLimit
CONSTANT MessageLossLimit, TimeoutLimit, RequestLimit, MaxMessageBufferSize

(* =========== HELPER OPERATORS =========== *)

\* Bounded sequences to prevent TLC enumeration issues
BoundedSeq(S, maxLen) ==
    UNION {[1..n -> S] : n \in 0..maxLen}

\* Simplified event templates (just use a few representative event types)
EventTemplate == {
    [instance_id |-> 1, registry_id |-> REGISTRY_ID_DMTF, detail_len |-> 100],
    [instance_id |-> 2, registry_id |-> REGISTRY_ID_VENDOR, detail_len |-> 200],
    [instance_id |-> 3, registry_id |-> REGISTRY_ID_DMTF, detail_len |-> 150]
}

\* Sequences of events bounded by MaxEvents length
EventSequences == BoundedSeq(EventTemplate, MaxEvents)

(* =========== FAULT COUNTERS =========== *)

\* Family 3: Session closure during callback window
\* Models the race condition where session state changes between validation and processing
VARIABLE sessionClosureCount

\* Family 2: Integer overflow in size accumulation
\* Allows injecting pathological size values to trigger overflow
VARIABLE sizeOverflowCount

\* Family 1: Sequence selection bias
\* Can force sequential or non-sequential path to focus testing
VARIABLE sequenceSelectionCount

\* Background faults (message loss, timeouts)
VARIABLE messageLossCount
VARIABLE timeoutCount

faultVars == << sessionClosureCount, sizeOverflowCount, sequenceSelectionCount,
               messageLossCount, timeoutCount >>

MCvars == << vars, faultVars >>

(* =========== FAULT INJECTION ACTIONS =========== *)

\* Family 3 Fault: Induce session closure between state check and callback
\* This models the transient state change vulnerability in libspdm_rsp_event_ack.c:93-236
\* where session_state is checked at line 93-98 but process_event is called at line 236
MCSessionClosureFault(limit) ==
    /\ sessionClosureCount < limit
    /\ \E sid \in Sessions:
       /\ session_state[sid] = "ESTABLISHED"
       /\ session_state' = [session_state EXCEPT ![sid] = "CLOSED"]
       /\ sessionClosureCount' = sessionClosureCount + 1
    /\ UNCHANGED << subscribed_types, messages, events_sequential,
                     event_id_map, msg_size_accum, pending_callbacks,
                     event_validated, integrator_subscribed_types,
                     sizeOverflowCount, sequenceSelectionCount,
                     messageLossCount, timeoutCount >>

\* Family 2 Fault: Inject oversized event details to trigger size accumulation overflow
\* libspdm_rsp_event_ack.c:188-190: calculated_request_size accumulation vulnerable
\* This fault allows testing whether the final validation at line 194 catches all overflows
MCSizeOverflowFault(limit) ==
    /\ sizeOverflowCount < limit
    /\ msg_size_accum < MaxMessageSize
    /\ msg_size_accum' = MaxMessageSize + 1000  \* Force overflow
    /\ sizeOverflowCount' = sizeOverflowCount + 1
    /\ UNCHANGED << session_state, subscribed_types, messages,
                     events_sequential, event_id_map, pending_callbacks,
                     event_validated, integrator_subscribed_types,
                     sessionClosureCount, sequenceSelectionCount,
                     messageLossCount, timeoutCount >>

\* Family 1 Fault: Bias sequence path selection to focus testing
\* Forces either sequential or non-sequential path
MCForceSequentialPath(limit) ==
    /\ sequenceSelectionCount < limit
    /\ sequenceSelectionCount' = sequenceSelectionCount + 1
    /\ events_sequential' = TRUE
    /\ UNCHANGED << session_state, subscribed_types, messages, event_id_map,
                     msg_size_accum, pending_callbacks, event_validated,
                     integrator_subscribed_types, sessionClosureCount,
                     sizeOverflowCount, messageLossCount, timeoutCount >>

MCForceNonSequentialPath(limit) ==
    /\ sequenceSelectionCount < limit
    /\ sequenceSelectionCount' = sequenceSelectionCount + 1
    /\ events_sequential' = FALSE
    /\ UNCHANGED << session_state, subscribed_types, messages, event_id_map,
                     msg_size_accum, pending_callbacks, event_validated,
                     integrator_subscribed_types, sessionClosureCount,
                     sizeOverflowCount, messageLossCount, timeoutCount >>

\* Background Fault: Message loss (dropped packets)
MCMessageLoss(limit) ==
    /\ messageLossCount < limit
    /\ messages /= {}
    /\ \E m \in messages:
       /\ messages' = messages \ {m}
       /\ messageLossCount' = messageLossCount + 1
    /\ UNCHANGED << session_state, subscribed_types, events_sequential,
                     event_id_map, msg_size_accum, pending_callbacks,
                     event_validated, integrator_subscribed_types,
                     sessionClosureCount, sizeOverflowCount, sequenceSelectionCount,
                     timeoutCount >>

\* Background Fault: Timeout (trigger new requests)
MCTimeout(limit) ==
    /\ timeoutCount < limit
    /\ \E sid \in Sessions:
       /\ session_state[sid] = "ESTABLISHED"
       /\ \E types \in SUBSET EventTypes:
          /\ messages' = messages \cup
             {[src |-> Requester, dst |-> Responder,
               type |-> "SUBSCRIBE_EVENT_TYPES", sid |-> sid,
               body |-> [event_types |-> types]]}
          /\ timeoutCount' = timeoutCount + 1
    /\ UNCHANGED << session_state, subscribed_types, events_sequential,
                     event_id_map, msg_size_accum, pending_callbacks,
                     event_validated, integrator_subscribed_types,
                     sessionClosureCount, sizeOverflowCount, sequenceSelectionCount,
                     messageLossCount >>

(* =========== CONSTRAINED BASE ACTIONS =========== *)

\* Reactive actions (do not bound) - wrapper to preserve fault variables
MCInitSession(sid) ==
    /\ InitSession(sid)
    /\ UNCHANGED faultVars

MCCloseSession(sid) ==
    /\ CloseSession(sid)
    /\ UNCHANGED faultVars

MCRespSubscribeEventTypesAck(sid) ==
    /\ RespSubscribeEventTypesAck(sid)
    /\ UNCHANGED faultVars

MCReqHandleEventAck(sid) ==
    /\ ReqHandleEventAck(sid)
    /\ UNCHANGED faultVars

MCProcessCallback ==
    /\ ProcessCallback
    /\ UNCHANGED faultVars

\* Constrained actions (bound by counters)
MCReqSubscribeEventTypes(sid, types, reqLimit) ==
    /\ timeoutCount < reqLimit
    /\ ReqSubscribeEventTypes(sid, types)
    /\ timeoutCount' = timeoutCount + 1
    /\ sessionClosureCount' = sessionClosureCount
    /\ sizeOverflowCount' = sizeOverflowCount
    /\ sequenceSelectionCount' = sequenceSelectionCount
    /\ messageLossCount' = messageLossCount

(* Path selection for event processing
   Family 1: Split into sequential and non-sequential
   Bound by sequenceSelectionCount to limit exploration
*)
MCRespSendEventAckSeq(sid, events, seqLimit) ==
    /\ sequenceSelectionCount < seqLimit
    /\ RespSendEventAckSeq(sid, events)
    /\ sequenceSelectionCount' = sequenceSelectionCount + 1
    /\ sessionClosureCount' = sessionClosureCount
    /\ sizeOverflowCount' = sizeOverflowCount
    /\ messageLossCount' = messageLossCount
    /\ timeoutCount' = timeoutCount

MCRespSendEventAckNonSeq(sid, events, seqLimit) ==
    /\ sequenceSelectionCount < seqLimit
    /\ RespSendEventAckNonSeq(sid, events)
    /\ sequenceSelectionCount' = sequenceSelectionCount + 1
    /\ sessionClosureCount' = sessionClosureCount
    /\ sizeOverflowCount' = sizeOverflowCount
    /\ messageLossCount' = messageLossCount
    /\ timeoutCount' = timeoutCount

(* =========== INITIALIZATION =========== *)

MCInit ==
    /\ Init
    /\ sessionClosureCount = 0
    /\ sizeOverflowCount = 0
    /\ sequenceSelectionCount = 0
    /\ messageLossCount = 0
    /\ timeoutCount = 0

(* =========== NEXT STATE RELATION =========== *)

\* Injected via operator override in MC.cfg:
\* InitSession <- MCInitSession
\* CloseSession <- MCCloseSession
\* etc.

MCNext ==
    \/ \E sid \in Sessions: MCInitSession(sid)
    \/ \E sid \in Sessions: MCCloseSession(sid)
    \/ \E sid \in Sessions, types \in SUBSET EventTypes: MCReqSubscribeEventTypes(sid, types, RequestLimit)
    \/ \E sid \in Sessions: MCRespSubscribeEventTypesAck(sid)
    \/ \E sid \in Sessions, events \in EventSequences: MCRespSendEventAckSeq(sid, events, SeqLimit)
    \/ \E sid \in Sessions, events \in EventSequences: MCRespSendEventAckNonSeq(sid, events, SeqLimit)
    \/ \E sid \in Sessions: MCReqHandleEventAck(sid)
    \/ MCProcessCallback
    \/ MCSessionClosureFault(SessionClosureLimit)
    \/ MCSizeOverflowFault(SizeOverflowLimit)
    \/ MCForceSequentialPath(SeqLimit)
    \/ MCForceNonSequentialPath(SeqLimit)
    \/ MCMessageLoss(MessageLossLimit)
    \/ MCTimeout(TimeoutLimit)

MCSpec == MCInit /\ [][MCNext]_MCvars

(* =========== STRUCTURAL INVARIANTS =========== *)

\* Type safety - must always hold
MCTypeOK ==
    /\ SessionStateOK
    /\ MessageOK
    /\ sessionClosureCount \in Nat
    /\ sizeOverflowCount \in Nat
    /\ sequenceSelectionCount \in Nat
    /\ messageLossCount \in Nat
    /\ timeoutCount \in Nat

\* Message cardinality bounds (prevent state explosion)
MCMessageBound ==
    Cardinality(messages) <= MaxMessageBufferSize

(* =========== BUG-FAMILY INVARIANTS =========== *)

\* Family 1: Path divergence - both paths should handle events correctly
MCFamily1_SequentialOrGapFree == SequentialOrGapFree

\* Family 2: Size overflow protection
MCFamily2_SizeAccumulationBounded == SizeAccumulationBounded

\* Family 3: Session state during processing
MCFamily3_EventsInEstablishedSession == EventsInEstablishedSession

\* Family 4: DMTF event validation
MCFamily4_DMTFEventsValidated == DMTFEventsValidated

\* Family 5: Subscription state divergence
MCFamily5_SubscriptionConsistency == SubscriptionConsistency

(* =========== SYMMETRIC REDUCTION =========== *)

\* Disabled for exhaustive model checking to find all bugs
\* Symmetry == Permutations(Sessions)

(* =========== VIEW FOR SYMMETRY =========== *)

MCView == << session_state, messages, events_sequential, event_id_map,
            msg_size_accum, subscribed_types, pending_callbacks,
            event_validated, integrator_subscribed_types >>

====
