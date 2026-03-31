---- MODULE MC ----
(*
 * Model Checking wrapper for MongoDB Session Lifecycle spec.
 *
 * Counter-bounds fault-injection actions and non-deterministic initiations.
 * Deterministic/reactive actions (message handlers, state resets) are unbounded.
 *)

EXTENDS base

INSTANCE base

\* --- Counter-bounded limits ---
CONSTANTS
    MaxBeginTxn,            \* Limit on BeginTransaction
    MaxPrepareTxn,          \* Limit on PrepareTransaction
    MaxStepDown,            \* Limit on StepDownBegin
    MaxKillSession,         \* Limit on KillSessionMark
    MaxReaperRun,           \* Limit on ReaperScanMemory
    MaxEagerReap,           \* Limit on EagerReapMark
    MaxEndSession,          \* Limit on EndSession
    MaxReaperBypass,        \* Limit on ReaperBypassPreparedCheck (fault injection)
    MaxReaperFail,          \* Limit on ReaperFailBetweenDeletes (fault injection)
    MaxEagerReapFail,       \* Limit on EagerReapFail (fault injection)
    MaxKillTimeout          \* Limit on KillSessionTimeout (fault injection)

\* --- Counter variables ---
VARIABLES
    beginTxnCount,
    prepareTxnCount,
    stepDownCount,
    killSessionCount,
    reaperRunCount,
    eagerReapCount,
    endSessionCount,
    reaperBypassCount,
    reaperFailCount,
    eagerReapFailCount,
    killTimeoutCount

faultVars == <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
               reaperRunCount, eagerReapCount, endSessionCount,
               reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

mcVars == <<vars, faultVars>>

\* --- Symmetry ---
ModelSymmetry == Permutations(Session) \cup Permutations(Thread)

\* --- MCInit ---
MCInit ==
    /\ Init
    /\ beginTxnCount = 0
    /\ prepareTxnCount = 0
    /\ stepDownCount = 0
    /\ killSessionCount = 0
    /\ reaperRunCount = 0
    /\ eagerReapCount = 0
    /\ endSessionCount = 0
    /\ reaperBypassCount = 0
    /\ reaperFailCount = 0
    /\ eagerReapFailCount = 0
    /\ killTimeoutCount = 0

\* --- Counter-bounded wrappers ---

MCCheckOutSession(t, s) ==
    /\ CheckOutSession(t, s)
    /\ UNCHANGED faultVars

MCCheckInSession(t) ==
    /\ CheckInSession(t)
    /\ UNCHANGED faultVars

MCBeginTransaction(t) ==
    /\ beginTxnCount < MaxBeginTxn
    /\ BeginTransaction(t)
    /\ beginTxnCount' = beginTxnCount + 1
    /\ UNCHANGED <<prepareTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

MCPrepareTransaction(t) ==
    /\ prepareTxnCount < MaxPrepareTxn
    /\ PrepareTransaction(t)
    /\ prepareTxnCount' = prepareTxnCount + 1
    /\ UNCHANGED <<beginTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

MCCommitPreparedTransaction(t) ==
    /\ CommitPreparedTransaction(t)
    /\ UNCHANGED faultVars

MCAbortTransaction(t) ==
    /\ AbortTransaction(t)
    /\ UNCHANGED faultVars

MCAbortPreparedTransaction(t) ==
    /\ AbortPreparedTransaction(t)
    /\ UNCHANGED faultVars

MCResetTransactionState(t) ==
    /\ ResetTransactionState(t)
    /\ UNCHANGED faultVars

MCKillSessionMark(t, s) ==
    /\ killSessionCount < MaxKillSession
    /\ KillSessionMark(t, s)
    /\ killSessionCount' = killSessionCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

MCKillSessionCheckout(t) ==
    /\ KillSessionCheckout(t)
    /\ UNCHANGED faultVars

MCKillSessionFinish(t) ==
    /\ KillSessionFinish(t)
    /\ UNCHANGED faultVars

MCKillSessionTimeout(t) ==
    /\ killTimeoutCount < MaxKillTimeout
    /\ KillSessionTimeout(t)
    /\ killTimeoutCount' = killTimeoutCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount>>

MCReaperScanMemory(t) ==
    /\ reaperRunCount < MaxReaperRun
    /\ ReaperScanMemory(t)
    /\ reaperRunCount' = reaperRunCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
                   eagerReapCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

MCReaperDeleteImages(t) ==
    /\ ReaperDeleteImages(t)
    /\ UNCHANGED faultVars

MCReaperDeleteTxnRecords(t) ==
    /\ ReaperDeleteTxnRecords(t)
    /\ UNCHANGED faultVars

MCReaperComplete ==
    /\ ReaperComplete
    /\ UNCHANGED faultVars

MCReaperFailBetweenDeletes(t) ==
    /\ reaperFailCount < MaxReaperFail
    /\ ReaperFailBetweenDeletes(t)
    /\ reaperFailCount' = reaperFailCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperBypassCount, eagerReapFailCount, killTimeoutCount>>

MCEagerReapMark(s) ==
    /\ eagerReapCount < MaxEagerReap
    /\ EagerReapMark(s)
    /\ eagerReapCount' = eagerReapCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

MCEagerReapExecute ==
    /\ EagerReapExecute
    /\ UNCHANGED faultVars

MCEagerReapComplete ==
    /\ EagerReapComplete
    /\ UNCHANGED faultVars

MCEagerReapFail ==
    /\ eagerReapFailCount < MaxEagerReapFail
    /\ EagerReapFail
    /\ eagerReapFailCount' = eagerReapFailCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, killTimeoutCount>>

MCStepDownBegin(t) ==
    /\ stepDownCount < MaxStepDown
    /\ StepDownBegin(t)
    /\ stepDownCount' = stepDownCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, killSessionCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

MCStepDownKillSessions(t) ==
    /\ StepDownKillSessions(t)
    /\ UNCHANGED faultVars

MCStepDownComplete(t) ==
    /\ StepDownComplete(t)
    /\ UNCHANGED faultVars

MCStepUp ==
    /\ StepUp
    /\ UNCHANGED faultVars

MCEndSession(s) ==
    /\ endSessionCount < MaxEndSession
    /\ EndSession(s)
    /\ endSessionCount' = endSessionCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, eagerReapCount,
                   reaperBypassCount, reaperFailCount, eagerReapFailCount, killTimeoutCount>>

MCReaperBypassPreparedCheck(t) ==
    /\ reaperBypassCount < MaxReaperBypass
    /\ ReaperBypassPreparedCheck(t)
    /\ reaperBypassCount' = reaperBypassCount + 1
    /\ UNCHANGED <<beginTxnCount, prepareTxnCount, stepDownCount, killSessionCount,
                   reaperRunCount, eagerReapCount, endSessionCount,
                   reaperFailCount, eagerReapFailCount, killTimeoutCount>>

\* --- MCNext ---
MCNext ==
    \* Session checkout/checkin (reactive — unbounded)
    \/ \E t \in Thread, s \in Session : MCCheckOutSession(t, s)
    \/ \E t \in Thread : MCCheckInSession(t)
    \* Transaction lifecycle (bounded initiation, reactive completion)
    \/ \E t \in Thread : MCBeginTransaction(t)
    \/ \E t \in Thread : MCPrepareTransaction(t)
    \/ \E t \in Thread : MCCommitPreparedTransaction(t)
    \/ \E t \in Thread : MCAbortTransaction(t)
    \/ \E t \in Thread : MCAbortPreparedTransaction(t)
    \/ \E t \in Thread : MCResetTransactionState(t)
    \* Kill sessions (bounded mark, reactive checkout/finish)
    \/ \E t \in Thread, s \in Session : MCKillSessionMark(t, s)
    \/ \E t \in Thread : MCKillSessionCheckout(t)
    \/ \E t \in Thread : MCKillSessionFinish(t)
    \/ \E t \in Thread : MCKillSessionTimeout(t)
    \* Reaper (bounded scan, reactive deletion)
    \/ \E t \in Thread : MCReaperScanMemory(t)
    \/ \E t \in Thread : MCReaperDeleteImages(t)
    \/ \E t \in Thread : MCReaperDeleteTxnRecords(t)
    \/ MCReaperComplete
    \* Eager reap
    \/ \E s \in Session : MCEagerReapMark(s)
    \/ MCEagerReapExecute
    \/ MCEagerReapComplete
    \* Step-down
    \/ \E t \in Thread : MCStepDownBegin(t)
    \/ \E t \in Thread : MCStepDownKillSessions(t)
    \/ \E t \in Thread : MCStepDownComplete(t)
    \/ MCStepUp
    \* End sessions
    \/ \E s \in Session : MCEndSession(s)
    \* Fault injection
    \/ \E t \in Thread : MCReaperBypassPreparedCheck(t)
    \/ \E t \in Thread : MCReaperFailBetweenDeletes(t)
    \/ MCEagerReapFail

MCSpec == MCInit /\ [][MCNext]_mcVars

\* --- State constraint (prune state space) ---
StateConstraint ==
    /\ \A s \in Session : killsRequested[s] <= 3
    /\ \A s \in Session : numWaiting[s] <= 3

\* --- View (exclude counters from state fingerprint) ---
MCView == vars

====
