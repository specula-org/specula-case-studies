------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Threads, OFDs, FDs, Tokens, SharedTable
Nil == 0
Modes == {"SH", "EX", "UN"}
ASSUME /\ Threads /= {} /\ OFDs /= {} /\ FDs /= {} /\ Tokens /= {}
       /\ Nil \notin (Threads \cup OFDs \cup FDs \cup Tokens)
       /\ SharedTable \in BOOLEAN
\* fs/file/file_table.rs:355-360. A non-shared table has one participating
\* thread. This domain assumption is separate from syscall entry and locking.
ASSUME SharedTable \/ Cardinality(Threads) = 1

(* Category B. Asterinas 0c60537098f4c2949ad2d382aaf499de72263d76.
   Source paths without a prefix below are relative to kernel/core/src/.
   Scenario 1: fdOwner, captured request identity, ordered items.
   Scenario 2: mode is separate from the installed item. No Linux policy is
   substituted into the implementation. MC contains a sequential oracle.
   Scenario 3: each request token identifies its shared item queue and its
   distinct waker. Queue entries are sequences, including duplicates.
   Scenarios 4/5: references have explicit sources, PCs and destructor frames.
   Scheduler locks model the per-target runqueue bridge, not CPU selection.
   Signals, timeouts, allocation failure and arbitrary spurious wakes are
   outside this signal-free fixture. Mutex wait-queue internals are abstracted
   by a waiting PC and acquisition only when the guard is free. *)

VARIABLE s
vars == <<s>>

BlankThread ==
    [pc |-> "idle", kind |-> "none", fd |-> Nil,
     request |-> Nil, captured |-> Nil, callRef |-> FALSE,
     pending |-> Nil, temp |-> Nil, mode |-> "UN", nb |-> FALSE,
     rid |-> Nil, target |-> Nil, scan |-> 1, remove |-> FALSE,
     replace |-> 0, drainQ |-> Nil, drainTo |-> "idle", popped |-> Nil,
     dtor |-> Nil, stack |-> <<>>, result |-> "NONE"]
BlankWaker == [tid |-> Nil, notified |-> FALSE, closed |-> TRUE]

\* fs/file/flock.rs:101-105; fs/vfs/fs_apis/inode_ext.rs:73-82.
\* The fixture starts before any modeled opens, requests or context creation.
Init ==
    s = [fdOwner |-> [f \in FDs |-> Nil],
         life |-> [o \in OFDs |-> "unused"], refs |-> [o \in OFDs |-> 0],
         th |-> [t \in Threads |-> BlankThread],
         items |-> <<>>, context |-> FALSE, listOwner |-> Nil,
         tableOwner |-> Nil, used |-> {},
         queues |-> [q \in Tokens |-> <<>>],
         waker |-> [q \in Tokens |-> BlankWaker],
         rqLock |-> [t \in Threads |-> Nil],
         runnable |-> [t \in Threads |-> TRUE],
         last |-> "Init", actor |-> Nil, beforeItems |-> <<>>]

\* Ghost action history checks that notifications never grant ownership.
\* It records fs/file/flock.rs:116-127 separately from ostd wait.rs:262-282.
Commit(x, a, t) ==
    s' = [x EXCEPT !.last = a, !.actor = t, !.beforeItems = s.items]
PC(x, t, p) == [x EXCEPT !.th[t].pc = p]
DeleteAt(xs, i) == SubSeq(xs, 1, i - 1) \o SubSeq(xs, i + 1, Len(xs))
OwnerIndices(o) == {i \in 1..Len(s.items) : s.items[i].owner = o}
OwnerIndex(o) == IF OwnerIndices(o) = {} THEN 0
                 ELSE CHOOSE i \in OwnerIndices(o) : TRUE
\* fs/file/flock.rs:45-60,116. The first conflicting item wins registration.
ConflictIndices(t) ==
    {i \in 1..Len(s.items) :
        /\ s.items[i].owner /= s.th[t].request
        /\ (s.items[i].mode = "EX" \/ s.th[t].mode = "EX")}
FirstConflict(t) == CHOOSE i \in ConflictIndices(t) :
                       \A j \in ConflictIndices(t) : i <= j
HeldMode(o) == IF OwnerIndex(o) = 0 THEN "UN"
               ELSE s.items[OwnerIndex(o)].mode
TableReady(t) == s.tableOwner = Nil
FreeFDs == {f \in FDs : s.fdOwner[f] = Nil}
LowestFree(f) == f \in FreeFDs /\ \A g \in FreeFDs : f <= g

\* fs/file/flock.rs:64-81 and ostd/src/sync/wait.rs:110-131.
\* Calling wake_all is synchronous. Its caller cannot resume until draining
\* finishes. Queue pop, atomic notification and scheduler enqueue are split.
StartDrain(x, t, q, resume) ==
    [x EXCEPT !.th[t].drainQ = q, !.th[t].drainTo = resume,
              !.th[t].popped = Nil, !.th[t].pc = "drain"]

\* Installed alloc/src/sync.rs:2850-2855,2896-2898,2132-2143.
\* x has already removed the reference source. The last atomic decrement
\* enters a synchronous destructor, saving its caller and any outer guard.
DropRef(x, t, o, resume) ==
    LET y == [x EXCEPT !.refs[o] = @ - 1]
        frame == [resume |-> resume, target |-> x.th[t].target,
                  scan |-> x.th[t].scan, dtor |-> x.th[t].dtor]
    IN IF s.refs[o] = 1
       THEN [y EXCEPT !.life[o] = "destroying", !.th[t].dtor = o,
                      !.th[t].stack = Append(@, frame),
                      !.th[t].pc = "dropEnter"]
       ELSE PC(y, t, resume)

\* syscall/open.rs:34-56,102-103; fs/vfs/path/mod.rs:169-207.
\* File creation precedes acquisition of the insertion guard.
SysOpen(t, o) ==
    /\ s.th[t].pc = "idle"
    /\ s.life[o] = "unused" /\ FreeFDs /= {}
    /\ Commit([s EXCEPT !.life[o] = "live", !.refs[o] = 1,
                       !.th[t] = [BlankThread EXCEPT !.pc = "openInsert",
                                  !.kind = "open", !.pending = o]],
              "SysOpen", t)

\* syscall/open.rs:54-65; fs/file/file_table.rs:190-193. Clone and insert
\* under the table guard, then release it. The caller keeps its original Arc.
FileTableInsert(t, f) ==
    /\ s.th[t].pc = "openInsert" /\ TableReady(t) /\ LowestFree(f)
    /\ Commit([s EXCEPT !.fdOwner[f] = s.th[t].pending,
                       !.refs[s.th[t].pending] = @ + 1, !.th[t].fd = f,
                       !.th[t].pc = "openPut", !.th[t].result = "OK"],
              "FileTableInsert", t)

\* syscall/open.rs:65-67. The original Arc survives on_open and is put at
\* function exit. A last put must finish its synchronous destructor first.
ArcPutOpen(t) ==
    /\ s.th[t].pc = "openPut" /\ s.th[t].pending /= Nil
    /\ Commit(DropRef([s EXCEPT !.th[t].pending = Nil], t,
                      s.th[t].pending, "openReturn"), "ArcPutOpen", t)

\* syscall/open.rs:66-67. Return occurs after the local Arc's cleanup.
SysOpenReturn(t) ==
    /\ s.th[t].pc = "openReturn"
    /\ Commit(PC(s, t, "idle"), "SysOpenReturn", t)

\* syscall/dup.rs:13-18; fs/file/file_table.rs:137-165,181-187.
\* Clone and installation occur within the same table critical section.
SysDup(t, f, g) ==
    /\ s.th[t].pc = "idle" /\ TableReady(t)
    /\ s.fdOwner[f] /= Nil /\ LowestFree(g)
    /\ Commit([s EXCEPT !.fdOwner[g] = s.fdOwner[f],
                       !.refs[s.fdOwner[f]] = @ + 1,
                       !.th[t] = [BlankThread EXCEPT !.kind = "dup",
                                  !.fd = g, !.result = "OK"]], "SysDup", t)

\* syscall/close.rs:22-28; fs/file/file_table.rs:196-205.
\* FD removal transfers the reference to ClosedFile. It is not a put.
SysClose(t, f) ==
    /\ s.th[t].pc = "idle" /\ TableReady(t) /\ s.fdOwner[f] /= Nil
    /\ Commit([s EXCEPT !.fdOwner[f] = Nil, !.tableOwner = t,
                       !.th[t] = [BlankThread EXCEPT !.pc = "closeTable",
                                  !.kind = "close", !.fd = f,
                                  !.pending = s.fdOwner[f]]], "SysClose", t)

\* syscall/close.rs:28,35. This guard is gone before ClosedFile is dropped.
CloseFileTableUnlock(t) ==
    /\ s.th[t].pc = "closeTable" /\ s.tableOwner = t
    /\ Commit([s EXCEPT !.tableOwner = Nil, !.th[t].pc = "closedDrop"],
              "CloseFileTableUnlock", t)

\* fs/file/file_table.rs:292-298. Range-lock cleanup uses another lock and
\* has no work in this fixture. Its file field is then dropped normally.
ClosedFileDrop(t) ==
    /\ s.th[t].pc = "closedDrop" /\ s.th[t].pending /= Nil
    /\ Commit(DropRef([s EXCEPT !.th[t].pending = Nil], t,
                      s.th[t].pending, "closeReturn"), "ClosedFileDrop", t)

\* syscall/close.rs:35-44. Final destruction must return before close does.
SysCloseReturn(t) ==
    /\ s.th[t].pc = "closeReturn"
    /\ Commit([s EXCEPT !.th[t].pc = "idle", !.th[t].result = "OK"],
              "SysCloseReturn", t)

\* syscall/flock.rs:12-16. Admission is separate from the file lookup.
SysFlock(t, f, m, nb) ==
    /\ s.th[t].pc = "idle"
    /\ m \in Modes /\ nb \in BOOLEAN
    /\ Commit([s EXCEPT !.th[t] = [BlankThread EXCEPT !.pc = "lookup",
                 !.kind = "flock", !.fd = f, !.mode = m, !.nb = nb]],
              "SysFlock", t)

\* fs/file/file_table.rs:341-361; syscall/flock.rs:16-18.
\* Shared lookup clones while the read guard is held, then releases it.
GetFileFast(t) ==
    /\ s.th[t].pc = "lookup" /\ TableReady(t)
    /\ s.fdOwner[s.th[t].fd] /= Nil
    /\ LET o == s.fdOwner[s.th[t].fd]
       IN Commit([s EXCEPT !.th[t].request = o, !.th[t].captured = o,
                   !.th[t].callRef = SharedTable, !.th[t].pc = "dispatch",
                   !.refs[o] = @ + IF SharedTable THEN 1 ELSE 0],
                 "GetFileFast", t)

\* fs/file/file_table.rs:357,360, get_file:237-243; syscall/flock.rs:16.
GetFileFastBadFd(t) ==
    /\ s.th[t].pc = "lookup" /\ TableReady(t)
    /\ s.fdOwner[s.th[t].fd] = Nil
    /\ Commit([s EXCEPT !.th[t].result = "EBADF",
                       !.th[t].pc = "flockReturn"], "GetFileFastBadFd", t)

\* syscall/flock.rs:19-20; fs/file/inode_handle.rs:237-251.
UnlockFlock(t) ==
    /\ s.th[t].pc = "dispatch" /\ s.th[t].mode = "UN"
    /\ Commit([s EXCEPT !.th[t].target = s.th[t].request,
                       !.th[t].result = "OK",
                       !.th[t].pc = IF s.context THEN "unlockEnter"
                                   ELSE "callPut"], "UnlockFlock", t)

\* syscall/flock.rs:22-28; fs/file/flock.rs:29-36. Allocation IDs are fresh
\* for the finite fixture and are never reused, even after an item is gone.
FlockItemNew(t, q) ==
    /\ s.th[t].pc = "dispatch" /\ s.th[t].mode \in {"SH", "EX"}
    /\ q \in Tokens \ s.used
    /\ Commit([s EXCEPT !.used = @ \cup {q}, !.th[t].rid = q,
                       !.th[t].pc = "context"], "FlockItemNew", t)

\* fs/file/inode_handle.rs:233-234; fs/vfs/fs_apis/inode_ext.rs:73-78.
FsLockContextOrInit(t) ==
    /\ s.th[t].pc = "context"
    /\ Commit([s EXCEPT !.context = TRUE,
                       !.th[t].pc = IF s.th[t].nb THEN "tryEnter"
                                   ELSE "waiterNew"], "FsLockContextOrInit", t)

\* fs/file/flock.rs:147-149; ostd/src/sync/wait.rs:181-189.
\* process/signal/pause.rs:164-166 installs an inert signal hook here.
WaiterNewPair(t) ==
    /\ s.th[t].pc = "waiterNew"
    /\ Commit([s EXCEPT !.waker[s.th[t].rid] =
                         [tid |-> t, notified |-> FALSE, closed |-> FALSE],
                       !.th[t].pc = "tryEnter"], "WaiterNewPair", t)

\* fs/file/flock.rs:115; ostd/src/sync/mutex.rs:35-36,62-65.
TrySetLockEnter(t) ==
    /\ s.th[t].pc = "tryEnter"
    /\ Commit(PC(s, t, "tryWait"), "TrySetLockEnter", t)
TrySetLockAcquire(t) ==
    /\ s.th[t].pc = "tryWait" /\ s.listOwner = Nil
    /\ Commit([s EXCEPT !.listOwner = t, !.th[t].pc = "tryCheck"],
              "TrySetLockAcquire", t)

\* fs/file/flock.rs:116-120. Conflict does not remove the caller's old mode.
TrySetLockNonblockingConflict(t) ==
    /\ s.th[t].pc = "tryCheck" /\ s.listOwner = t /\ s.th[t].nb
    /\ ConflictIndices(t) /= {}
    /\ Commit([s EXCEPT !.th[t].result = "EAGAIN",
                       !.th[t].pc = "tryReturn"],
              "TrySetLockNonblockingConflict", t)

\* fs/file/flock.rs:116-120; ostd/src/sync/wait.rs:145-148.
\* Search and enqueue hold the list Mutex. No list mutation can intervene.
TrySetLockRegister(t) ==
    /\ s.th[t].pc = "tryCheck" /\ s.listOwner = t /\ ~s.th[t].nb
    /\ ConflictIndices(t) /= {}
    /\ LET q == s.items[FirstConflict(t)].q
       IN Commit([s EXCEPT !.queues[q] = Append(@, s.th[t].rid),
                           !.th[t].result = "WAIT",
                           !.th[t].pc = "tryReturn"],
                 "TrySetLockRegister", t)

\* fs/file/flock.rs:122-124,69-81. Assignment drops the old item before
\* installing the clone. Keep the guard throughout this synchronous drain.
TrySetLockReplace(t) ==
    /\ s.th[t].pc = "tryCheck" /\ s.listOwner = t
    /\ ConflictIndices(t) = {} /\ OwnerIndex(s.th[t].request) /= 0
    /\ LET i == OwnerIndex(s.th[t].request)
       IN Commit(StartDrain([s EXCEPT !.th[t].replace = i], t,
                            s.items[i].q, "tryInstall"),
                 "TrySetLockReplace", t)

\* fs/file/flock.rs:126-127. A new owner needs no old-item destructor.
TrySetLockAppend(t) ==
    /\ s.th[t].pc = "tryCheck" /\ s.listOwner = t
    /\ ConflictIndices(t) = {} /\ OwnerIndex(s.th[t].request) = 0
    /\ Commit([s EXCEPT !.items = Append(@,
                 [owner |-> s.th[t].request, mode |-> s.th[t].mode,
                  q |-> s.th[t].rid]), !.th[t].result = "OK",
                 !.th[t].pc = "tryReturn"], "TrySetLockAppend", t)

\* fs/file/flock.rs:124. Nothing can change the conflict result while this
\* guard is held. The request clone and installed item share the same queue.
TrySetLockInstall(t) ==
    /\ s.th[t].pc = "tryInstall" /\ s.listOwner = t
    /\ Commit([s EXCEPT !.items[s.th[t].replace] =
                [owner |-> s.th[t].request, mode |-> s.th[t].mode,
                 q |-> s.th[t].rid], !.th[t].result = "OK",
                !.th[t].pc = "tryReturn"], "TrySetLockInstall", t)

\* fs/file/flock.rs:120,130-131,144-155; ostd/src/sync/mutex.rs:113-116.
TrySetLockUnlock(t) ==
    /\ s.th[t].pc = "tryReturn" /\ s.listOwner = t
    /\ Commit([s EXCEPT !.listOwner = Nil,
                 !.th[t].pc = IF s.th[t].result = "WAIT" THEN "doWait"
                             ELSE IF s.th[t].nb THEN "requestDrop"
                             ELSE "waiterClose"], "TrySetLockUnlock", t)

\* ostd/src/sync/wait.rs:218-230,272-275. A successful acquire swap consumes
\* a notification and retries the whole condition. No signal cancels it.
WakerDoWait(t) ==
    /\ s.th[t].pc = "doWait"
    /\ LET q == s.th[t].rid
       IN Commit([s EXCEPT !.waker[q].notified = FALSE,
                    !.th[t].pc = IF s.waker[q].notified THEN "tryEnter"
                                ELSE "parkCheck"], "WakerDoWait", t)

\* ostd/src/task/scheduler/mod.rs:453-470;
\* sched/sched_class/mod.rs:234-238,255-258. Check and dequeue share rq lock.
SchedulerParkCheck(t) ==
    /\ s.th[t].pc = "parkCheck" /\ s.rqLock[t] = Nil
    /\ Commit([s EXCEPT !.rqLock[t] = t,
                 !.th[t].pc = IF s.waker[s.th[t].rid].notified
                             THEN "parkAbort" ELSE "parkCommit"],
              "SchedulerParkCheck", t)

\* ostd/src/task/scheduler/mod.rs:469-485;
\* sched/sched_class/mod.rs:410-414. A pending unpark cannot pass rq lock.
SchedulerParkCommit(t) ==
    /\ s.th[t].pc = "parkCommit" /\ s.rqLock[t] = t
    /\ Commit([s EXCEPT !.runnable[t] = FALSE,
                       !.rqLock[t] = Nil,
                       !.th[t].pc = "parked"], "SchedulerParkCommit", t)

\* ostd/src/task/scheduler/mod.rs:455-456. An early notification avoids park.
SchedulerParkAbort(t) ==
    /\ s.th[t].pc = "parkAbort" /\ s.rqLock[t] = t
    /\ Commit([s EXCEPT !.rqLock[t] = Nil,
                       !.th[t].pc = "doWait"], "SchedulerParkAbort", t)

\* ostd/src/task/scheduler/mod.rs:476-480; ostd/src/sync/wait.rs:273.
SchedulerResume(t) ==
    /\ s.th[t].pc = "parked" /\ s.runnable[t]
    /\ Commit(PC(s, t, "doWait"), "SchedulerResume", t)

\* ostd/src/sync/wait.rs:244-249,278-281. Closed stale queue entries remain.
WaiterClose(t) ==
    /\ s.th[t].pc = "waiterClose"
    /\ Commit([s EXCEPT !.waker[s.th[t].rid].closed = TRUE,
                       !.waker[s.th[t].rid].notified = TRUE,
                       !.th[t].pc = "requestDrop"], "WaiterClose", t)

\* fs/file/flock.rs:139-157,78-81. Dropping the local request drains the
\* same queue as its installed clone, outside the list Mutex.
FlockItemDropRequest(t) ==
    /\ s.th[t].pc = "requestDrop"
    /\ Commit(StartDrain(s, t, s.th[t].rid, "callPut"),
              "FlockItemDropRequest", t)

\* ostd/src/sync/wait.rs:119-126. Release the queue spinlock before wake_up.
WaitQueuePop(t) ==
    /\ s.th[t].pc = "drain" /\ s.queues[s.th[t].drainQ] /= <<>>
    /\ LET q == s.th[t].drainQ
       IN Commit([s EXCEPT !.queues[q] = Tail(@),
                           !.th[t].popped = Head(s.queues[q]),
                           !.th[t].pc = "wake"], "WaitQueuePop", t)

\* ostd/src/sync/wait.rs:262-268. The release swap precedes scheduler enqueue.
WakerWakeUp(t) ==
    /\ s.th[t].pc = "wake"
    /\ LET q == s.th[t].popped
       IN Commit([s EXCEPT !.waker[q].notified = TRUE,
                    !.th[t].pc = IF s.waker[q].notified THEN "drain"
                                ELSE "unpark",
                    !.th[t].popped = IF s.waker[q].notified THEN Nil ELSE q],
                 "WakerWakeUp", t)

\* ostd/src/task/scheduler/mod.rs:488-493;
\* sched/sched_class/mod.rs:223-250. The rq-lock recheck bridges a wake
\* between the park check and dequeue. Notification alone is not enqueue.
SchedulerUnpark(t) ==
    /\ s.th[t].pc = "unpark" /\ s.rqLock[s.waker[s.th[t].popped].tid] = Nil
    /\ Commit([s EXCEPT !.runnable[s.waker[s.th[t].popped].tid] = TRUE,
                       !.th[t].popped = Nil, !.th[t].pc = "drain"],
              "SchedulerUnpark", t)

\* ostd/src/sync/wait.rs:113-115,121-123,133. Even a second explicit/Drop
\* drain is a separate call. A live request queue can receive new entries.
WaitQueueFinish(t) ==
    /\ s.th[t].pc = "drain" /\ s.queues[s.th[t].drainQ] = <<>>
    /\ Commit([s EXCEPT !.th[t].pc = s.th[t].drainTo,
                       !.th[t].drainQ = Nil, !.th[t].popped = Nil],
              "WaitQueueFinish", t)

\* fs/file/flock.rs:166; ostd/src/sync/mutex.rs:35-36. Record the attempt
\* even when the same thread owns the outer guard. Acquisition still waits.
FlockListUnlockEnter(t) ==
    /\ s.th[t].pc = "unlockEnter"
    /\ Commit(PC(s, t, "unlockWait"), "FlockListUnlockEnter", t)
FlockListUnlockAcquire(t) ==
    /\ s.th[t].pc = "unlockWait" /\ s.listOwner = Nil
    /\ Commit([s EXCEPT !.listOwner = t, !.th[t].scan = 1,
                       !.th[t].pc = "scan"], "FlockListUnlockAcquire", t)

\* fs/file/flock.rs:40-41,167-176; installed alloc/src/sync.rs:3299-3327.
\* Successful Weak upgrade owns a real temporary reference before the
\* closure compares owners or drops that temporary.
FlockOwnerUpgrade(t) ==
    /\ s.th[t].pc = "scan" /\ s.listOwner = t
    /\ s.th[t].scan <= Len(s.items)
    /\ LET o == s.items[s.th[t].scan].owner
       IN /\ s.refs[o] > 0
          /\ Commit([s EXCEPT !.refs[o] = @ + 1, !.th[t].temp = o,
                              !.th[t].pc = "compareOwner"],
                    "FlockOwnerUpgrade", t)

\* fs/file/flock.rs:178-179. A failed upgrade cannot resurrect the owner.
FlockOwnerExpired(t) ==
    /\ s.th[t].pc = "scan" /\ s.listOwner = t
    /\ s.th[t].scan <= Len(s.items)
    /\ s.refs[s.items[s.th[t].scan].owner] = 0
    /\ Commit(PC(s, t, "removeItem"), "FlockOwnerExpired", t)

\* fs/file/flock.rs:169-174. Explicit wake happens before the temporary put.
FlockOwnerMatch(t) ==
    /\ s.th[t].pc = "compareOwner" /\ s.th[t].temp = s.th[t].target
    /\ Commit(StartDrain([s EXCEPT !.th[t].remove = TRUE], t,
                         s.items[s.th[t].scan].q, "tempPut"),
              "FlockOwnerMatch", t)

\* fs/file/flock.rs:175-176. Retaining B while unlocking A still drops the
\* upgraded Arc inside A's list guard when this closure returns.
FlockOwnerKeep(t) ==
    /\ s.th[t].pc = "compareOwner" /\ s.th[t].temp /= s.th[t].target
    /\ Commit([s EXCEPT !.th[t].remove = FALSE, !.th[t].pc = "tempPut"],
              "FlockOwnerKeep", t)

\* fs/file/flock.rs:168-181; installed alloc/src/sync.rs:2850-2898.
\* The destructor follows solely from the last decrement, not a fault action.
ArcPutTemporary(t) ==
    /\ s.th[t].pc = "tempPut" /\ s.th[t].temp /= Nil
    /\ Commit(DropRef([s EXCEPT !.th[t].temp = Nil], t,
                      s.th[t].temp, "afterTemp"), "ArcPutTemporary", t)

\* fs/file/flock.rs:174-181. The retain decision runs after the local drop.
FlockRetainContinue(t) ==
    /\ s.th[t].pc = "afterTemp" /\ s.listOwner = t
    /\ Commit([s EXCEPT !.th[t].pc = IF s.th[t].remove THEN "removeItem"
                                   ELSE "scan",
                 !.th[t].scan = IF s.th[t].remove THEN @ ELSE @ + 1],
              "FlockRetainContinue", t)

\* fs/file/flock.rs:174,179,78-81. Retain removes the item and calls its
\* destructor, including when Weak upgrade failed. Keep the next scan index.
FlockItemDropRemoved(t) ==
    /\ s.th[t].pc = "removeItem" /\ s.listOwner = t
    /\ LET i == s.th[t].scan
       IN Commit(StartDrain([s EXCEPT !.items = DeleteAt(@, i)], t,
                            s.items[i].q, "scan"), "FlockItemDropRemoved", t)

\* fs/file/flock.rs:181-182; ostd/src/sync/mutex.rs:113-116.
FlockListUnlockRelease(t) ==
    /\ s.th[t].pc = "scan" /\ s.listOwner = t
    /\ s.th[t].scan > Len(s.items)
    /\ Commit([s EXCEPT !.listOwner = Nil,
                 !.th[t].pc = IF s.th[t].dtor = Nil THEN "callPut"
                             ELSE "dropFinish"], "FlockListUnlockRelease", t)

\* syscall/flock.rs:16-34; fs/file/file_table.rs:355-360. Borrowed lookups
\* have no Arc to put. A shared syscall can perform the final put after close.
ArcPutSyscall(t) ==
    /\ s.th[t].pc = "callPut"
    /\ Commit(IF s.th[t].callRef
              THEN DropRef([s EXCEPT !.th[t].callRef = FALSE], t,
                           s.th[t].request, "flockReturn")
              ELSE PC(s, t, "flockReturn"), "ArcPutSyscall", t)

\* fs/file/inode_handle.rs:537-541,237-251. Cleanup may need the same Mutex
\* as an outer unlock. That outer guard is deliberately not released here.
InodeHandleDropEnter(t) ==
    /\ s.th[t].pc = "dropEnter" /\ s.th[t].dtor /= Nil
    /\ Commit([s EXCEPT !.th[t].target = s.th[t].dtor,
                 !.th[t].pc = IF s.context THEN "unlockEnter"
                             ELSE "dropFinish"], "InodeHandleDropEnter", t)

\* fs/file/inode_handle.rs:539-541; installed alloc/src/sync.rs:2143.
\* Resume the exact caller only after its synchronous destructor returned.
InodeHandleDropFinish(t) ==
    /\ s.th[t].pc = "dropFinish" /\ s.th[t].stack /= <<>>
    /\ LET f == s.th[t].stack[Len(s.th[t].stack)]
       IN Commit([s EXCEPT !.life[s.th[t].dtor] = "dead",
                 !.th[t].pc = f.resume, !.th[t].target = f.target,
                 !.th[t].scan = f.scan, !.th[t].dtor = f.dtor,
                 !.th[t].stack = SubSeq(@, 1, Len(@) - 1)],
                 "InodeHandleDropFinish", t)

\* syscall/flock.rs:29-34. Preserve result/captured identity for the observer.
SysFlockReturn(t) ==
    /\ s.th[t].pc = "flockReturn"
    /\ Commit(PC(s, t, "idle"), "SysFlockReturn", t)

\* The disjunction preserves each source operation's interleaving boundary.
ThreadStep(t) ==
    \/ \E f \in FDs : FileTableInsert(t, f)
    \/ ArcPutOpen(t) \/ SysOpenReturn(t)
    \/ CloseFileTableUnlock(t) \/ ClosedFileDrop(t) \/ SysCloseReturn(t)
    \/ GetFileFast(t) \/ GetFileFastBadFd(t) \/ UnlockFlock(t)
    \/ \E q \in Tokens : FlockItemNew(t, q)
    \/ FsLockContextOrInit(t) \/ WaiterNewPair(t)
    \/ TrySetLockEnter(t) \/ TrySetLockAcquire(t)
    \/ TrySetLockNonblockingConflict(t) \/ TrySetLockRegister(t)
    \/ TrySetLockReplace(t) \/ TrySetLockAppend(t) \/ TrySetLockInstall(t)
    \/ TrySetLockUnlock(t) \/ WakerDoWait(t)
    \/ SchedulerParkCheck(t) \/ SchedulerParkCommit(t)
    \/ SchedulerParkAbort(t) \/ SchedulerResume(t) \/ WaiterClose(t)
    \/ FlockItemDropRequest(t) \/ WaitQueuePop(t) \/ WakerWakeUp(t)
    \/ SchedulerUnpark(t) \/ WaitQueueFinish(t)
    \/ FlockListUnlockEnter(t) \/ FlockListUnlockAcquire(t)
    \/ FlockOwnerUpgrade(t) \/ FlockOwnerExpired(t)
    \/ FlockOwnerMatch(t) \/ FlockOwnerKeep(t) \/ ArcPutTemporary(t)
    \/ FlockRetainContinue(t) \/ FlockItemDropRemoved(t)
    \/ FlockListUnlockRelease(t) \/ ArcPutSyscall(t)
    \/ InodeHandleDropEnter(t) \/ InodeHandleDropFinish(t) \/ SysFlockReturn(t)

Next == \E t \in Threads :
    \/ ThreadStep(t)
    \/ \E o \in OFDs : SysOpen(t, o)
    \/ \E f, g \in FDs : SysDup(t, f, g)
    \/ \E f \in FDs : SysClose(t, f)
    \/ \E f \in FDs, m \in Modes, nb \in BOOLEAN : SysFlock(t, f, m, nb)
Spec == Init /\ [][Next]_vars

\* Source-independent shape checks on the above source projections.
PCs == {"idle", "openInsert", "openPut", "openReturn",
        "closeTable", "closedDrop", "closeReturn",
        "lookup", "dispatch", "flockReturn", "context", "waiterNew",
        "tryEnter", "tryWait", "tryCheck", "tryReturn", "tryInstall",
        "doWait", "parkCheck", "parkCommit", "parkAbort", "parked",
        "waiterClose", "requestDrop", "callPut", "drain", "wake", "unpark",
        "unlockEnter", "unlockWait", "scan", "compareOwner", "tempPut",
        "afterTemp", "removeItem", "dropEnter", "dropFinish"}
TypeOK ==
    /\ s.fdOwner \in [FDs -> OFDs \cup {Nil}]
    /\ s.life \in [OFDs -> {"unused", "live", "destroying", "dead"}]
    /\ s.refs \in [OFDs -> Nat]
    /\ s.items \in Seq([owner : OFDs, mode : {"SH", "EX"}, q : Tokens])
    /\ s.context \in BOOLEAN
    /\ s.listOwner \in Threads \cup {Nil}
    /\ s.tableOwner \in Threads \cup {Nil}
    /\ s.used \subseteq Tokens
    /\ s.queues \in [Tokens -> Seq(Tokens)]
    /\ s.waker \in [Tokens -> [tid : Threads \cup {Nil},
                               notified : BOOLEAN, closed : BOOLEAN]]
    /\ s.rqLock \in [Threads -> Threads \cup {Nil}]
    /\ s.runnable \in [Threads -> BOOLEAN]
    /\ DOMAIN s.th = Threads
    /\ \A t \in Threads :
        /\ s.th[t].pc \in PCs /\ s.th[t].mode \in Modes
        /\ s.th[t].nb \in BOOLEAN /\ s.th[t].callRef \in BOOLEAN
        /\ s.th[t].request \in OFDs \cup {Nil}
        /\ s.th[t].captured \in OFDs \cup {Nil}
        /\ s.th[t].pending \in OFDs \cup {Nil}
        /\ s.th[t].temp \in OFDs \cup {Nil}
        /\ s.th[t].dtor \in OFDs \cup {Nil}
        /\ s.th[t].target \in OFDs \cup {Nil}
        /\ s.th[t].fd \in FDs \cup {Nil}
        /\ s.th[t].rid \in Tokens \cup {Nil}
        /\ s.th[t].drainQ \in Tokens \cup {Nil}
        /\ s.th[t].popped \in Tokens \cup {Nil}
        /\ s.th[t].scan \in Nat /\ s.th[t].replace \in Nat
        /\ s.th[t].remove \in BOOLEAN
        /\ s.th[t].stack \in Seq([resume : PCs, target : OFDs \cup {Nil},
                                   scan : Nat, dtor : OFDs \cup {Nil}])
        /\ s.th[t].result \in {"NONE", "OK", "WAIT", "EAGAIN", "EBADF"}

\* fs/file/flock.rs:45-60,116-127. Expired Weak items may remain in the list.
CompatibleOwners == \A i, j \in 1..Len(s.items) :
    i /= j => (s.items[i].owner = s.items[j].owner \/
               (s.items[i].mode = "SH" /\ s.items[j].mode = "SH"))
UniqueOwnerItem ==
    Cardinality({s.items[i].owner : i \in 1..Len(s.items)}) = Len(s.items)

\* fs/file/file_table.rs:341-361. captured is immutable lookup evidence.
CapturedOwnerStable == \A t \in Threads : s.th[t].request = s.th[t].captured
FdRefs(o) == Cardinality({f \in FDs : s.fdOwner[f] = o})
CallRefs(o) == Cardinality({t \in Threads :
                               s.th[t].request = o /\ s.th[t].callRef})
\* Open keeps pending through insertion and on_open, until ArcPutOpen.
\* Close keeps the transferred table reference until ClosedFileDrop.
PendingRefs(o) == Cardinality({t \in Threads : s.th[t].pending = o})
TempRefs(o) == Cardinality({t \in Threads : s.th[t].temp = o})
\* syscall/open.rs:54-67; fs/file/file_table.rs:181-205,274-298,355-360; flock.rs:168;
\* installed alloc/src/sync.rs:2854,3305-3327. Independent counter vs owners.
ReferenceAccounting == \A o \in OFDs :
    /\ s.refs[o] = FdRefs(o) + CallRefs(o) + PendingRefs(o) + TempRefs(o)
    /\ (s.life[o] = "live" <=> s.refs[o] > 0)
    /\ (s.life[o] \in {"destroying", "dead", "unused"} => s.refs[o] = 0)
    /\ (s.life[o] = "dead" => OwnerIndex(o) = 0)

\* ostd/src/sync/wait.rs:119-131,244-281; scheduler/mod.rs:441-493.
WakeActions == {"WakerDoWait", "SchedulerParkCheck", "SchedulerParkCommit",
    "SchedulerParkAbort", "SchedulerResume", "WaiterClose", "WaitQueuePop",
    "WakerWakeUp", "SchedulerUnpark", "WaitQueueFinish"}
WakeRequiresRetry == s.last \in WakeActions => s.items = s.beforeItems
QueueHas(q, r) == \E i \in 1..Len(s.queues[q]) : s.queues[q][i] = r
QueueWillDrain(q) ==
    (\E i \in 1..Len(s.items) : s.items[i].q = q) \/
    (\E t \in Threads : s.th[t].drainQ = q)
\* flock.rs:118,124,173,179; ostd/src/sync/wait.rs:119-128,273-274.
\* An in-flight pop/wake is an obligation even after it left the queue.
NoOrphanedRetry == \A t \in Threads :
    s.th[t].pc \in {"doWait", "parkCheck", "parkCommit", "parkAbort", "parked"}
    => LET r == s.th[t].rid
       IN /\ ~s.waker[r].closed
          /\ (s.waker[r].notified \/
              (\E q \in Tokens : QueueHas(q, r) /\ QueueWillDrain(q)) \/
              (\E u \in Threads : s.th[u].popped = r))

\* flock.rs:166-181; inode_handle.rs:537-541; ostd mutex.rs:35-65.
\* This diagnostic is intentionally not assumed or enabled in base.cfg.
NoRecursiveListWait == ~\E t \in Threads :
    /\ s.th[t].pc = "unlockWait" /\ s.listOwner = t
    /\ s.th[t].dtor /= Nil /\ Len(s.th[t].stack) > 0

\* Scenario 4/5 progress is conditional on the finite fixture being scheduled.
FinalReleaseCompletes == \A o \in OFDs :
    (s.life[o] = "destroying") ~> (s.life[o] = "dead")

\* Guard and waker shapes, not Linux behavioral promises.
Structure ==
    /\ (s.tableOwner /= Nil => s.th[s.tableOwner].pc = "closeTable")
    /\ (s.listOwner /= Nil => s.context)
    /\ \A q \in Tokens :
        /\ (s.waker[q].closed =>
             (s.waker[q].tid = Nil \/ s.waker[q].notified))
    /\ \A t \in Threads : s.rqLock[t] /= Nil =>
           s.th[s.rqLock[t]].pc \in {"parkAbort", "parkCommit"}
=============================================================================
