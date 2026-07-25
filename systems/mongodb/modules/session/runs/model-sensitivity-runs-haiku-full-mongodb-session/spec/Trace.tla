---- MODULE Trace ----
(* Trace Validation Spec for MongoDB Session Catalog
   Replays recorded execution traces against base spec to verify consistency.
   Category A: Standard linear trace with single cursor.
*)

EXTENDS base, Naturals, Sequences, TLC

(* ============================================================================
   TRACE LOADING
   ============================================================================ *)

(* Trace events loaded from NDJSON file - override with actual trace in config *)
TraceLog == <<>>

(* ============================================================================
   TRACE VARIABLES
   ============================================================================ *)

VARIABLE l  (* Cursor: index into TraceLog *)

TraceVars == <<l>>

AllVars == <<vars, TraceVars>>

(* ============================================================================
   TRACE INITIALIZATION
   ============================================================================ *)

TraceInit ==
  /\ Init
  /\ l = 1

(* ============================================================================
   TRACE HELPERS
   ============================================================================ *)

GetCurrentEvent == IF l <= Len(TraceLog) THEN TraceLog[l] ELSE NULL

IsEvent(eventName) == GetCurrentEvent.event = eventName

IsNodeEvent(eventName, sid) ==
  /\ IsEvent(eventName)
  /\ GetCurrentEvent.sessionId = sid

(* Event field extractors *)
GetEventField(field) == GetCurrentEvent[field]

GetEventState(field) == GetCurrentEvent.state[field]

(* ============================================================================
   TRACE ACTION WRAPPERS - CHECKOUT
   ============================================================================ *)

(* Match CheckOutSessionInner trace event *)
ValidateCheckOutPostState(sid, forKill) ==
  /\ sessionState'[sid] = "CHECKED_OUT"
  /\ checkoutOpCtx'[sid] /= NULL
  /\ killsRequested'[sid] = killsRequested[sid]  (* Unchanged by checkout *)

MatchCheckOutSession(sid, forKill) ==
  /\ IsNodeEvent("CheckOutSession", sid)
  /\ GetEventField("forKill") = forKill
  /\ CheckOutSessionInner(sid, forKill)
  /\ ValidateCheckOutPostState(sid, forKill)
  /\ l' = l + 1

(* ============================================================================
   TRACE ACTION WRAPPERS - KILL
   ============================================================================ *)

(* Match ObservableSession.kill trace event *)
ValidateKillPostState(sid) ==
  /\ killsRequested'[sid] = killsRequested[sid] + 1
  /\ killsRequested'[sid] > 0
  /\ IF checkoutOpCtx[sid] /= NULL
     THEN killsRequested_interrupted'[sid] = TRUE
     ELSE killsRequested_interrupted'[sid] = killsRequested_interrupted[sid]

MatchKill(sid) ==
  /\ IsNodeEvent("Kill", sid)
  /\ ObservableSessionKill(sid)
  /\ ValidateKillPostState(sid)
  /\ l' = l + 1

(* ============================================================================
   TRACE ACTION WRAPPERS - RELEASE
   ============================================================================ *)

(* Match ReleaseSession trace event *)
ValidateReleasePostState(sid) ==
  /\ sessionState'[sid] = "AVAILABLE"
  /\ checkoutOpCtx'[sid] = NULL
  /\ IF killsRequested[sid] > 0
     THEN killsRequested'[sid] = killsRequested[sid] - 1
     ELSE killsRequested'[sid] = killsRequested[sid]

MatchReleaseSession(sid) ==
  /\ IsNodeEvent("ReleaseSession", sid)
  /\ ReleaseSession(sid)
  /\ ValidateReleasePostState(sid)
  /\ l' = l + 1

(* ============================================================================
   TRACE ACTION WRAPPERS - REAP
   ============================================================================ *)

(* Match ScanSessionsForReap trace event *)
ValidateScanReapPostState ==
  /\ reapRunning' = TRUE
  /\ \A s \in GetEventField("marked_for_reap") : markedForReap'[s] = TRUE

MatchScanSessionsForReap ==
  /\ IsEvent("ScanSessionsForReap")
  /\ ScanSessionsForReap
  /\ ValidateScanReapPostState
  /\ l' = l + 1

MatchFinishReap ==
  /\ IsEvent("FinishReap")
  /\ FinishReap
  /\ reapRunning' = FALSE
  /\ l' = l + 1

(* ============================================================================
   TRACE ACTION WRAPPERS - REFRESH/REAP JOBS
   ============================================================================ *)

(* Match PeriodicRefresh trace event *)
ValidateRefreshPostState ==
  /\ refreshRunning' = TRUE
  /\ \A s \in GetEventField("refreshed_sessions") : s \in refreshedSessionIds'

MatchPeriodicRefresh ==
  /\ IsEvent("PeriodicRefresh")
  /\ PeriodicRefresh
  /\ ValidateRefreshPostState
  /\ l' = l + 1

MatchFinishRefresh ==
  /\ IsEvent("FinishRefresh")
  /\ FinishRefresh
  /\ refreshRunning' = FALSE
  /\ l' = l + 1

(* ============================================================================
   TRACE ACTION WRAPPERS - CHILD SESSION CREATION
   ============================================================================ *)

(* Match CreateChildSession trace event *)
ValidateCreateChildPostState(parentSid, childSid) ==
  /\ parentOf'[childSid] = parentSid
  /\ childSid \in childrenOf'[parentSid]
  /\ sessionState'[childSid] = "AVAILABLE"

MatchCreateChildSession(parentSid, childSid) ==
  /\ IsEvent("CreateChildSession")
  /\ GetEventField("parentSessionId") = parentSid
  /\ GetEventField("childSessionId") = childSid
  /\ CreateChildSession(parentSid, childSid)
  /\ ValidateCreateChildPostState(parentSid, childSid)
  /\ l' = l + 1

(* ============================================================================
   TRACE ACTION WRAPPERS - CALLBACKS
   ============================================================================ *)

MatchExecuteEagerReapCallback(sid) ==
  /\ IsNodeEvent("ExecuteEagerReapCallback", sid)
  /\ ExecuteEagerReapCallback(sid)
  /\ callbackExecuting' = TRUE
  /\ l' = l + 1

MatchCompleteEagerReapCallback(sid) ==
  /\ IsNodeEvent("CompleteEagerReapCallback", sid)
  /\ CompleteEagerReapCallback(sid)
  /\ callbackExecuting' = FALSE
  /\ sid \notin pendingCallbacks'
  /\ l' = l + 1

(* ============================================================================
   SILENT ACTIONS (No trace events)
   ============================================================================ *)

(* Silent action: Operation completion without trace event *)
SilentCompleteOperation ==
  /\ l <= Len(TraceLog)
  /\ (IF l < Len(TraceLog) THEN TraceLog[l+1].event /= "CompleteOperation" ELSE TRUE)
  /\ \E opCtxId \in DOMAIN opContexts : CompleteOperation(opCtxId)
  /\ UNCHANGED <<l, sessionState, killsRequested, markedForReap, reapMode,
                  checkoutOpCtx, parentOf, childrenOf, refreshRunning, reapRunning,
                  refreshedSessionIds, reapedSessionIds, cacheState, activeSessions,
                  killsRequested_interrupted, pendingCallbacks, callbackExecuting>>

(* Silent action: Kill tokens being checked *)
SilentCheckKillStatus ==
  /\ l <= Len(TraceLog)
  /\ \E s \in SessionIds : TRUE  (* Placeholder for killed status checks *)
  /\ UNCHANGED vars
  /\ UNCHANGED <<l>>

(* ============================================================================
   TRACE NEXT RELATION
   ============================================================================ *)

TraceNext ==
  /\ l <= Len(TraceLog)
  /\ \/ \E sid \in SessionIds : MatchCheckOutSession(sid, FALSE)
     \/ \E sid \in SessionIds : MatchCheckOutSession(sid, TRUE)
     \/ \E sid \in SessionIds : MatchKill(sid)
     \/ \E sid \in SessionIds : MatchReleaseSession(sid)
     \/ MatchScanSessionsForReap
     \/ MatchFinishReap
     \/ MatchPeriodicRefresh
     \/ MatchFinishRefresh
     \/ \E p, c \in SessionIds : MatchCreateChildSession(p, c)
     \/ \E sid \in SessionIds : MatchExecuteEagerReapCallback(sid)
     \/ \E sid \in SessionIds : MatchCompleteEagerReapCallback(sid)
     \/ SilentCompleteOperation
     \/ SilentCheckKillStatus

(* Stuttering when all events consumed *)
TraceStutter ==
  /\ l > Len(TraceLog)
  /\ UNCHANGED AllVars

(* Specification for trace validation *)
TraceSpec == TraceInit /\ [][TraceNext \/ TraceStutter]_AllVars

(* ============================================================================
   TRACE COMPLETION PROPERTY
   ============================================================================ *)

(* Temporal property: All trace events must be consumed *)
TraceFullyConsumed == <> (l > Len(TraceLog))

TraceMatched == TraceFullyConsumed

(* ============================================================================
   INVARIANTS FOR TRACE VALIDATION
   ============================================================================ *)

(* Type OK must hold throughout trace validation *)
TraceTypeOK ==
  /\ DOMAIN sessionState = SessionIds
  /\ DOMAIN killsRequested = SessionIds
  /\ \A s \in SessionIds : killsRequested[s] >= 0
  /\ sessionState \in [SessionIds -> SessionStates]
  /\ killsRequested \in [SessionIds -> Nat]
  /\ l >= 1 /\ l <= Len(TraceLog) + 1

(* Core safety invariants must hold at every trace point *)
TraceSafetyInvariants ==
  /\ CheckedOutXorKilled
  /\ ParentNotReapedWithChildren
  /\ NoOrphanedChildren
  /\ InterruptConsistency
  /\ KillCountNonNegative

(* Structural consistency during trace *)
TraceStructuralInvariants ==
  /\ SessionStateValid
  /\ ReapModeValid
  /\ CacheStateValid
  /\ ParentChildConsistency

====
