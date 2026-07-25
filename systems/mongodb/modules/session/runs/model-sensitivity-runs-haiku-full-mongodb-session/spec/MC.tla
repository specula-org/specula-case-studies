---- MODULE MC ----
(* Model Checking spec for mongodb-session with counter-bounded actions *)

EXTENDS base

(* ============================================================================
   COUNTER-BOUNDED FAULT INJECTION ACTIONS
   ============================================================================ *)

(* These counters track how many times each non-deterministic action fires *)
VARIABLE faultCounters

faultVars == <<faultCounters>>

MCVars == <<vars, faultVars>>

(* ============================================================================
   FAULT INJECTION: Checkout-Kill Race (Family 1)
   ============================================================================ *)

(* Allow operations to interleave between checkout phases *)
MCCheckOutSessionInner(sid, forKill) ==
  /\ faultCounters.checkout < MaxCheckoutLimit
  /\ CheckOutSessionInner(sid, forKill)
  /\ faultCounters' = [faultCounters EXCEPT !.checkout = @ + 1]

(* ============================================================================
   FAULT INJECTION: Kill Races (Family 1, 4)
   ============================================================================ *)

MCObservableSessionKill(sid) ==
  /\ faultCounters.kill < MaxKillLimit
  /\ ObservableSessionKill(sid)
  /\ faultCounters' = [faultCounters EXCEPT !.kill = @ + 1]

(* ============================================================================
   FAULT INJECTION: Release-Callback Race (Family 5)
   ============================================================================ *)

MCReleaseSession(sid) ==
  /\ faultCounters.release < MaxReleaseLimit
  /\ ReleaseSession(sid)
  /\ faultCounters' = [faultCounters EXCEPT !.release = @ + 1]

MCExecuteEagerReapCallback(sid) ==
  /\ faultCounters.callbackExec < MaxCallbackLimit
  /\ ExecuteEagerReapCallback(sid)
  /\ faultCounters' = [faultCounters EXCEPT !.callbackExec = @ + 1]

MCCompleteEagerReapCallback(sid) ==
  /\ faultCounters.callbackComplete < MaxCallbackLimit
  /\ CompleteEagerReapCallback(sid)
  /\ faultCounters' = [faultCounters EXCEPT !.callbackComplete = @ + 1]

(* ============================================================================
   FAULT INJECTION: Parent-Child Reap Race (Family 2)
   ============================================================================ *)

MCScanSessionsForReap ==
  /\ faultCounters.reapScan < MaxReapScanLimit
  /\ ScanSessionsForReap
  /\ faultCounters' = [faultCounters EXCEPT !.reapScan = @ + 1]

MCCreateChildSession(parentSid, childSid) ==
  /\ faultCounters.createChild < MaxCreateChildLimit
  /\ CreateChildSession(parentSid, childSid)
  /\ faultCounters' = [faultCounters EXCEPT !.createChild = @ + 1]

(* ============================================================================
   FAULT INJECTION: Refresh-Reap Race (Family 3)
   ============================================================================ *)

MCPeriodicRefresh ==
  /\ faultCounters.refresh < MaxRefreshLimit
  /\ PeriodicRefresh
  /\ faultCounters' = [faultCounters EXCEPT !.refresh = @ + 1]

MCPeriodicReap ==
  /\ faultCounters.reap < MaxReapLimit
  /\ (ScanSessionsForReap \/ FinishReap)
  /\ faultCounters' = [faultCounters EXCEPT !.reap = @ + 1]

(* ============================================================================
   UNCONSTRAINED (REACTIVE) ACTIONS
   ============================================================================ *)

(* Reactive actions that don't introduce non-determinism *)

MCFinishRefresh == FinishRefresh /\ UNCHANGED faultVars

MCFinishReap == FinishReap /\ UNCHANGED faultVars

MCCompleteOperation(opCtxId) ==
  CompleteOperation(opCtxId) /\ UNCHANGED faultVars

(* ============================================================================
   MC INITIALIZATION
   ============================================================================ *)

MCInit ==
  /\ Init
  /\ faultCounters = [
      checkout      |-> 0,
      kill          |-> 0,
      release       |-> 0,
      callbackExec  |-> 0,
      callbackComplete |-> 0,
      reapScan      |-> 0,
      createChild   |-> 0,
      refresh       |-> 0,
      reap          |-> 0
    ]

(* ============================================================================
   MC NEXT-STATE RELATION
   ============================================================================ *)

MCNext ==
  \/ \E sid \in SessionIds : MCCheckOutSessionInner(sid, FALSE)
  \/ \E sid \in SessionIds : MCCheckOutSessionInner(sid, TRUE)
  \/ \E sid \in SessionIds : MCObservableSessionKill(sid)
  \/ \E sid \in SessionIds : MCReleaseSession(sid)
  \/ MCScanSessionsForReap
  \/ MCPeriodicReap
  \/ MCFinishReap
  \/ MCPeriodicRefresh
  \/ MCFinishRefresh
  \/ \E p, c \in SessionIds : MCCreateChildSession(p, c)
  \/ \E sid \in SessionIds : MCExecuteEagerReapCallback(sid)
  \/ \E sid \in SessionIds : MCCompleteEagerReapCallback(sid)
  \/ \E opCtxId \in DOMAIN opContexts : MCCompleteOperation(opCtxId)

(* ============================================================================
   SYMMETRY REDUCTION
   ============================================================================ *)

Symmetry == Permutations(SessionIds)

(* ============================================================================
   STATE SPACE PRUNING
   ============================================================================ *)

(* Prune states where we've exceeded reasonable bounds *)
StateSpacePruning ==
  /\ faultCounters.checkout <= MaxCheckoutLimit + 1
  /\ faultCounters.kill <= MaxKillLimit + 1
  /\ faultCounters.release <= MaxReleaseLimit + 1
  /\ faultCounters.reapScan <= MaxReapScanLimit + 1
  /\ faultCounters.createChild <= MaxCreateChildLimit + 1
  /\ faultCounters.refresh <= MaxRefreshLimit + 1
  /\ faultCounters.reap <= MaxReapLimit + 1
  /\ faultCounters.callbackExec <= MaxCallbackLimit + 1
  /\ faultCounters.callbackComplete <= MaxCallbackLimit + 1

(* ============================================================================
   INVARIANTS FOR MC (Standard + Structural)
   ============================================================================ *)

(* Standard safety: Type OK *)
MCTypeOK ==
  /\ DOMAIN sessionState = SessionIds
  /\ DOMAIN killsRequested = SessionIds
  /\ DOMAIN markedForReap = SessionIds
  /\ DOMAIN reapMode = SessionIds
  /\ DOMAIN checkoutOpCtx = SessionIds
  /\ DOMAIN parentOf = SessionIds
  /\ DOMAIN childrenOf = SessionIds
  /\ DOMAIN cacheState = SessionIds
  /\ DOMAIN killsRequested_interrupted = SessionIds
  /\ sessionState \in [SessionIds -> SessionStates]
  /\ killsRequested \in [SessionIds -> Nat]
  /\ markedForReap \in [SessionIds -> BOOLEAN]
  /\ reapMode \in [SessionIds -> ReapModes]
  /\ cacheState \in [SessionIds -> CacheStates]
  /\ activeSessions \subseteq SessionIds
  /\ refreshRunning \in BOOLEAN
  /\ reapRunning \in BOOLEAN
  /\ refreshedSessionIds \subseteq SessionIds
  /\ reapedSessionIds \subseteq SessionIds
  /\ pendingCallbacks \subseteq SessionIds
  /\ callbackExecuting \in BOOLEAN
  /\ StateSpacePruning

(* Structural invariants *)
MCStructuralInvariants ==
  /\ SessionStateValid
  /\ ReapModeValid
  /\ CacheStateValid
  /\ OperationContextsConsistent
  /\ ParentChildConsistency
  /\ KillCountNonNegative

(* Core safety invariants *)
MCSafetyInvariants ==
  /\ CheckedOutXorKilled
  /\ ParentNotReapedWithChildren
  /\ NoOrphanedChildren
  /\ InterruptConsistency
  /\ CallbackExecution

====
