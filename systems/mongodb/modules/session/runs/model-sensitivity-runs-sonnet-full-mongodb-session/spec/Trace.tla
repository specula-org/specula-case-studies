-------------------------------- MODULE Trace --------------------------------
(*
 * Trace validation spec for MongoDBSession.
 *
 * Category: A (Distributed / Message-Passing) — uses single-file linear trace
 * with cursor variable `l`.
 *
 * Validates that a recorded execution trace from the MongoDB session subsystem
 * is consistent with the base spec (MongoDBSession.tla).
 *
 * Trace files (.ndjson) are in traces/ (sibling of spec/).
 *
 * Each trace event is a JSON object:
 *   { "event": <name>, "session": <id>, "state": { ... } }
 *)

EXTENDS MongoDBSession, Sequences, TLC, IOUtils, Json

(*------------------------------------------------------------------
 * TRACE LOADING
 *------------------------------------------------------------------*)

\* Path to the trace file. Override via IOEnv.JSON for per-run selection.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* Cursor variable: walks through trace events 1..Len(TraceLog).
VARIABLE l

(*------------------------------------------------------------------
 * SESSION MAPPING
 *------------------------------------------------------------------*)

\* Extract the set of sessions referenced in the trace.
\* The trace emits string session IDs; we map them to the Session constant.
TraceSessions ==
    { TraceLog[i].session : i \in 1..Len(TraceLog) }

\* Guard: session ID in trace must be in the spec's Session set.
SessionInSpec(sid) == sid \in Session

(*------------------------------------------------------------------
 * EVENT PREDICATES
 *------------------------------------------------------------------*)

IsEvent(name) ==
    l <= Len(TraceLog) /\ TraceLog[l].event = name

IsSessionEvent(name, s) ==
    IsEvent(name) /\ TraceLog[l].session = ToString(s)

(*------------------------------------------------------------------
 * POST-STATE VALIDATION
 * For each action wrapper, validate that spec state matches trace state
 * for the key fields the action modifies.
 *------------------------------------------------------------------*)

\* Validate after CheckoutSession(s): checkoutOpCtx should be "normal"
ValidateCheckoutSession(s) ==
    /\ checkoutOpCtx[s] = "normal"
    /\ sessionInCatalog[s] = TRUE

\* Validate after CheckinSession(s): checkoutOpCtx should be "none"
ValidateCheckinSession(s) ==
    /\ checkoutOpCtx[s] = "none"

\* Validate after RequestKill(s): killsRequested incremented
ValidateRequestKill(s) ==
    /\ killsRequested[s] > 0
    /\ killTokenRegistered[s] = FALSE

\* Validate after RegisterKillChangeSucceed(s): token registered
ValidateRegisterKillChangeSucceed(s) ==
    /\ killTokenRegistered[s] = TRUE

\* Validate after KillReleaseClearCheckout(s): checkoutOpCtx cleared
ValidateKillReleaseClearCheckout(s) ==
    /\ checkoutOpCtx[s] = "none"
    /\ killReleasePhase[s] = "cleared"

\* Validate after KillReleaseNotify(s): phase advanced
ValidateKillReleaseNotify(s) ==
    /\ killReleasePhase[s] = "notified"

\* Validate after KillReleaseDecrement(s): kills decremented, token cleared
ValidateKillReleaseDecrement(s) ==
    /\ killReleasePhase[s] = "none"
    /\ (killsRequested[s] = 0 \/ killTokenRegistered[s] = FALSE)

\* Validate after RefreshSucceed(s): sessionLastRefreshed updated
ValidateRefreshSucceed(s) ==
    /\ sessionLastRefreshed[s] = TraceLog[l].state.lastRefreshed

\* Validate after MemoryReap(s): session removed from catalog
ValidateMemoryReap(s) ==
    /\ sessionInCatalog[s] = FALSE

\* Validate after DiskReapImage(s): image record deleted
ValidateDiskReapImage(s) ==
    /\ imageRecordOnDisk[s] = FALSE

\* Validate after DiskReapTxn(s): txn record deleted
ValidateDiskReapTxn(s) ==
    /\ txnRecordOnDisk[s] = FALSE

(*------------------------------------------------------------------
 * ACTION WRAPPERS
 * Each wrapper: match event → call base action → validate post-state → advance l
 *------------------------------------------------------------------*)

TraceWaitForCheckout(s) ==
    /\ IsSessionEvent("wait_for_checkout", s)
    /\ WaitForCheckout(s)
    /\ l' = l + 1

TraceCheckoutSession(s) ==
    /\ IsSessionEvent("checkout_session", s)
    /\ CheckoutSession(s)
    /\ ValidateCheckoutSession(s)'
    /\ l' = l + 1

TraceCheckinSession(s) ==
    /\ IsSessionEvent("checkin_session", s)
    /\ CheckinSession(s)
    /\ ValidateCheckinSession(s)'
    /\ l' = l + 1

TraceRequestKill(s) ==
    /\ IsSessionEvent("request_kill", s)
    /\ RequestKill(s)
    /\ ValidateRequestKill(s)'
    /\ l' = l + 1

TraceRegisterKillChangeSucceed(s) ==
    /\ IsSessionEvent("register_kill_change_succeed", s)
    /\ RegisterKillChangeSucceed(s)
    /\ ValidateRegisterKillChangeSucceed(s)'
    /\ l' = l + 1

TraceKillReleaseClearCheckout(s) ==
    /\ IsSessionEvent("kill_release_clear_checkout", s)
    /\ KillReleaseClearCheckout(s)
    /\ ValidateKillReleaseClearCheckout(s)'
    /\ l' = l + 1

TraceKillReleaseNotify(s) ==
    /\ IsSessionEvent("kill_release_notify", s)
    /\ KillReleaseNotify(s)
    /\ ValidateKillReleaseNotify(s)'
    /\ l' = l + 1

TraceKillReleaseDecrement(s) ==
    /\ IsSessionEvent("kill_release_decrement", s)
    /\ KillReleaseDecrement(s)
    /\ ValidateKillReleaseDecrement(s)'
    /\ l' = l + 1

TraceStartRefresh ==
    /\ IsEvent("start_refresh")
    /\ StartRefresh
    /\ l' = l + 1

TraceRefreshSucceed(s) ==
    /\ IsSessionEvent("refresh_succeed", s)
    /\ RefreshSucceed(s)
    /\ sessionLastRefreshed[s]' = TraceLog[l].state.lastRefreshed
    /\ l' = l + 1

TraceRefreshFail(s) ==
    /\ IsSessionEvent("refresh_fail", s)
    /\ RefreshFail(s)
    /\ l' = l + 1

TraceEndRefresh ==
    /\ IsEvent("end_refresh")
    /\ EndRefresh
    /\ l' = l + 1

TraceStartReap ==
    /\ IsEvent("start_reap")
    /\ StartReap
    /\ l' = l + 1

TraceMemoryReap(s) ==
    /\ IsSessionEvent("memory_reap", s)
    /\ MemoryReap(s)
    /\ ValidateMemoryReap(s)'
    /\ l' = l + 1

TraceDiskReapImage(s) ==
    /\ IsSessionEvent("disk_reap_image", s)
    /\ DiskReapImage(s)
    /\ ValidateDiskReapImage(s)'
    /\ l' = l + 1

TraceDiskReapTxn(s) ==
    /\ IsSessionEvent("disk_reap_txn", s)
    /\ DiskReapTxn(s)
    /\ ValidateDiskReapTxn(s)'
    /\ l' = l + 1

TraceEndReap ==
    /\ IsEvent("end_reap")
    /\ EndReap
    /\ l' = l + 1

(*------------------------------------------------------------------
 * SILENT ACTIONS
 * Handle spec state changes with no corresponding trace event.
 * All are tightly constrained to prevent state space explosion.
 *------------------------------------------------------------------*)

\* RevivifySession fires silently between MemoryReap and DiskReapTxn.
\* Only enabled when the next event is a checkout for a reaped session.
SilentRevivify(s) ==
    /\ l <= Len(TraceLog)
    /\ sessionInCatalog[s] = FALSE
    \* Constrain to fire only when the next trace event is a checkout for this session.
    /\ \/ (IsSessionEvent("checkout_session", s))
       \/ (IsSessionEvent("checkin_session", s))
    /\ RevivifySession(s)
    /\ UNCHANGED l

\* CheckoutForKill fires silently when the normal checkin already cleared checkoutOpCtx
\* but the trace next records kill_release_clear_checkout (no explicit checkout_for_kill event).
\* In this scenario _releaseSession with a kill token calls _checkOutSessionInner internally;
\* the harness does not emit a checkout_for_kill trace event for that internal step.
SilentCheckoutForKill(s) ==
    /\ l <= Len(TraceLog)
    /\ killTokenRegistered[s] = TRUE
    /\ killsRequested[s] > 0
    /\ checkoutOpCtx[s] = "none"
    \* Only fire when the very next event is the kill release for this session.
    /\ IsSessionEvent("kill_release_clear_checkout", s)
    /\ CheckoutForKill(s)
    /\ UNCHANGED l

\* TickClock fires silently when time must advance to match upcoming trace events.
\* Tightly constrained: only tick if currentTime+1 does not exceed the lastRefreshed
\* value expected by any future refresh_succeed event, or the reapCutoff expected by
\* any future start_reap event. This prevents the clock from racing ahead and making
\* those trace actions impossible to satisfy.
SilentTickClock ==
    /\ l <= Len(TraceLog)
    /\ currentTime < MaxTime
    /\ \A i \in l..Len(TraceLog) :
           /\ (TraceLog[i].event = "refresh_succeed"
               => currentTime + 1 <= TraceLog[i].state.lastRefreshed)
           /\ (TraceLog[i].event = "start_reap"
               => currentTime + 1 <= TraceLog[i].state.reapCutoff)
    /\ TickClock
    /\ UNCHANGED l

(*------------------------------------------------------------------
 * TRACE INIT
 * Must match the implementation's actual initial state,
 * which may differ from the base spec's Init.
 *------------------------------------------------------------------*)

TraceInit ==
    /\ Init
    /\ l = 1

(*------------------------------------------------------------------
 * TRACE NEXT
 *------------------------------------------------------------------*)

TraceNext ==
    \/ \E s \in Session : TraceWaitForCheckout(s)
    \/ \E s \in Session : TraceCheckoutSession(s)
    \/ \E s \in Session : TraceCheckinSession(s)
    \/ \E s \in Session : TraceRequestKill(s)
    \/ \E s \in Session : TraceRegisterKillChangeSucceed(s)
    \/ \E s \in Session : TraceKillReleaseClearCheckout(s)
    \/ \E s \in Session : TraceKillReleaseNotify(s)
    \/ \E s \in Session : TraceKillReleaseDecrement(s)
    \/ TraceStartRefresh
    \/ \E s \in Session : TraceRefreshSucceed(s)
    \/ \E s \in Session : TraceRefreshFail(s)
    \/ TraceEndRefresh
    \/ TraceStartReap
    \/ \E s \in Session : TraceMemoryReap(s)
    \/ \E s \in Session : TraceDiskReapImage(s)
    \/ \E s \in Session : TraceDiskReapTxn(s)
    \/ TraceEndReap
    \* Silent actions (tightly constrained)
    \/ \E s \in Session : SilentRevivify(s)
    \/ \E s \in Session : SilentCheckoutForKill(s)
    \/ SilentTickClock
    \* Stuttering when trace is fully consumed
    \/ (l > Len(TraceLog) /\ UNCHANGED <<vars, l>>)

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>> /\ WF_<<vars, l>>(TraceNext)

(*------------------------------------------------------------------
 * TRACE COMPLETION
 *------------------------------------------------------------------*)

\* The entire trace must be consumed. Without this, TLC reports "no errors"
\* even when l never advances.
TraceMatched == <>(l > Len(TraceLog))

(*==================================================================
 * INVARIANTS FOR TRACE VALIDATION
 * Include: safety invariants + structural invariants.
 * Exclude: fault-injection invariants (only meaningful with fault injection active).
 *==================================================================*)

TraceTypeOK == TypeOK

TraceStructuralInvariants ==
    /\ AtMostOneCheckout
    /\ CheckoutImpliesInCatalog
    /\ KillCheckoutRequiresToken
    /\ DiskReapDoneConsistency

=============================================================================
