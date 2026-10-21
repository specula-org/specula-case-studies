------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category B: one preprocessed JSON object, conventionally a one-line .ndjson
\* file, containing per-actor arrays. Raw per-thread NDJSON is not this input.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
TraceData == JsonDeserialize(JsonFile)
traces == TraceData.traces
TraceThreads == {TraceData.waiters[i] : i \in 1..Len(TraceData.waiters)}
TraceChildPid == TraceData.child_pid
TraceChildUid == TraceData.child_uid
TraceExitValues == {TraceData.exit_value}

VARIABLE cursor
tracevars == <<s, cursor>>
Actors == Threads \cup {"child"}
Remaining(st) == SelectSeq(TraceData.waiters, LAMBDA t : t \in st.notifyTodo)
SyscallOptions(r) == (IF r.api = "waitid" THEN 4 ELSE 0)
                    + (IF r.nohang THEN 1 ELSE 0)
                    + (IF r.nowait THEN 16777216 ELSE 0)

ThreadEvents == {"SysWaitBegin",
                 "TryWaitChildrenLock",
                 "TryWaitChildrenMatch",
                 "TryWaitChildrenZombie",
                 "TryWaitChildrenRetain",
                 "ReapZombieChildRemove",
                 "ReapZombieChildPidRemove",
                 "ReapZombieChildFinish",
                 "TryWaitChildrenUnlock",
                 "DoWaitFound",
                 "DoWaitNoMatch",
                 "DoWaitNoHang",
                 "DoWaitPending",
                 "WaiterNewPair",
                 "SetSignalledWaker",
                 "WaitQueueEnqueue",
                 "PauseCheckCancellation",
                 "WakerConsumeToken",
                 "ParkCurrentCheck",
                 "ParkCurrentDequeue",
                 "ParkCurrentResume",
                 "ParkCurrentSpurious",
                 "ClearSignalledWaker",
                 "WaiterClose",
                 "SysWait4ReadStatus",
                 "SysWaitidReadStatus",
                 "SysWaitCopyout",
                 "WaitStatusDrop",
                 "SysWaitReturn"}
ExitEvents == {"ProcessStoreExitCode",
               "ProcessPublishZombie",
               "ProcessEnqueueSignal",
               "WakeSignalledWakerNone",
               "WakeSignalledWakerGet",
               "ProcessSignalLoopDone",
               "WakerWakeUp",
               "SchedulerUnparkTarget",
               "WakerWakeFinish",
               "WaitQueueWakeAllCheck",
               "WaitQueueWakeAllPop",
               "WaitQueueWakeAllDone"}

ArgsKeys(event) ==
    CASE event = "SysWaitBegin" -> {"call", "request", "pid", "which", "options", "rusage", "buffer", "initial"}
      [] event = "TryWaitChildrenLock" -> {"call"}
      [] event = "TryWaitChildrenMatch" -> {"call"}
      [] event = "TryWaitChildrenZombie" -> {"call"}
      [] event = "TryWaitChildrenRetain" -> {"call"}
      [] event = "ReapZombieChildRemove" -> {"call"}
      [] event = "ReapZombieChildPidRemove" -> {"call"}
      [] event = "ReapZombieChildFinish" -> {"call"}
      [] event = "TryWaitChildrenUnlock" -> {"call"}
      [] event = "DoWaitFound" -> {"call"}
      [] event = "DoWaitNoMatch" -> {"call"}
      [] event = "DoWaitNoHang" -> {"call"}
      [] event = "DoWaitPending" -> {"call"}
      [] event = "WaiterNewPair" -> {"call"}
      [] event = "SetSignalledWaker" -> {"call"}
      [] event = "WaitQueueEnqueue" -> {"call"}
      [] event = "PauseCheckCancellation" -> {"call"}
      [] event = "WakerConsumeToken" -> {"call"}
      [] event = "ParkCurrentCheck" -> {"call"}
      [] event = "ParkCurrentDequeue" -> {"call"}
      [] event = "ParkCurrentResume" -> {"call"}
      [] event = "ParkCurrentSpurious" -> {"call"}
      [] event = "ClearSignalledWaker" -> {"call"}
      [] event = "WaiterClose" -> {"call"}
      [] event = "SysWait4ReadStatus" -> {"call"}
      [] event = "SysWaitidReadStatus" -> {"call"}
      [] event = "SysWaitCopyout" -> {"call"}
      [] event = "WaitStatusDrop" -> {"call"}
      [] event = "SysWaitReturn" -> {"call"}
      [] event = "ProcessStoreExitCode" -> {"call", "value"}
      [] event = "ProcessPublishZombie" -> {"call"}
      [] event = "ProcessEnqueueSignal" -> {"call"}
      [] event = "WakeSignalledWakerNone" -> {"call", "thread"}
      [] event = "WakeSignalledWakerGet" -> {"call", "thread"}
      [] event = "ProcessSignalLoopDone" -> {"call"}
      [] event = "WakerWakeUp" -> {"call"}
      [] event = "SchedulerUnparkTarget" -> {"call"}
      [] event = "WakerWakeFinish" -> {"call"}
      [] event = "WaitQueueWakeAllCheck" -> {"call"}
      [] event = "WaitQueueWakeAllPop" -> {"call"}
      [] event = "WaitQueueWakeAllDone" -> {"call"}
      [] OTHER -> {}

\* Metadata states the fixture preconditions. Binary, ABI, and source hashes
\* must also be authenticated in the collection manifest by the harness worker.
MetadataOK ==
    /\ TraceData.schema = "asterinas-wait-reap-timebox-v1"
    /\ TraceData.source = "0c60537098f4c2949ad2d382aaf499de72263d76"
    /\ TraceData.waiters \in Seq(STRING)
    /\ Len(TraceData.waiters) = 2 /\ Cardinality(Threads) = 2
    /\ "child" \notin Threads /\ NoThread \notin Threads
    /\ ChildPid > 0 /\ ChildUid >= 0 /\ TraceData.exit_value \in 0..255
    /\ TraceData.smp \in Nat \ {0} /\ TraceData.concurrent \in BOOLEAN
    /\ (TraceData.concurrent => TraceData.smp >= 2)
    /\ TraceData.sigchld = "SIG_DFL" /\ TraceData.sa_nocldwait = FALSE
    /\ TraceData.sigchld_blocked = TRUE
    /\ TraceData.valid_buffers = TRUE /\ TraceData.rusage_null = TRUE
    /\ DOMAIN TraceData.buffers = Threads
    /\ \A t \in Threads : TraceData.buffers[t] \in Nat \ {0}
    /\ \A a,b \in Threads : a /= b =>
         (TraceData.buffers[a] >= TraceData.buffers[b] + 128 \/
          TraceData.buffers[b] >= TraceData.buffers[a] + 128)

TraceShapeOK ==
    /\ DOMAIN traces = Actors
    /\ \E a \in Actors : Len(traces[a]) > 0
    /\ \A a \in Actors : \A i \in 1..Len(traces[a]) :
         LET e == traces[a][i] IN
         /\ DOMAIN e = {"tag", "actor", "event", "start", "end", "args", "post"}
         /\ e.tag = "trace" /\ e.actor = a
         /\ e.event \in (IF a \in Threads THEN ThreadEvents ELSE ExitEvents)
         /\ e.start \in Nat /\ e.end \in Nat /\ e.start <= e.end
         /\ DOMAIN e.args = ArgsKeys(e.event)
         /\ (IF i = 1 THEN TRUE ELSE traces[a][i-1].end <= e.start)

ThreadsWithEvents == {a \in Actors : cursor[a] <= Len(traces[a])}
ViablePIDs ==
    {a \in ThreadsWithEvents :
       ~\E b \in ThreadsWithEvents :
          b /= a /\ traces[b][cursor[b]].end < traces[a][cursor[a]].start}

\* Every captured argument is checked. Invocation and waker identities are
\* generation pairs, never raw pointer equality across allocator reuse.
ValidateArguments(e) ==
    CASE e.event = "SysWaitBegin" ->
         /\ e.args.call = <<e.actor, s.current[e.actor] + 1>>
         /\ e.args.request \in ValidRequests
         /\ e.args.pid = ChildPid
         /\ e.args.which = (IF e.args.request.api = "waitid" THEN 1 ELSE 0)
         /\ e.args.options = SyscallOptions(e.args.request)
         /\ e.args.rusage = 0
         /\ e.args.buffer = TraceData.buffers[e.actor]
         /\ e.args.initial = BlankOutput(e.args.request.api)
      [] e.event \in ThreadEvents -> e.args.call = Key(e.actor)
      [] e.event = "ProcessStoreExitCode" ->
         e.args.call = NoCall /\ e.args.value \in ExitValues
      [] e.event = "WakeSignalledWakerGet" ->
         e.args.thread \in Threads /\ e.args.call = s.signalReg[e.args.thread]
      [] e.event = "WakeSignalledWakerNone" ->
         e.args.thread \in Threads /\ e.args.call = NoCall
      [] e.event \in {"WakerWakeUp", "SchedulerUnparkTarget", "WakerWakeFinish"} ->
         e.args.call = s.wakeTarget
      [] e.event = "WaitQueueWakeAllPop" -> e.args.call = Head(s.queue)
      [] OTHER -> e.args.call = NoCall

\* Exact record equality makes missing, extra, and mismatched post-state fields
\* fail validation. History predicates are computed by the base actions.
\* Atomic return values are checked against pre-state as well as the new token.
ExpectedPost(e) ==
    CASE e.event = "SysWaitBegin" ->
         \* syscall/wait4.rs:18-36; syscall/waitid.rs:29-43.
         [pc |-> s'.calls[e.args.call].pc,
          current |-> s'.current[e.actor],
          api |-> s'.calls[e.args.call].api,
          nohang |-> s'.calls[e.args.call].nohang,
          nowait |-> s'.calls[e.args.call].nowait,
          out |-> s'.calls[e.args.call].out]
      [] e.event = "TryWaitChildrenLock" ->
         \* process/wait.rs:293; ostd/src/sync/mutex.rs:62-65.
         [pc |-> s'.calls[e.args.call].pc,
          childrenOwner |-> s'.childrenOwner]
      [] e.event = "TryWaitChildrenMatch" ->
         \* process/wait.rs:296-304,335.
         [pc |-> s'.calls[e.args.call].pc,
          scan |-> s'.calls[e.args.call].scan,
          childPresent |-> s'.childPresent]
      [] e.event = "TryWaitChildrenZombie" ->
         \* process/wait.rs:310; process/status.rs:41-43.
         [pc |-> s'.calls[e.args.call].pc,
          scan |-> s'.calls[e.args.call].scan,
          acquired |-> s'.calls[e.args.call].acquired]
      [] e.event = "TryWaitChildrenRetain" ->
         \* process/wait.rs:311-319.
         [pc |-> s'.calls[e.args.call].pc,
          selected |-> s'.calls[e.args.call].selected,
          selectedPid |-> s'.calls[e.args.call].selectedPid,
          selectedPresent |-> s'.calls[e.args.call].selectedPresent,
          retained |-> s'.calls[e.args.call].retained]
      [] e.event = "ReapZombieChildRemove" ->
         \* process/wait.rs:344-345.
         [pc |-> s'.calls[e.args.call].pc,
          childPresent |-> s'.childPresent,
          claimed |-> e.args.call \in s'.claims]
      [] e.event = "ReapZombieChildPidRemove" ->
         \* process/wait.rs:363; process/pid_table.rs:148-166.
         [pc |-> s'.calls[e.args.call].pc,
          pidPresent |-> s'.pidPresent]
      [] e.event = "ReapZombieChildFinish" ->
         \* process/wait.rs:365-374.
         [pc |-> s'.calls[e.args.call].pc]
      [] e.event = "TryWaitChildrenUnlock" ->
         \* process/wait.rs:319,335; ostd/src/sync/mutex.rs:56-69.
         [pc |-> s'.calls[e.args.call].pc,
          childrenOwner |-> s'.childrenOwner]
      [] e.event = "DoWaitFound" ->
         \* process/wait.rs:75-76.
         [pc |-> s'.calls[e.args.call].pc,
          outcome |-> s'.calls[e.args.call].outcome]
      [] e.event = "DoWaitNoMatch" ->
         \* process/wait.rs:78-85.
         [pc |-> s'.calls[e.args.call].pc,
          outcome |-> s'.calls[e.args.call].outcome]
      [] e.event = "DoWaitNoHang" ->
         \* process/wait.rs:77,88-89.
         [pc |-> s'.calls[e.args.call].pc,
          outcome |-> s'.calls[e.args.call].outcome]
      [] e.event = "DoWaitPending" ->
         \* process/wait.rs:99-100; process/signal/pause.rs:235-245.
         [pc |-> s'.calls[e.args.call].pc]
      [] e.event = "WaiterNewPair" ->
         \* process/signal/pause.rs:240; ostd/src/sync/wait.rs:181-189.
         [pc |-> s'.calls[e.args.call].pc,
          created |-> s'.calls[e.args.call].created,
          token |-> s'.calls[e.args.call].token,
          closed |-> s'.calls[e.args.call].closed]
      [] e.event = "SetSignalledWaker" ->
         \* process/signal/pause.rs:164; process/posix_thread/mod.rs:177-180.
         [pc |-> s'.calls[e.args.call].pc,
          signalReg |-> s'.signalReg[e.actor]]
      [] e.event = "WaitQueueEnqueue" ->
         \* process/signal/pause.rs:241-244; ostd/src/sync/wait.rs:145-149.
         [pc |-> s'.calls[e.args.call].pc,
          queue |-> s'.queue,
          queueCount |-> Len(s'.queue)]
      [] e.event = "PauseCheckCancellation" ->
         \* process/signal/pause.rs:149-161; time/wait.rs:184-206.
         [pc |-> s'.calls[e.args.call].pc,
          pendingUnblocked |-> FALSE,
          timerActive |-> FALSE]
      [] e.event = "WakerConsumeToken" ->
         \* ostd/src/sync/wait.rs:273-275.
         [pc |-> s'.calls[e.args.call].pc,
          token |-> s'.calls[e.args.call].token,
          oldToken |-> s.calls[e.args.call].token]
      [] e.event = "ParkCurrentCheck" ->
         \* ostd/src/task/scheduler/mod.rs:453-470; sched/sched_class/mod.rs:255-258.
         [pc |-> s'.calls[e.args.call].pc,
          rqHeld |-> s'.rqHeld[e.actor],
          observedToken |-> s.calls[e.args.call].token]
      [] e.event = "ParkCurrentDequeue" ->
         \* ostd/src/task/scheduler/mod.rs:469-484; sched/sched_class/mod.rs:410-414.
         [pc |-> s'.calls[e.args.call].pc,
          runnable |-> s'.runnable[e.actor],
          rqHeld |-> s'.rqHeld[e.actor]]
      [] e.event = "ParkCurrentResume" ->
         \* ostd/src/task/scheduler/mod.rs:473-482; ostd/src/sync/wait.rs:273-275.
         [pc |-> s'.calls[e.args.call].pc,
          runnable |-> s'.runnable[e.actor]]
      [] e.event = "ParkCurrentSpurious" ->
         \* ostd/src/task/scheduler/mod.rs:441-444.
         [runnable |-> s'.runnable[e.actor]]
      [] e.event = "ClearSignalledWaker" ->
         \* process/signal/pause.rs:166; process/posix_thread/mod.rs:183-185.
         [pc |-> s'.calls[e.args.call].pc,
          signalReg |-> s'.signalReg[e.actor]]
      [] e.event = "WaiterClose" ->
         \* ostd/src/sync/wait.rs:244-248,278-281.
         [pc |-> s'.calls[e.args.call].pc,
          token |-> s'.calls[e.args.call].token,
          closed |-> s'.calls[e.args.call].closed]
      [] e.event = "SysWait4ReadStatus" ->
         \* syscall/wait4.rs:45,63-65; process/status.rs:71-72.
         [pc |-> s'.calls[e.args.call].pc,
          readCode |-> s'.calls[e.args.call].readCode,
          selectedPid |-> s'.calls[e.args.call].selectedPid,
          retained |-> s'.calls[e.args.call].retained]
      [] e.event = "SysWaitidReadStatus" ->
         \* syscall/waitid.rs:55-63,88-90; process/wait.rs:129-143.
         [pc |-> s'.calls[e.args.call].pc,
          readCode |-> s'.calls[e.args.call].readCode,
          selectedPid |-> s'.calls[e.args.call].selectedPid,
          uid |-> ChildUid,
          retained |-> s'.calls[e.args.call].retained]
      [] e.event = "SysWaitCopyout" ->
         \* syscall/wait4.rs:46-47; syscall/waitid.rs:66.
         [pc |-> s'.calls[e.args.call].pc,
          out |-> s'.calls[e.args.call].out,
          outputWritten |-> s'.calls[e.args.call].outputWritten,
          retained |-> s'.calls[e.args.call].retained]
      [] e.event = "WaitStatusDrop" ->
         \* process/wait.rs:120-164; syscall/wait4.rs:60; syscall/waitid.rs:69.
         [pc |-> s'.calls[e.args.call].pc,
          retained |-> s'.calls[e.args.call].retained]
      [] e.event = "SysWaitReturn" ->
         \* syscall/wait4.rs:36-43,60; syscall/waitid.rs:43-50,69.
         [pc |-> s'.calls[e.args.call].pc,
          ret |-> s'.calls[e.args.call].ret,
          libcRet |-> IF s'.calls[e.args.call].ret < 0 THEN -1 ELSE s'.calls[e.args.call].ret,
          errno |-> IF s'.calls[e.args.call].ret < 0 THEN -s'.calls[e.args.call].ret ELSE 0,
          out |-> s'.calls[e.args.call].out]
      [] e.event = "ProcessStoreExitCode" ->
         \* process/posix_thread/exit.rs:53,63-89; process/status.rs:75-77.
         [exitPc |-> s'.exitPc,
          exitValue |-> s'.exitValue,
          storedCode |-> s'.storedCode]
      [] e.event = "ProcessPublishZombie" ->
         \* process/exit.rs:36; process/status.rs:51-53.
         [exitPc |-> s'.exitPc,
          zombie |-> s'.zombie]
      [] e.event = "ProcessEnqueueSignal" ->
         \* process/exit.rs:183-184; process/process/mod.rs:646-648.
         [exitPc |-> s'.exitPc,
          pendingSignal |-> s'.pendingSignal,
          remaining |-> Remaining(s')]
      [] e.event = "WakeSignalledWakerNone" ->
         \* process/process/mod.rs:648-655; process/posix_thread/mod.rs:250-253.
         [exitPc |-> s'.exitPc,
          remaining |-> Remaining(s')]
      [] e.event = "WakeSignalledWakerGet" ->
         \* process/posix_thread/mod.rs:250-253.
         [exitPc |-> s'.exitPc,
          remaining |-> Remaining(s'),
          signalHeld |-> s'.signalHeld,
          wakeTarget |-> s'.wakeTarget,
          wakeChannel |-> s'.wakeChannel]
      [] e.event = "ProcessSignalLoopDone" ->
         \* process/process/mod.rs:648-656; process/exit.rs:184-186.
         [exitPc |-> s'.exitPc]
      [] e.event = "WakerWakeUp" ->
         \* ostd/src/sync/wait.rs:262-268.
         [exitPc |-> s'.exitPc,
          token |-> s'.calls[e.args.call].token,
          oldToken |-> s.calls[e.args.call].token]
      [] e.event = "SchedulerUnparkTarget" ->
         \* ostd/src/task/scheduler/mod.rs:488-494; sched/sched_class/mod.rs:223-250.
         [exitPc |-> s'.exitPc,
          runnable |-> s'.runnable[e.args.call[1]],
          rqHeld |-> s'.rqHeld[e.args.call[1]]]
      [] e.event = "WakerWakeFinish" ->
         \* process/posix_thread/mod.rs:250-253; ostd/src/sync/wait.rs:128-131.
         [exitPc |-> s'.exitPc,
          signalHeld |-> s'.signalHeld,
          wakeTarget |-> s'.wakeTarget,
          wakeChannel |-> s'.wakeChannel]
      [] e.event = "WaitQueueWakeAllCheck" ->
         \* ostd/src/sync/wait.rs:111-115,136-140.
         [exitPc |-> s'.exitPc,
          queueCount |-> Len(s'.queue)]
      [] e.event = "WaitQueueWakeAllPop" ->
         \* ostd/src/sync/wait.rs:119-126.
         [exitPc |-> s'.exitPc,
          queue |-> s'.queue,
          queueCount |-> Len(s'.queue),
          wakeTarget |-> s'.wakeTarget,
          wakeChannel |-> s'.wakeChannel]
      [] e.event = "WaitQueueWakeAllDone" ->
         \* ostd/src/sync/wait.rs:120-123.
         [exitPc |-> s'.exitPc,
          queueCount |-> Len(s'.queue)]
      [] OTHER -> [invalidEvent |-> TRUE]

ValidatePostState(e) == e.post = ExpectedPost(e)

\* Each dispatch arm invokes the full base action. No steps are silent.
BaseAction(e) ==
    CASE e.event = "SysWaitBegin" ->
         \* syscall/wait4.rs:18-36; syscall/waitid.rs:29-43.
         SysWaitBegin(e.actor, e.args.request)
      [] e.event = "TryWaitChildrenLock" ->
         \* process/wait.rs:293; ostd/src/sync/mutex.rs:62-65.
         TryWaitChildrenLock(e.actor)
      [] e.event = "TryWaitChildrenMatch" ->
         \* process/wait.rs:296-304,335.
         TryWaitChildrenMatch(e.actor)
      [] e.event = "TryWaitChildrenZombie" ->
         \* process/wait.rs:310; process/status.rs:41-43.
         TryWaitChildrenZombie(e.actor)
      [] e.event = "TryWaitChildrenRetain" ->
         \* process/wait.rs:311-319.
         TryWaitChildrenRetain(e.actor)
      [] e.event = "ReapZombieChildRemove" ->
         \* process/wait.rs:344-345.
         ReapZombieChildRemove(e.actor)
      [] e.event = "ReapZombieChildPidRemove" ->
         \* process/wait.rs:363; process/pid_table.rs:148-166.
         ReapZombieChildPidRemove(e.actor)
      [] e.event = "ReapZombieChildFinish" ->
         \* process/wait.rs:365-374.
         ReapZombieChildFinish(e.actor)
      [] e.event = "TryWaitChildrenUnlock" ->
         \* process/wait.rs:319,335; ostd/src/sync/mutex.rs:56-69.
         TryWaitChildrenUnlock(e.actor)
      [] e.event = "DoWaitFound" ->
         \* process/wait.rs:75-76.
         DoWaitFound(e.actor)
      [] e.event = "DoWaitNoMatch" ->
         \* process/wait.rs:78-85.
         DoWaitNoMatch(e.actor)
      [] e.event = "DoWaitNoHang" ->
         \* process/wait.rs:77,88-89.
         DoWaitNoHang(e.actor)
      [] e.event = "DoWaitPending" ->
         \* process/wait.rs:99-100; process/signal/pause.rs:235-245.
         DoWaitPending(e.actor)
      [] e.event = "WaiterNewPair" ->
         \* process/signal/pause.rs:240; ostd/src/sync/wait.rs:181-189.
         WaiterNewPair(e.actor)
      [] e.event = "SetSignalledWaker" ->
         \* process/signal/pause.rs:164; process/posix_thread/mod.rs:177-180.
         SetSignalledWaker(e.actor)
      [] e.event = "WaitQueueEnqueue" ->
         \* process/signal/pause.rs:241-244; ostd/src/sync/wait.rs:145-149.
         WaitQueueEnqueue(e.actor)
      [] e.event = "PauseCheckCancellation" ->
         \* process/signal/pause.rs:149-161; time/wait.rs:184-206.
         PauseCheckCancellation(e.actor)
      [] e.event = "WakerConsumeToken" ->
         \* ostd/src/sync/wait.rs:273-275.
         WakerConsumeToken(e.actor)
      [] e.event = "ParkCurrentCheck" ->
         \* ostd/src/task/scheduler/mod.rs:453-470; sched/sched_class/mod.rs:255-258.
         ParkCurrentCheck(e.actor)
      [] e.event = "ParkCurrentDequeue" ->
         \* ostd/src/task/scheduler/mod.rs:469-484; sched/sched_class/mod.rs:410-414.
         ParkCurrentDequeue(e.actor)
      [] e.event = "ParkCurrentResume" ->
         \* ostd/src/task/scheduler/mod.rs:473-482; ostd/src/sync/wait.rs:273-275.
         ParkCurrentResume(e.actor)
      [] e.event = "ParkCurrentSpurious" ->
         \* ostd/src/task/scheduler/mod.rs:441-444.
         ParkCurrentSpurious(e.actor)
      [] e.event = "ClearSignalledWaker" ->
         \* process/signal/pause.rs:166; process/posix_thread/mod.rs:183-185.
         ClearSignalledWaker(e.actor)
      [] e.event = "WaiterClose" ->
         \* ostd/src/sync/wait.rs:244-248,278-281.
         WaiterClose(e.actor)
      [] e.event = "SysWait4ReadStatus" ->
         \* syscall/wait4.rs:45,63-65; process/status.rs:71-72.
         SysWait4ReadStatus(e.actor)
      [] e.event = "SysWaitidReadStatus" ->
         \* syscall/waitid.rs:55-63,88-90; process/wait.rs:129-143.
         SysWaitidReadStatus(e.actor)
      [] e.event = "SysWaitCopyout" ->
         \* syscall/wait4.rs:46-47; syscall/waitid.rs:66.
         SysWaitCopyout(e.actor)
      [] e.event = "WaitStatusDrop" ->
         \* process/wait.rs:120-164; syscall/wait4.rs:60; syscall/waitid.rs:69.
         WaitStatusDrop(e.actor)
      [] e.event = "SysWaitReturn" ->
         \* syscall/wait4.rs:36-43,60; syscall/waitid.rs:43-50,69.
         SysWaitReturn(e.actor)
      [] e.event = "ProcessStoreExitCode" ->
         \* process/posix_thread/exit.rs:53,63-89; process/status.rs:75-77.
         ProcessStoreExitCode(e.args.value)
      [] e.event = "ProcessPublishZombie" ->
         \* process/exit.rs:36; process/status.rs:51-53.
         ProcessPublishZombie
      [] e.event = "ProcessEnqueueSignal" ->
         \* process/exit.rs:183-184; process/process/mod.rs:646-648.
         ProcessEnqueueSignal
      [] e.event = "WakeSignalledWakerNone" ->
         \* process/process/mod.rs:648-655; process/posix_thread/mod.rs:250-253.
         WakeSignalledWakerNone(e.args.thread)
      [] e.event = "WakeSignalledWakerGet" ->
         \* process/posix_thread/mod.rs:250-253.
         WakeSignalledWakerGet(e.args.thread)
      [] e.event = "ProcessSignalLoopDone" ->
         \* process/process/mod.rs:648-656; process/exit.rs:184-186.
         ProcessSignalLoopDone
      [] e.event = "WakerWakeUp" ->
         \* ostd/src/sync/wait.rs:262-268.
         WakerWakeUp
      [] e.event = "SchedulerUnparkTarget" ->
         \* ostd/src/task/scheduler/mod.rs:488-494; sched/sched_class/mod.rs:223-250.
         SchedulerUnparkTarget
      [] e.event = "WakerWakeFinish" ->
         \* process/posix_thread/mod.rs:250-253; ostd/src/sync/wait.rs:128-131.
         WakerWakeFinish
      [] e.event = "WaitQueueWakeAllCheck" ->
         \* ostd/src/sync/wait.rs:111-115,136-140.
         WaitQueueWakeAllCheck
      [] e.event = "WaitQueueWakeAllPop" ->
         \* ostd/src/sync/wait.rs:119-126.
         WaitQueueWakeAllPop
      [] e.event = "WaitQueueWakeAllDone" ->
         \* ostd/src/sync/wait.rs:120-123.
         WaitQueueWakeAllDone
      [] OTHER -> FALSE
MatchEvent(e) ==
    /\ BaseAction(e)
    /\ ValidateArguments(e)
    /\ ValidatePostState(e)

TraceInit ==
    /\ MetadataOK /\ TraceShapeOK /\ Init
    /\ cursor = [a \in Actors |-> 1]
TraceAdvance ==
    /\ ThreadsWithEvents /= {}
    /\ \E a \in ViablePIDs :
         /\ MatchEvent(traces[a][cursor[a]])
         /\ cursor' = [cursor EXCEPT ![a] = @ + 1]
TraceNext ==
    \/ TraceAdvance
    \/ /\ ThreadsWithEvents = {} /\ UNCHANGED tracevars

\* Cursor progress fairness excludes artificial stuttering on a matchable
\* prefix. It imposes no scheduler or protocol liveness on a recorded trace.
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceAdvance)
TraceMatched == <>(ThreadsWithEvents = {})
TraceCursorOK == cursor \in [Actors -> Nat \ {0}]
TraceEndOK ==
    ThreadsWithEvents = {} =>
       /\ s.exitPc = "done" /\ s.childrenOwner = NoThread
       /\ \A k \in DOMAIN s.calls : s.calls[k].pc = "done"
       /\ \A t \in Threads : s.signalReg[t] = NoCall /\ ~s.rqHeld[t]

\* R2: a counterexample to this invariant is a complete matching interleaving.
\* Keep final-state validation in the reachability target as well as the cfg.
TraceComplete == ThreadsWithEvents = {} /\ TraceEndOK
TraceNoCompleteMatch == ~TraceComplete

=============================================================================
