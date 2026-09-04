-------------------------------- MODULE MC --------------------------------
(***************************************************************************)
(* Model-checking wrapper for the Nanvix PM base spec.                     *)
(*                                                                         *)
(* The base spec's action granularity (split at every block / preempt /    *)
(* kcall-return boundary) is already the interleaving surface -- TLC        *)
(* explores all orderings across those boundaries.  This layer bounds the  *)
(* *initiation / nondeterministic* actions with per-action counters so the *)
(* state space is finite and so that hunting configs can zero out the      *)
(* subsystems irrelevant to a given Scenario, keeping the target mechanism  *)
(* reachable.  Reactive follow-ups (schedule, wake, deliver, relock,       *)
(* harvest, exit-cleanup/reinsert, resume) are NOT bounded -- they only     *)
(* fire in response to already-bounded initiations.                        *)
(***************************************************************************)

EXTENDS base

CONSTANTS
    CreateLimit,    \* CreateProcess (admission)
    CreateThreadLimit, \* CreateThread (spawn a thread in an existing process)
    SleepLimit,     \* Sleep (voluntary block onto a condvar)
    AlarmLimit,     \* AlarmFire (timer expiry -> sleeper becomes interrupted/timedout)
    KillLimit,      \* PostSignal* (procd kill of another process)
    SigactLimit,    \* SetDisposition / InstallHandler (sigaction)
    MaskLimit,      \* MaskChange (sigprocmask)
    ExecLimit,      \* Exec (execv image replacement)
    SigsuspLimit,   \* SigSuspendInstall (sigsuspend temporary-mask install)
    MarkIntrLimit,  \* MarkInterruptedBySignal (record a signal-interrupt restart)
    RvLimit,        \* RegisterRendezvous (push/pull rendezvous counterpart blocks)
    LockLimit,      \* LockMutexAcquire / LockMutexCancel
    CondwaitLimit,  \* CondWaitUnlock (start of wait_cond)
    TerminateLimit, \* Runnable/Suspended/Interrupted Terminate (procd terminate)
    ExitLimit,      \* ExitTakeRunning (do_exit)
    PreemptLimit,   \* Preempt (timer preemption)
    MaxOps          \* StateConstraint: bound on total operations (search depth)

VARIABLES ctr           \* record of per-action firing counters

mcVars == <<ctr>>

CtrInit ==
    ctr = [ create   |-> 0, cthread  |-> 0, sleep    |-> 0, alarm    |-> 0, kill    |-> 0,
            sigact   |-> 0, mask     |-> 0, exec     |-> 0, sigsusp |-> 0,
            markintr |-> 0, rv       |-> 0, lock     |-> 0, condwait|-> 0,
            terminate|-> 0, exit     |-> 0, preempt  |-> 0 ]

\* ========================================================================
\* Bounded initiation / fault-injection wrappers
\* ========================================================================

MCCreateProcess ==
    /\ ctr.create < CreateLimit
    /\ CreateProcess
    /\ ctr' = [ctr EXCEPT !.create = @ + 1]

MCCreateThread ==
    /\ ctr.cthread < CreateThreadLimit
    /\ CreateThread
    /\ ctr' = [ctr EXCEPT !.cthread = @ + 1]

MCSleep ==
    /\ ctr.sleep < SleepLimit
    /\ \E c \in CondAddr : Sleep(c)
    /\ ctr' = [ctr EXCEPT !.sleep = @ + 1]

MCAlarmFire ==
    /\ ctr.alarm < AlarmLimit
    /\ AlarmFire
    /\ ctr' = [ctr EXCEPT !.alarm = @ + 1]

MCPostSignalHandler ==
    /\ ctr.kill < KillLimit
    /\ \E p \in Proc, s \in Signal : PostSignalHandler(p, s)
    /\ ctr' = [ctr EXCEPT !.kill = @ + 1]

MCPostSignalDefaultTerminate ==
    /\ ctr.kill < KillLimit
    /\ \E p \in Proc, s \in Signal : PostSignalDefaultTerminate(p, s)
    /\ ctr' = [ctr EXCEPT !.kill = @ + 1]

MCSetDisposition ==
    /\ ctr.sigact < SigactLimit
    /\ \E p \in Proc, s \in Signal, d \in {"default","ignore","handler"} : SetDisposition(p, s, d)
    /\ ctr' = [ctr EXCEPT !.sigact = @ + 1]

MCInstallHandler ==
    /\ ctr.sigact < SigactLimit
    /\ \E p \in Proc, s \in Signal, sar \in BOOLEAN : InstallHandler(p, s, sar)
    /\ ctr' = [ctr EXCEPT !.sigact = @ + 1]

MCMaskChange ==
    /\ ctr.mask < MaskLimit
    /\ \E m \in SUBSET Signal : MaskChange(m)
    /\ ctr' = [ctr EXCEPT !.mask = @ + 1]

MCExec ==
    /\ ctr.exec < ExecLimit
    /\ Exec
    /\ ctr' = [ctr EXCEPT !.exec = @ + 1]

MCSigSuspendInstall ==
    /\ ctr.sigsusp < SigsuspLimit
    /\ \E m \in SUBSET Signal : SigSuspendInstall(m)
    /\ ctr' = [ctr EXCEPT !.sigsusp = @ + 1]

MCMarkInterruptedBySignal ==
    /\ ctr.markintr < MarkIntrLimit
    /\ \E s \in Signal : MarkInterruptedBySignal(s)
    /\ ctr' = [ctr EXCEPT !.markintr = @ + 1]

MCRegisterRendezvous ==
    /\ ctr.rv < RvLimit
    /\ RegisterRendezvous
    /\ ctr' = [ctr EXCEPT !.rv = @ + 1]

MCLockMutexAcquire ==
    /\ ctr.lock < LockLimit
    /\ \E a \in MutexAddr : LockMutexAcquire(a)
    /\ ctr' = [ctr EXCEPT !.lock = @ + 1]

MCLockMutexCancel ==
    /\ ctr.lock < LockLimit
    /\ \E a \in MutexAddr : LockMutexCancel(a)
    /\ ctr' = [ctr EXCEPT !.lock = @ + 1]

MCCondWaitUnlock ==
    /\ ctr.condwait < CondwaitLimit
    /\ \E c \in CondAddr, a \in MutexAddr : CondWaitUnlock(c, a)
    /\ ctr' = [ctr EXCEPT !.condwait = @ + 1]

MCRunnableTerminate ==
    /\ ctr.terminate < TerminateLimit
    /\ RunnableTerminate
    /\ ctr' = [ctr EXCEPT !.terminate = @ + 1]

MCSuspendedTerminate ==
    /\ ctr.terminate < TerminateLimit
    /\ SuspendedTerminate
    /\ ctr' = [ctr EXCEPT !.terminate = @ + 1]

MCInterruptedTerminate ==
    /\ ctr.terminate < TerminateLimit
    /\ InterruptedTerminate
    /\ ctr' = [ctr EXCEPT !.terminate = @ + 1]

MCExitTakeRunning ==
    /\ ctr.exit < ExitLimit
    /\ ExitTakeRunning
    /\ ctr' = [ctr EXCEPT !.exit = @ + 1]

MCPreempt ==
    /\ ctr.preempt < PreemptLimit
    /\ Preempt
    /\ ctr' = [ctr EXCEPT !.preempt = @ + 1]

\* ========================================================================
\* Unbounded reactive pass-throughs (UNCHANGED ctr)
\* ========================================================================

MCSchedule                 == Schedule                 /\ UNCHANGED ctr
MCHarvestZombieProc        == HarvestZombieProc        /\ UNCHANGED ctr
MCNotifyDequeue            == (\E c \in CondAddr : NotifyDequeue(c)) /\ UNCHANGED ctr
MCWakeDequeued             == WakeDequeued             /\ UNCHANGED ctr
MCResumeInterrupted        == ResumeInterrupted        /\ UNCHANGED ctr
MCDispatcherCheckpoint     == DispatcherCheckpoint     /\ UNCHANGED ctr
MCExitCleanupRendezvous    == ExitCleanupRendezvous    /\ UNCHANGED ctr
MCExitReinsert             == ExitReinsert             /\ UNCHANGED ctr
MCUnlockMutex              == (\E a \in MutexAddr : UnlockMutex(a)) /\ UNCHANGED ctr
MCCondWaitSleep            == CondWaitSleep            /\ UNCHANGED ctr
MCCondWaitRelock           == CondWaitRelock           /\ UNCHANGED ctr
MCCondWaitRelockInterrupted== CondWaitRelockInterrupted/\ UNCHANGED ctr
MCDeliverSignal            == DeliverSignal            /\ UNCHANGED ctr
MCSigReturn                == SigReturn                /\ UNCHANGED ctr
MCCreateProcessSpuriousOOM == CreateProcessSpuriousOOM /\ UNCHANGED ctr

\* ========================================================================
\* Init / Next / Spec
\* ========================================================================

MCInit == Init /\ CtrInit

MCNext ==
    \/ MCSchedule
    \/ MCPreempt
    \/ MCCreateProcess
    \/ MCCreateThread
    \/ MCCreateProcessSpuriousOOM
    \/ MCHarvestZombieProc
    \/ MCSleep
    \/ MCAlarmFire
    \/ MCNotifyDequeue
    \/ MCWakeDequeued
    \/ MCRunnableTerminate
    \/ MCSuspendedTerminate
    \/ MCInterruptedTerminate
    \/ MCResumeInterrupted
    \/ MCDispatcherCheckpoint
    \/ MCRegisterRendezvous
    \/ MCExitTakeRunning
    \/ MCExitCleanupRendezvous
    \/ MCExitReinsert
    \/ MCLockMutexAcquire
    \/ MCLockMutexCancel
    \/ MCUnlockMutex
    \/ MCCondWaitUnlock
    \/ MCCondWaitSleep
    \/ MCCondWaitRelock
    \/ MCCondWaitRelockInterrupted
    \/ MCPostSignalHandler
    \/ MCPostSignalDefaultTerminate
    \/ MCSetDisposition
    \/ MCInstallHandler
    \/ MCDeliverSignal
    \/ MCMaskChange
    \/ MCExec
    \/ MCSigSuspendInstall
    \/ MCSigReturn
    \/ MCMarkInterruptedBySignal

MCSpec == MCInit /\ [][MCNext]_<<vars, ctr>>

\* ========================================================================
\* Symmetry (Proc and Thread are symmetric model values; Signal is NOT --
\* signal delivery is lowest-numbered-first, so its ordering is significant).
\* ========================================================================

Symmetry == Permutations(Proc) \cup Permutations(Thread)

\* ========================================================================
\* State-space constraint (bounds total firing; redundant with per-action
\* limits but guards against runaway records).
\* ========================================================================

StateConstraint ==
    /\ ctr.create + ctr.cthread + ctr.sleep + ctr.alarm + ctr.kill + ctr.sigact + ctr.mask
       + ctr.exec + ctr.sigsusp + ctr.markintr + ctr.rv + ctr.lock + ctr.condwait
       + ctr.terminate + ctr.exit + ctr.preempt =< MaxOps

\* ========================================================================
\* Invariant handles (base-spec invariants surfaced for MC.cfg / hunt cfgs)
\* ========================================================================

\* Structural / safety (always checked during convergence)
MCTypeOK                 == TypeOK
MCSingleOwner            == SingleOwner

\* Extension (Scenario) invariants -- enabled in hunt cfgs
MCNoLostNotify           == NoLostNotify
MCSignalReachesSafety    == SignalReachesSafety
MCTerminatedThreadsDie   == TerminatedThreadsDie
MCRunningValidAtWakeup   == RunningValidAtWakeup
MCNoSpuriousOOM          == NoSpuriousOOM
MCCondWaitReturnsLocked  == CondWaitReturnsLocked
MCSyncSlotConservation   == SyncSlotConservation
MCMaskHonored            == MaskHonored
MCNoImmortalPending      == NoImmortalPending
MCSavedMaskRestored      == SavedMaskRestored
\* RestartAttribution (MC-10b) removed: not a real contract (SA_RESTART is applied per
\* the delivered signal, and KcallRestart carries no signal number).  See base.tla and
\* brief-coverage.md.

=============================================================================
