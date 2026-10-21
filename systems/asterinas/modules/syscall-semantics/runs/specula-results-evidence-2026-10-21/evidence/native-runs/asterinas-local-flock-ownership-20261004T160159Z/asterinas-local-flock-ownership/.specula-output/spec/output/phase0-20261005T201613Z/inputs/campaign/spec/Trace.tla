------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

(* Category B timeboxes. The input is one preprocessed JSON object on one
   NDJSON line, with a separate ordered event array for every thread. Raw
   per-thread NDJSON remains evidence alongside that lossless preprocessing. *)
JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
            ELSE "../traces/trace.ndjson"
TraceData == JsonDeserialize(JsonFile)
AsSet(xs) == {xs[i] : i \in 1..Len(xs)}
TraceThreads == AsSet(TraceData.threads)
TraceOFDs == AsSet(TraceData.ofds)
TraceFDs == AsSet(TraceData.fds)
TraceTokens == AsSet(TraceData.tokens)
TraceShared == TraceData.sharedTable
\* JSON object keys are strings. Identity values use positive integers so
\* TLC can compare them with the base's zero sentinel without a type error.
traces == [t \in TraceThreads |-> TraceData.traces[ToString(t)]]

VARIABLE l
traceVars == <<vars, l>>
ThreadsWithEvents == {t \in Threads : l[t] <= Len(traces[t])}
ViablePIDs ==
    {t \in ThreadsWithEvents : ~\E u \in ThreadsWithEvents :
        /\ u /= t
        /\ traces[u][l[u]].end < traces[t][l[t]].start}

(* Source mappings for the following snapshots are in the action comments
   in base.tla and the 1:1 instrumentation table. They check recorded atomic
   outcomes/local continuation fields, not later unsynchronized rereads. *)
RefPost(o) == [ofd |-> o, strong |-> s'.refs[o], life |-> s'.life[o]]
FDPost(f) == [fd |-> f, owner |-> s'.fdOwner[f]]
QueuePost(q) == [id |-> q, entries |-> s'.queues[q]]
WakerPost(q) == [id |-> q, tid |-> s'.waker[q].tid,
                 notified |-> s'.waker[q].notified,
                 closed |-> s'.waker[q].closed]
RQPost(q) == [id |-> q, owner |-> s'.rqLock[s.waker[q].tid],
              runnable |-> s'.runnable[s.waker[q].tid]]

\* Every event includes the acting thread's complete local projection.
\* The exact record equality below rejects missing and unchecked extra fields.
PostState(t, e) ==
    [thread |-> s'.th[t]] @@
    CASE e.event = "SysOpen" -> [ref |-> RefPost(e.args.ofd)]
      [] e.event = "FileTableInsert" ->
            [fd |-> FDPost(e.args.fd), ref |-> RefPost(s.th[t].pending)]
      [] e.event = "ArcPutOpen" -> [ref |-> RefPost(s.th[t].pending)]
      [] e.event = "SysDup" ->
            [fd |-> FDPost(e.args.newfd), ref |-> RefPost(s.fdOwner[e.args.fd])]
      [] e.event = "SysClose" ->
            [fd |-> FDPost(e.args.fd), tableOwner |-> s'.tableOwner]
      [] e.event = "CloseFileTableUnlock" -> [tableOwner |-> s'.tableOwner]
      [] e.event = "ClosedFileDrop" -> [ref |-> RefPost(s.th[t].pending)]
      [] e.event = "GetFileFast" -> [ref |-> RefPost(s'.th[t].request)]
      [] e.event = "FlockItemNew" -> [token |-> e.args.q, fresh |-> e.args.q \in s'.used]
      [] e.event = "FsLockContextOrInit" -> [context |-> s'.context]
      [] e.event \in {"WaiterNewPair", "WaiterClose"} ->
            [waker |-> WakerPost(s.th[t].rid)]
      [] e.event \in {"TrySetLockAcquire", "TrySetLockUnlock",
                      "FlockListUnlockAcquire", "FlockListUnlockRelease"} ->
            [listOwner |-> s'.listOwner]
      [] e.event = "TrySetLockNonblockingConflict" ->
            [blocker |-> s.items[FirstConflict(t)]]
      [] e.event = "TrySetLockRegister" ->
            [blocker |-> s.items[FirstConflict(t)],
             queue |-> QueuePost(s.items[FirstConflict(t)].q)]
      [] e.event \in {"TrySetLockAppend", "TrySetLockInstall",
                      "FlockItemDropRemoved"} -> [items |-> s'.items]
      [] e.event = "WakerDoWait" ->
            [waker |-> WakerPost(s.th[t].rid),
             consumed |-> s.waker[s.th[t].rid].notified]
      [] e.event = "SchedulerParkCheck" ->
            [rq |-> RQPost(s.th[t].rid),
             sawNotification |-> s.waker[s.th[t].rid].notified]
      [] e.event \in {"SchedulerParkCommit", "SchedulerParkAbort"} ->
            [rq |-> RQPost(s.th[t].rid)]
      [] e.event = "WaitQueuePop" -> [queue |-> QueuePost(s.th[t].drainQ)]
      [] e.event = "WakerWakeUp" ->
            [waker |-> WakerPost(s.th[t].popped),
             accepted |-> ~s.waker[s.th[t].popped].notified]
      [] e.event = "SchedulerUnpark" -> [rq |-> RQPost(s.th[t].popped)]
      [] e.event = "FlockListUnlockEnter" -> [selfHeld |-> s'.listOwner = t]
      [] e.event = "FlockOwnerUpgrade" -> [ref |-> RefPost(s'.th[t].temp)]
      [] e.event = "FlockOwnerExpired" ->
            [ref |-> [ofd |-> s.items[s.th[t].scan].owner,
                      strong |-> s'.refs[s.items[s.th[t].scan].owner]]]
      [] e.event = "ArcPutTemporary" -> [ref |-> RefPost(s.th[t].temp)]
      [] e.event = "ArcPutSyscall" -> [ref |-> RefPost(s.th[t].request)]
      [] e.event = "InodeHandleDropFinish" -> [ref |-> RefPost(s.th[t].dtor)]
      [] OTHER -> [x \in {} |-> x]
ValidatePostState(t, e) == e.state = PostState(t, e)

\* Dispatch always invokes the full base action, including every guard.
CallBase(t, e) ==
    CASE e.event = "SysOpen" ->
            /\ DOMAIN e.args = {"ofd"} /\ e.args.ofd \in OFDs
            /\ SysOpen(t, e.args.ofd)
      [] e.event = "FileTableInsert" ->
            /\ DOMAIN e.args = {"fd"} /\ e.args.fd \in FDs
            /\ FileTableInsert(t, e.args.fd)
      [] e.event = "SysDup" ->
            /\ DOMAIN e.args = {"fd", "newfd"}
            /\ e.args.fd \in FDs /\ e.args.newfd \in FDs
            /\ SysDup(t, e.args.fd, e.args.newfd)
      [] e.event = "SysClose" ->
            /\ DOMAIN e.args = {"fd"} /\ e.args.fd \in FDs
            /\ SysClose(t, e.args.fd)
      [] e.event = "SysFlock" ->
            /\ DOMAIN e.args = {"fd", "mode", "nb"}
            /\ e.args.fd \in FDs
            /\ SysFlock(t, e.args.fd, e.args.mode, e.args.nb)
      [] e.event = "FlockItemNew" ->
            /\ DOMAIN e.args = {"q"} /\ e.args.q \in Tokens
            /\ FlockItemNew(t, e.args.q)
      [] e.event = "CloseFileTableUnlock" -> /\ DOMAIN e.args = {} /\ CloseFileTableUnlock(t)
      [] e.event = "ArcPutOpen" -> /\ DOMAIN e.args = {} /\ ArcPutOpen(t)
      [] e.event = "SysOpenReturn" -> /\ DOMAIN e.args = {} /\ SysOpenReturn(t)
      [] e.event = "ClosedFileDrop" -> /\ DOMAIN e.args = {} /\ ClosedFileDrop(t)
      [] e.event = "SysCloseReturn" -> /\ DOMAIN e.args = {} /\ SysCloseReturn(t)
      [] e.event = "GetFileFast" -> /\ DOMAIN e.args = {} /\ GetFileFast(t)
      [] e.event = "GetFileFastBadFd" -> /\ DOMAIN e.args = {} /\ GetFileFastBadFd(t)
      [] e.event = "UnlockFlock" -> /\ DOMAIN e.args = {} /\ UnlockFlock(t)
      [] e.event = "FsLockContextOrInit" -> /\ DOMAIN e.args = {} /\ FsLockContextOrInit(t)
      [] e.event = "WaiterNewPair" -> /\ DOMAIN e.args = {} /\ WaiterNewPair(t)
      [] e.event = "TrySetLockEnter" -> /\ DOMAIN e.args = {} /\ TrySetLockEnter(t)
      [] e.event = "TrySetLockAcquire" -> /\ DOMAIN e.args = {} /\ TrySetLockAcquire(t)
      [] e.event = "TrySetLockNonblockingConflict" -> /\ DOMAIN e.args = {} /\ TrySetLockNonblockingConflict(t)
      [] e.event = "TrySetLockRegister" -> /\ DOMAIN e.args = {} /\ TrySetLockRegister(t)
      [] e.event = "TrySetLockReplace" -> /\ DOMAIN e.args = {} /\ TrySetLockReplace(t)
      [] e.event = "TrySetLockAppend" -> /\ DOMAIN e.args = {} /\ TrySetLockAppend(t)
      [] e.event = "TrySetLockInstall" -> /\ DOMAIN e.args = {} /\ TrySetLockInstall(t)
      [] e.event = "TrySetLockUnlock" -> /\ DOMAIN e.args = {} /\ TrySetLockUnlock(t)
      [] e.event = "WakerDoWait" -> /\ DOMAIN e.args = {} /\ WakerDoWait(t)
      [] e.event = "SchedulerParkCheck" -> /\ DOMAIN e.args = {} /\ SchedulerParkCheck(t)
      [] e.event = "SchedulerParkCommit" -> /\ DOMAIN e.args = {} /\ SchedulerParkCommit(t)
      [] e.event = "SchedulerParkAbort" -> /\ DOMAIN e.args = {} /\ SchedulerParkAbort(t)
      [] e.event = "SchedulerResume" -> /\ DOMAIN e.args = {} /\ SchedulerResume(t)
      [] e.event = "WaiterClose" -> /\ DOMAIN e.args = {} /\ WaiterClose(t)
      [] e.event = "FlockItemDropRequest" -> /\ DOMAIN e.args = {} /\ FlockItemDropRequest(t)
      [] e.event = "WaitQueuePop" -> /\ DOMAIN e.args = {} /\ WaitQueuePop(t)
      [] e.event = "WakerWakeUp" -> /\ DOMAIN e.args = {} /\ WakerWakeUp(t)
      [] e.event = "SchedulerUnpark" -> /\ DOMAIN e.args = {} /\ SchedulerUnpark(t)
      [] e.event = "WaitQueueFinish" -> /\ DOMAIN e.args = {} /\ WaitQueueFinish(t)
      [] e.event = "FlockListUnlockEnter" -> /\ DOMAIN e.args = {} /\ FlockListUnlockEnter(t)
      [] e.event = "FlockListUnlockAcquire" -> /\ DOMAIN e.args = {} /\ FlockListUnlockAcquire(t)
      [] e.event = "FlockOwnerUpgrade" -> /\ DOMAIN e.args = {} /\ FlockOwnerUpgrade(t)
      [] e.event = "FlockOwnerExpired" -> /\ DOMAIN e.args = {} /\ FlockOwnerExpired(t)
      [] e.event = "FlockOwnerMatch" -> /\ DOMAIN e.args = {} /\ FlockOwnerMatch(t)
      [] e.event = "FlockOwnerKeep" -> /\ DOMAIN e.args = {} /\ FlockOwnerKeep(t)
      [] e.event = "ArcPutTemporary" -> /\ DOMAIN e.args = {} /\ ArcPutTemporary(t)
      [] e.event = "FlockRetainContinue" -> /\ DOMAIN e.args = {} /\ FlockRetainContinue(t)
      [] e.event = "FlockItemDropRemoved" -> /\ DOMAIN e.args = {} /\ FlockItemDropRemoved(t)
      [] e.event = "FlockListUnlockRelease" -> /\ DOMAIN e.args = {} /\ FlockListUnlockRelease(t)
      [] e.event = "ArcPutSyscall" -> /\ DOMAIN e.args = {} /\ ArcPutSyscall(t)
      [] e.event = "InodeHandleDropEnter" -> /\ DOMAIN e.args = {} /\ InodeHandleDropEnter(t)
      [] e.event = "InodeHandleDropFinish" -> /\ DOMAIN e.args = {} /\ InodeHandleDropFinish(t)
      [] e.event = "SysFlockReturn" -> /\ DOMAIN e.args = {} /\ SysFlockReturn(t)
      [] OTHER -> FALSE

MatchEvent(t, e) ==
    /\ DOMAIN e = {"tag", "event", "tid", "inode", "start", "end", "args", "state"}
    /\ e.tag = "trace" /\ e.tid = t /\ e.inode = TraceData.inode
    /\ e.start \in Nat /\ e.end \in Nat /\ e.start <= e.end
    /\ CallBase(t, e)
    /\ ValidatePostState(t, e)
TraceInit ==
    /\ TraceData.schema = 1
    /\ TraceData.source = "0c60537098f4c2949ad2d382aaf499de72263d76"
    /\ DOMAIN TraceData.traces = {ToString(t) : t \in Threads}
    /\ (TraceData.concurrent => TraceData.smp >= 2)
    /\ Init
    /\ l = [t \in Threads |-> 1]
Consume ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in ViablePIDs :
        /\ MatchEvent(t, traces[t][l[t]])
        /\ l' = [l EXCEPT ![t] = @ + 1]
\* Every boundary is instrumented. There are no unobserved silent actions.
TraceNext == Consume \/ (ThreadsWithEvents = {} /\ UNCHANGED traceVars)
TraceSpec == TraceInit /\ [][TraceNext]_traceVars
TraceFullyConsumed == ThreadsWithEvents = {}
\* A counterexample to this search invariant is a complete matching witness.
\* Exhaustion without a witness rejects the trace. See validate_trace.py.
TraceNoWitness == ~TraceFullyConsumed
=============================================================================
