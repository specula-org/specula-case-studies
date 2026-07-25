---- MODULE Trace ----
(*
 * Trace validation spec for MongoDB Session Lifecycle.
 *
 * Category A: Single-file linear trace (distributed system pattern).
 * Replays NDJSON traces against the base spec to verify consistency.
 *)

EXTENDS base, Json, Sequences, IOUtils, TLC

\* --- Trace Loading ---

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only session lifecycle events
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : "event" \in DOMAIN e)

\* --- Cursor ---

VARIABLE l  \* Cursor into TraceLog

traceVars == <<vars, l>>

\* --- Helpers ---

logline == TraceLog[l]

IsEvent(name) == logline.event = name

\* Map trace session IDs to spec Session constants
TraceSession == logline.session

\* Map trace thread IDs to spec Thread constants
TraceThread == logline.thread

\* --- Post-State Validation ---

\* Strong validation: verify session state AFTER the action (uses primed variables)
ValidatePostState(s) ==
    /\ IF "txnState" \in DOMAIN logline
       THEN txnState'[s] = logline.txnState
       ELSE TRUE
    /\ IF "sessionExists" \in DOMAIN logline
       THEN sessionExists'[s] = logline.sessionExists
       ELSE TRUE
    /\ IF "checkedOut" \in DOMAIN logline
       THEN (checkoutThread'[s] /= NilThread) = logline.checkedOut
       ELSE TRUE

\* Weak validation: only verify what's guaranteed by the trace (primed)
ValidatePostStateWeak(s) ==
    IF "txnState" \in DOMAIN logline
    THEN txnState'[s] = logline.txnState
    ELSE TRUE

\* --- Action Wrappers ---

\* Each wrapper: match event -> call base action -> validate -> advance cursor

TraceCheckOutSession ==
    /\ IsEvent("CheckOutSession")
    /\ LET s == TraceSession
           t == TraceThread
       IN
       /\ CheckOutSession(t, s)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TraceCheckInSession ==
    /\ IsEvent("CheckInSession")
    /\ LET t == TraceThread IN
       /\ CheckInSession(t)
    /\ l' = l + 1

TraceBeginTransaction ==
    /\ IsEvent("BeginTransaction")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ BeginTransaction(t)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TracePrepareTransaction ==
    /\ IsEvent("PrepareTransaction")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ PrepareTransaction(t)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TraceCommitPreparedTransaction ==
    /\ IsEvent("CommitPreparedTransaction")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ CommitPreparedTransaction(t)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TraceAbortTransaction ==
    /\ IsEvent("AbortTransaction")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ AbortTransaction(t)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

TraceAbortPreparedTransaction ==
    /\ IsEvent("AbortPreparedTransaction")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ AbortPreparedTransaction(t)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TraceResetTransactionState ==
    /\ IsEvent("ResetTransactionState")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ ResetTransactionState(t)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TraceKillSessionMark ==
    /\ IsEvent("KillSessionMark")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ KillSessionMark(t, s)
    /\ l' = l + 1

TraceKillSessionCheckout ==
    /\ IsEvent("KillSessionCheckout")
    /\ LET t == TraceThread IN
       /\ KillSessionCheckout(t)
    /\ l' = l + 1

TraceKillSessionFinish ==
    /\ IsEvent("KillSessionFinish")
    /\ LET t == TraceThread
           s == TraceSession
       IN
       /\ KillSessionFinish(t)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

TraceReaperScanMemory ==
    /\ IsEvent("ReaperScanMemory")
    /\ LET t == TraceThread IN
       /\ ReaperScanMemory(t)
    /\ l' = l + 1

TraceReaperDeleteImages ==
    /\ IsEvent("ReaperDeleteImages")
    /\ LET t == TraceThread IN
       /\ ReaperDeleteImages(t)
    /\ l' = l + 1

TraceReaperDeleteTxnRecords ==
    /\ IsEvent("ReaperDeleteTxnRecords")
    /\ LET t == TraceThread IN
       /\ ReaperDeleteTxnRecords(t)
    /\ l' = l + 1

TraceEagerReapMark ==
    /\ IsEvent("EagerReapMark")
    /\ LET s == TraceSession IN
       /\ EagerReapMark(s)
    /\ l' = l + 1

TraceEagerReapExecute ==
    /\ IsEvent("EagerReapExecute")
    /\ EagerReapExecute
    /\ l' = l + 1

TraceStepDownBegin ==
    /\ IsEvent("StepDownBegin")
    /\ LET t == TraceThread IN
       /\ StepDownBegin(t)
    /\ l' = l + 1

TraceStepDownKillSessions ==
    /\ IsEvent("StepDownKillSessions")
    /\ LET t == TraceThread IN
       /\ StepDownKillSessions(t)
    /\ l' = l + 1

TraceStepDownComplete ==
    /\ IsEvent("StepDownComplete")
    /\ LET t == TraceThread IN
       /\ StepDownComplete(t)
    /\ l' = l + 1

TraceStepUp ==
    /\ IsEvent("StepUp")
    /\ StepUp
    /\ l' = l + 1

TraceEndSession ==
    /\ IsEvent("EndSession")
    /\ LET s == TraceSession IN
       /\ EndSession(s)
    /\ l' = l + 1

\* --- Silent Actions ---
\* Handle base spec state changes that don't have corresponding trace events.
\* Each silent action is tightly constrained to prevent state space explosion.

\* Silent: ReaperComplete (internal state transition, no trace event)
SilentReaperComplete ==
    /\ l <= Len(TraceLog)
    /\ reaperPhase = "done"
    /\ ReaperComplete
    /\ UNCHANGED l

\* Silent: EagerReapComplete (async completion, no trace event)
SilentEagerReapComplete ==
    /\ l <= Len(TraceLog)
    /\ eagerReapActive
    /\ EagerReapComplete
    /\ UNCHANGED l

\* Silent: ResetTransactionState (may not have dedicated trace event)
\* Look-ahead guard: only fire when the next trace event is NOT ResetTransactionState,
\* to avoid racing with the explicit trace action.
SilentResetTransactionState ==
    /\ l <= Len(TraceLog)
    /\ ~IsEvent("ResetTransactionState")
    /\ \E t \in Thread :
       /\ threadState[t] = "holdingSession"
       /\ LET s == threadSession[t] IN
          /\ txnState[s] \in {"committed", "aborted"}
          /\ ResetTransactionState(t)
    /\ UNCHANGED l

\* --- TraceInit ---
\* Initialize from trace's first event or defaults.

TraceInit ==
    /\ Init
    /\ l = 1

\* --- TraceNext ---

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceCheckOutSession
          \/ TraceCheckInSession
          \/ TraceBeginTransaction
          \/ TracePrepareTransaction
          \/ TraceCommitPreparedTransaction
          \/ TraceAbortTransaction
          \/ TraceAbortPreparedTransaction
          \/ TraceResetTransactionState
          \/ TraceKillSessionMark
          \/ TraceKillSessionCheckout
          \/ TraceKillSessionFinish
          \/ TraceReaperScanMemory
          \/ TraceReaperDeleteImages
          \/ TraceReaperDeleteTxnRecords
          \/ TraceEagerReapMark
          \/ TraceEagerReapExecute
          \/ TraceStepDownBegin
          \/ TraceStepDownKillSessions
          \/ TraceStepDownComplete
          \/ TraceStepUp
          \/ TraceEndSession
    \* Silent actions (don't consume trace events)
    \/ SilentReaperComplete
    \/ SilentEagerReapComplete
    \/ SilentResetTransactionState
    \* Stuttering after trace consumed
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

\* --- Trace Completion ---
\* Temporal property: entire trace was consumed.
TraceMatched == <>(l > Len(TraceLog))

====
