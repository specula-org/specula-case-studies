--------------------------------- MODULE MC ---------------------------------
(*
 * Model checking wrapper for MongoDBSession.
 *
 * Adds counter-bounded fault injection for:
 *   - RegisterKillChangeFail (Family 2: registerChange throws, orphan kill counter)
 *   - RefreshFail per session (Family 3: partial refresh failure)
 *   - RevivifySession (Family 4: re-vivification between reap phases)
 *
 * Normal, deterministic/reactive actions (CheckoutSession, CheckinSession,
 * KillReleaseClearCheckout, KillReleaseNotify, KillReleaseDecrement,
 * StartRefresh, RefreshSucceed, EndRefresh, StartReap, MemoryReap,
 * DiskReapImage, DiskReapTxn, EndReap, TickClock) are NOT bounded —
 * they react to existing state and must remain live for bug reachability.
 *)

EXTENDS MongoDBSession

(*------------------------------------------------------------------
 * FAULT COUNTER VARIABLES
 *------------------------------------------------------------------*)

\* One counter per fault-injection action.
\* Stored as a record to exclude from the TLC view (symmetry / state space).
VARIABLE faultVars

MCFaultVarsInit ==
    faultVars = [
        killChangeFail  |-> 0,   \* RegisterKillChangeFail firings
        refreshFail     |-> 0,   \* RefreshFail firings (summed across sessions)
        revivify        |-> 0    \* RevivifySession firings
    ]

(*------------------------------------------------------------------
 * COUNTER BOUNDS (injected via MC.cfg CONSTANTS)
 *------------------------------------------------------------------*)

CONSTANTS
    MaxKillChangeFailLimit,  \* max RegisterKillChangeFail firings per run
    MaxRefreshFailLimit,     \* max RefreshFail firings per run (total)
    MaxRevivifyLimit         \* max RevivifySession firings per run

(*------------------------------------------------------------------
 * BOUNDED FAULT WRAPPERS
 *------------------------------------------------------------------*)

\* Bounded: RegisterKillChangeFail — registerChange throws, leaving orphan kill counter.
\* Fault mechanism: crash window between session.kill() (synchronous) and
\* registerChange (session_catalog_mongod.cpp:683-686).
MCRegisterKillChangeFail(s) ==
    /\ faultVars.killChangeFail < MaxKillChangeFailLimit
    /\ RegisterKillChangeFail(s)
    /\ faultVars' = [faultVars EXCEPT !.killChangeFail = @ + 1]

\* Bounded: RefreshFail — session fails to refresh.
\* Fault mechanism: write error in refreshSessions not reflected back for runningOp sessions
\* (logical_session_cache_impl.cpp:373-398).
MCRefreshFail(s) ==
    /\ faultVars.refreshFail < MaxRefreshFailLimit
    /\ RefreshFail(s)
    /\ faultVars' = [faultVars EXCEPT !.refreshFail = @ + 1]

\* Bounded: RevivifySession — new checkout between memory and disk reap phases.
\* Fault mechanism: the gap between MemoryReap and DiskReapTxn allows a new operation
\* to re-create the session in the catalog with no txn record (session_catalog.cpp:118).
MCRevivifySession(s) ==
    /\ faultVars.revivify < MaxRevivifyLimit
    /\ RevivifySession(s)
    /\ faultVars' = [faultVars EXCEPT !.revivify = @ + 1]

(*------------------------------------------------------------------
 * PASS-THROUGH WRAPPERS (unbounded, reactive)
 *------------------------------------------------------------------*)

\* All deterministic/reactive actions pass through unchanged, with UNCHANGED faultVars.

MCWaitForCheckout(s)           == WaitForCheckout(s)           /\ UNCHANGED faultVars
MCCheckoutSession(s)           == CheckoutSession(s)           /\ UNCHANGED faultVars
MCCheckinSession(s)            == CheckinSession(s)            /\ UNCHANGED faultVars
MCRequestKill(s)               == RequestKill(s)               /\ UNCHANGED faultVars
MCRegisterKillChangeSucceed(s) == RegisterKillChangeSucceed(s) /\ UNCHANGED faultVars
MCCheckoutForKill(s)           == CheckoutForKill(s)           /\ UNCHANGED faultVars
MCKillReleaseClearCheckout(s)  == KillReleaseClearCheckout(s)  /\ UNCHANGED faultVars
MCKillReleaseNotify(s)         == KillReleaseNotify(s)         /\ UNCHANGED faultVars
MCKillReleaseDecrement(s)      == KillReleaseDecrement(s)      /\ UNCHANGED faultVars
MCStartRefresh                 == StartRefresh                  /\ UNCHANGED faultVars
MCRefreshSucceed(s)            == RefreshSucceed(s)            /\ UNCHANGED faultVars
MCEndRefresh                   == EndRefresh                    /\ UNCHANGED faultVars
MCStartReap                    == StartReap                     /\ UNCHANGED faultVars
MCMemoryReap(s)                == MemoryReap(s)                /\ UNCHANGED faultVars
MCDiskReapImage(s)             == DiskReapImage(s)             /\ UNCHANGED faultVars
MCDiskReapTxn(s)               == DiskReapTxn(s)              /\ UNCHANGED faultVars
MCEndReap                      == EndReap                      /\ UNCHANGED faultVars
MCTickClock                    == TickClock                    /\ UNCHANGED faultVars

(*------------------------------------------------------------------
 * MC INIT / NEXT
 *------------------------------------------------------------------*)

MCInit == Init /\ MCFaultVarsInit

MCNext ==
    \/ \E s \in Session : MCWaitForCheckout(s)
    \/ \E s \in Session : MCCheckoutSession(s)
    \/ \E s \in Session : MCCheckinSession(s)
    \/ \E s \in Session : MCRequestKill(s)
    \/ \E s \in Session : MCRegisterKillChangeSucceed(s)
    \/ \E s \in Session : MCRegisterKillChangeFail(s)
    \/ \E s \in Session : MCCheckoutForKill(s)
    \/ \E s \in Session : MCKillReleaseClearCheckout(s)
    \/ \E s \in Session : MCKillReleaseNotify(s)
    \/ \E s \in Session : MCKillReleaseDecrement(s)
    \/ MCStartRefresh
    \/ \E s \in Session : MCRefreshSucceed(s)
    \/ \E s \in Session : MCRefreshFail(s)
    \/ MCEndRefresh
    \/ MCStartReap
    \/ \E s \in Session : MCMemoryReap(s)
    \/ \E s \in Session : MCDiskReapImage(s)
    \/ \E s \in Session : MCDiskReapTxn(s)
    \/ \E s \in Session : MCRevivifySession(s)
    \/ MCEndReap
    \/ MCTickClock

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

(*------------------------------------------------------------------
 * SYMMETRY / VIEW
 *------------------------------------------------------------------*)

\* Symmetry reduction over the session set.
MCSymmetry == Permutations(Session)

\* Exclude fault counters from the TLC state view to reduce state space.
MCView == vars

(*------------------------------------------------------------------
 * STATE SPACE PRUNING
 *------------------------------------------------------------------*)

\* Bound the number of simultaneous waiters to prevent unbounded state space.
MCWaitersConstraint ==
    \A s \in Session : waiters[s] <= 2

=============================================================================
