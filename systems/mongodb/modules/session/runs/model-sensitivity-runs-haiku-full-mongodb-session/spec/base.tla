---- MODULE base ----
(* MongoDB Logical Session Catalog - Base Specification
   Category A: Distributed/Message-Passing with concurrent state machines
   Targets 5 bug families from modeling brief: checkout-kill-release race,
   parent-child consistency, refresh-reap asynchronous race,
   killsRequested counter ordering, and unlock-callback race.
*)

EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

(* ============================================================================
   CONSTANTS
   ============================================================================ *)

CONSTANT SessionIds, MaxReapCount, MaxRefreshCount
CONSTANT MaxCheckoutLimit, MaxKillLimit, MaxReleaseLimit
CONSTANT MaxCallbackLimit, MaxReapScanLimit, MaxCreateChildLimit
CONSTANT MaxRefreshLimit, MaxReapLimit, MaxOpCtxId

(* ============================================================================
   SESSION STATE DEFINITIONS
   ============================================================================ *)

(* Session lifecycle states (Family 1, 3.1 Recommendation 1) *)
SessionStates == {"AVAILABLE", "CHECKED_OUT", "KILLING", "KILLED"}
ReapModes == {"EXCLUSIVE", "NONEXCLUSIVE"}
CacheStates == {"ACTIVE", "ENDING", "EXPIRED"}

(* ============================================================================
   VARIABLES - BASE PROTOCOL
   ============================================================================ *)

(* Per-session session catalog state *)
VARIABLE sessionState         (* Session ID -> SessionStates *)
VARIABLE killsRequested       (* Session ID -> Nat (counter) *)
VARIABLE markedForReap        (* Session ID -> BOOL *)
VARIABLE reapMode             (* Session ID -> ReapModes *)
VARIABLE checkoutOpCtx        (* Session ID -> OpCtxId or NULL *)

(* Parent-child relationships (Family 2, 3.1 Recommendation 3) *)
VARIABLE parentOf             (* SessionId -> SessionId or NULL (NULL means top-level) *)
VARIABLE childrenOf           (* SessionId -> Set of SessionIds *)

(* Background job scheduling (Family 3, 3.1 Recommendation 4) *)
VARIABLE refreshRunning       (* BOOL *)
VARIABLE reapRunning          (* BOOL *)
VARIABLE refreshedSessionIds  (* Set of SessionIds that have been refreshed *)
VARIABLE reapedSessionIds     (* Set of SessionIds that have been reaped *)

(* Cache state for Family 3 *)
VARIABLE cacheState           (* Session ID -> CacheStates *)
VARIABLE activeSessions       (* Set of SessionIds in cache *)

(* Operation contexts for interrupt tracking *)
VARIABLE opContexts           (* OpCtxId -> {interrupted: BOOL, done: BOOL} *)
VARIABLE nextOpCtxId          (* Nat - counter for unique IDs *)

(* ============================================================================
   VARIABLES - EXTENSION: Kill Request Tracking (Family 4, 3.1 Recommendation 2)
   ============================================================================ *)

VARIABLE killsRequested_interrupted  (* Session ID -> BOOL (true if actually interrupted) *)

(* ============================================================================
   VARIABLES - EXTENSION: Reap Marking (Family 2, 3.1 Recommendation 3)
   ============================================================================ *)

(* Already included: markedForReap, reapMode *)

(* ============================================================================
   VARIABLES - EXTENSION: Release Unlock-Callback (Family 5)
   ============================================================================ *)

VARIABLE pendingCallbacks     (* Set of sessions with eager reap callbacks pending *)
VARIABLE callbackExecuting    (* BOOL - tracks if callback is executing without lock *)

(* ============================================================================
   ALL VARIABLES
   ============================================================================ *)

vars == <<
  sessionState, killsRequested, markedForReap, reapMode, checkoutOpCtx,
  parentOf, childrenOf,
  refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds,
  cacheState, activeSessions,
  opContexts, nextOpCtxId,
  killsRequested_interrupted,
  pendingCallbacks, callbackExecuting
>>

sessionCatalogVars == <<
  sessionState, killsRequested, markedForReap, reapMode, checkoutOpCtx,
  parentOf, childrenOf, killsRequested_interrupted,
  pendingCallbacks, callbackExecuting
>>

cacheVars == <<
  refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds,
  cacheState, activeSessions
>>

(* ============================================================================
   HELPERS
   ============================================================================ *)

NULL == -1  (* Sentinel value for "no value" - distinct from all opCtxIds which are >= 0 *)

IsAllocatedSession(s) == s \in DOMAIN parentOf

GetAllDescendants(s) ==
  childrenOf[s]  (* Simplified: only direct children for now *)

HasChildren(s) == childrenOf[s] /= {}

AllChildrenMarkedForReap(s) ==
  \A child \in childrenOf[s] : markedForReap[child]

(* Family 2: Check if all children are marked for reap or if parent itself should be reaped *)
CanReapParent(s) ==
  \A child \in childrenOf[s] : markedForReap[child]

(* ============================================================================
   INITIALIZATION
   ============================================================================ *)

Init ==
  /\ sessionState = [s \in SessionIds |-> "AVAILABLE"]
  /\ killsRequested = [s \in SessionIds |-> 0]
  /\ markedForReap = [s \in SessionIds |-> FALSE]
  /\ reapMode = [s \in SessionIds |-> "NONEXCLUSIVE"]
  /\ checkoutOpCtx = [s \in SessionIds |-> NULL]
  /\ parentOf = [s \in SessionIds |-> NULL]
  /\ childrenOf = [s \in SessionIds |-> {}]
  /\ refreshRunning = FALSE
  /\ reapRunning = FALSE
  /\ refreshedSessionIds = {}
  /\ reapedSessionIds = {}
  /\ cacheState = [s \in SessionIds |-> "ACTIVE"]
  /\ activeSessions = SessionIds
  /\ opContexts = [id \in {} |-> {}]  (* Start with empty map *)
  /\ nextOpCtxId = 0
  /\ killsRequested_interrupted = [s \in SessionIds |-> FALSE]
  /\ pendingCallbacks = {}
  /\ callbackExecuting = FALSE

(* ============================================================================
   ACTIONS - SESSION CHECKOUT (Family 1)
   ============================================================================ *)

(* session_catalog.cpp:105-154 *)
CheckOutSessionInner(sid, forKill) ==
  /\ ~markedForReap[sid]  (* line 130-135: Precondition checks *)
  /\ IF forKill
     THEN /\ killsRequested[sid] > 0  (* line 140-142: Wait for not killed *)
          /\ ~markedForReap[sid]
     ELSE /\ killsRequested[sid] = 0  (* Session must not be marked for killing *)
  /\ sessionState[sid] = "AVAILABLE"  (* line 116-119: Transition available -> checked out *)
  /\ \E opCtxId \in (0..MaxOpCtxId) \ DOMAIN opContexts :  (* Allocate new operation context *)
      /\ opCtxId = nextOpCtxId
      /\ sessionState' = [sessionState EXCEPT ![sid] = "CHECKED_OUT"]
      /\ checkoutOpCtx' = [checkoutOpCtx EXCEPT ![sid] = opCtxId]
      /\ opContexts' = opContexts @@ (opCtxId :> [interrupted |-> FALSE, done |-> FALSE])
      /\ nextOpCtxId' = nextOpCtxId + 1
      /\ UNCHANGED <<killsRequested, markedForReap, reapMode, parentOf, childrenOf,
                      refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds,
                      cacheState, activeSessions, killsRequested_interrupted,
                      pendingCallbacks, callbackExecuting>>

(* ============================================================================
   ACTIONS - SESSION KILL (Family 1, 4)
   ============================================================================ *)

(* session_catalog.cpp:447-457 *)
ObservableSessionKill(sid) ==
  /\ IsAllocatedSession(sid)
  /\ LET oldCount == killsRequested[sid]  (* line 448: reads before incrementing *)
         newCount == oldCount + 1
     IN /\ killsRequested' = [killsRequested EXCEPT ![sid] = newCount]
        (* line 451-454: conditionally interrupt if operation exists *)
        /\ IF checkoutOpCtx[sid] /= NULL
           THEN LET opCtxId == checkoutOpCtx[sid]
                IN /\ opContexts' = [opContexts EXCEPT ![opCtxId].interrupted = TRUE]
                   /\ killsRequested_interrupted' = [killsRequested_interrupted EXCEPT ![sid] = TRUE]
           ELSE /\ UNCHANGED opContexts
                /\ UNCHANGED killsRequested_interrupted
        /\ UNCHANGED <<sessionState, markedForReap, reapMode, checkoutOpCtx, parentOf, childrenOf,
                        refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds,
                        cacheState, activeSessions, nextOpCtxId, pendingCallbacks, callbackExecuting>>

(* ============================================================================
   ACTIONS - SESSION RELEASE (Family 1, 5)
   ============================================================================ *)

(* session_catalog.cpp:354-417 *)
ReleaseSession(sid) ==
  /\ sessionState[sid] = "CHECKED_OUT"
  /\ checkoutOpCtx[sid] /= NULL
  /\ LET opCtxId == checkoutOpCtx[sid]
     IN /\ IF killsRequested[sid] > 0
           THEN /\ killsRequested' = [killsRequested EXCEPT ![sid] = killsRequested[sid] - 1]
           ELSE /\ UNCHANGED killsRequested
        /\ sessionState' = [sessionState EXCEPT ![sid] =
                            IF killsRequested[sid] > 0 THEN "AVAILABLE" ELSE "AVAILABLE"]
        /\ checkoutOpCtx' = [checkoutOpCtx EXCEPT ![sid] = NULL]
        (* line 412: unlock before callback *)
        /\ pendingCallbacks' = IF markedForReap[sid] THEN pendingCallbacks \cup {sid}
                              ELSE pendingCallbacks
        (* line 414-415: callback would trigger here but we model it separately *)
        /\ UNCHANGED << markedForReap, reapMode, parentOf, childrenOf, refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds, cacheState, activeSessions, opContexts, nextOpCtxId, killsRequested_interrupted, callbackExecuting >>

(* ============================================================================
   ACTIONS - SESSION REAPING (Family 2)
   ============================================================================ *)

(* session_catalog.cpp:234-286: Scan sessions for reap *)
ScanSessionsForReap ==
  /\ ~reapRunning  (* Prevent concurrent reap *)
  /\ reapRunning' = TRUE
  /\ \E toReap \in SUBSET SessionIds :  (* Non-deterministic choice of what to reap *)
      /\ \A s \in toReap :
           (parentOf[s] = NULL \/ parentOf[s] \in toReap)  (* If child marked, parent must be too *)
      /\ LET reapedParents == {s \in toReap : parentOf[s] = NULL}
             reapedChildren == {s \in toReap : parentOf[s] /= NULL}
         IN /\ markedForReap' = [s \in SessionIds |->
                                 IF s \in toReap THEN TRUE ELSE markedForReap[s]]
            /\ reapedSessionIds' = reapedSessionIds \cup toReap
            /\ UNCHANGED << sessionState, killsRequested, reapMode, checkoutOpCtx, parentOf, childrenOf, refreshRunning, refreshedSessionIds, cacheState, activeSessions, opContexts, nextOpCtxId, killsRequested_interrupted, pendingCallbacks, callbackExecuting >>

(* Finish reap job *)
FinishReap ==
  /\ reapRunning
  /\ reapRunning' = FALSE
  /\ UNCHANGED << sessionState, killsRequested, markedForReap, reapMode, checkoutOpCtx, parentOf, childrenOf, refreshRunning, refreshedSessionIds, reapedSessionIds, cacheState, activeSessions, opContexts, nextOpCtxId, killsRequested_interrupted, pendingCallbacks, callbackExecuting >>

(* ============================================================================
   ACTIONS - LOGICAL SESSION CACHE (Family 3)
   ============================================================================ *)

(* logical_session_cache_impl.cpp:277-455 *)
PeriodicRefresh ==
  /\ ~refreshRunning
  /\ refreshRunning' = TRUE
  /\ \E toRefresh \in SUBSET activeSessions :
      /\ refreshedSessionIds' = refreshedSessionIds \cup toRefresh
      /\ cacheState' = [s \in SessionIds |->
                        IF s \in toRefresh THEN "ACTIVE" ELSE cacheState[s]]
      /\ activeSessions' = activeSessions \cup toRefresh  (* line 385-398: back-swap *)
      /\ UNCHANGED << sessionState, killsRequested, markedForReap, reapMode, checkoutOpCtx, parentOf, childrenOf, reapRunning, reapedSessionIds, opContexts, nextOpCtxId, killsRequested_interrupted, pendingCallbacks, callbackExecuting >>

FinishRefresh ==
  /\ refreshRunning
  /\ refreshRunning' = FALSE
  /\ UNCHANGED << sessionState, killsRequested, markedForReap, reapMode, checkoutOpCtx, parentOf, childrenOf, reapRunning, refreshedSessionIds, reapedSessionIds, cacheState, activeSessions, opContexts, nextOpCtxId, killsRequested_interrupted, pendingCallbacks, callbackExecuting >>

(* ============================================================================
   ACTIONS - CHILD SESSION CREATION (Family 2)
   ============================================================================ *)

(* session_catalog.cpp:331-352 *)
CreateChildSession(parentSid, childSid) ==
  /\ parentSid \in SessionIds
  /\ childSid \in SessionIds
  /\ parentSid /= childSid  (* Sessions cannot be their own parents *)
  /\ parentOf[parentSid] = NULL  (* Parent must not itself be a child - one-level hierarchy *)
  /\ childSid \notin childrenOf[parentSid]
  /\ parentOf[childSid] = NULL  (* Not already a child *)
  /\ parentOf' = [parentOf EXCEPT ![childSid] = parentSid]
  /\ childrenOf' = [childrenOf EXCEPT ![parentSid] = @ \cup {childSid}]
  /\ sessionState' = [sessionState EXCEPT ![childSid] = "AVAILABLE"]
  /\ killsRequested' = [killsRequested EXCEPT ![childSid] = 0]
  /\ markedForReap' = [markedForReap EXCEPT ![childSid] = FALSE]
  /\ UNCHANGED << reapMode, checkoutOpCtx, refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds, cacheState, activeSessions, opContexts, nextOpCtxId, killsRequested_interrupted, pendingCallbacks, callbackExecuting >>

(* ============================================================================
   ACTIONS - RELEASE UNLOCK-CALLBACK RACE (Family 5)
   ============================================================================ *)

(* session_catalog.cpp:414-415: Callback executes unlocked *)
ExecuteEagerReapCallback(sid) ==
  /\ sid \in pendingCallbacks
  /\ ~callbackExecuting
  /\ callbackExecuting' = TRUE
  /\ UNCHANGED << sessionState, killsRequested, markedForReap, reapMode, checkoutOpCtx, parentOf, childrenOf, refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds, cacheState, activeSessions, opContexts, nextOpCtxId, killsRequested_interrupted, pendingCallbacks, killsRequested_interrupted >>

CompleteEagerReapCallback(sid) ==
  /\ sid \in pendingCallbacks
  /\ callbackExecuting
  /\ callbackExecuting' = FALSE
  /\ pendingCallbacks' = pendingCallbacks \ {sid}
  /\ UNCHANGED << sessionState, killsRequested, markedForReap, reapMode, checkoutOpCtx, parentOf, childrenOf, refreshRunning, reapRunning, refreshedSessionIds, reapedSessionIds, cacheState, activeSessions, opContexts, nextOpCtxId, killsRequested_interrupted >>

(* ============================================================================
   ACTIONS - OPERATION COMPLETION (Background action)
   ============================================================================ *)

CompleteOperation(opCtxId) ==
  /\ opCtxId \in DOMAIN opContexts
  /\ ~opContexts[opCtxId].done
  /\ opContexts' = [opContexts EXCEPT ![opCtxId].done = TRUE]
  /\ UNCHANGED vars

(* ============================================================================
   NEXT-STATE RELATION
   ============================================================================ *)

Next ==
  \/ \E sid \in SessionIds : CheckOutSessionInner(sid, FALSE)
  \/ \E sid \in SessionIds : CheckOutSessionInner(sid, TRUE)
  \/ \E sid \in SessionIds : ObservableSessionKill(sid)
  \/ \E sid \in SessionIds : ReleaseSession(sid)
  \/ ScanSessionsForReap
  \/ FinishReap
  \/ PeriodicRefresh
  \/ FinishRefresh
  \/ \E p, c \in SessionIds : CreateChildSession(p, c)
  \/ \E sid \in SessionIds : ExecuteEagerReapCallback(sid)
  \/ \E sid \in SessionIds : CompleteEagerReapCallback(sid)
  \/ \E opCtxId \in DOMAIN opContexts : CompleteOperation(opCtxId)

(* ============================================================================
   INVARIANTS - SAFETY (Family-driven)
   ============================================================================ *)

(* Family 4: killsRequested counter never negative *)
KillCountNonNegative ==
  \A s \in SessionIds : killsRequested[s] >= 0

(* Family 1: Session cannot be both checked out and killed *)
CheckedOutXorKilled ==
  \A s \in SessionIds :
    ~(sessionState[s] = "CHECKED_OUT" /\ killsRequested[s] > 0)

(* Family 2: Parent-child consistency *)
ParentNotReapedWithChildren ==
  \A p \in SessionIds :
    (markedForReap[p] /\ parentOf[p] = NULL /\ HasChildren(p)) =>
    (\A c \in childrenOf[p] : markedForReap[c])

(* Family 2: No orphaned children *)
NoOrphanedChildren ==
  \A c \in SessionIds :
    (parentOf[c] /= NULL) =>
    (\E p \in SessionIds : p = parentOf[c] /\ parentOf[p] = NULL)

(* Family 4: If kill incremented counter, interrupt must be tracked *)
InterruptConsistency ==
  \A s \in SessionIds :
    (killsRequested[s] > 0) =>
    (killsRequested_interrupted[s] \/ checkoutOpCtx[s] = NULL)

(* Family 5: Callbacks don't corrupt state *)
CallbackExecution ==
  (callbackExecuting = FALSE) \/ (pendingCallbacks /= {})

(* ============================================================================
   INVARIANTS - STRUCTURAL
   ============================================================================ *)

SessionStateValid ==
  \A s \in SessionIds : sessionState[s] \in SessionStates

ReapModeValid ==
  \A s \in SessionIds : reapMode[s] \in ReapModes

CacheStateValid ==
  \A s \in SessionIds : cacheState[s] \in CacheStates

OperationContextsConsistent ==
  \A opCtxId \in DOMAIN opContexts :
    /\ opContexts[opCtxId].interrupted \in BOOLEAN
    /\ opContexts[opCtxId].done \in BOOLEAN

ParentChildConsistency ==
  \A s \in SessionIds :
    /\ (parentOf[s] \in SessionIds \/ parentOf[s] = NULL)
    /\ (\A c \in childrenOf[s] : parentOf[c] = s)
    /\ (\A c \in childrenOf[s] : c \in SessionIds)

(* ============================================================================
   TEMPORAL PROPERTIES
   ============================================================================ *)

(* Eventually, checked out sessions must be released *)
SessionsEventuallyRelease ==
  \A s \in SessionIds :
    (sessionState[s] = "CHECKED_OUT") ~> (sessionState[s] = "AVAILABLE")

(* Refresh/reap jobs eventually complete *)
JobsEventuallyComplete ==
  ((refreshRunning) ~> (~refreshRunning))
  /\ ((reapRunning) ~> (~reapRunning))

====
