------------------------------ MODULE Trace ------------------------------
(***************************************************************************)
(* Trace-validation spec for the Nanvix PM base spec.                      *)
(*                                                                         *)
(* Nanvix PM is single-core with interrupts disabled, so kernel events are *)
(* TOTALLY ORDERED.  We therefore use a single linear cursor `l` (the      *)
(* Category-A pattern) rather than the per-thread timebox pattern: the     *)
(* recorded trace is one NDJSON file whose events are replayed in order,   *)
(* each driving exactly one base-spec action and validating the resulting  *)
(* post-state.                                                             *)
(*                                                                         *)
(* Instrumentation (see instrumentation-spec.md) captures, at every event, *)
(* the post-action CORE lifecycle state (procState, threadState, running)  *)
(* plus the sub-state field(s) the action modifies and any bug-ghost it    *)
(* can set.  ValidatePostState checks those fields against the base spec's *)
(* primed state, so a divergence between spec and implementation surfaces  *)
(* as a trace-validation failure.                                          *)
(*                                                                         *)
(* CONSTANTS are STRINGS here (e.g. "p1","t1") so they match the JSON      *)
(* object keys the harness emits; NoProc/NoThread/NoCond/NoMask are the    *)
(* corresponding sentinel strings.                                         *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, TLC, Sequences, Integers

\* ========================================================================
\* Trace loading
\* ========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

VARIABLE l
traceVars == <<l>>

logline == TraceLog[l]

IsEvent(name) == l <= Len(TraceLog) /\ logline.event = name

\* A field may be omitted from an event when it is not relevant; Has() guards it.
Has(rec, field) == field \in DOMAIN rec

\* ndJsonDeserialize maps a JSON array to a TLA+ sequence.  Set-valued spec fields
\* (pending/blocked/held, and the SUBSET-Signal value of savedBlocked) are emitted as
\* JSON arrays, so convert the sequence back to a set before comparing.
AsSet(s) == { s[i] : i \in DOMAIN s }

\* ========================================================================
\* Post-state validation helpers
\* ========================================================================

\* Core lifecycle state -- captured at every event, validated strongly.
ValidateCore ==
    /\ procState'   = logline.state.procState
    /\ threadState' = logline.state.threadState
    /\ running'     = logline.state.running

\* Optional field validators: only checked when the harness emitted the field,
\* so no check is vacuously true against a field the harness never captures.
ChkThreadReason == Has(logline.state, "threadReason") => threadReason' = logline.state.threadReason
ChkPending      == Has(logline.state, "pending")  => pending' = [p \in Proc |-> AsSet(logline.state.pending[p])]
ChkBlocked      == Has(logline.state, "blocked")  => blocked' = [t \in Thread |-> AsSet(logline.state.blocked[t])]
ChkDisposition  == Has(logline.state, "disposition")  => disposition'  = logline.state.disposition
ChkSavedBlocked == Has(logline.state, "savedBlocked") =>
                     savedBlocked' = [t \in Thread |->
                       IF logline.state.savedBlocked[t] = NoMask
                       THEN NoMask ELSE AsSet(logline.state.savedBlocked[t])]
ChkMutexInMap   == Has(logline.state, "mutexInMap")   => mutexInMap'   = logline.state.mutexInMap
ChkMutexLocked  == Has(logline.state, "mutexLocked")  => mutexLocked'  = logline.state.mutexLocked
ChkMutexOwner   == Has(logline.state, "mutexOwner")   => mutexOwner'   = logline.state.mutexOwner
ChkHeld         == Has(logline.state, "held")     => held' = [t \in Thread |-> AsSet(logline.state.held[t])]
ChkCondWaiters  == Has(logline.state, "condWaiters")  => condWaiters'  = logline.state.condWaiters
ChkExitPhase    == Has(logline.state, "exitPhase")    => exitPhase'    = logline.state.exitPhase

\* Bug-ghost validators: a real execution should never set a bug ghost, so the
\* harness always emits FALSE for these; if the spec sets one during replay, the
\* spec and implementation disagree (a genuine bug the trace did NOT exercise).
ChkGhosts ==
    /\ Has(logline.state, "panicked")             => panicked'             = logline.state.panicked
    /\ Has(logline.state, "lostNotify")           => lostNotify'           = logline.state.lostNotify
    /\ Has(logline.state, "signalDeliveryFailed") => signalDeliveryFailed' = logline.state.signalDeliveryFailed
    /\ Has(logline.state, "resumedAfterTerminate")=> resumedAfterTerminate'= logline.state.resumedAfterTerminate
    /\ Has(logline.state, "condWaitBad")          => condWaitBad'          = logline.state.condWaitBad
    /\ Has(logline.state, "maskViolated")         => maskViolated'         = logline.state.maskViolated
    /\ Has(logline.state, "immortalPending")      => immortalPending'      = logline.state.immortalPending
    /\ Has(logline.state, "savedMaskViolated")    => savedMaskViolated'    = logline.state.savedMaskViolated
    /\ Has(logline.state, "restartMisattributed") => restartMisattributed' = logline.state.restartMisattributed
    /\ Has(logline.state, "spuriousOOM")          => spuriousOOM'          = logline.state.spuriousOOM

\* ========================================================================
\* Action wrappers (event -> base action -> validate -> advance cursor)
\* ========================================================================

TSchedule ==
    /\ IsEvent("Schedule")
    /\ Schedule
    /\ ValidateCore
    /\ l' = l + 1

TPreempt ==
    /\ IsEvent("Preempt")
    /\ Preempt
    /\ ValidateCore
    /\ l' = l + 1

TCreateProcess ==
    /\ IsEvent("CreateProcess")
    /\ CreateProcess
    /\ ValidateCore /\ ChkPending
    /\ l' = l + 1

TCreateThread ==
    /\ IsEvent("CreateThread")
    /\ CreateThread
    /\ ValidateCore /\ ChkBlocked
    /\ l' = l + 1

TCreateProcessSpuriousOOM ==
    /\ IsEvent("CreateProcessSpuriousOOM")
    /\ CreateProcessSpuriousOOM
    /\ ValidateCore /\ ChkGhosts
    /\ l' = l + 1

THarvestZombieProc ==
    /\ IsEvent("HarvestZombieProc")
    /\ HarvestZombieProc
    /\ ValidateCore /\ ChkMutexLocked /\ ChkMutexOwner /\ ChkHeld
    /\ l' = l + 1

TSleep ==
    /\ IsEvent("Sleep")
    /\ Sleep(logline.cond)
    /\ ValidateCore /\ ChkCondWaiters
    /\ l' = l + 1

TAlarmFire ==
    /\ IsEvent("AlarmFire")
    /\ AlarmFire
    /\ ValidateCore /\ ChkThreadReason /\ ChkCondWaiters
    /\ l' = l + 1

TNotifyDequeue ==
    /\ IsEvent("NotifyDequeue")
    /\ NotifyDequeue(logline.cond)
    /\ ChkCondWaiters
    /\ l' = l + 1

TWakeDequeued ==
    /\ IsEvent("WakeDequeued")
    /\ WakeDequeued
    /\ ValidateCore /\ ChkThreadReason /\ ChkGhosts
    /\ l' = l + 1

TRunnableTerminate ==
    /\ IsEvent("RunnableTerminate")
    /\ RunnableTerminate
    /\ ValidateCore /\ ChkThreadReason
    /\ l' = l + 1

TSuspendedTerminate ==
    /\ IsEvent("SuspendedTerminate")
    /\ SuspendedTerminate
    /\ ValidateCore /\ ChkThreadReason
    /\ l' = l + 1

TInterruptedTerminate ==
    /\ IsEvent("InterruptedTerminate")
    /\ InterruptedTerminate
    /\ ValidateCore /\ ChkThreadReason
    /\ l' = l + 1

TResumeInterrupted ==
    /\ IsEvent("ResumeInterrupted")
    /\ ResumeInterrupted
    /\ ValidateCore /\ ChkThreadReason
    /\ l' = l + 1

TDispatcherCheckpoint ==
    /\ IsEvent("DispatcherCheckpoint")
    /\ DispatcherCheckpoint
    /\ ValidateCore /\ ChkThreadReason /\ ChkGhosts
    /\ l' = l + 1

TRegisterRendezvous ==
    /\ IsEvent("RegisterRendezvous")
    /\ RegisterRendezvous
    /\ ValidateCore
    /\ l' = l + 1

TExitTakeRunning ==
    /\ IsEvent("ExitTakeRunning")
    /\ ExitTakeRunning
    /\ ValidateCore /\ ChkExitPhase
    /\ l' = l + 1

TExitCleanupRendezvous ==
    /\ IsEvent("ExitCleanupRendezvous")
    /\ ExitCleanupRendezvous
    /\ ChkExitPhase /\ ChkGhosts
    /\ l' = l + 1

TExitReinsert ==
    /\ IsEvent("ExitReinsert")
    /\ ExitReinsert
    /\ ValidateCore /\ ChkThreadReason /\ ChkExitPhase
    /\ l' = l + 1

TLockMutexAcquire ==
    /\ IsEvent("LockMutexAcquire")
    /\ LockMutexAcquire(logline.mutex)
    /\ ChkMutexInMap /\ ChkMutexLocked /\ ChkMutexOwner /\ ChkHeld
    /\ l' = l + 1

TLockMutexCancel ==
    /\ IsEvent("LockMutexCancel")
    /\ LockMutexCancel(logline.mutex)
    /\ ChkMutexInMap
    /\ l' = l + 1

TUnlockMutex ==
    /\ IsEvent("UnlockMutex")
    /\ UnlockMutex(logline.mutex)
    /\ ChkMutexInMap /\ ChkMutexLocked /\ ChkMutexOwner /\ ChkHeld
    /\ l' = l + 1

TCondWaitUnlock ==
    /\ IsEvent("CondWaitUnlock")
    /\ CondWaitUnlock(logline.cond, logline.mutex)
    /\ ChkMutexLocked /\ ChkMutexOwner /\ ChkHeld
    /\ l' = l + 1

TCondWaitSleep ==
    /\ IsEvent("CondWaitSleep")
    /\ CondWaitSleep
    /\ ValidateCore /\ ChkCondWaiters
    /\ l' = l + 1

TCondWaitRelock ==
    /\ IsEvent("CondWaitRelock")
    /\ CondWaitRelock
    /\ ChkMutexLocked /\ ChkMutexOwner /\ ChkHeld
    /\ l' = l + 1

TCondWaitRelockInterrupted ==
    /\ IsEvent("CondWaitRelockInterrupted")
    /\ CondWaitRelockInterrupted
    /\ ChkMutexLocked /\ ChkHeld /\ ChkGhosts
    /\ l' = l + 1

TPostSignalHandler ==
    /\ IsEvent("PostSignalHandler")
    /\ PostSignalHandler(logline.pid, logline.sig)
    /\ ValidateCore /\ ChkPending /\ ChkThreadReason /\ ChkGhosts
    /\ l' = l + 1

TPostSignalDefaultTerminate ==
    /\ IsEvent("PostSignalDefaultTerminate")
    /\ PostSignalDefaultTerminate(logline.pid, logline.sig)
    /\ ValidateCore /\ ChkThreadReason /\ ChkGhosts
    /\ l' = l + 1

TSetDisposition ==
    /\ IsEvent("SetDisposition")
    /\ SetDisposition(logline.pid, logline.sig, logline.disp)
    /\ ChkDisposition /\ ChkGhosts
    /\ l' = l + 1

TInstallHandler ==
    /\ IsEvent("InstallHandler")
    /\ InstallHandler(logline.pid, logline.sig, logline.sar)
    /\ ChkDisposition
    /\ l' = l + 1

TDeliverSignal ==
    /\ IsEvent("DeliverSignal")
    /\ DeliverSignal
    /\ ChkPending /\ ChkBlocked /\ ChkGhosts
    /\ l' = l + 1

TMaskChange ==
    /\ IsEvent("MaskChange")
    /\ MaskChange(logline.mask)
    /\ ChkBlocked
    /\ l' = l + 1

TExec ==
    /\ IsEvent("Exec")
    /\ Exec
    /\ ChkPending /\ ChkDisposition
    /\ l' = l + 1

TSigSuspendInstall ==
    /\ IsEvent("SigSuspendInstall")
    /\ SigSuspendInstall(logline.mask)
    /\ ChkBlocked /\ ChkSavedBlocked /\ ChkGhosts
    /\ l' = l + 1

TSigReturn ==
    /\ IsEvent("SigReturn")
    /\ SigReturn
    /\ ChkBlocked /\ ChkSavedBlocked
    /\ l' = l + 1

TMarkInterruptedBySignal ==
    /\ IsEvent("MarkInterruptedBySignal")
    /\ MarkInterruptedBySignal(logline.sig)
    /\ l' = l + 1

\* ========================================================================
\* Trace Init / Next
\* ========================================================================

\* Bootstrap: the implementation boots with a single running process owning one
\* running thread.  Pin TraceInit to ONE deterministic initial state (the base spec's
\* Init is nondeterministic over which slot boots) so replay has a unique start and no
\* dead-end initial state can spuriously violate TraceMatched.
bootProc   == CHOOSE p \in Proc : TRUE
bootThread == CHOOSE t \in Thread : TRUE

TraceInit ==
    /\ Init
    /\ running = bootProc
    /\ threadState[bootThread] = "running"
    /\ l = 1

\* Stuttering step once the whole trace is consumed.  Without it the trace-consumed
\* terminal state has no successor, so a validator that runs TLC with default deadlock
\* detection (e.g. the MCP run_trace_validation tool, which does not pass -deadlock)
\* reports that benign terminal state as a "Deadlock reached" error.  TraceDone gives the
\* accepting state a self-loop; a genuine spec/impl divergence still stalls the cursor at
\* l <= Len(TraceLog) where TraceDone is NOT enabled, so it deadlocks and is flagged.
TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<vars, traceVars>>

TraceNext ==
    \/ TraceDone
    \/ TSchedule
    \/ TPreempt
    \/ TCreateProcess
    \/ TCreateThread
    \/ TCreateProcessSpuriousOOM
    \/ THarvestZombieProc
    \/ TSleep
    \/ TAlarmFire
    \/ TNotifyDequeue
    \/ TWakeDequeued
    \/ TRunnableTerminate
    \/ TSuspendedTerminate
    \/ TInterruptedTerminate
    \/ TResumeInterrupted
    \/ TDispatcherCheckpoint
    \/ TRegisterRendezvous
    \/ TExitTakeRunning
    \/ TExitCleanupRendezvous
    \/ TExitReinsert
    \/ TLockMutexAcquire
    \/ TLockMutexCancel
    \/ TUnlockMutex
    \/ TCondWaitUnlock
    \/ TCondWaitSleep
    \/ TCondWaitRelock
    \/ TCondWaitRelockInterrupted
    \/ TPostSignalHandler
    \/ TPostSignalDefaultTerminate
    \/ TSetDisposition
    \/ TInstallHandler
    \/ TDeliverSignal
    \/ TMaskChange
    \/ TExec
    \/ TSigSuspendInstall
    \/ TSigReturn
    \/ TMarkInterruptedBySignal

TraceSpec ==
    TraceInit /\ [][TraceNext]_<<vars, traceVars>> /\ WF_<<vars, traceVars>>(TraceNext)

\* ========================================================================
\* Completion property
\* ========================================================================

\* TraceMatched must be checked (PROPERTIES TraceMatched in Trace.cfg): without it
\* TLC reports "no error" even when the cursor never advances past the trace.
TraceMatched == <>(l > Len(TraceLog))

=============================================================================
