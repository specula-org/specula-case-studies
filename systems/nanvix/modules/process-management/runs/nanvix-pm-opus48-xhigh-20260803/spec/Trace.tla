-------------------------------- MODULE Trace --------------------------------
(*****************************************************************************)
(* Trace-validation layer for the Nanvix PM base specification.               *)
(*                                                                            *)
(* CATEGORY A (single-file, linear cursor).  Although the target is a          *)
(* concurrent runtime, the Nanvix kernel is single-core and runs interrupts-   *)
(* disabled (pm/mod.rs:46), so a whole kernel call executes atomically and the  *)
(* observable PM events are TOTALLY ORDERED.  There is no sub-operation         *)
(* overlap to reconstruct, so the Category-B per-thread timebox pattern does     *)
(* not apply: a single recorded event stream with one global cursor `l` is the   *)
(* faithful representation.  Each recorded event is one base-spec action; the    *)
(* wrapper binds the event's arguments, fires the FULL base action (never a       *)
(* bypass), validates the implementation-observable post-state fields the action  *)
(* modifies, then advances the cursor.                                            *)
(*                                                                                *)
(* Ghost variables (`g`, plus the per-thread ghost fields `ps` and the reap        *)
(* counter `rp`) are model-internal bookkeeping and are NOT emitted by the          *)
(* implementation, so they are intentionally excluded from post-state validation.  *)
(* Every other field is observable and validated.                                  *)
(*****************************************************************************)
EXTENDS base, Json, TLC

VARIABLE l                       \* linear trace cursor (1-indexed)

tvars == <<vars, l>>

(* Trace file (default ../traces/trace.ndjson).  Point the run at another file by *)
(* editing this operator or replacing the file in place.                          *)
JsonFile == "../traces/trace.ndjson"
TraceLog == ndJsonDeserialize(JsonFile)

Lg  == TraceLog[l]               \* current logline
Ev(a)   == Lg.action = a
RT(x)   == IF x = "NULL" THEN NULL ELSE x       \* resolve a possibly-absent ref
SetOf(a) == { a[i] : i \in DOMAIN a }           \* JSON array -> set

(* Accounting is emitted on every event and validated on every event: the          *)
(* post-state live counts must always equal what the base action computed.          *)
Acct == /\ tlive' = Lg.tlive
        /\ plive' = Lg.plive

-----------------------------------------------------------------------------
(* Bootstrap: the recorded execution starts at the kernel's post-boot state,       *)
(* which is exactly the base spec's Init (one alive process, one running thread).   *)
TraceInit == Init /\ l = 1

-----------------------------------------------------------------------------
(* ============================  ACTION WRAPPERS  ======================== *)
(* Each wrapper: (1) matches the event name, (2) fires the base action with the    *)
(* recorded arguments, (3) checks the observable post-state, (4) advances `l`.      *)

W_Schedule ==
    /\ Ev("Schedule") /\ Schedule(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt /\ Acct /\ l' = l + 1

W_Preempt ==
    /\ Ev("Preempt") /\ Preempt(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt /\ Acct /\ l' = l + 1

W_CreateThread ==
    /\ Ev("CreateThread") /\ CreateThread(Lg.caller, Lg.nt, Lg.det)
    /\ th'[Lg.nt].st = Lg.ntSt
    /\ th'[Lg.nt].pr = Lg.ntPr
    /\ th'[Lg.nt].det = Lg.det
    /\ deferred' = SetOf(Lg.deferred)
    /\ Acct /\ l' = l + 1

W_Fork ==
    /\ Ev("Fork") /\ Fork(Lg.caller, Lg.cp, Lg.ctid)
    /\ pr'[Lg.cp].st = Lg.cpSt
    /\ th'[Lg.ctid].st = Lg.ctidSt
    /\ th'[Lg.ctid].pr = Lg.ctidPr
    /\ deferred' = SetOf(Lg.deferred)
    /\ Acct /\ l' = l + 1

W_ExecRefuse ==
    /\ Ev("ExecRefuse") /\ ExecRefuse(Lg.caller)
    /\ Acct /\ l' = l + 1

W_ExecReplace ==
    /\ Ev("ExecReplace") /\ ExecReplace(Lg.caller, Lg.nt)
    /\ th'[Lg.nt].st = Lg.ntSt
    /\ th'[Lg.caller].st = Lg.callerSt
    /\ SetOf(Lg.pPd) = pr'[th[Lg.caller].pr].pd
    /\ Acct /\ l' = l + 1

W_ExitThread ==
    /\ Ev("ExitThread") /\ ExitThread(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt
    /\ pr'[th[Lg.t].pr].st = Lg.pSt
    /\ deferred' = SetOf(Lg.deferred)
    /\ Acct /\ l' = l + 1

W_JoinThread ==
    /\ Ev("JoinThread") /\ JoinThread(Lg.caller, Lg.u)
    /\ th'[Lg.caller].st = Lg.callerSt
    /\ th'[Lg.u].st = Lg.uSt
    /\ Acct /\ l' = l + 1

W_JoinResume ==
    /\ Ev("JoinResume") /\ JoinResume(Lg.caller)
    /\ th'[Lg.caller].st = Lg.callerSt
    /\ th'[th[Lg.caller].bo].st = Lg.uSt
    /\ Acct /\ l' = l + 1

W_DetachThread ==
    /\ Ev("DetachThread") /\ DetachThread(Lg.caller, Lg.u)
    /\ th'[Lg.u].st = Lg.uSt
    /\ th'[Lg.u].det = Lg.uDet
    /\ Acct /\ l' = l + 1

W_HarvestZombies ==
    /\ Ev("HarvestZombies") /\ HarvestZombies(Lg.p)
    /\ pr'[Lg.p].st = Lg.pSt
    /\ Acct /\ l' = l + 1

W_ReapDeferredSafe ==
    /\ Ev("ReapDeferredSafe") /\ ReapDeferredSafe(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt
    /\ deferred' = SetOf(Lg.deferred)
    /\ Acct /\ l' = l + 1

W_ReapDeferredUnsafe ==
    /\ Ev("ReapDeferredUnsafe") /\ ReapDeferredUnsafe(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt
    /\ deferred' = SetOf(Lg.deferred)
    /\ Acct /\ l' = l + 1

W_LockAcquire ==
    /\ Ev("LockAcquire") /\ LockAcquire(Lg.t, Lg.m)
    /\ mu'[Lg.m].ow = RT(Lg.muOw)
    /\ Acct /\ l' = l + 1

W_LockBlock ==
    /\ Ev("LockBlock") /\ LockBlock(Lg.t, Lg.m)
    /\ th'[Lg.t].st = Lg.tSt
    /\ mu'[Lg.m].q = Lg.muQ
    /\ Acct /\ l' = l + 1

W_LockResume ==
    /\ Ev("LockResume") /\ LockResume(Lg.t, Lg.m)
    /\ th'[Lg.t].st = Lg.tSt
    /\ mu'[Lg.m].ow = RT(Lg.muOw)
    /\ Acct /\ l' = l + 1

W_Unlock ==
    /\ Ev("Unlock") /\ Unlock(Lg.t, Lg.m)
    /\ mu'[Lg.m].ow = RT(Lg.muOw)
    /\ Acct /\ l' = l + 1

W_PutMutex ==
    /\ Ev("PutMutex") /\ PutMutex(Lg.caller, Lg.m)
    /\ mu'[Lg.m].ex = Lg.muEx
    /\ Acct /\ l' = l + 1

W_WaitCondPark ==
    /\ Ev("WaitCondPark") /\ WaitCondPark(Lg.t, Lg.c, Lg.m)
    /\ th'[Lg.t].st = Lg.tSt
    /\ co'[Lg.c].q = Lg.coQ
    /\ mu'[Lg.m].ow = RT(Lg.muOw)
    /\ Acct /\ l' = l + 1

W_SignalCond ==
    /\ Ev("SignalCond") /\ SignalCond(Lg.caller, Lg.c)
    /\ co'[Lg.c].q = Lg.coQ
    /\ Acct /\ l' = l + 1

W_CondResumeReacquire ==
    /\ Ev("CondResumeReacquire") /\ CondResumeReacquire(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt
    /\ mu'[th[Lg.t].wm].ow = RT(Lg.muOw)
    /\ Acct /\ l' = l + 1

W_CondInterrupt ==
    /\ Ev("CondInterrupt") /\ CondInterrupt(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt
    /\ co'[th[Lg.t].bo].q = Lg.coQ
    /\ Acct /\ l' = l + 1

W_PutCond ==
    /\ Ev("PutCond") /\ PutCond(Lg.caller, Lg.c)
    /\ co'[Lg.c].ex = Lg.coEx
    /\ Acct /\ l' = l + 1

W_Sleep ==
    /\ Ev("Sleep") /\ Sleep(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt /\ Acct /\ l' = l + 1

W_Wake ==
    /\ Ev("Wake") /\ Wake(Lg.t)
    /\ th'[Lg.t].st = Lg.tSt /\ Acct /\ l' = l + 1

W_Kill ==
    /\ Ev("Kill") /\ Kill(Lg.caller, Lg.p, Lg.s)
    /\ pr'[Lg.p].st = Lg.pSt
    /\ pr'[Lg.p].sp = Lg.pSp
    /\ SetOf(Lg.pPd) = pr'[Lg.p].pd
    /\ Acct /\ l' = l + 1

W_ContinueProcess ==
    /\ Ev("ContinueProcess") /\ ContinueProcess(Lg.caller, Lg.p)
    /\ pr'[Lg.p].sp = Lg.pSp
    /\ Acct /\ l' = l + 1

W_Sigaction ==
    /\ Ev("Sigaction") /\ Sigaction(Lg.caller, Lg.p, Lg.s, Lg.nd)
    /\ pr'[Lg.p].dp[Lg.s] = Lg.dpS
    /\ Acct /\ l' = l + 1

W_Sigprocmask ==
    /\ Ev("Sigprocmask") /\ Sigprocmask(Lg.t, SetOf(Lg.nm))
    /\ th'[Lg.t].bl = SetOf(Lg.tBl)
    /\ Acct /\ l' = l + 1

W_AsyncDeliver ==
    /\ Ev("AsyncDeliver") /\ AsyncDeliver(Lg.t)
    /\ th'[Lg.t].bl = SetOf(Lg.tBl)
    /\ Len(th'[Lg.t].fr) = Lg.frLen
    /\ SetOf(Lg.pPd) = pr'[th[Lg.t].pr].pd
    /\ Acct /\ l' = l + 1

W_Sigsuspend ==
    /\ Ev("Sigsuspend") /\ Sigsuspend(Lg.t, SetOf(Lg.tempmask))
    /\ th'[Lg.t].bl = SetOf(Lg.tBl)
    /\ Acct /\ l' = l + 1

W_Sigreturn ==
    /\ Ev("Sigreturn") /\ Sigreturn(Lg.t)
    /\ th'[Lg.t].bl = SetOf(Lg.tBl)
    /\ Len(th'[Lg.t].fr) = Lg.frLen
    /\ Acct /\ l' = l + 1

-----------------------------------------------------------------------------
AllWrappers ==
    \/ W_Schedule            \/ W_Preempt
    \/ W_CreateThread        \/ W_Fork
    \/ W_ExecRefuse          \/ W_ExecReplace
    \/ W_ExitThread
    \/ W_JoinThread          \/ W_JoinResume          \/ W_DetachThread
    \/ W_HarvestZombies      \/ W_ReapDeferredSafe     \/ W_ReapDeferredUnsafe
    \/ W_LockAcquire         \/ W_LockBlock            \/ W_LockResume
    \/ W_Unlock              \/ W_PutMutex
    \/ W_WaitCondPark        \/ W_SignalCond
    \/ W_CondResumeReacquire \/ W_CondInterrupt        \/ W_PutCond
    \/ W_Sleep               \/ W_Wake
    \/ W_Kill                \/ W_ContinueProcess
    \/ W_Sigaction           \/ W_Sigprocmask          \/ W_AsyncDeliver
    \/ W_Sigsuspend          \/ W_Sigreturn

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ AllWrappers
    \/ /\ l > Len(TraceLog)              \* trace consumed: terminal stutter
       /\ UNCHANGED tvars

(* Weak fairness on cursor advancement: whenever the next recorded event has a      *)
(* matching enabled wrapper, it must eventually fire.  Without this, `[][...]_tvars` *)
(* would admit an infinite stutter at l=1 that vacuously fails TraceMatched.         *)
TraceAdvance == l <= Len(TraceLog) /\ AllWrappers

TraceSpec == TraceInit /\ [][TraceNext]_tvars /\ WF_tvars(TraceAdvance)

-----------------------------------------------------------------------------
(* Completion property: the whole recorded trace must be consumed.  Without      *)
(* this the run can report "no error" even when `l` never advanced.               *)
TraceMatched == <>(l > Len(TraceLog))

=============================================================================
