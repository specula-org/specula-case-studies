------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
\* Category B: NDJSON is grouped into per-thread arrays, never replayed in file
\* order across threads. State fields are mandatory, action-specific projections.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
Raw == ndJsonDeserialize(JsonFile)
Manifest == Raw[1]
Events == SubSeq(Raw,2,Len(Raw))
EventPIDs == {Events[i].pid : i \in 1..Len(Events)}
traces == [pid \in EventPIDs |-> SelectSeq(Events,LAMBDA e : e.pid=pid)]

TraceWaitIds == SeqSet(Manifest.wait_ids)
TraceCallIds == SeqSet(Manifest.call_ids)
TraceControllers == SeqSet(Manifest.controllers)
TraceKeys == SeqSet(Manifest.keys)
TraceBuckets == SeqSet(Manifest.buckets)
TraceBucketMap == Manifest.bucket_of
TraceWords == Manifest.initial_words
TraceValues == SeqSet(Manifest.values)
TraceQuotas == SeqSet(Manifest.quotas)
\* v2 JSON objects retain a uniform boolean/integer duration representation.
DecodeDuration(d) == [timed |-> d.timed, ticks |-> d.ticks]
TraceDurations == {DecodeDuration(Manifest.durations[i]) : i \in 1..Len(Manifest.durations)}

VARIABLES l, collection, batchOwners
tracevars == <<s,l,collection,batchOwners>>
EmptyCollection == [pid |-> "", batch |-> 0]
ThreadsWithEvents == {pid \in EventPIDs : l[pid]<=Len(traces[pid])}
Pending(pid) == traces[pid][l[pid]]
\* Only proved cross-thread ordering may narrow these timeboxes. Lock handoffs,
\* same-thread order, and explicit synchronization edges live in deps.
DepsMet(e) == \A i \in 1..Len(e.deps) : l[e.deps[i][1]]>e.deps[i][2]
ViablePIDs ==
    {pid \in ThreadsWithEvents :
        /\ DepsMet(Pending(pid))
        /\ ~\E other \in ThreadsWithEvents :
             other/=pid /\ Pending(other).end<Pending(pid).start}

ArgNames(name) ==
    CASE name="SysFutexWait" -> {"g","k","v","d"}
      [] name="FutexWaitLock" -> {"g"}
      [] name="FutexWaitLoad" -> {"g"}
      [] name="FutexWaitFault" -> {"g"}
      [] name="FutexWaitFaultUnlock" -> {"g"}
      [] name="HandlePageFault" -> {"g"}
      [] name="FutexWaitCompare" -> {"g"}
      [] name="FutexWaitMismatchUnlock" -> {"g"}
      [] name="FutexBucketAddItem" -> {"g"}
      [] name="FutexWaitUnlock" -> {"g"}
      [] name="PauseTimeoutCheck" -> {"g"}
      [] name="TimerSetTimeout" -> {"g"}
      [] name="WakerDoWait" -> {"g"}
      [] name="WaiterPark" -> {"g"}
      [] name="PauseTimeoutTimerLock" -> {"g"}
      [] name="PauseTimeoutNoTimer" -> {"g"}
      [] name="PauseTimeoutRemain" -> {"g"}
      [] name="TimerCancel" -> {"g"}
      [] name="PauseTimeoutTimerUnlock" -> {"g"}
      [] name="PauseTimeoutTimerDrop" -> {"g"}
      [] name="TimerCollect" -> {"g","batch"}
      [] name="TimerCallbackUpgrade" -> {"g","batch"}
      [] name="TimerCallbackLock" -> {"g","batch"}
      [] name="TimerCallbackCheck" -> {"g","batch"}
      [] name="TimerCallbackWake" -> {"g","batch"}
      [] name="TimerCallbackUnpark" -> {"g","batch"}
      [] name="TimerCallbackFinish" -> {"g","batch"}
      [] name="FutexCleanupLock" -> {"g"}
      [] name="FutexRemoveByWaker" -> {"g"}
      [] name="FutexCleanupUnlock" -> {"g"}
      [] name="FutexWaitDecide" -> {"g"}
      [] name="WaiterDrop" -> {"g"}
      [] name="SysFutexWaitReturn" -> {"g"}
      [] name="SysFutexControl" -> {"c","a","kind","src","dst","nw","nm"}
      [] name="LockBucketPairsFirst" -> {"c"}
      [] name="LockBucketPairsSecond" -> {"c"}
      [] name="FutexWakeStart" -> {"c"}
      [] name="FutexItemWake" -> {"c","g","attempted"}
      [] name="FutexWakeUnpark" -> {"c","g"}
      [] name="FutexWakeRetain" -> {"c","g"}
      [] name="FutexWakeEnd" -> {"c"}
      [] name="FutexUpdateItemKey" -> {"c","g"}
      [] name="FutexExtractItem" -> {"c","g"}
      [] name="FutexExtractedKey" -> {"c","g"}
      [] name="FutexAppendExtracted" -> {"c","g"}
      [] name="FutexMoveEnd" -> {"c"}
      [] name="FutexRequeueFinish" -> {"c"}
      [] name="FutexReleaseDest" -> {"c"}
      [] name="FutexReleaseSource" -> {"c"}
      [] name="SysFutexControlReturn" -> {"c"}
      [] name="UserStore" -> {"k","v"}
      [] name="TimerSetClock" -> {"g","t"}
      [] name="PauseTimeoutClock" -> {"g","t"}
      [] name="WaiterSpuriousReturn" -> {"g"}
      [] name="TimerCollectClock" -> {"t","batch"}
      [] name="TimerCollectEnd" -> {"batch"}
      [] name="ClockAdvance" -> {"t"}
      [] OTHER -> {}

InputOK ==
    /\ Manifest.tag="manifest" /\ Manifest.schema="private-futex-v3"
    /\ Manifest.source="0c60537098f4c2949ad2d382aaf499de72263d76"
    /\ Manifest.tree="4693fdec88cd7da14bed4f1541eba593f123059c"
    /\ Manifest.cpu_count>=2 /\ Manifest.complete_attempt
    /\ \A i \in 1..Len(Manifest.durations) :
         /\ DOMAIN Manifest.durations[i]={"timed","ticks"}
         /\ Manifest.durations[i].timed \in BOOLEAN
         /\ Manifest.durations[i].ticks \in Nat
         /\ (~Manifest.durations[i].timed => Manifest.durations[i].ticks=0)
    /\ Len(Events)>0
    /\ \A pid \in EventPIDs : \A i \in 1..Len(traces[pid]) :
         LET e==traces[pid][i] IN
         /\ e.tag="trace" /\ e.seq=i /\ e.start<=e.end
         /\ e.cpu \in 0..(Manifest.cpu_count-1)
         /\ ArgNames(e.event)/={} /\ DOMAIN e.args=ArgNames(e.event)
         /\ \A j \in 1..Len(e.deps) :
              /\ e.deps[j][1] \in EventPIDs
              /\ e.deps[j][2] \in 1..Len(traces[e.deps[j][1]])
ASSUME InputOK

WaitPost(e,z) ==
    LET g==e.args.g w==z.w[g] en==z.e[g] tm==z.tm[g] b==w.original IN
    CASE e.event="SysFutexWait" -> [pc |-> w.pc, key |-> w.key, original |-> w.original, expected |-> w.expected, duration |-> w.duration, entryKey |-> en.key, owner |-> en.owner]
      [] e.event="FutexWaitLock" -> [pc |-> w.pc, bucket |-> b, lockOwner |-> z.locks[b]]
      [] e.event="FutexWaitLoad" -> [pc |-> w.pc, observed |-> w.observed]
      [] e.event="FutexWaitFault" -> [pc |-> w.pc]
      [] e.event="FutexWaitFaultUnlock" -> [pc |-> w.pc, bucket |-> b, lockOwner |-> z.locks[b]]
      [] e.event="HandlePageFault" -> [pc |-> w.pc]
      [] e.event="FutexWaitCompare" -> [pc |-> w.pc, observed |-> w.observed, result |-> w.result]
      [] e.event="FutexWaitMismatchUnlock" -> [pc |-> w.pc, bucket |-> b, lockOwner |-> z.locks[b], owner |-> en.owner]
      [] e.event="FutexBucketAddItem" -> [pc |-> w.pc, bucket |-> b, queue |-> z.q[b], owner |-> en.owner]
      [] e.event="FutexWaitUnlock" -> [pc |-> w.pc, bucket |-> b, lockOwner |-> z.locks[b]]
      [] e.event="PauseTimeoutCheck" -> [pc |-> w.pc, pause |-> w.pause, timerState |-> tm.state, deadline |-> tm.deadline]
      [] e.event="TimerSetClock" -> [pc |-> w.pc, sample |-> w.sample, now |-> z.now]
      [] e.event="TimerSetTimeout" -> [pc |-> w.pc, timerState |-> tm.state, deadline |-> tm.deadline, localRef |-> tm.localRef, sample |-> w.sample]
      [] e.event="WakerDoWait" -> [pc |-> w.pc, flagWritten |-> w.hasWoken]
      [] e.event="WaiterPark" -> [pc |-> w.pc]
      [] e.event="WaiterSpuriousReturn" -> [pc |-> w.pc]
      [] e.event="PauseTimeoutTimerLock" -> [pc |-> w.pc, timerLock |-> tm.lock]
      [] e.event="PauseTimeoutNoTimer" -> [pc |-> w.pc, pause |-> w.pause]
      [] e.event="PauseTimeoutClock" -> [pc |-> w.pc, sample |-> w.sample, now |-> z.now]
      [] e.event="PauseTimeoutRemain" -> [pc |-> w.pc, pause |-> w.pause, sample |-> w.sample]
      [] e.event="TimerCancel" -> [pc |-> w.pc, cancelled |-> tm.cancelled, timerState |-> tm.state]
      [] e.event="PauseTimeoutTimerUnlock" -> [pc |-> w.pc, timerLock |-> tm.lock]
      [] e.event="PauseTimeoutTimerDrop" -> [pc |-> w.pc, localRef |-> tm.localRef]
      [] e.event="TimerCollect" -> [callback |-> tm.cb, timerState |-> tm.state, sample |-> z.collect.sample, ready |-> z.collect.ready]
      [] e.event="TimerCallbackUpgrade" -> [callback |-> tm.cb, callbackRef |-> tm.cbRef, pending |-> z.callbacks[CallbackBatch(g)]]
      [] e.event="TimerCallbackLock" -> [callback |-> tm.cb, timerLock |-> tm.lock, pending |-> z.callbacks[CallbackBatch(g)]]
      [] e.event="TimerCallbackCheck" -> [callback |-> tm.cb, pending |-> z.callbacks[CallbackBatch(g)]]
      [] e.event="TimerCallbackWake" -> [callback |-> tm.cb, accepted |-> tm.accepted, flagWritten |-> w.hasWoken, pending |-> z.callbacks[CallbackBatch(g)]]
      [] e.event="TimerCallbackUnpark" -> [callback |-> tm.cb, pending |-> z.callbacks[CallbackBatch(g)]]
      [] e.event="TimerCallbackFinish" -> [callback |-> tm.cb, callbackRef |-> tm.cbRef, timerLock |-> tm.lock, pending |-> z.callbacks[CallbackBatch(g)]]
      [] e.event="FutexCleanupLock" -> [pc |-> w.pc, bucket |-> b, lockOwner |-> z.locks[b]]
      [] e.event="FutexRemoveByWaker" -> [pc |-> w.pc, bucket |-> b, queue |-> z.q[b], cleanup |-> w.cleanup]
      [] e.event="FutexCleanupUnlock" -> [pc |-> w.pc, bucket |-> b, lockOwner |-> z.locks[b]]
      [] e.event="FutexWaitDecide" -> [pc |-> w.pc, result |-> w.result]
      [] e.event="WaiterDrop" -> [pc |-> w.pc, closed |-> w.closed, flagWritten |-> w.hasWoken]
      [] e.event="SysFutexWaitReturn" -> [pc |-> w.pc, result |-> w.result, returns |-> w.returns]

CallPost(e,z) ==
    LET c==e.args.c o==z.op[c] sb==BucketOf[o.src] db==BucketOf[o.dst] IN
    CASE e.event="SysFutexControl" -> [pc |-> o.pc, actor |-> o.actor, kind |-> o.kind, src |-> o.src, dst |-> o.dst, rawWake |-> o.rawWake, rawMove |-> o.rawMove, effective |-> o.effective, activeCall |-> z.actor[o.actor[1]]]
      [] e.event="LockBucketPairsFirst" -> [pc |-> o.pc, bucket |-> Min(sb,db), lockOwner |-> z.locks[Min(sb,db)]]
      [] e.event="LockBucketPairsSecond" -> [pc |-> o.pc, bucket |-> Max(sb,db), lockOwner |-> z.locks[Max(sb,db)]]
      [] e.event="FutexWakeStart" -> [pc |-> o.pc, sourceQueue |-> z.q[sb]]
      [] e.event="FutexItemWake" -> IF e.args.attempted THEN [pc |-> o.pc, index |-> o.index, waiter |-> o.temp, accepted |-> o.accepted, flagWritten |-> z.w[e.args.g].hasWoken] ELSE [pc |-> o.pc, index |-> o.index]
      [] e.event="FutexWakeUnpark" -> [pc |-> o.pc]
      [] e.event="FutexWakeRetain" -> [pc |-> o.pc, index |-> o.index, wakes |-> o.wakes, queue |-> z.q[sb], owner |-> z.e[e.args.g].owner]
      [] e.event="FutexWakeEnd" -> [pc |-> o.pc, index |-> o.index, wakes |-> o.wakes]
      [] e.event="FutexUpdateItemKey" -> [pc |-> o.pc, index |-> o.index, moves |-> o.moves, entryKey |-> z.e[e.args.g].key]
      [] e.event="FutexExtractItem" -> [pc |-> o.pc, index |-> o.index, moves |-> o.moves, transfer |-> o.temp, queue |-> z.q[sb], owner |-> z.e[e.args.g].owner]
      [] e.event="FutexExtractedKey" -> [pc |-> o.pc, entryKey |-> z.e[e.args.g].key, owner |-> z.e[e.args.g].owner]
      [] e.event="FutexAppendExtracted" -> [pc |-> o.pc, transfer |-> o.temp, queue |-> z.q[db], owner |-> z.e[e.args.g].owner]
      [] e.event="FutexMoveEnd" -> [pc |-> o.pc]
      [] e.event="FutexRequeueFinish" -> [pc |-> o.pc, wakes |-> o.wakes, moves |-> o.moves, sourceQueue |-> z.q[sb], destQueue |-> z.q[db]]
      [] e.event="FutexReleaseDest" -> [pc |-> o.pc, bucket |-> db, lockOwner |-> z.locks[db]]
      [] e.event="FutexReleaseSource" -> [pc |-> o.pc, bucket |-> sb, lockOwner |-> z.locks[sb]]
      [] e.event="SysFutexControlReturn" -> [pc |-> o.pc, result |-> o.result, activeCall |-> z.actor[o.actor[1]]]

WaitEvents == {"SysFutexWait","FutexWaitLock","FutexWaitLoad","FutexWaitFault","FutexWaitFaultUnlock","HandlePageFault","FutexWaitCompare","FutexWaitMismatchUnlock","FutexBucketAddItem","FutexWaitUnlock","PauseTimeoutCheck","TimerSetClock","TimerSetTimeout","WakerDoWait","WaiterPark","WaiterSpuriousReturn","PauseTimeoutTimerLock","PauseTimeoutNoTimer","PauseTimeoutClock","PauseTimeoutRemain","TimerCancel","PauseTimeoutTimerUnlock","PauseTimeoutTimerDrop","TimerCollect","TimerCallbackUpgrade","TimerCallbackLock","TimerCallbackCheck","TimerCallbackWake","TimerCallbackUnpark","TimerCallbackFinish","FutexCleanupLock","FutexRemoveByWaker","FutexCleanupUnlock","FutexWaitDecide","WaiterDrop","SysFutexWaitReturn"}
CallEvents == {"SysFutexControl","LockBucketPairsFirst","LockBucketPairsSecond","FutexWakeStart","FutexItemWake","FutexWakeUnpark","FutexWakeRetain","FutexWakeEnd","FutexUpdateItemKey","FutexExtractItem","FutexExtractedKey","FutexAppendExtracted","FutexMoveEnd","FutexRequeueFinish","FutexReleaseDest","FutexReleaseSource","SysFutexControlReturn"}
CallbackEvents == {"TimerCollectClock","TimerCollectEnd","TimerCollect","TimerCallbackUpgrade","TimerCallbackLock","TimerCallbackCheck","TimerCallbackWake","TimerCallbackUnpark","TimerCallbackFinish"}

PostState(e,z) ==
    CASE e.event \in WaitEvents -> WaitPost(e,z)
      [] e.event \in CallEvents -> CallPost(e,z)
      [] e.event="UserStore" -> [key |-> e.args.k, word |-> z.word[e.args.k], stores |-> z.stores]
      [] e.event="TimerCollectClock" -> [active |-> z.collect.active, sample |-> z.collect.sample, now |-> z.now, ready |-> z.collect.ready]
      [] e.event="TimerCollectEnd" -> [active |-> z.collect.active, sample |-> z.collect.sample, ready |-> z.collect.ready, callbackStates |-> [i \in 1..Len(z.collect.ready) |-> z.tm[z.collect.ready[i]].cb], pending |-> IF z.collect.ready= <<>> THEN <<>> ELSE z.callbacks[Head(z.collect.ready)]]
      [] e.event="ClockAdvance" -> [now |-> z.now]

\* Equality checks the entire required record, including its domain. Missing
\* fields and unsolicited unchecked state fields are both rejected.
ValidatePostState(e) == e.state=PostState(e,s')

\* T:220-221. Concrete stream/batch ownership survives heap release and later
\* collections. CallbackBatch names the invocation's private vector in base.
ExecutionEvents == CallbackEvents \ {"TimerCollectClock","TimerCollectEnd","TimerCollect"}
ValidateActor(e) ==
    CASE e.event \in ExecutionEvents ->
         /\ e.pid \in SeqSet(Manifest.timer_pids)
         /\ batchOwners[CallbackBatch(e.args.g)]=[pid |-> e.pid, batch |-> e.args.batch]
      [] e.event \in CallbackEvents -> e.pid \in SeqSet(Manifest.timer_pids)
      [] e.event \in WaitEvents -> e.pid=Manifest.wait_pids[ToString(e.args.g)]
      [] e.event \in CallEvents -> e.pid=Manifest.call_pids[ToString(e.args.c)]
      [] OTHER -> TRUE

SourceBucketForTrace(c) == BucketOf[s.op[c].src]

\* F:78-80; S:55-83; W:181-189. Instrument each semantic boundary separately.
TraceSysFutexWait(e) ==
    /\ e.event="SysFutexWait"
    /\ SysFutexWait(e.args.g,e.args.k,e.args.v,DecodeDuration(e.args.d))
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:83-88. Instrument each semantic boundary separately.
TraceFutexWaitLock(e) ==
    /\ e.event="FutexWaitLock"
    /\ FutexWaitLock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:86-90. Instrument each semantic boundary separately.
TraceFutexWaitLoad(e) ==
    /\ e.event="FutexWaitLoad"
    /\ FutexWaitLoad(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:86-93; thread_local.rs:116-135. Instrument each semantic boundary separately.
TraceFutexWaitFault(e) ==
    /\ e.event="FutexWaitFault"
    /\ FutexWaitFault(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:93. Instrument each semantic boundary separately.
TraceFutexWaitFaultUnlock(e) ==
    /\ e.event="FutexWaitFaultUnlock"
    /\ FutexWaitFaultUnlock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:95-104. Instrument each semantic boundary separately.
TraceHandlePageFault(e) ==
    /\ e.event="HandlePageFault"
    /\ HandlePageFault(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:107-112. Instrument each semantic boundary separately.
TraceFutexWaitCompare(e) ==
    /\ e.event="FutexWaitCompare"
    /\ FutexWaitCompare(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:107-112. Instrument each semantic boundary separately.
TraceFutexWaitMismatchUnlock(e) ==
    /\ e.event="FutexWaitMismatchUnlock"
    /\ FutexWaitMismatchUnlock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:114,473-475. Instrument each semantic boundary separately.
TraceFutexBucketAddItem(e) ==
    /\ e.event="FutexBucketAddItem"
    /\ FutexBucketAddItem(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:116-119. Instrument each semantic boundary separately.
TraceFutexWaitUnlock(e) ==
    /\ e.event="FutexWaitUnlock"
    /\ FutexWaitUnlock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:171-177; TW:72-79; T:178-184. Instrument each semantic boundary separately.
TracePauseTimeoutCheck(e) ==
    /\ e.event="PauseTimeoutCheck"
    /\ PauseTimeoutCheck(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* TW:160-166; T:64-82; P:172-176. Instrument each semantic boundary separately.
TraceTimerSetTimeout(e) ==
    /\ e.event="TimerSetTimeout"
    /\ TimerSetTimeout(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* W:273. Instrument each semantic boundary separately.
TraceWakerDoWait(e) ==
    /\ e.event="WakerDoWait"
    /\ WakerDoWait(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* W:274. Instrument each semantic boundary separately.
TraceWaiterPark(e) ==
    /\ e.event="WaiterPark"
    /\ WaiterPark(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:202-204. Instrument each semantic boundary separately.
TracePauseTimeoutTimerLock(e) ==
    /\ e.event="PauseTimeoutTimerLock"
    /\ PauseTimeoutTimerLock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:202-221. Instrument each semantic boundary separately.
TracePauseTimeoutNoTimer(e) ==
    /\ e.event="PauseTimeoutNoTimer"
    /\ PauseTimeoutNoTimer(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:204-208; T:105-112. Instrument each semantic boundary separately.
TracePauseTimeoutRemain(e) ==
    /\ e.event="PauseTimeoutRemain"
    /\ PauseTimeoutRemain(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:207-208; T:87-90,253-255. Instrument each semantic boundary separately.
TraceTimerCancel(e) ==
    /\ e.event="TimerCancel"
    /\ TimerCancel(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:202-221. Instrument each semantic boundary separately.
TracePauseTimeoutTimerUnlock(e) ==
    /\ e.event="PauseTimeoutTimerUnlock"
    /\ PauseTimeoutTimerUnlock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:202-221. Instrument each semantic boundary separately.
TracePauseTimeoutTimerDrop(e) ==
    /\ e.event="PauseTimeoutTimerDrop"
    /\ PauseTimeoutTimerDrop(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:207-215,299-304. The base action checks the original-deadline heap head,
\* including cancelled nodes, before comparing this batch sample.
TraceTimerCollect(e) ==
    /\ e.event="TimerCollect"
    /\ collection=[pid |-> e.pid, batch |-> e.args.batch]
    /\ TimerCollect(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:262-265. Instrument each semantic boundary separately.
TraceTimerCallbackUpgrade(e) ==
    /\ e.event="TimerCallbackUpgrade"
    /\ TimerCallbackUpgrade(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:267. Instrument each semantic boundary separately.
TraceTimerCallbackLock(e) ==
    /\ e.event="TimerCallbackLock"
    /\ TimerCallbackLock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:269-272. Instrument each semantic boundary separately.
TraceTimerCallbackCheck(e) ==
    /\ e.event="TimerCallbackCheck"
    /\ TimerCallbackCheck(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* P:174-175; W:262-265. Instrument each semantic boundary separately.
TraceTimerCallbackWake(e) ==
    /\ e.event="TimerCallbackWake"
    /\ TimerCallbackWake(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* W:266; P:174-175. Instrument each semantic boundary separately.
TraceTimerCallbackUnpark(e) ==
    /\ e.event="TimerCallbackUnpark"
    /\ TimerCallbackUnpark(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:262-281. Instrument each semantic boundary separately.
TraceTimerCallbackFinish(e) ==
    /\ e.event="TimerCallbackFinish"
    /\ TimerCallbackFinish(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:124. Instrument each semantic boundary separately.
TraceFutexCleanupLock(e) ==
    /\ e.event="FutexCleanupLock"
    /\ FutexCleanupLock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:124,477-482. Instrument each semantic boundary separately.
TraceFutexRemoveByWaker(e) ==
    /\ e.event="FutexRemoveByWaker"
    /\ FutexRemoveByWaker(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:124. Instrument each semantic boundary separately.
TraceFutexCleanupUnlock(e) ==
    /\ e.event="FutexCleanupUnlock"
    /\ FutexCleanupUnlock(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:125-139; S:136-139. Instrument each semantic boundary separately.
TraceFutexWaitDecide(e) ==
    /\ e.event="FutexWaitDecide"
    /\ FutexWaitDecide(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* W:244-248,278-281. Instrument each semantic boundary separately.
TraceWaiterDrop(e) ==
    /\ e.event="WaiterDrop"
    /\ WaiterDrop(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* S:81-83,136-143. Instrument each semantic boundary separately.
TraceSysFutexWaitReturn(e) ==
    /\ e.event="SysFutexWaitReturn"
    /\ SysFutexWaitReturn(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* S:97-117,146-150; F:353-366. Instrument each semantic boundary separately.
TraceSysFutexControl(e) ==
    /\ e.event="SysFutexControl"
    /\ e.args.a=Manifest.call_actors[ToString(e.args.c)]
    /\ SysFutexControl(e.args.c,e.args.a,e.args.kind,e.args.src,e.args.dst,e.args.nw,e.args.nm)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:398-427; F:165-168. Instrument each semantic boundary separately.
TraceLockBucketPairsFirst(e) ==
    /\ e.event="LockBucketPairsFirst"
    /\ LockBucketPairsFirst(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:416-424. Instrument each semantic boundary separately.
TraceLockBucketPairsSecond(e) ==
    /\ e.event="LockBucketPairsSecond"
    /\ LockBucketPairsSecond(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:368,485-488. Instrument each semantic boundary separately.
TraceFutexWakeStart(e) ==
    /\ e.event="FutexWakeStart"
    /\ FutexWakeStart(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:488-495; W:262-265. Instrument each semantic boundary separately.
TraceFutexItemWake(e) ==
    /\ e.event="FutexItemWake"
    /\ e.args.g=s.q[SourceBucketForTrace(e.args.c)][s.op[e.args.c].index]
    /\ e.args.attempted=(s.e[e.args.g].key=s.op[e.args.c].src /\ s.op[e.args.c].wakes<s.op[e.args.c].effective)
    /\ FutexItemWake(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* W:266-268; F:489. Instrument each semantic boundary separately.
TraceFutexWakeUnpark(e) ==
    /\ e.event="FutexWakeUnpark"
    /\ e.args.g=s.op[e.args.c].temp
    /\ FutexWakeUnpark(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:489-495. Instrument each semantic boundary separately.
TraceFutexWakeRetain(e) ==
    /\ e.event="FutexWakeRetain"
    /\ e.args.g=s.op[e.args.c].temp
    /\ FutexWakeRetain(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:353-354,368-379. Instrument each semantic boundary separately.
TraceFutexWakeEnd(e) ==
    /\ e.event="FutexWakeEnd"
    /\ FutexWakeEnd(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:500-511. Instrument each semantic boundary separately.
TraceFutexUpdateItemKey(e) ==
    /\ e.event="FutexUpdateItemKey"
    /\ e.args.g=s.q[SourceBucketForTrace(e.args.c)][s.op[e.args.c].index]
    /\ FutexUpdateItemKey(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:520-529. Instrument each semantic boundary separately.
TraceFutexExtractItem(e) ==
    /\ e.event="FutexExtractItem"
    /\ e.args.g=s.q[SourceBucketForTrace(e.args.c)][s.op[e.args.c].index]
    /\ FutexExtractItem(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:530-531. Instrument each semantic boundary separately.
TraceFutexExtractedKey(e) ==
    /\ e.event="FutexExtractedKey"
    /\ e.args.g=s.op[e.args.c].temp
    /\ FutexExtractedKey(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:532,473-475. Instrument each semantic boundary separately.
TraceFutexAppendExtracted(e) ==
    /\ e.event="FutexAppendExtracted"
    /\ e.args.g=s.op[e.args.c].temp
    /\ FutexAppendExtracted(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:502,521-533. Instrument each semantic boundary separately.
TraceFutexMoveEnd(e) ==
    /\ e.event="FutexMoveEnd"
    /\ FutexMoveEnd(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:368-381. Instrument each semantic boundary separately.
TraceFutexRequeueFinish(e) ==
    /\ e.event="FutexRequeueFinish"
    /\ FutexRequeueFinish(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:370-381. Instrument each semantic boundary separately.
TraceFutexReleaseDest(e) ==
    /\ e.event="FutexReleaseDest"
    /\ FutexReleaseDest(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:170,381. Instrument each semantic boundary separately.
TraceFutexReleaseSource(e) ==
    /\ e.event="FutexReleaseSource"
    /\ FutexReleaseSource(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* F:170,381; S:142-143. Instrument each semantic boundary separately.
TraceSysFutexControlReturn(e) ==
    /\ e.event="SysFutexControlReturn"
    /\ SysFutexControlReturn(e.args.c)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* Brief scenario 1, user atomic store before S:97-100. Instrument each semantic boundary separately.
TraceUserStore(e) ==
    /\ e.event="UserStore"
    /\ UserStore(e.args.k,e.args.v)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* TW:143-155 or an independent clock probe. This does not consume timer locals.
TraceClockAdvance(e) ==
    /\ e.event="ClockAdvance"
    /\ ClockAdvance(e.args.t)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:67-68. Preserve the operation or collection identity.
TraceTimerSetClock(e) ==
    /\ e.event="TimerSetClock"
    /\ TimerSetClock(e.args.g,e.args.t)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:106-109. Preserve the operation or collection identity.
TracePauseTimeoutClock(e) ==
    /\ e.event="PauseTimeoutClock"
    /\ PauseTimeoutClock(e.args.g,e.args.t)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* Q:441-444; W:272-275. A scheduler return leaves Waker observers unchanged.
TraceWaiterSpuriousReturn(e) ==
    /\ e.event="WaiterSpuriousReturn"
    /\ WaiterSpuriousReturn(e.args.g)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:200-206. Preserve the operation or collection identity.
TraceTimerCollectClock(e) ==
    /\ e.event="TimerCollectClock"
    /\ e.args.batch=e.seq
    \* T:220-221. A sequential execution stream must drain its previous vector.
    /\ \A b \in WaitIds : batchOwners[b].pid/=e.pid
    /\ TimerCollectClock(e.args.t)
    /\ ValidateActor(e) /\ ValidatePostState(e)

\* T:207-218. Preserve the operation or collection identity.
TraceTimerCollectEnd(e) ==
    /\ e.event="TimerCollectEnd"
    /\ collection=[pid |-> e.pid, batch |-> e.args.batch]
    /\ TimerCollectEnd
    /\ ValidateActor(e) /\ ValidatePostState(e)

MatchEvent(e) ==
    CASE e.event="SysFutexWait" -> TraceSysFutexWait(e)
      [] e.event="FutexWaitLock" -> TraceFutexWaitLock(e)
      [] e.event="FutexWaitLoad" -> TraceFutexWaitLoad(e)
      [] e.event="FutexWaitFault" -> TraceFutexWaitFault(e)
      [] e.event="FutexWaitFaultUnlock" -> TraceFutexWaitFaultUnlock(e)
      [] e.event="HandlePageFault" -> TraceHandlePageFault(e)
      [] e.event="FutexWaitCompare" -> TraceFutexWaitCompare(e)
      [] e.event="FutexWaitMismatchUnlock" -> TraceFutexWaitMismatchUnlock(e)
      [] e.event="FutexBucketAddItem" -> TraceFutexBucketAddItem(e)
      [] e.event="FutexWaitUnlock" -> TraceFutexWaitUnlock(e)
      [] e.event="PauseTimeoutCheck" -> TracePauseTimeoutCheck(e)
      [] e.event="TimerSetTimeout" -> TraceTimerSetTimeout(e)
      [] e.event="WakerDoWait" -> TraceWakerDoWait(e)
      [] e.event="WaiterPark" -> TraceWaiterPark(e)
      [] e.event="PauseTimeoutTimerLock" -> TracePauseTimeoutTimerLock(e)
      [] e.event="PauseTimeoutNoTimer" -> TracePauseTimeoutNoTimer(e)
      [] e.event="PauseTimeoutRemain" -> TracePauseTimeoutRemain(e)
      [] e.event="TimerCancel" -> TraceTimerCancel(e)
      [] e.event="PauseTimeoutTimerUnlock" -> TracePauseTimeoutTimerUnlock(e)
      [] e.event="PauseTimeoutTimerDrop" -> TracePauseTimeoutTimerDrop(e)
      [] e.event="TimerCollect" -> TraceTimerCollect(e)
      [] e.event="TimerCallbackUpgrade" -> TraceTimerCallbackUpgrade(e)
      [] e.event="TimerCallbackLock" -> TraceTimerCallbackLock(e)
      [] e.event="TimerCallbackCheck" -> TraceTimerCallbackCheck(e)
      [] e.event="TimerCallbackWake" -> TraceTimerCallbackWake(e)
      [] e.event="TimerCallbackUnpark" -> TraceTimerCallbackUnpark(e)
      [] e.event="TimerCallbackFinish" -> TraceTimerCallbackFinish(e)
      [] e.event="FutexCleanupLock" -> TraceFutexCleanupLock(e)
      [] e.event="FutexRemoveByWaker" -> TraceFutexRemoveByWaker(e)
      [] e.event="FutexCleanupUnlock" -> TraceFutexCleanupUnlock(e)
      [] e.event="FutexWaitDecide" -> TraceFutexWaitDecide(e)
      [] e.event="WaiterDrop" -> TraceWaiterDrop(e)
      [] e.event="SysFutexWaitReturn" -> TraceSysFutexWaitReturn(e)
      [] e.event="SysFutexControl" -> TraceSysFutexControl(e)
      [] e.event="LockBucketPairsFirst" -> TraceLockBucketPairsFirst(e)
      [] e.event="LockBucketPairsSecond" -> TraceLockBucketPairsSecond(e)
      [] e.event="FutexWakeStart" -> TraceFutexWakeStart(e)
      [] e.event="FutexItemWake" -> TraceFutexItemWake(e)
      [] e.event="FutexWakeUnpark" -> TraceFutexWakeUnpark(e)
      [] e.event="FutexWakeRetain" -> TraceFutexWakeRetain(e)
      [] e.event="FutexWakeEnd" -> TraceFutexWakeEnd(e)
      [] e.event="FutexUpdateItemKey" -> TraceFutexUpdateItemKey(e)
      [] e.event="FutexExtractItem" -> TraceFutexExtractItem(e)
      [] e.event="FutexExtractedKey" -> TraceFutexExtractedKey(e)
      [] e.event="FutexAppendExtracted" -> TraceFutexAppendExtracted(e)
      [] e.event="FutexMoveEnd" -> TraceFutexMoveEnd(e)
      [] e.event="FutexRequeueFinish" -> TraceFutexRequeueFinish(e)
      [] e.event="FutexReleaseDest" -> TraceFutexReleaseDest(e)
      [] e.event="FutexReleaseSource" -> TraceFutexReleaseSource(e)
      [] e.event="SysFutexControlReturn" -> TraceSysFutexControlReturn(e)
      [] e.event="UserStore" -> TraceUserStore(e)
      [] e.event="TimerSetClock" -> TraceTimerSetClock(e)
      [] e.event="PauseTimeoutClock" -> TracePauseTimeoutClock(e)
      [] e.event="WaiterSpuriousReturn" -> TraceWaiterSpuriousReturn(e)
      [] e.event="TimerCollectClock" -> TraceTimerCollectClock(e)
      [] e.event="TimerCollectEnd" -> TraceTimerCollectEnd(e)
      [] e.event="ClockAdvance" -> TraceClockAdvance(e)
      [] OTHER -> FALSE

TraceInit == Init /\ l=[pid \in EventPIDs |-> 1]
    /\ collection=EmptyCollection
    /\ batchOwners=[b \in WaitIds |-> EmptyCollection]
TraceNext ==
    \/ /\ ThreadsWithEvents/={}
       /\ \E pid \in ViablePIDs :
            /\ MatchEvent(Pending(pid))
            /\ l'=[l EXCEPT ![pid]=@+1]
            /\ collection'=IF Pending(pid).event="TimerCollectClock"
                 THEN [pid |-> pid, batch |-> Pending(pid).args.batch]
                 ELSE IF Pending(pid).event="TimerCollectEnd"
                      THEN EmptyCollection ELSE collection
            /\ batchOwners'=[b \in WaitIds |->
                 IF s'.callbacks[b]= <<>> THEN EmptyCollection
                 ELSE IF Pending(pid).event="TimerCollectEnd" /\ s.callbacks[b]= <<>>
                      THEN collection ELSE batchOwners[b]]
    \/ /\ ThreadsWithEvents={}
       /\ UNCHANGED tracevars
\* No silent kernel transitions. Each operation read and batch boundary is explicit.
TraceSpec == TraceInit /\ [][TraceNext]_tracevars
TraceMatched == <>(ThreadsWithEvents={})
TraceFinishedState == ThreadsWithEvents={} =>
    /\ ~s.collect.active
    /\ \A b \in WaitIds : s.callbacks[b]= <<>>
    /\ \A g \in WaitIds : s.w[g].pc="done"
    /\ \A c \in CallIds : s.op[c].pc="done"
\* Reachability sentinel: its counterexample is a fully consumed replay witness.
\* A temporal failure or a dead branch alone cannot disprove existential replay.
TraceIncomplete == ThreadsWithEvents/={}
=============================================================================

