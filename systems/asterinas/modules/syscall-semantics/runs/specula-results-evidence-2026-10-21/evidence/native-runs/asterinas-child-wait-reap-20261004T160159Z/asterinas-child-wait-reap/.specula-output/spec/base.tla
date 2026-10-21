------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

\* Category B. Asterinas 0c60537098f4c2949ad2d382aaf499de72263d76.
\* Paths starting process/, syscall/, or sched/ are under kernel/core/src/.
\* S1: children mutex and consuming claim. S2: retained Arc and observations.
\* S3: waiter generations, two wake paths, queue residue, scheduler handoff.
\* S4: exit publication. S5: API-specific outcomes and unchanged empty output.
\* Fork has established the fixture. No client budget is imposed by this module.
CONSTANTS Threads, ChildPid, ChildUid, ExitValues
ASSUME /\ IsFiniteSet(Threads) /\ Cardinality(Threads) = 2
       /\ ChildPid \in Nat \ {0} /\ ChildUid \in Nat
       /\ ExitValues \subseteq 0..255 /\ ExitValues /= {}

NoThread == "none"
NoCall == <<>>
\* Keep the pending marker numeric so TLC can compare it with ABI results.
\* ChildPid is positive, and the other fixture results are 0 and -10.
PendingRet == -9999
Requests == { [api |-> a, nohang |-> h, nowait |-> w] :
               a \in {"wait4", "waitid"}, h \in BOOLEAN, w \in BOOLEAN }
ValidRequests == {r \in Requests : r.api = "waitid" \/ ~r.nowait}

\* One record keeps unmodified components unchanged in every action.
\* calls retains completed generations so stale queue entries cannot target a
\* new invocation. claims and the *HadRef/*Present fields are history variables.
VARIABLE s
vars == <<s>>
Key(t) == <<t, s.current[t]>>
At(t, step) == IF s.current[t] = 0 THEN FALSE
              ELSE s.calls[Key(t)].pc = step /\ s.runnable[t]
Ready(t) == IF s.current[t] = 0 THEN TRUE
            ELSE s.calls[Key(t)].pc = "done"

\* syscall/wait4.rs:41-47; syscall/waitid.rs:49-66. The primary fixture
\* poisons wait4 status but prezeros waitid fields. WR-SQ is a separate control.
BlankOutput(api) == [pid |-> 0, uid |-> 0, signo |-> 0, siCode |-> 0,
                     status |-> IF api = "wait4" THEN -999 ELSE 0]
\* process/term_status.rs:13-18; syscall/waitid.rs:73-90.
Encoded(v) == 256 * v
Output(c) == IF c.api = "wait4"
             THEN [BlankOutput("wait4") EXCEPT !.status = c.readCode]
             ELSE [pid |-> c.selectedPid, uid |-> ChildUid, signo |-> 17,
                   siCode |-> 1, status |-> c.readCode \div 256]

\* syscall/wait4.rs:18-36; syscall/waitid.rs:29-43; process/wait.rs:64-68.
NewCall(r) ==
    [pc |-> "lock", api |-> r.api, nohang |-> r.nohang, nowait |-> r.nowait,
     scan |-> "unset", acquired |-> FALSE, selected |-> FALSE,
     selectedPid |-> 0, selectedPresent |-> FALSE, retained |-> FALSE,
     created |-> FALSE, token |-> FALSE, closed |-> FALSE,
     readCode |-> -1, readHadRef |-> FALSE, copyHadRef |-> FALSE,
     outputWritten |-> FALSE, out |-> BlankOutput(r.api),
     outcome |-> "pending", ret |-> PendingRet,
     beganWithChild |-> s.childPresent,
     beganAfterConsume |-> \E k \in s.claims : s.calls[k].pc = "done"]

\* process/status.rs:28-35. The established child is live and discoverable.
\* process/signal/pause.rs:235-245; ostd/src/sync/wait.rs:51-55: no waiters yet.
Init ==
    s = [childPresent |-> TRUE, pidPresent |-> TRUE, zombie |-> FALSE,
         storedCode |-> 0, exitValue |-> -1, exitPc |-> "store",
         pendingSignal |-> FALSE, childrenOwner |-> NoThread,
         current |-> [t \in Threads |-> 0], calls |-> [k \in {} |-> 0],
         claims |-> {}, signalReg |-> [t \in Threads |-> NoCall],
         queue |-> <<>>, runnable |-> [t \in Threads |-> TRUE],
         rqHeld |-> [t \in Threads |-> FALSE], signalHeld |-> NoThread,
         notifyTodo |-> {}, wakeTarget |-> NoCall, wakeChannel |-> "none"]

\* syscall/wait4.rs:18-36; syscall/waitid.rs:29-43. Fixture arguments are
\* positive ChildPid, valid distinct buffers, null rusage, and blocked SIGCHLD.
SysWaitBegin(t, r) ==
    /\ t \in Threads /\ r \in ValidRequests /\ Ready(t) /\ s.runnable[t]
    /\ LET k == <<t, s.current[t] + 1>> IN
       s' = [s EXCEPT !.current[t] = @ + 1,
                      !.calls = @ @@ (k :> NewCall(r))]

\* process/wait.rs:293; ostd/src/sync/mutex.rs:35-69. Internal mutex waiting
\* is projected as eventual acquisition, separately from the children queue.
TryWaitChildrenLock(t) ==
    /\ At(t, "lock") /\ s.childrenOwner = NoThread
    /\ s' = [s EXCEPT !.childrenOwner = t, !.calls[Key(t)].pc = "match"]

\* process/wait.rs:296-304,335; process/process_filter.rs:28-31,68-70.
TryWaitChildrenMatch(t) ==
    /\ At(t, "match") /\ s.childrenOwner = t
    /\ s' = [s EXCEPT
         !.calls[Key(t)].scan = IF s.childPresent THEN "matched" ELSE "absent",
         !.calls[Key(t)].pc = IF s.childPresent THEN "zombie" ELSE "unlock"]

\* process/wait.rs:310,322-335; process/status.rs:41-43. This Acquire
\* observation is separate from the immutable PID match and the Arc clone.
TryWaitChildrenZombie(t) ==
    /\ At(t, "zombie") /\ s.childrenOwner = t
    /\ s' = [s EXCEPT !.calls[Key(t)].acquired = s.zombie,
         !.calls[Key(t)].scan = IF s.zombie THEN "zombie" ELSE "live",
         !.calls[Key(t)].pc = IF s.zombie THEN "retain" ELSE "unlock"]

\* process/wait.rs:311-319. WNOWAIT keeps the map entry. Selection snapshots
\* membership while protected. The retained object outlives that membership.
TryWaitChildrenRetain(t) ==
    /\ At(t, "retain") /\ s.childrenOwner = t
    /\ s' = [s EXCEPT !.calls[Key(t)].selected = TRUE,
         !.calls[Key(t)].selectedPid = ChildPid,
         !.calls[Key(t)].selectedPresent = s.childPresent,
         !.calls[Key(t)].retained = TRUE,
         !.calls[Key(t)].pc = IF s.calls[Key(t)].nowait THEN "unlock"
                             ELSE "remove"]

\* process/wait.rs:312-317,344-345. This map removal is the consuming claim.
ReapZombieChildRemove(t) ==
    /\ At(t, "remove") /\ s.childrenOwner = t /\ s.childPresent
    /\ s' = [s EXCEPT !.childPresent = FALSE,
         !.claims = @ \cup {Key(t)}, !.calls[Key(t)].pc = "pidRemove"]

\* process/wait.rs:347-363; process/pid_table.rs:148-166. The nested PID
\* lock is assumed to progress. It does not release the children mutex.
ReapZombieChildPidRemove(t) ==
    /\ At(t, "pidRemove") /\ s.childrenOwner = t
    /\ s' = [s EXCEPT !.pidPresent = FALSE, !.calls[Key(t)].pc = "cleanup"]

\* process/wait.rs:365-374. Group/session and accounting updates are omitted
\* under the fixture. Their completion retains this lock and the result Arc.
ReapZombieChildFinish(t) ==
    /\ At(t, "cleanup") /\ s.childrenOwner = t
    /\ s' = [s EXCEPT !.calls[Key(t)].pc = "unlock"]

\* process/wait.rs:319,335; ostd/src/sync/mutex.rs:56-69. No children-queue
\* notification is added at reap. The mutex's own contention queue is abstract.
TryWaitChildrenUnlock(t) ==
    /\ At(t, "unlock") /\ s.childrenOwner = t
    /\ s' = [s EXCEPT !.childrenOwner = NoThread,
                      !.calls[Key(t)].pc = "decide"]

\* process/signal/pause.rs:164-168,240-245. Fast-path returns have no waiter
\* to close. Slow-path returns clear the signal slot before dropping Waiter.
ReturnPc(k, outcome) == IF s.calls[k].created THEN "clearSignal"
                       ELSE IF outcome = "event" THEN "read" ELSE "return"

\* process/wait.rs:75-76.
DoWaitFound(t) ==
    /\ At(t, "decide") /\ s.calls[Key(t)].scan = "zombie"
    /\ s' = [s EXCEPT !.calls[Key(t)].outcome = "event",
                      !.calls[Key(t)].pc = ReturnPc(Key(t), "event")]

\* process/wait.rs:78-85. No matching tracees exist in this fixture.
DoWaitNoMatch(t) ==
    /\ At(t, "decide") /\ s.calls[Key(t)].scan = "absent"
    /\ s' = [s EXCEPT !.calls[Key(t)].outcome = "ECHILD",
                      !.calls[Key(t)].pc = ReturnPc(Key(t), "ECHILD")]

\* process/wait.rs:77,88-89. A cached live scan remains no-event even when
\* exit or another call's reap precedes this invocation's eventual return.
DoWaitNoHang(t) ==
    /\ At(t, "decide") /\ s.calls[Key(t)].scan = "live"
    /\ s.calls[Key(t)].nohang
    /\ s' = [s EXCEPT !.calls[Key(t)].outcome = "noevent",
                      !.calls[Key(t)].pc = ReturnPc(Key(t), "noevent")]

\* process/wait.rs:99-100; process/signal/pause.rs:235-245;
\* ostd/src/sync/wait.rs:219-229. First failure creates a waiter. Each later
\* failure checks cancellation before entering the wake-token/park loop.
DoWaitPending(t) ==
    /\ At(t, "decide") /\ s.calls[Key(t)].scan = "live"
    /\ ~s.calls[Key(t)].nohang
    /\ s' = [s EXCEPT !.calls[Key(t)].pc =
         IF s.calls[Key(t)].created THEN "cancel" ELSE "create"]

\* process/signal/pause.rs:240; ostd/src/sync/wait.rs:181-189.
WaiterNewPair(t) ==
    /\ At(t, "create")
    /\ s' = [s EXCEPT !.calls[Key(t)].created = TRUE,
         !.calls[Key(t)].token = FALSE, !.calls[Key(t)].closed = FALSE,
         !.calls[Key(t)].pc = "register"]

\* process/signal/pause.rs:164; process/posix_thread/mod.rs:177-180,250-253.
SetSignalledWaker(t) ==
    /\ At(t, "register") /\ s.signalHeld /= t /\ s.signalReg[t] = NoCall
    /\ s' = [s EXCEPT !.signalReg[t] = Key(t), !.calls[Key(t)].pc = "enqueue"]

\* process/signal/pause.rs:241-244; ostd/src/sync/wait.rs:145-149.
\* Enqueue and count Acquire RMW share the queue lock. Duplicates are retained.
WaitQueueEnqueue(t) ==
    /\ At(t, "enqueue")
    /\ s' = [s EXCEPT !.queue = Append(@, Key(t)),
                      !.calls[Key(t)].pc = "lock"]

\* process/signal/pause.rs:149-161; process/signal/pending.rs:131-145;
\* time/wait.rs:184-206. Only blocked SIGCHLD is pending, with no timer.
PauseCheckCancellation(t) ==
    /\ At(t, "cancel")
    /\ s' = [s EXCEPT !.calls[Key(t)].pc = "token"]

\* ostd/src/sync/wait.rs:273-275. Acquire swap consumes permission to recheck,
\* not a child status. Returning from wait() re-enqueues before every scan.
WakerConsumeToken(t) ==
    /\ At(t, "token")
    /\ s' = [s EXCEPT !.calls[Key(t)].token = FALSE,
         !.calls[Key(t)].pc = IF s.calls[Key(t)].token THEN "enqueue" ELSE "park"]

\* ostd/src/task/scheduler/mod.rs:453-470; sched/sched_class/mod.rs:255-258.
\* The runqueue lock protects both this check and the following dequeue.
\* A wake-token swap is allowed between them, while enqueue must wait.
ParkCurrentCheck(t) ==
    /\ At(t, "park") /\ ~s.rqHeld[t]
    /\ s' = [s EXCEPT !.rqHeld[t] = ~s.calls[Key(t)].token,
         !.calls[Key(t)].pc = IF s.calls[Key(t)].token THEN "token" ELSE "dequeue"]

\* ostd/src/task/scheduler/mod.rs:469-484; sched/sched_class/mod.rs:410-414.
\* The saved false check is not repeated here. Unpark waits for lock release.
ParkCurrentDequeue(t) ==
    /\ At(t, "dequeue") /\ s.rqHeld[t]
    /\ s' = [s EXCEPT !.runnable[t] = FALSE, !.rqHeld[t] = FALSE,
                      !.calls[Key(t)].pc = "parked"]

\* ostd/src/task/scheduler/mod.rs:473-482; ostd/src/sync/wait.rs:273-275.
ParkCurrentResume(t) ==
    /\ At(t, "parked")
    /\ s' = [s EXCEPT !.calls[Key(t)].pc = "token"]

\* ostd/src/task/scheduler/mod.rs:441-444. Optional environmental scheduler
\* return, never a wake token. MC bounds it and completion does not rely on it.
ParkCurrentSpurious(t) ==
    /\ s.current[t] > 0 /\ s.calls[Key(t)].pc = "parked" /\ ~s.runnable[t]
    /\ s' = [s EXCEPT !.runnable[t] = TRUE]

\* process/signal/pause.rs:166; process/posix_thread/mod.rs:183-185,250-253.
ClearSignalledWaker(t) ==
    /\ At(t, "clearSignal") /\ s.signalHeld /= t
    /\ s' = [s EXCEPT !.signalReg[t] = NoCall, !.calls[Key(t)].pc = "close"]

\* ostd/src/sync/wait.rs:244-248,278-281. Acquire close leaves true in the
\* same token used by wake_up. Old queue entries keep this generation's Arc.
WaiterClose(t) ==
    /\ At(t, "close")
    /\ s' = [s EXCEPT !.calls[Key(t)].closed = TRUE,
         !.calls[Key(t)].token = TRUE,
         !.calls[Key(t)].pc = IF s.calls[Key(t)].outcome = "event"
                             THEN "read" ELSE "return"]

\* syscall/wait4.rs:45,63-65; process/status.rs:71-72.
SysWait4ReadStatus(t) ==
    /\ At(t, "read") /\ s.calls[Key(t)].api = "wait4"
    /\ s' = [s EXCEPT !.calls[Key(t)].readCode = s.storedCode,
         !.calls[Key(t)].readHadRef = s.calls[Key(t)].retained,
         !.calls[Key(t)].pc = "copy"]

\* syscall/waitid.rs:55-63,88-90; process/wait.rs:129-143.
\* Fixed PID/UID and retained main task make these immutable reads one step.
SysWaitidReadStatus(t) ==
    /\ At(t, "read") /\ s.calls[Key(t)].api = "waitid"
    /\ s' = [s EXCEPT !.calls[Key(t)].readCode = s.storedCode,
         !.calls[Key(t)].readHadRef = s.calls[Key(t)].retained,
         !.calls[Key(t)].pc = "copy"]

\* syscall/wait4.rs:46-47; syscall/waitid.rs:66. Buffers are stable, valid,
\* and private to each call. WR-CF does not inject faults into this action.
SysWaitCopyout(t) ==
    /\ At(t, "copy")
    /\ s' = [s EXCEPT !.calls[Key(t)].out = Output(s.calls[Key(t)]),
         !.calls[Key(t)].outputWritten = TRUE,
         !.calls[Key(t)].copyHadRef = s.calls[Key(t)].retained,
         !.calls[Key(t)].pc = "drop"]

\* process/wait.rs:120-164; syscall/wait4.rs:60; syscall/waitid.rs:69.
\* Drop the returned WaitStatus after its last read/copy, before caller return.
WaitStatusDrop(t) ==
    /\ At(t, "drop")
    /\ s' = [s EXCEPT !.calls[Key(t)].retained = FALSE,
                      !.calls[Key(t)].pc = "return"]

\* syscall/wait4.rs:36-43,60; syscall/waitid.rs:43-50,69.
\* ret records the direct kernel ABI result. Libc errno conversion is external.
SysWaitReturn(t) ==
    /\ At(t, "return")
    /\ s' = [s EXCEPT !.calls[Key(t)].pc = "done",
         !.calls[Key(t)].ret = CASE s.calls[Key(t)].outcome = "ECHILD" -> -10
                              [] s.calls[Key(t)].outcome = "noevent" -> 0
                              [] OTHER -> IF s.calls[Key(t)].api = "wait4"
                                          THEN s.calls[Key(t)].selectedPid ELSE 0]

\* process/posix_thread/exit.rs:53,63-89,120-122; process/status.rs:75-77.
\* The single child thread stores its normal exit code before publication.
ProcessStoreExitCode(v) ==
    /\ s.exitPc = "store" /\ v \in ExitValues
    /\ s' = [s EXCEPT !.exitValue = v, !.storedCode = Encoded(v),
                      !.exitPc = "publish"]

\* process/exit.rs:30-40; process/status.rs:51-53. Release publication is
\* independent of children locking and precedes both notification channels.
ProcessPublishZombie ==
    /\ s.exitPc = "publish"
    /\ s' = [s EXCEPT !.zombie = TRUE, !.exitPc = "signalEnqueue"]

\* process/exit.rs:177-186; process/process/mod.rs:641-648.
\* The parent is live. SIGCHLD stays pending despite being blocked.
ProcessEnqueueSignal ==
    /\ s.exitPc = "signalEnqueue"
    /\ s' = [s EXCEPT !.pendingSignal = TRUE, !.notifyTodo = Threads,
                      !.exitPc = "signalLoop"]

\* process/process/mod.rs:648-656; process/posix_thread/mod.rs:250-253.
\* The fixed parent task vector is projected as either enumeration order.
WakeSignalledWakerNone(t) ==
    /\ s.exitPc = "signalLoop" /\ t \in s.notifyTodo
    /\ s.signalReg[t] = NoCall
    /\ s' = [s EXCEPT !.notifyTodo = @ \ {t}]

\* process/posix_thread/mod.rs:250-253. Hold the signalled-waker lock through
\* wake_up, including a delayed unpark. Registration/clear cannot pass it.
WakeSignalledWakerGet(t) ==
    /\ s.exitPc = "signalLoop" /\ t \in s.notifyTodo
    /\ s.signalReg[t] /= NoCall
    /\ s' = [s EXCEPT !.notifyTodo = @ \ {t}, !.signalHeld = t,
         !.wakeTarget = s.signalReg[t], !.wakeChannel = "signal", !.exitPc = "wake"]

\* process/process/mod.rs:648-656; process/exit.rs:184-186.
ProcessSignalLoopDone ==
    /\ s.exitPc = "signalLoop" /\ s.notifyTodo = {}
    /\ s' = [s EXCEPT !.exitPc = "queueCheck"]

\* ostd/src/sync/wait.rs:262-268. The Release swap may race with the
\* runqueue-protected park check/dequeue. An already true token suppresses
\* unpark, including for closed or duplicate queue entries.
WakerWakeUp ==
    /\ s.exitPc = "wake"
    /\ s' = [s EXCEPT !.calls[s.wakeTarget].token = TRUE,
         !.exitPc = IF s.calls[s.wakeTarget].token THEN "wakeFinish" ELSE "unpark"]

\* ostd/src/task/scheduler/mod.rs:488-494; sched/sched_class/mod.rs:223-250.
\* Project CPU selection and the assignment retry onto the target runqueue
\* lock. Delaying this step covers wake between park check and dequeue.
SchedulerUnparkTarget ==
    /\ s.exitPc = "unpark" /\ ~s.rqHeld[s.wakeTarget[1]]
    /\ s' = [s EXCEPT !.runnable[s.wakeTarget[1]] = TRUE,
                      !.exitPc = "wakeFinish"]

\* process/posix_thread/mod.rs:250-253; ostd/src/sync/wait.rs:128-131.
\* Only the signal path held the per-thread signal lock. Queue pop released
\* its lock before calling wake_up, so the next entry can be enqueued meanwhile.
WakerWakeFinish ==
    /\ s.exitPc = "wakeFinish"
    /\ s' = [s EXCEPT !.signalHeld = NoThread, !.wakeTarget = NoCall,
         !.wakeChannel = "none",
         !.exitPc = IF s.wakeChannel = "signal" THEN "signalLoop" ELSE "queuePop"]

\* ostd/src/sync/wait.rs:111-115,136-140. The Release RMW observes the
\* queue-count modification order. A later registration still rechecks.
WaitQueueWakeAllCheck ==
    /\ s.exitPc = "queueCheck"
    /\ s' = [s EXCEPT !.exitPc = IF Len(s.queue) = 0 THEN "done" ELSE "queuePop"]

\* ostd/src/sync/wait.rs:119-126. Pop/count Release and lock release are one
\* queue critical section. WakerWakeUp is a separate interleaving point.
WaitQueueWakeAllPop ==
    /\ s.exitPc = "queuePop" /\ Len(s.queue) > 0
    /\ s' = [s EXCEPT !.queue = Tail(@), !.wakeTarget = Head(s.queue),
                      !.wakeChannel = "queue", !.exitPc = "wake"]

\* ostd/src/sync/wait.rs:120-123. There is no extra wake after this empty pop.
WaitQueueWakeAllDone ==
    /\ s.exitPc = "queuePop" /\ Len(s.queue) = 0
    /\ s' = [s EXCEPT !.exitPc = "done"]

ThreadStep(t) ==
    \/ TryWaitChildrenLock(t) \/ TryWaitChildrenMatch(t)
    \/ TryWaitChildrenZombie(t) \/ TryWaitChildrenRetain(t)
    \/ ReapZombieChildRemove(t) \/ ReapZombieChildPidRemove(t)
    \/ ReapZombieChildFinish(t) \/ TryWaitChildrenUnlock(t)
    \/ DoWaitFound(t) \/ DoWaitNoMatch(t) \/ DoWaitNoHang(t) \/ DoWaitPending(t)
    \/ WaiterNewPair(t) \/ SetSignalledWaker(t) \/ WaitQueueEnqueue(t)
    \/ PauseCheckCancellation(t) \/ WakerConsumeToken(t)
    \/ ParkCurrentCheck(t) \/ ParkCurrentDequeue(t) \/ ParkCurrentResume(t)
    \/ ClearSignalledWaker(t) \/ WaiterClose(t)
    \/ SysWait4ReadStatus(t) \/ SysWaitidReadStatus(t) \/ SysWaitCopyout(t)
    \/ WaitStatusDrop(t) \/ SysWaitReturn(t)

ExitReactive ==
    \/ ProcessPublishZombie \/ ProcessEnqueueSignal \/ ProcessSignalLoopDone
    \/ \E t \in Threads : WakeSignalledWakerNone(t) \/ WakeSignalledWakerGet(t)
    \/ WakerWakeUp \/ SchedulerUnparkTarget \/ WakerWakeFinish
    \/ WaitQueueWakeAllCheck \/ WaitQueueWakeAllPop \/ WaitQueueWakeAllDone
ExitStep == (\E v \in ExitValues : ProcessStoreExitCode(v)) \/ ExitReactive
Reactive == ExitReactive \/ (\E t \in Threads : ThreadStep(t))
Next == ExitStep \/ (\E t \in Threads :
           ThreadStep(t) \/ ParkCurrentSpurious(t) \/
           (\E r \in ValidRequests : SysWaitBegin(t, r)))
Spec == Init /\ [][Next]_vars

\* These domains and properties are obligations, not additional action guards.
CallPCs == {"lock", "match", "zombie", "retain", "remove", "pidRemove",
    "cleanup", "unlock", "decide", "create", "register", "enqueue", "cancel",
    "token", "park", "dequeue", "parked", "clearSignal", "close", "read",
    "copy", "drop", "return", "done"}
LockedPCs == {"match", "zombie", "retain", "remove", "pidRemove", "cleanup", "unlock"}
ExitPCs == {"store", "publish", "signalEnqueue", "signalLoop", "queueCheck",
           "queuePop", "wake", "unpark", "wakeFinish", "done"}
CallType(c) ==
    /\ c.pc \in CallPCs /\ c.api \in {"wait4", "waitid"}
    /\ c.nohang \in BOOLEAN /\ c.nowait \in BOOLEAN
    /\ c.api = "wait4" => ~c.nowait
    /\ c.scan \in {"unset", "matched", "live", "absent", "zombie"}
    /\ \A f \in {"acquired", "selected", "selectedPresent", "retained", "created",
                  "token", "closed", "readHadRef", "copyHadRef", "outputWritten",
                  "beganWithChild", "beganAfterConsume"} : c[f] \in BOOLEAN
    /\ c.selectedPid \in {0, ChildPid} /\ c.readCode \in {-1} \cup (0..65280)
    /\ c.out \in [pid : {0, ChildPid}, uid : {0, ChildUid}, signo : {0, 17},
                  siCode : {0, 1}, status : {-999} \cup (0..65280)]
    /\ c.outcome \in {"pending", "event", "noevent", "ECHILD"}
    /\ c.ret \in {PendingRet, -10, 0, ChildPid}
TypeOK ==
    /\ s.childPresent \in BOOLEAN /\ s.pidPresent \in BOOLEAN /\ s.zombie \in BOOLEAN
    /\ s.storedCode \in 0..65280 /\ s.exitValue \in {-1} \cup ExitValues
    /\ s.exitPc \in ExitPCs /\ s.pendingSignal \in BOOLEAN
    /\ s.childrenOwner \in Threads \cup {NoThread}
    /\ s.current \in [Threads -> Nat]
    /\ DOMAIN s.calls = UNION {{<<t,n>> : n \in 1..s.current[t]} : t \in Threads}
    /\ \A k \in DOMAIN s.calls : CallType(s.calls[k])
    /\ s.claims \subseteq DOMAIN s.calls
    /\ s.signalReg \in [Threads -> (DOMAIN s.calls) \cup {NoCall}]
    /\ s.queue \in Seq(DOMAIN s.calls)
    /\ s.runnable \in [Threads -> BOOLEAN] /\ s.rqHeld \in [Threads -> BOOLEAN]
    /\ s.signalHeld \in Threads \cup {NoThread} /\ s.notifyTodo \subseteq Threads
    /\ s.wakeTarget \in (DOMAIN s.calls) \cup {NoCall}
    /\ s.wakeChannel \in {"none", "signal", "queue"}

\* S1, process/wait.rs:293-319,344-374.
LockExclusion ==
    /\ Cardinality({k \in DOMAIN s.calls : s.calls[k].pc \in LockedPCs}) <= 1
    /\ \A k \in DOMAIN s.calls : s.calls[k].pc \in LockedPCs =>
          s.childrenOwner = k[1] /\ Key(k[1]) = k
UniqueConsume == Cardinality(s.claims) <= 1

\* S1/S2, process/wait.rs:298-319. A late output uses its earlier selection.
NoFreshSelectionAfterRemoval ==
    \A k \in DOMAIN s.calls :
       /\ s.calls[k].selected => s.calls[k].selectedPresent
       /\ s.calls[k].beganAfterConsume => ~s.calls[k].selected
       /\ (s.calls[k].beganAfterConsume /\ s.calls[k].pc = "done") =>
             s.calls[k].outcome = "ECHILD"
ObservationPreservesAvailability ==
    /\ (~s.childPresent) <=> (s.claims /= {})
    /\ \A k \in s.claims : ~s.calls[k].nowait /\ s.calls[k].selected

\* S2, process/wait.rs:120-164; task_set.rs:63-74,141-143; syscall outputs.
RetainedSelectionValid ==
    \A k \in DOMAIN s.calls : LET c == s.calls[k] IN
       /\ c.retained => c.selected /\ c.selectedPresent /\ c.acquired
       /\ c.pc \in {"read", "copy", "drop"} => c.retained
       /\ c.readCode /= -1 => c.readHadRef /\ c.selected /\ c.acquired
       /\ c.outputWritten => c.copyHadRef /\ c.readHadRef /\ c.selected

\* S4, process/status.rs:41-53,71-77; process/term_status.rs:13-18.
PublishedStatusAgreement ==
    \A k \in DOMAIN s.calls : LET c == s.calls[k] IN
       /\ c.acquired => s.zombie /\ s.storedCode = Encoded(s.exitValue)
       /\ c.selected => c.selectedPid = ChildPid /\ c.acquired
       /\ c.readCode /= -1 => c.readCode = Encoded(s.exitValue)
       /\ c.outputWritten => c.out = Output(c)

\* S5, process/wait.rs:75-89; syscall/wait4.rs:36-60; waitid.rs:43-69.
ApiOutcomeCorrect ==
    \A k \in DOMAIN s.calls : LET c == s.calls[k] IN
       /\ c.outcome = "event" => c.selected /\ c.scan = "zombie"
       /\ c.outcome = "noevent" => c.nohang /\ c.scan = "live" /\ ~c.selected
       /\ c.outcome = "ECHILD" => c.scan = "absent" /\ ~c.selected
       /\ ~c.outputWritten => c.out = BlankOutput(c.api)
       /\ c.pc = "done" =>
          /\ c.outcome /= "pending"
          /\ (c.outcome = "event") <=> c.outputWritten
          /\ c.ret = CASE c.outcome = "ECHILD" -> -10
                     [] c.outcome = "noevent" -> 0
                     [] OTHER -> IF c.api = "wait4" THEN ChildPid ELSE 0

\* Structural checks target generation mistakes as well as source projection.
QueueEntriesValid ==
    /\ \A i \in 1..Len(s.queue) : s.calls[s.queue[i]].created
    /\ \A k \in DOMAIN s.calls : s.calls[k].closed => s.calls[k].token
    /\ \A t \in Threads : s.signalReg[t] /= NoCall =>
          s.calls[s.signalReg[t]].created /\ ~s.calls[s.signalReg[t]].closed
    /\ \A t \in Threads : s.rqHeld[t] => At(t, "dequeue")
    /\ ~s.pidPresent => ~s.childPresent
    /\ s.exitPc \in {"wake", "unpark", "wakeFinish"} => s.wakeTarget /= NoCall

\* S3 progress obligations. Quantifiers range over invocation identities, so
\* starting a later call cannot erase an earlier call's completion obligation.
Completed(k) == k \in DOMAIN s.calls /\ s.calls[k].pc = "done"
BlockingWaitCompletes ==
    \A t \in Threads : \A n \in Nat \ {0} :
       (<<t,n>> \in DOMAIN s.calls /\ ~s.calls[<<t,n>>].nohang /\ s.zombie)
       ~> Completed(<<t,n>>)
PairEligible(a, b) ==
    /\ a \in DOMAIN s.calls /\ b \in DOMAIN s.calls /\ a[1] /= b[1]
    /\ s.childPresent /\ s.claims = {}
    /\ \A k \in {a,b} : ~s.calls[k].nowait /\ ~s.calls[k].nohang
         /\ s.calls[k].beganWithChild /\ s.calls[k].pc /= "done"
PairCompleted(a, b) ==
    /\ Completed(a) /\ Completed(b)
    /\ {s.calls[a].outcome, s.calls[b].outcome} = {"event", "ECHILD"}
    /\ Cardinality(s.claims \cap {a,b}) = 1
CompetingConsumersComplete ==
    \A a \in Threads \X (Nat \ {0}) : \A b \in Threads \X (Nat \ {0}) :
       PairEligible(a,b) ~> PairCompleted(a,b)

=============================================================================
