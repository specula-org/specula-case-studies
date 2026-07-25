---- MODULE Trace ----
(* =========================================================================
 * Trace validation for MongoDB Resharding Coordinator
 *
 * Replays a recorded execution trace against base.tla to verify the spec
 * faithfully models the implementation's state transitions.
 * ========================================================================= *)
EXTENDS base, Sequences, TLC, Integers, IOUtils, Json

(* =========================================================================
 * Trace Loading
 * ========================================================================= *)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/basic_resharding.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only "trace" tagged lines
TraceLog == SelectSeq(RawTraceLog, LAMBDA x : "tag" \in DOMAIN x /\ x.tag = "trace")

(* =========================================================================
 * Cursor variable
 * ========================================================================= *)

VARIABLE l  \* Current position in trace (1-indexed)

traceVars == <<vars, l>>

(* =========================================================================
 * State Mapping: MongoDB log strings → TLA+ constants
 * ========================================================================= *)

MapCoordState(s) ==
    CASE s = "unused"              -> CUnused
      [] s = "initializing"        -> CInitializing
      [] s = "preparing-to-donate" -> CPreparingToDonate
      [] s = "cloning"             -> CCloning
      [] s = "applying"            -> CApplying
      [] s = "blocking-writes"     -> CBlockingWrites
      [] s = "committing"          -> CCommitting
      [] s = "aborting"            -> CAborting
      [] s = "quiesced"            -> CQuiesced
      [] s = "done"                -> CDone
      [] OTHER                     -> CUnused

(* =========================================================================
 * Event helpers
 * ========================================================================= *)

logline == TraceLog[l]

IsEvent(name) ==
    /\ "event" \in DOMAIN logline
    /\ "name" \in DOMAIN logline.event
    /\ logline.event.name = name

GetState(field) ==
    IF "state" \in DOMAIN logline.event /\ field \in DOMAIN logline.event.state
    THEN logline.event.state[field]
    ELSE "unknown"

(* =========================================================================
 * Post-state validation
 * Verifies spec state matches trace after each action.
 * ========================================================================= *)

ValidateCoordState ==
    LET newState == GetState("coordState") IN
    IF newState = "unknown" THEN TRUE
    ELSE coordState' = MapCoordState(newState)

(* =========================================================================
 * Trace Action Wrappers
 * Each wrapper: match event → call base action → validate → advance cursor
 * ========================================================================= *)

TraceCoordInitialize ==
    /\ IsEvent("CoordInitialize")
    /\ CoordInitialize
    /\ ValidateCoordState
    /\ l' = l + 1

TraceCoordPrepare ==
    /\ IsEvent("CoordPrepare")
    /\ CoordPrepare
    /\ ValidateCoordState
    /\ l' = l + 1

TraceCoordTransitionToCloning ==
    /\ IsEvent("CoordTransitionToCloning")
    /\ CoordTransitionToCloning
    /\ ValidateCoordState
    /\ l' = l + 1

TraceCoordTransitionToApplying ==
    /\ IsEvent("CoordTransitionToApplying")
    /\ CoordTransitionToApplying
    /\ ValidateCoordState
    /\ l' = l + 1

TraceCoordTransitionToBlocking ==
    /\ IsEvent("CoordTransitionToBlocking")
    /\ CoordTransitionToBlocking
    /\ ValidateCoordState
    /\ l' = l + 1

TraceCoordCommit ==
    /\ IsEvent("CoordCommit")
    /\ CoordCommit
    /\ ValidateCoordState
    /\ l' = l + 1

TraceCoordAbortPersist ==
    /\ IsEvent("CoordAbortPersist")
    /\ CoordAbortPersist
    /\ ValidateCoordState
    /\ l' = l + 1

TraceCoordFinish ==
    /\ IsEvent("CoordFinish")
    /\ \/ CoordFinish
       \/ CoordAbortFinish
       \/ CoordAbortCoordinatorOnly
    /\ ValidateCoordState
    /\ l' = l + 1

(* =========================================================================
 * Silent Actions — fire without consuming a trace event
 * Must be tightly constrained to avoid state space explosion
 * ========================================================================= *)

\* Silent: majority commits (happen between transitions, no log event)
SilentMajority ==
    /\ l <= Len(TraceLog)
    /\ \/ CoordInitializeMajority
       \/ CoordPrepareMajority
       \/ CoordGenericMajority
       \/ CoordCommitMajority
       \/ CoordTellParticipantsCommit
       \/ CoordAbortMajority
       \/ CoordTellParticipantsAbort
    /\ UNCHANGED l

\* Silent: observer promise check (internal, no log event)
SilentObserverCheck ==
    /\ l <= Len(TraceLog)
    /\ ObserverCheck
    /\ UNCHANGED l

\* Silent: abort request (no separate log line for the request itself)
SilentAbortRequest ==
    /\ l <= Len(TraceLog)
    \* Only fire if next event is CoordAbortPersist (constraint to prevent explosion)
    /\ IsEvent("CoordAbortPersist")
    /\ \/ CoordAbortRequest
       \/ CoordAbortOnParticipantError
    /\ UNCHANGED l

\* Silent: participant state changes (not logged on coordinator)
SilentParticipantAdvance ==
    /\ l <= Len(TraceLog)
    /\ \/ \E d \in Donor : DonorAdvance(d)
       \/ \E d \in Donor : DonorDone(d)
       \/ \E r \in Recipient : RecipientAdvance(r)
       \/ \E r \in Recipient : RecipientDone(r)
    /\ UNCHANGED l

\* Silent: participant error
SilentParticipantError ==
    /\ l <= Len(TraceLog)
    \* Only fire if next event is abort-related
    /\ \/ IsEvent("CoordAbortPersist")
       \/ IsEvent("CoordFinish")
    /\ \/ \E d \in Donor : DonorError(d)
       \/ \E r \in Recipient : RecipientError(r)
    /\ UNCHANGED l

\* Silent: coordinator crash and recovery
SilentCoordCrash ==
    /\ l <= Len(TraceLog)
    /\ CoordCrash
    /\ UNCHANGED l

SilentCoordRecover ==
    /\ l <= Len(TraceLog)
    /\ CoordRecover
    /\ UNCHANGED l

(* =========================================================================
 * Trace Init
 * ========================================================================= *)

TraceInit ==
    /\ Init
    /\ l = 1

(* =========================================================================
 * Trace Next
 * ========================================================================= *)

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceCoordInitialize
          \/ TraceCoordPrepare
          \/ TraceCoordTransitionToCloning
          \/ TraceCoordTransitionToApplying
          \/ TraceCoordTransitionToBlocking
          \/ TraceCoordCommit
          \/ TraceCoordAbortPersist
          \/ TraceCoordFinish
    \/ SilentMajority
    \/ SilentObserverCheck
    \/ SilentAbortRequest
    \/ SilentParticipantAdvance
    \/ SilentParticipantError
    \/ SilentCoordCrash
    \/ SilentCoordRecover

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* Trace was fully consumed (reaches deadlock = success)
TraceFinished == l = Len(TraceLog) + 1

(* =========================================================================
 * View — exclude trace cursor from state fingerprint
 * ========================================================================= *)

TraceView == <<vars>>

====
