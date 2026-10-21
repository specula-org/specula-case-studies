------------------------------- MODULE MC -------------------------------
EXTENDS base

(***************************************************************************
Finite Category B environment for brief scenarios 1-4. Faults retain the real
unlock/resolve/relock/reload compensation. No historical repair is disabled.
ReactiveNext is used unchanged, including every timer and completion step.
Scenario gates constrain client admission only. They do not schedule the kernel.
***************************************************************************)
CONSTANTS Mode, TargetKey, WakeArgs, MoveArgs,
          WaitBound, CallBound, FaultBound, StoreBound, TimedBound
VARIABLE budget
mcvars == <<s,budget>>

MCInit == Init /\ budget=[wait |-> 0, call |-> 0, fault |-> 0, store |-> 0, timed |-> 0]

Enrolled(g) == s.e[g].registered=1 /\ s.e[g].removals=0
    /\ s.w[g].pc \in {"pauseCheck","armRead","arm","wait","park","sleep"}
    /\ ~s.w[g].hasWoken /\ ~s.w[g].closed
Done(g) == s.w[g].pc="done"
CallDone(c) == s.op[c].pc="done"

\* Brief F00/F01-F10 select client workloads. F:114 is the enrollment evidence.
WaitPlan(g,k,v,d) ==
    CASE Mode="free" -> TRUE
      [] Mode="ordered" -> g=1 /\ k="A" /\ v=0 /\ d=Never
      [] Mode="mismatch" -> g=1 /\ k="A" /\ v=1 /\ d=Never
      [] Mode \in {"quota","wakeControl"} -> g \in {1,2} /\ k="A" /\ v=0 /\ d=Never
      [] Mode="unrelated" -> v=0 /\ d=Never /\
          ((g=1 /\ k="A") \/ (g=2 /\ k="C" /\ Enrolled(1))
            \/ (g=3 /\ k="A" /\ Enrolled(2)))
      [] Mode \in {"ownership","live"} -> v=0 /\
          ((g=1 /\ k="A" /\ d=Never)
            \/ (g=2 /\ k="A" /\ d=After(1) /\ Enrolled(1))
            \/ (Mode="live" /\ g \in {3,4} /\ k=TargetKey /\ d=Never
                  /\ Done(1) /\ Done(2) /\ CallDone(1)
                  /\ (g=3 \/ Enrolled(3))))
      [] Mode="opposite" -> g \in {1,2,3,4} /\ v=0 /\ d=Never
          /\ k=(IF g<=2 THEN "A" ELSE TargetKey)
      [] OTHER -> FALSE

\* S:97-117. Quota variants share production dispatch, including same-address.
CallPlan(c,kind,src,dst,nw,nm) ==
    CASE Mode="free" -> TRUE
      [] Mode="ordered" -> c=1 /\ kind="wake" /\ src="A" /\ dst="A"
            /\ nw=1 /\ nm=0 /\ s.stores=1
      [] Mode="mismatch" -> c=1 /\ kind="wake" /\ src="A" /\ dst="A"
            /\ nw=1 /\ nm=0 /\ Done(1)
      [] Mode="wakeControl" -> c=1 /\ kind="wake" /\ src="A" /\ dst="A"
            /\ nw=0 /\ nm=0 /\ Enrolled(1) /\ Enrolled(2)
      [] Mode \in {"quota","unrelated"} -> c=1 /\ kind="requeue"
            /\ src="A" /\ dst=TargetKey /\ nw \in WakeArgs /\ nm \in MoveArgs
            /\ (IF Mode="quota" THEN Enrolled(1) /\ Enrolled(2)
                  ELSE Enrolled(1) /\ Enrolled(2) /\ Enrolled(3))
      [] Mode \in {"ownership","live"} ->
          \/ /\ c=1 /\ kind="requeue" /\ src="A" /\ dst=TargetKey
             /\ nw=1 /\ nm=1 /\ Enrolled(1) /\ Enrolled(2)
          \/ /\ Mode="ownership" /\ c=2 /\ kind="wake" /\ src=TargetKey /\ dst=TargetKey
             /\ nw=2 /\ nm=0 /\ CallDone(1)
          \/ /\ Mode="live" /\ c=2 /\ kind="requeue" /\ src=TargetKey /\ dst="A"
             /\ nw=1 /\ nm=1 /\ Enrolled(3) /\ Enrolled(4)
          \/ /\ Mode="live" /\ c \in {3,4} /\ kind="wake" /\ nw=2 /\ nm=0
             /\ src=(IF c=3 THEN "A" ELSE TargetKey) /\ dst=src /\ CallDone(2)
             /\ (c=3 \/ CallDone(3))
      [] Mode="opposite" ->
          \/ /\ c \in {1,2} /\ kind="requeue" /\ nw=1 /\ nm=1
             /\ src=(IF c=1 THEN "A" ELSE TargetKey)
             /\ dst=(IF c=1 THEN TargetKey ELSE "A")
             /\ \A g \in WaitIds : s.e[g].registered=1
          \/ /\ c \in {3,4} /\ kind="wake" /\ nw=2 /\ nm=0
             /\ src=(IF c=3 THEN "A" ELSE TargetKey) /\ dst=src
             /\ CallDone(1) /\ CallDone(2)
      [] OTHER -> FALSE

MCWait(g,k,v,d) ==
    /\ budget.wait<WaitBound /\ (d=Never \/ budget.timed<TimedBound)
    /\ WaitPlan(g,k,v,d) /\ SysFutexWait(g,k,v,d)
    /\ budget'=[budget EXCEPT !.wait=@+1, !.timed=IF d=Never THEN @ ELSE @+1]
MCCall(c,a,kind,src,dst,nw,nm) ==
    /\ budget.call<CallBound /\ CallPlan(c,kind,src,dst,nw,nm)
    /\ SysFutexControl(c,a,kind,src,dst,nw,nm)
    /\ budget'=[budget EXCEPT !.call=@+1]
MCFault(g) ==
    /\ budget.fault<FaultBound /\ FutexWaitFault(g)
    /\ budget'=[budget EXCEPT !.fault=@+1]
MCStore(k,v) ==
    /\ budget.store<StoreBound
    /\ (Mode="free" \/ (Mode="ordered" /\ k="A" /\ v=1))
    /\ UserStore(k,v) /\ budget'=[budget EXCEPT !.store=@+1]

\* T:67-81. A sampled deadline may expire before publication takes the heap lock.
\* Once every armed or sampled deadline has expired, extra ticks change no guard.
MCClock ==
    /\ \E g \in WaitIds :
         \/ s.tm[g].state="armed" /\ s.now<s.tm[g].deadline
         \/ s.w[g].pc="arm" /\ s.now<s.w[g].sample+s.w[g].duration.ticks
    /\ ClockAdvance(s.now+1) /\ UNCHANGED budget

MCNext ==
    \/ /\ ReactiveNext /\ UNCHANGED budget
    \/ MCClock
    \/ \E g \in WaitIds, k \in Keys, v \in Values, d \in Durations : MCWait(g,k,v,d)
    \/ \E c \in CallIds, a \in Controllers, kind \in {"wake","requeue"},
          src,dst \in Keys, nw,nm \in Quotas : MCCall(c,a,kind,src,dst,nw,nm)
    \/ \E g \in WaitIds : MCFault(g)
    \/ \E k \in Keys, v \in Values : MCStore(k,v)
MCSpec == MCInit /\ [][MCNext]_mcvars

\* Symmetry permutes only controller actors. Keys, generation ordinals and bucket
\* numbers carry scenario roles and lock order, and must never be permuted.
Symmetry == Permutations(Controllers)
\* Keep budgets in the view because they affect which futures are possible.
MCView == mcvars
\* There are no messages. Capacity follows the finite set of registration tokens.
FiniteCapacity == \A b \in Buckets : Len(s.q[b])<=Cardinality(WaitIds)
MCTypeOK == TypeOK /\ budget \in [wait:0..WaitBound, call:0..CallBound,
                               fault:0..FaultBound, store:0..StoreBound, timed:0..TimedBound]
\* F:398-427. A call requesting its second lock already owns only the lower one.
OrderedLocks == \A c \in CallIds : s.op[c].pc="lockSecond" =>
    s.locks[FirstBucket(c)]=COwner(c) /\ FirstBucket(c)<SecondBucket(c)
\* Brief scenario 1 has exactly one immutable predicate update and one WAKE.
\* F:83-119,485-498. Check only after compare has resolved, without requiring OK
\* to imply a true user predicate.
NoMissedOrderedWake == Mode="ordered" =>
    (s.op[1].pc="done" /\ s.e[1].registered=1 => s.w[1].futexAccepted)

\* S:146-150; L/waitwake.c:180-197. Two quiet enrolled waits make WAKE(0)
\* accept exactly one in this dedicated control, independently of REQUEUE.
WakeZeroControl == Mode="wakeControl" =>
    (s.op[1].pc="done" => s.op[1].wakes=1 /\ s.op[1].result=1 /\ s.op[1].moves=0)

\* Fair scheduling, lock service and timer delivery, with finite admitted work.
\* No fairness forces an optional client WAKE into existence. No watchdog oracle.
Fairness == /\ \A g \in WaitIds : WF_mcvars(WaitStep(g) /\ UNCHANGED budget)
            /\ \A g \in WaitIds : WF_mcvars(TimerStep(g) /\ UNCHANGED budget)
            /\ \A c \in CallIds : WF_mcvars(ControlStep(c) /\ UNCHANGED budget)
            /\ WF_mcvars(CollectionStep /\ UNCHANGED budget)
            /\ WF_mcvars(MCClock)
MCFairSpec == MCSpec /\ Fairness
ControlCompletion == \A c \in CallIds : (s.op[c].pc/="idle") ~> (s.op[c].pc="done")
TimedCompletion == \A g \in WaitIds :
    (s.e[g].registered=1 /\ s.w[g].duration.timed) ~> (s.w[g].returns=1)
=============================================================================
