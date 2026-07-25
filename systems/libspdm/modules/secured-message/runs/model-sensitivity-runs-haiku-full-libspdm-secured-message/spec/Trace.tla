----------------------- MODULE Trace -------------------------
(* Trace validation spec for libspdm-secured-message *)

EXTENDS base, Naturals, Sequences

CONSTANTS
    (* JSON file path for trace *)
    IOEnv

------------------------------------------------------------------------
(* TRACE LOADING *)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

(* TraceLog: Sequence of trace events from test_trace_module.ndjson *)
(* First, just test with the first event *)
TraceLog ==
    <<
        (* Event 1: transition_to_established *)
        [event |-> EVT_TRANSITION_ESTABLISHED,
         role |-> REQUESTER_ROLE,
         session_id |-> SID_ZERO]
    >>

------------------------------------------------------------------------
(* TRACE VARIABLES *)

VARIABLE l  \* Cursor: index into TraceLog

traceVars == <<l>>

------------------------------------------------------------------------
(* EVENT PREDICATES *)

IsEvent(event_name, line) ==
    IF l <= Len(TraceLog) THEN
        LET logline == TraceLog[l] IN
        logline.event = event_name
    ELSE FALSE

IsNodeEvent(event_name, role, sid, line) ==
    IF l <= Len(TraceLog) THEN
        LET logline == TraceLog[l] IN
        /\ logline.event = event_name
        /\ logline.role = role
        /\ logline.session_id = sid
    ELSE FALSE

------------------------------------------------------------------------
(* POST-STATE VALIDATION PREDICATES *)

ValidateTransitionPostState(role, sid, logline) ==
    \* Transition to established: no specific seq num validation
    TRUE

ValidateEncodePostState(role, sid, logline) ==
    TRUE

ValidateDecodePostState(role, sid, logline) ==
    TRUE

------------------------------------------------------------------------
(* TRACE ACTION WRAPPERS *)

(* Wrapper: Initialize Session (no trace event for init) *)
TraceInitializeSession(role, sid) ==
    /\ InitializeSession(role, sid)
    /\ UNCHANGED <<l>>

(* Wrapper: Transition to Established *)
TraceTransitionToEstablished(role, sid) ==
    /\ l <= Len(TraceLog)
    /\ LET logline == TraceLog[l] IN
        /\ logline.event = EVT_TRANSITION_ESTABLISHED
        /\ logline.role = role
        /\ logline.session_id = sid
        /\ TransitionToEstablished(role, sid)
        /\ ValidateTransitionPostState(role, sid, logline)
    /\ l' = l + 1

(* Wrapper: Complete Zeroization *)
TraceCompleteZeroization(role, sid) ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("complete_zeroization", role, sid, l)
    /\ CompleteZeroization(role, sid)
    /\ l' = l + 1

(* Wrapper: Encode Message *)
TraceEncodeSecuredMessage(role, sid) ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("encode_message", role, sid, l)
    /\ LET logline == TraceLog[l] IN
        /\ EncodeSecuredMessage(role, sid)
        /\ ValidateEncodePostState(role, sid, logline)
    /\ l' = l + 1

(* Wrapper: Decode with First Endian *)
TraceAttemptDecodeFirstEndian(role, sid) ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("decode_first_endian", role, sid, l)
    /\ LET logline == TraceLog[l] IN
        /\ AttemptDecodeFirstEndian(role, sid)
        /\ ValidateDecodePostState(role, sid, logline)
    /\ l' = l + 1

(* Wrapper: Initiate Key Update *)
TraceInitiateKeyUpdate(role, sid) ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("initiate_key_update", role, sid, l)
    /\ InitiateKeyUpdate(role, sid)
    /\ l' = l + 1

(* Wrapper: Confirm Key Update *)
TraceConfirmKeyUpdate(role, sid) ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("confirm_key_update", role, sid, l)
    /\ ConfirmKeyUpdate(role, sid)
    /\ l' = l + 1

(* Wrapper: Rollback *)
TraceRollbackToBackupKey(role, sid) ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("rollback_backup_key", role, sid, l)
    /\ RollbackToBackupKey(role, sid)
    /\ l' = l + 1

------------------------------------------------------------------------
(* SILENT ACTIONS *)

(* Done action: fires when trace is complete *)
Done ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<varAll, l>>

------------------------------------------------------------------------
(* TRACE INIT *)

TraceInit ==
    /\ Init
    /\ l = 1

------------------------------------------------------------------------
(* TRACE NEXT *)

TraceNext ==
    \/ Done
    \/ \E role \in Roles, sid \in SessionIDs :
        \/ TraceTransitionToEstablished(role, sid)
        \/ TraceCompleteZeroization(role, sid)
        \/ TraceEncodeSecuredMessage(role, sid)
        \/ TraceAttemptDecodeFirstEndian(role, sid)
        \/ TraceInitiateKeyUpdate(role, sid)
        \/ TraceConfirmKeyUpdate(role, sid)
        \/ TraceRollbackToBackupKey(role, sid)

------------------------------------------------------------------------
(* TEMPORAL PROPERTIES *)

TraceMatched == <>(l > Len(TraceLog))

========================================================================
