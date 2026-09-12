------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

\* Category A. Temporal 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
\* Paths in action comments are relative to the pinned source root.
\* S1 acceptance/ownership; S2 read/bypass; S3 ack/GC; S4 History/replacement.
\* SQL V1 only. One partition, priority 3, unversioned; write batch size 1.
\* History's durability/recovery is an interface assumption, not an outbox model.
CONSTANTS Owners, Work, CallIds, Pollers, StartIds, InitialOwner,
          RangeSize, BatchSize, ReloadAt, DeleteBatchSize
ASSUME /\ InitialOwner \in Owners /\ Owners /= {} /\ Work /= {}
       /\ RangeSize > 0 /\ BatchSize > ReloadAt /\ ReloadAt >= 0
       /\ DeleteBatchSize > 0 /\ 0 \notin CallIds /\ 0 \notin Pollers
       /\ 0 \notin StartIds /\ "none" \notin Work

\* S1/S3: durable metadata and rows; immutable identity registry is an observer.
VARIABLES durable, catalog
\* S1-S3: per-owner lifetime, local DB/reader locks, cursors, matcher and GC.
VARIABLE owner
\* S1/S4: singleton writer batch; store result differs from observed reply.
VARIABLE writer
\* S2: captured read bounds, SQL snapshot and delayed delivery/processing.
VARIABLE reader
\* S1/S3: per-owner DB mutex spans metadata I/O including takeover snapshot.
VARIABLE metadata
\* S4: poller/History request, effect, reply, completion and Worker boundary.
VARIABLE dispatch
\* S1/S4: Add attempts, buffered append reply, server return and caller receipt.
VARIABLE calls
\* S4: external eligibility, accepted start ID, receipt; no workflow internals.
VARIABLE history
\* S1-S4: observer evidence only; never used to guard implementation actions.
VARIABLE audit
\* S2/S3: observer maximum within a lifetime; excludes global durable ack.
VARIABLE cursor
coreVars == <<durable, catalog, owner, writer, reader, metadata,
              dispatch, calls, history, audit>>
vars == <<coreVars, cursor>>

Max(a,b) == IF a > b THEN a ELSE b
Min(a,b) == IF a < b THEN a ELSE b
MaxSet(s) == IF s = {} THEN 0 ELSE CHOOSE n \in s : \A k \in s : k <= n
First(s,n) == {i \in s : Cardinality({j \in s : j < i}) < n}
EmptyMap == [x \in {} |-> x]
Running(o) == owner[o].life \in {"ready", "stopping"}
Alive(o) == owner[o].life # "crashed"
ReaderFree(o) == owner[o].readerLock = "free"
DBFree(o) == writer[o].pc \notin {"store", "storeResult"}
             /\ metadata[o].pc = "idle"
Eligible(w) == ~history[w].expired /\ ~history[w].obsolete
Discharged(w) == ~Eligible(w) \/ history[w].start # 0
Covers(w, rows, boundary) ==
    \E r \in rows : r > boundary /\ catalog[r].work = w
Recoverable(w) == Covers(w, durable.rows, durable.ack)
UsedStarts == {dispatch[p].request : p \in {x \in Pollers : dispatch[x].pc # "idle"}} \cup
              {history[w].start : w \in Work}

\* pri_task_reader.go:452-479: remove precisely the leading completed entries.
AckRemaining(o,r) ==
    LET done == owner[o].done \cup {r}
        prefix == {i \in owner[o].outstanding :
                      \A j \in owner[o].outstanding : j <= i => j \in done}
    IN owner[o].outstanding \ prefix
AckAfter(o,r) ==
    LET remaining == AckRemaining(o,r)
        popped == owner[o].outstanding \ remaining
    IN IF remaining = {} /\ owner[o].read >= owner[o].maxRead
       THEN owner[o].read ELSE Max(owner[o].ack, MaxSet(popped))

IdleWriter == [pc |-> "idle", work |-> "none", call |-> 0, poller |-> 0,
               parent |-> 0, id |-> 0, range |-> 0, before |-> 0,
               outcome |-> "none", reply |-> "none"]
IdleReader == [pc |-> "idle", low |-> 0, max |-> 0, upper |-> 0,
               scans |-> 0, rows |-> {}, todo |-> {}]
IdleMetadata == [pc |-> "idle", kind |-> "none", expect |-> 0,
                 newRange |-> 0, ack |-> 0, outcome |-> "none"]
IdleDispatch == [pc |-> "idle", owner |-> InitialOwner, id |-> 0,
                 call |-> 0, work |-> "none", request |-> 0,
                 result |-> "none", reply |-> "none", replacement |-> 0, appendReply |-> "none"]
IdleCall == [pc |-> "unused", owner |-> InitialOwner, work |-> "none",
             buffer |-> "none", response |-> "none", receipt |-> "none"]
EmptyOwner(life,range) ==
    [life |-> life, range |-> range, nextId |-> 1, endId |-> RangeSize,
     read |-> 0, ack |-> 0, cachedAck |-> 0, maxRead |-> 0,
     outstanding |-> {}, done |-> {}, loaded |-> 0, adding |-> {},
     queued |-> {}, appendQueue |-> <<>>, notify |-> life = "ready", readerLock |-> "free",
     cacheRead |-> 0, cachePoller |-> 0, backoff |-> FALSE, skipFinal |-> FALSE, dirty |-> FALSE,
     stopStep |-> "none", gcPC |-> "idle", gcBound |-> 0,
     gcLast |-> 0, gcCount |-> 0]

\* db.go:210-233; pri_task_writer.go:140-149; pri_task_reader.go:67-93,163.
\* Bootstrap is a settled empty queue with first owner range 1, not migration.
Init ==
    /\ durable = [range |-> 1, ack |-> 0, rows |-> {}]
    /\ catalog = EmptyMap
    /\ owner = [o \in Owners |-> EmptyOwner(IF o = InitialOwner THEN "ready"
                                           ELSE "cold", IF o = InitialOwner THEN 1 ELSE 0)]
    /\ writer = [o \in Owners |-> IdleWriter]
    /\ reader = [o \in Owners |-> IdleReader]
    /\ metadata = [o \in Owners |-> IdleMetadata]
    /\ dispatch = [p \in Pollers |-> IdleDispatch]
    /\ calls = [a \in CallIds |-> IdleCall]
    /\ history = [w \in Work |-> [start |-> 0, expired |-> FALSE,
                                  obsolete |-> FALSE, worker |-> FALSE]]
    /\ audit = [accepted |-> {}, committed |-> {}, uncertain |-> {},
                 deleted |-> {}, fences |-> {}, releases |-> {},
                 badDelete |-> FALSE, badRelease |-> FALSE]
    /\ cursor = [o \in Owners |-> [read |-> 0, ack |-> 0]]

\* Observer wrapper: also used by MC and Trace, never changes enabledness.
Track(A) == A /\ cursor' = [o \in Owners |->
    [read |-> Max(cursor[o].read, owner'[o].read),
     ack |-> Max(cursor[o].ack, owner'[o].ack)]]

\* S1/S4: an external Add attempt, including retry with the same logical work.
AddTask(a, w, o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    /\ w \in Work
    /\ o \in Owners
    \* service/matching/task_queue_partition_manager.go:612-619
    /\ calls[a].pc = "unused" /\ owner[o].life = "ready"
    \* service/matching/task_queue_partition_manager.go:612-619
    /\ calls' = [calls EXCEPT ![a] = [IdleCall EXCEPT !.pc = "offer", !.work = w, !.owner = o]]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, history, audit>>

\* No waiting eligible poller or backlog present; persist on this partition.
TrySyncMatchFallback(a) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    \* service/matching/pri_matcher.go:415-430; service/matching/task_queue_partition_manager.go:644-659
    /\ calls[a].pc = "offer"
    \* service/matching/pri_matcher.go:415-430; service/matching/task_queue_partition_manager.go:644-659
    /\ calls' = [calls EXCEPT ![a].pc = "spool"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, history, audit>>

\* S4: sync pair is not yet an accepted start.
TrySyncMatch(a, p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    /\ p \in Pollers
    \* service/matching/pri_matcher.go:390-421; service/matching/matching_engine.go:3511-3527
    /\ calls[a].pc = "offer" /\ owner[calls[a].owner].life = "ready"
    \* service/matching/pri_matcher.go:390-421; service/matching/matching_engine.go:3511-3527
    /\ dispatch[p].pc = "idle"
    \* service/matching/pri_matcher.go:390-421; service/matching/matching_engine.go:3511-3527
    /\ owner[calls[a].owner].queued = {}
    \* service/matching/pri_matcher.go:390-421; service/matching/matching_engine.go:3511-3527
    /\ dispatch' = [dispatch EXCEPT ![p] = [IdleDispatch EXCEPT
          !.pc = "matched", !.owner = calls[a].owner, !.call = a,
          !.work = calls[a].work]]
    \* service/matching/pri_matcher.go:390-421; service/matching/matching_engine.go:3511-3527
    /\ calls' = [calls EXCEPT ![a].pc = "syncWait"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, history, audit>>

\* Enqueue into appendCh; pending requests may accumulate while writer is busy.
SpoolTask(a) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    \* service/matching/pri_backlog_manager.go:248-252; service/matching/pri_task_writer.go:68-98
    /\ calls[a].pc = "spool" /\ Running(calls[a].owner)
    \* service/matching/pri_backlog_manager.go:248-252; service/matching/pri_task_writer.go:68-98
    /\ owner' = [owner EXCEPT ![calls[a].owner].appendQueue = Append(@,
          [work |-> calls[a].work, call |-> a, poller |-> 0, parent |-> 0])]
    \* service/matching/pri_backlog_manager.go:248-252; service/matching/pri_task_writer.go:68-98
    /\ calls' = [calls EXCEPT ![a].pc = "appendWait"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, history, audit>>

\* Single writer receives FIFO append request; selected MaxTaskBatchSize=1.
TaskWriterDequeue(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_writer.go:162-170,182-190
    /\ Running(o) /\ writer[o].pc = "idle" /\ Len(owner[o].appendQueue) > 0
    \* service/matching/pri_task_writer.go:162-170,182-190
    /\ LET req == Head(owner[o].appendQueue) IN
           writer' = [writer EXCEPT ![o] = [IdleWriter EXCEPT !.pc = "assign",
              !.work = req.work, !.call = req.call, !.poller = req.poller, !.parent = req.parent]]
    \* service/matching/pri_task_writer.go:162-170,182-190
    /\ owner' = [owner EXCEPT ![o].appendQueue = Tail(@)]
    /\ UNCHANGED <<durable, catalog, reader, metadata, dispatch, calls, history, audit>>

\* Reserve the next ID before I/O. IDs are never reused, including rejection.
AssignTaskIDs(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_writer.go:108-121
    /\ writer[o].pc = "assign" /\ Running(o)
    \* service/matching/pri_task_writer.go:108-121
    /\ owner[o].nextId <= owner[o].endId
    \* service/matching/pri_task_writer.go:108-121
    /\ writer' = [writer EXCEPT ![o].pc = "create", ![o].id = owner[o].nextId]
    \* service/matching/pri_task_writer.go:108-121
    /\ catalog' = catalog @@ (owner[o].nextId :>
          [work |-> writer[o].work, parent |-> writer[o].parent])
    \* service/matching/pri_task_writer.go:108-121
    /\ owner' = [owner EXCEPT ![o].nextId = @ + 1]
    /\ UNCHANGED <<durable, reader, metadata, dispatch, calls, history, audit>>

\* Acquire the per-owner DB mutex and capture previous max; SQL V1 ignores metadata piggyback.
CreateTasksBegin(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:528-573
    /\ writer[o].pc = "create" /\ DBFree(o) /\ Running(o)
    \* service/matching/db.go:528-573
    /\ writer' = [writer EXCEPT ![o].pc = "store", ![o].range = owner[o].range,
                       ![o].before = owner[o].maxRead]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, calls, history, audit>>

\* Atomic insert plus range lock/condition transaction; no partial batch commit.
CreateTasksCommit(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* common/persistence/sql/task_v1.go:80-98,187-205
    /\ writer[o].pc = "store" /\ writer[o].range = durable.range
    \* common/persistence/sql/task_v1.go:80-98,187-205
    /\ durable' = [durable EXCEPT !.rows = @ \cup {writer[o].id}]
    \* common/persistence/sql/task_v1.go:80-98,187-205
    /\ writer' = [writer EXCEPT ![o].pc = "storeResult", ![o].outcome = "commit"]
    \* common/persistence/sql/task_v1.go:80-98,187-205
    /\ audit' = [audit EXCEPT !.committed = @ \cup {writer[o].id},
          !.fences = @ \cup {<<writer[o].range, durable.range>>}]
    /\ UNCHANGED <<catalog, owner, reader, metadata, dispatch, calls, history>>

\* Range mismatch rejects the whole transaction; a reactive result, not a fault budget.
CreateTasksConditionFailed(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* common/persistence/sql/task_v1.go:80-98,187-205
    /\ writer[o].pc = "store" /\ writer[o].range # durable.range
    \* common/persistence/sql/task_v1.go:80-98,187-205
    /\ writer' = [writer EXCEPT ![o].pc = "storeResult", ![o].outcome = "condition"]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, calls, history, audit>>

\* Inject persistence limit rejection or an uncommitted failed transaction.
CreateTasksReject(o, result) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ result \in {"limit", "noCommit"}
    \* service/matching/db.go:677-697; common/persistence/sql/task_v1.go:80-98
    /\ writer[o].pc = "store"
    \* service/matching/db.go:677-697; common/persistence/sql/task_v1.go:80-98
    /\ writer' = [writer EXCEPT ![o].pc = "storeResult", ![o].outcome = result]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, calls, history, audit>>

\* Release DB mutex only after maxRead advances, even on failed writes.
CreateTasksReturn(o, reply) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ reply \in {"ok", "definite", "unknown", "condition"}
    \* service/matching/db.go:575-597; service/matching/pri_task_writer.go:124-137; service/matching/pri_backlog_manager.go:108-116
    /\ writer[o].pc = "storeResult" /\ Alive(o)
    \* service/matching/db.go:575-597; service/matching/pri_task_writer.go:124-137; service/matching/pri_backlog_manager.go:108-116
    /\ (CASE writer[o].outcome = "commit" -> reply = "ok"
         [] writer[o].outcome = "condition" -> reply = "condition"
         [] writer[o].outcome = "limit" -> reply = "definite"
         [] OTHER -> reply = "unknown")
    \* service/matching/db.go:575-597; service/matching/pri_task_writer.go:124-137; service/matching/pri_backlog_manager.go:108-116
    /\ owner' = [owner EXCEPT ![o].maxRead = writer[o].id,
          ![o].dirty = @ \/ reply = "ok",
          ![o].skipFinal = @,
          ![o].life = IF reply = "condition" THEN "unload" ELSE @]
    \* service/matching/db.go:575-597; service/matching/pri_task_writer.go:124-137; service/matching/pri_backlog_manager.go:108-116
    /\ writer' = [writer EXCEPT ![o].reply = reply,
          ![o].pc = IF reply = "ok" THEN "notify" ELSE "publish"]
    /\ UNCHANGED <<durable, catalog, reader, metadata, dispatch, calls, history, audit>>

\* A committed transaction returns Unavailable/timeout; no successful reader signal.
CreateTasksUncertainReturn(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:575-596,677-697; service/matching/pri_task_writer.go:125-133
    /\ writer[o].pc = "storeResult" /\ writer[o].outcome = "commit" /\ Alive(o)
    \* service/matching/db.go:575-596,677-697; service/matching/pri_task_writer.go:125-133
    /\ owner' = [owner EXCEPT ![o].maxRead = writer[o].id]
    \* service/matching/db.go:575-596,677-697; service/matching/pri_task_writer.go:125-133
    /\ writer' = [writer EXCEPT ![o].pc = "publish", ![o].reply = "unknown"]
    \* service/matching/db.go:575-596,677-697; service/matching/pri_task_writer.go:125-133
    /\ audit' = [audit EXCEPT !.uncertain = @ \cup {writer[o].id}]
    /\ UNCHANGED <<durable, catalog, reader, metadata, dispatch, calls, history>>

\* Reader-lock region of successful direct bypass; matcher insertion follows separately.
SignalNewTasksBypass(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:382-412
    /\ writer[o].pc = "notify" /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:382-412
    /\ owner[o].read = writer[o].before /\ owner[o].loaded + 1 <= BatchSize
    \* service/matching/pri_task_reader.go:382-412
    /\ writer[o].id \notin owner[o].outstanding
    \* service/matching/pri_task_reader.go:382-412
    /\ owner' = [owner EXCEPT ![o].read = writer[o].id,
          ![o].outstanding = @ \cup {writer[o].id}, ![o].loaded = @ + 1,
          ![o].adding = @ \cup {writer[o].id}]
    \* service/matching/pri_task_reader.go:382-412
    /\ writer' = [writer EXCEPT ![o].pc = "adding"]
    /\ UNCHANGED <<durable, catalog, reader, metadata, dispatch, calls, history, audit>>

\* Bypass failed: enqueue the coalescing reader wakeup without advancing read.
SignalNewTasksWake(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:390-403
    /\ writer[o].pc = "notify" /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:390-403
    /\ ~(owner[o].read = writer[o].before /\ owner[o].loaded + 1 <= BatchSize
            /\ writer[o].id \notin owner[o].outstanding)
    \* service/matching/pri_task_reader.go:390-403
    /\ owner' = [owner EXCEPT ![o].notify = TRUE]
    \* service/matching/pri_task_reader.go:390-403
    /\ writer' = [writer EXCEPT ![o].pc = "publish"]
    /\ UNCHANGED <<durable, catalog, reader, metadata, dispatch, calls, history, audit>>

\* Outside reader lock: insert registered work into the fixed unversioned matcher.
AddTaskToMatcher(o, r) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ r \in owner[o].adding
    \* service/matching/pri_task_reader.go:298-314; service/matching/physical_task_queue_manager.go:601-610
    /\ Running(o)
    \* service/matching/pri_task_reader.go:298-314; service/matching/physical_task_queue_manager.go:601-610
    /\ owner' = [owner EXCEPT ![o].adding = @ \ {r}, ![o].queued = @ \cup {r}]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Canceled queue rejects insertion; retry acquire exits without acknowledging the registered record.
AddTaskToMatcherClosed(o, r) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ r \in owner[o].adding
    \* service/matching/pri_task_reader.go:316-338
    /\ owner[o].life = "stopped"
    \* service/matching/pri_task_reader.go:316-338
    /\ owner' = [owner EXCEPT ![o].adding = @ \ {r}]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Return from signalReaders only after the bypass insertion returns.
SignalReadersDone(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:410-412; service/matching/pri_task_writer.go:136-137
    /\ writer[o].pc = "adding" /\ Alive(o)
    \* service/matching/pri_task_reader.go:410-412; service/matching/pri_task_writer.go:136-137
    /\ writer[o].id \notin owner[o].adding
    \* service/matching/pri_task_reader.go:410-412; service/matching/pri_task_writer.go:136-137
    /\ writer' = [writer EXCEPT ![o].pc = "publish"]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, calls, history, audit>>

\* Publish the buffered append result; caller receipt is a separate selection.
TaskWriterPublish(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_writer.go:168-174
    /\ writer[o].pc = "publish" /\ writer[o].call # 0 /\ Alive(o)
    \* service/matching/pri_task_writer.go:168-174
    /\ calls' = [calls EXCEPT ![writer[o].call].buffer = writer[o].reply]
    \* service/matching/pri_task_writer.go:168-174
    /\ writer' = [writer EXCEPT ![o] = IdleWriter]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, history, audit>>

\* Add returns success only after receiving the successful append response.
AppendTaskReceive(a) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    \* service/matching/pri_task_writer.go:89-96; service/matching/task_queue_partition_manager.go:659-668
    /\ calls[a].pc = "appendWait" /\ calls[a].buffer # "none"
    \* service/matching/pri_task_writer.go:89-96; service/matching/task_queue_partition_manager.go:659-668
    /\ calls' = [calls EXCEPT ![a].pc = "reply",
          ![a].response = IF calls[a].buffer = "ok" THEN "ok" ELSE "error"]
    \* service/matching/pri_task_writer.go:89-96; service/matching/task_queue_partition_manager.go:659-668
    /\ audit' = [audit EXCEPT !.accepted = IF calls[a].buffer = "ok"
                         THEN @ \cup {calls[a].work} ELSE @]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, history>>

\* Queue shutdown can win receipt selection even if the submitted write committed.
AppendTaskShutdown(a) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    \* service/matching/pri_task_writer.go:72-96
    /\ calls[a].pc \in {"offer", "spool", "appendWait", "syncWait"}
    \* service/matching/pri_task_writer.go:72-96
    /\ owner[calls[a].owner].life \in {"stopped", "crashed"}
    \* service/matching/pri_task_writer.go:72-96
    /\ calls' = [calls EXCEPT ![a].pc = "reply", ![a].response = "error"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, history, audit>>

\* Caller observes the server response.
AddTaskReply(a) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    \* service/matching/task_queue_partition_manager.go:638,659-670
    /\ calls[a].pc = "reply"
    \* service/matching/task_queue_partition_manager.go:638,659-670
    /\ calls' = [calls EXCEPT ![a].pc = "done", ![a].receipt = calls[a].response]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, history, audit>>

\* External transport loses the response; successful server acceptance remains.
AddTaskReplyLost(a) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ a \in CallIds
    \* service/matching/task_queue_partition_manager.go:638,659-670
    /\ calls[a].pc = "reply"
    \* service/matching/task_queue_partition_manager.go:638,659-670
    /\ calls' = [calls EXCEPT ![a].pc = "done", ![a].receipt = "lost"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, history, audit>>

\* Consume wake; capture reader lower bound under reader lock. No periodic scan is invented.
GetTasksPump(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:163-177,214-217
    /\ owner[o].life \in {"ready", "stopping", "stopped"} /\ reader[o].pc = "idle" /\ owner[o].notify /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:163-177,214-217
    /\ owner' = [owner EXCEPT ![o].notify = FALSE]
    \* service/matching/pri_task_reader.go:163-177,214-217
    /\ reader' = [reader EXCEPT ![o] = [IdleReader EXCEPT
          !.pc = IF owner[o].loaded > ReloadAt THEN "idle" ELSE "max",
          !.low = owner[o].read]]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* Capture maxRead separately through the DB mutex.
GetTaskBatchMax(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:219-244; service/matching/db.go:120-129
    /\ reader[o].pc = "max" /\ DBFree(o) /\ Alive(o)
    \* service/matching/pri_task_reader.go:219-244; service/matching/db.go:120-129
    /\ reader' = [reader EXCEPT ![o].max = owner[o].maxRead,
          ![o].pc = IF reader[o].low < owner[o].maxRead THEN "issue" ELSE "gap"]
    /\ UNCHANGED <<durable, catalog, owner, writer, metadata, dispatch, calls, history, audit>>

\* Unfenced GetTasks I/O for [low+1,upper+1).
GetTasksIssue(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:222-230; service/matching/db.go:700-715
    /\ reader[o].pc = "issue" /\ Alive(o)
    \* service/matching/pri_task_reader.go:222-230; service/matching/db.go:700-715
    /\ reader' = [reader EXCEPT ![o].upper = Min(reader[o].low + RangeSize, reader[o].max),
                                    ![o].pc = "store"]
    /\ UNCHANGED <<durable, catalog, owner, writer, metadata, dispatch, calls, history, audit>>

\* Actual ordered SQL read result; empty means no row in this interval at its snapshot.
GetTasksSnapshot(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* common/persistence/sql/task_v1.go:114-155; common/persistence/sql/sqlplugin/sqlite/task_v1.go:45-74
    /\ reader[o].pc = "store"
    \* common/persistence/sql/task_v1.go:114-155; common/persistence/sql/sqlplugin/sqlite/task_v1.go:45-74
    /\ reader' = [reader EXCEPT ![o].rows = First(
          {r \in durable.rows : reader[o].low < r /\ r <= reader[o].upper}, BatchSize),
          ![o].pc = "return"]
    /\ UNCHANGED <<durable, catalog, owner, writer, metadata, dispatch, calls, history, audit>>

\* Read I/O error schedules an explicit backoff wakeup.
GetTasksError(o) ==
    /\ o \in Owners /\ reader[o].pc = "store" /\ Alive(o) /\ ReaderFree(o)
    /\ reader' = [reader EXCEPT ![o] = IdleReader]
    /\ owner' = [owner EXCEPT ![o].backoff = TRUE]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* The independent timer callback acquires the reader mutex; it does not reset a newer read.
BackoffSignal(o) ==
    /\ o \in Owners /\ owner[o].backoff /\ Alive(o) /\ ReaderFree(o)
    /\ owner' = [owner EXCEPT ![o].notify = TRUE, ![o].backoff = FALSE]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* An empty SQL page scans the next bounded interval, up to the real ten-iteration limit.
GetTaskBatchReturn(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:222-244
    /\ reader[o].pc = "return" /\ Alive(o)
    \* service/matching/pri_task_reader.go:222-244
    /\ reader' = [reader EXCEPT
          ![o].pc = IF reader[o].rows # {} THEN "process"
                    ELSE IF reader[o].upper < reader[o].max /\ reader[o].scans + 1 < 10
                         THEN "issue" ELSE "gap",
          ![o].low = IF reader[o].rows = {} THEN reader[o].upper ELSE @,
          ![o].scans = @ + 1]
    /\ UNCHANGED <<durable, catalog, owner, writer, metadata, dispatch, calls, history, audit>>

\* Update read for every row, then filter expired, already-acked and outstanding duplicates under lock.
ProcessTaskBatch(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:247-295
    /\ reader[o].pc = "process" /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:247-295
    /\ LET fresh == {r \in reader[o].rows : ~history[catalog[r].work].expired
                      /\ r > owner[o].ack /\ r \notin owner[o].outstanding}
       IN /\ owner' = [owner EXCEPT ![o].read = Max(@, MaxSet(reader[o].rows)),
                  ![o].outstanding = @ \cup fresh, ![o].loaded = @ + Cardinality(fresh),
                  ![o].adding = @ \cup fresh]
          /\ reader' = [reader EXCEPT ![o].pc = "adding", ![o].todo = fresh]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* Pump signals the next read after adding the complete processed batch.
ProcessTaskBatchDone(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:198-200,280-282
    /\ reader[o].pc = "adding" /\ Alive(o)
    \* service/matching/pri_task_reader.go:198-200,280-282
    /\ reader[o].todo \cap owner[o].adding = {}
    \* service/matching/pri_task_reader.go:198-200,280-282
    /\ reader' = [reader EXCEPT ![o] = IdleReader]
    \* service/matching/pri_task_reader.go:198-200,280-282
    /\ owner' = [owner EXCEPT ![o].notify = TRUE]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* Keep the fixed stale-gap guard; never restore an older read or ack.
SetReadLevelAfterGapStale(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:484-497
    /\ reader[o].pc = "gap" /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:484-497
    /\ reader[o].low < owner[o].read
    \* service/matching/pri_task_reader.go:484-497
    /\ owner' = [owner EXCEPT ![o].notify = TRUE]
    \* service/matching/pri_task_reader.go:484-497
    /\ reader' = [reader EXCEPT ![o] = IdleReader]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* Nonempty outstanding prefix: move read alone, leaving ack unchanged.
SetReadLevelAfterGap(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:190-195,498-511
    /\ reader[o].pc = "gap" /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:190-195,498-511
    /\ reader[o].low >= owner[o].read /\ owner[o].ack # owner[o].read
    \* service/matching/pri_task_reader.go:190-195,498-511
    /\ owner' = [owner EXCEPT ![o].read = reader[o].low,
                    ![o].notify = @ \/ reader[o].low # reader[o].max]
    \* service/matching/pri_task_reader.go:190-195,498-511
    /\ reader' = [reader EXCEPT ![o] = IdleReader]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* Hold reader lock while propagating the new gap ack to the DB cache; read update follows.
SetReadLevelAfterGapAck(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:498-511
    /\ reader[o].pc = "gap" /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:498-511
    /\ reader[o].low >= owner[o].read /\ owner[o].ack = owner[o].read
    \* service/matching/pri_task_reader.go:498-511
    /\ owner' = [owner EXCEPT ![o].ack = reader[o].low,
          ![o].readerLock = "gapCache", ![o].cacheRead = reader[o].low]
    \* service/matching/pri_task_reader.go:498-511
    /\ reader' = [reader EXCEPT ![o].pc = "cache"]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* DB cache update and release of the nested DB/reader critical section; no metadata persistence.
UpdateAckLevelAfterGap(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:336-355; service/matching/pri_task_reader.go:509-511,190-195
    /\ owner[o].readerLock = "gapCache" /\ DBFree(o) /\ Alive(o)
    \* service/matching/db.go:336-355; service/matching/pri_task_reader.go:509-511,190-195
    /\ owner' = [owner EXCEPT ![o].dirty = @ \/ owner[o].cachedAck # Max(owner[o].cachedAck, owner[o].ack),
          ![o].cachedAck = Max(@, owner[o].ack),
          ![o].read = owner[o].cacheRead, ![o].readerLock = "free",
          ![o].notify = @ \/ reader[o].low # reader[o].max]
    \* service/matching/db.go:336-355; service/matching/pri_task_reader.go:509-511,190-195
    /\ reader' = [reader EXCEPT ![o] = IdleReader]
    /\ UNCHANGED <<durable, catalog, writer, metadata, dispatch, calls, history, audit>>

\* A poller matches one queued record; History request construction is a separate step.
PollTask(o, r, p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ r \in owner[o].queued
    /\ p \in Pollers
    \* service/matching/matching_engine.go:1015-1035,3511-3527,3590-3606
    /\ owner[o].life = "ready" /\ dispatch[p].pc = "idle"
    \* service/matching/matching_engine.go:1015-1035,3511-3527,3590-3606
    /\ owner' = [owner EXCEPT ![o].queued = @ \ {r}]
    \* service/matching/matching_engine.go:1015-1035,3511-3527,3590-3606
    /\ dispatch' = [dispatch EXCEPT ![p] = [IdleDispatch EXCEPT !.pc = "matched",
          !.owner = o, !.id = r, !.work = catalog[r].work]]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* After matching and the rate-limit wait, construct a fresh RequestId and issue History RPC.
RecordTaskStartedBegin(p, q) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    /\ q \in StartIds
    \* service/matching/matching_engine.go:3494-3527,3575-3606
    /\ dispatch[p].pc = "matched" /\ Alive(dispatch[p].owner) /\ q \notin UsedStarts
    \* service/matching/matching_engine.go:3494-3527,3575-3606
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "history", ![p].request = q]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* Rate limiter/context fails before constructing a History request. No accepted start is invented.
RecordTaskStartedPrecheckError(p, result) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    /\ result \in {"transient", "respool", "busy"}
    \* service/matching/matching_engine.go:3494-3503,3575-3584
    /\ dispatch[p].pc = "matched" /\ Alive(dispatch[p].owner)
    \* service/matching/matching_engine.go:3494-3503,3575-3584
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "historyReply", ![p].result = result]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* External History effect: accepted start, same-ID idempotence, obsolete or already started.
RecordTaskStarted(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/history/api/recordworkflowtaskstarted/api.go:68-111; service/history/api/recordactivitytaskstarted/api.go:150-183
    /\ dispatch[p].pc = "history"
    \* service/history/api/recordworkflowtaskstarted/api.go:68-111; service/history/api/recordactivitytaskstarted/api.go:150-183
    /\ LET w == dispatch[p].work
           result == IF history[w].obsolete THEN "obsolete"
                     ELSE IF history[w].start = 0 \/ history[w].start = dispatch[p].request
                          THEN "ok" ELSE "already"
       IN /\ history' = [history EXCEPT ![w].start =
                      IF result = "ok" THEN dispatch[p].request ELSE @]
          /\ dispatch' = [dispatch EXCEPT ![p].pc = "historyReply", ![p].result = result]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, audit>>

\* History fails without accepting: transient versus nontransient start error.
RecordTaskStartedError(p, result) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    /\ result \in {"transient", "respool", "busy"}
    \* service/matching/matching_engine.go:865-879,1113-1123; service/matching/pri_task_reader.go:119-139
    /\ dispatch[p].pc = "history"
    \* service/matching/matching_engine.go:865-879,1113-1123; service/matching/pri_task_reader.go:119-139
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "historyReply", ![p].result = result]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* Return the independently recorded History result to Matching.
RecordTaskStartedReply(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/matching_engine.go:808-885,1035-1128
    /\ dispatch[p].pc = "historyReply" /\ Alive(dispatch[p].owner)
    \* service/matching/matching_engine.go:808-885,1035-1128
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "finish", ![p].reply = dispatch[p].result]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* Lost response retried inside the same History RPC scope retains RequestId.
RecordTaskStartedRetryRPC(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/matching_engine.go:3527,3606; service/history/api/recordworkflowtaskstarted/api.go:98-111
    /\ dispatch[p].pc = "historyReply" /\ Alive(dispatch[p].owner) /\ dispatch[p].request # 0
    \* service/matching/matching_engine.go:3527,3606; service/history/api/recordworkflowtaskstarted/api.go:98-111
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "history", ![p].result = "none"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* Lost History response becomes a transient error; accepted History effect is retained.
RecordTaskStartedReplyLost(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/matching_engine.go:3527-3529,3606; service/matching/pri_task_reader.go:123-132
    /\ dispatch[p].pc = "historyReply" /\ Alive(dispatch[p].owner)
    \* service/matching/matching_engine.go:3527-3529,3606; service/matching/pri_task_reader.go:123-132
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "finish", ![p].reply = "transient"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* Sync finish sends response to Add; only BUSY_WORKFLOW start errors take spool fallback (partition manager:707-714).
FinishSyncTask(p) ==
    /\ p \in Pollers
    /\ dispatch[p].pc = "finish" /\ dispatch[p].call # 0 /\ Alive(dispatch[p].owner)
    /\ calls' = [calls EXCEPT ![dispatch[p].call].buffer =
          IF dispatch[p].reply \in {"ok", "already", "obsolete"} THEN "ok"
          ELSE IF dispatch[p].reply = "busy" THEN "busy" ELSE "unknown"]
    /\ dispatch' = [dispatch EXCEPT ![p].pc = IF dispatch[p].reply = "ok" THEN "worker" ELSE "idle"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, history, audit>>

\* task.go:getResponse and pri_matcher.go:trySyncMatch receive the buffered result.
SyncTaskReceive(a) ==
    /\ a \in CallIds /\ calls[a].pc = "syncWait" /\ calls[a].buffer # "none"
    /\ calls' = [calls EXCEPT ![a].pc = IF calls[a].buffer = "busy" THEN "spool" ELSE "reply",
          ![a].response = IF calls[a].buffer = "ok" THEN "ok" ELSE "error"]
    /\ audit' = [audit EXCEPT !.accepted = IF calls[a].buffer = "ok" THEN @ \cup {calls[a].work} ELSE @]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, history>>

\* Transient completion re-adds the same record, preserving outstanding status.
CompleteTaskTransient(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/pri_task_reader.go:119-133
    /\ dispatch[p].pc = "finish" /\ dispatch[p].call = 0
    \* service/matching/pri_task_reader.go:119-133
    /\ dispatch[p].reply = "transient" /\ Alive(dispatch[p].owner)
    \* service/matching/pri_task_reader.go:119-133
    /\ owner' = [owner EXCEPT ![dispatch[p].owner].adding = @ \cup {dispatch[p].id}]
    \* service/matching/pri_task_reader.go:119-133
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "idle"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* Replacement joins appendCh while original remains outstanding and reader lock is released.
RespoolTaskAfterError(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/pri_task_reader.go:135-140; service/matching/pri_backlog_manager.go:360-369
    /\ dispatch[p].pc = "finish" /\ dispatch[p].call = 0 /\ dispatch[p].reply \in {"respool", "busy"}
    \* service/matching/pri_task_reader.go:135-140; service/matching/pri_backlog_manager.go:360-369
    /\ Running(dispatch[p].owner)
    \* service/matching/pri_task_reader.go:135-140; service/matching/pri_backlog_manager.go:360-369
    /\ owner' = [owner EXCEPT ![dispatch[p].owner].appendQueue = Append(@,
          [work |-> dispatch[p].work, call |-> 0, poller |-> p, parent |-> dispatch[p].id])]
    \* service/matching/pri_task_reader.go:135-140; service/matching/pri_backlog_manager.go:360-369
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "replacement"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* Publish replacement result to its buffered channel; writer can start later work before callback resumes.
TaskWriterPublishReplacement(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_writer.go:172-174
    /\ writer[o].pc = "publish" /\ writer[o].poller # 0 /\ Alive(o)
    \* service/matching/pri_task_writer.go:172-174
    /\ LET p == writer[o].poller
           waiting == dispatch[p].pc = "replacement" /\ dispatch[p].owner = o
                       /\ dispatch[p].id = writer[o].parent
       IN dispatch' = IF waiting THEN [dispatch EXCEPT ![p].appendReply = writer[o].reply,
                            ![p].replacement = writer[o].id] ELSE dispatch
    \* service/matching/pri_task_writer.go:172-174
    /\ writer' = [writer EXCEPT ![o] = IdleWriter]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, calls, history, audit>>

\* Callback consumes success or final error; failed replacement unloads without original ack.
RespoolTaskReturn(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/pri_backlog_manager.go:367-387; service/matching/pri_task_reader.go:137-139
    /\ dispatch[p].pc = "replacement" /\ dispatch[p].appendReply # "none"
    \* service/matching/pri_backlog_manager.go:367-387; service/matching/pri_task_reader.go:137-139
    /\ Alive(dispatch[p].owner)
    \* service/matching/pri_backlog_manager.go:367-387; service/matching/pri_task_reader.go:137-139
    /\ dispatch' = [dispatch EXCEPT ![p].pc = IF dispatch[p].appendReply = "ok" THEN "finish" ELSE "replacementFailed",
               ![p].reply = IF dispatch[p].appendReply = "ok" THEN "replaced" ELSE "respool"]
    \* service/matching/pri_backlog_manager.go:367-387; service/matching/pri_task_reader.go:137-139
    /\ owner' = [owner EXCEPT ![dispatch[p].owner].skipFinal = @,
               ![dispatch[p].owner].life = IF dispatch[p].appendReply # "ok" THEN "unload" ELSE @]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* ThrottleRetry appends a new replacement attempt at channel tail, without releasing original.
RespoolTaskRetry(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/pri_backlog_manager.go:367-369
    /\ dispatch[p].pc = "replacement" /\ dispatch[p].appendReply \in {"unknown", "definite"}
    \* service/matching/pri_backlog_manager.go:367-369
    /\ Running(dispatch[p].owner)
    \* service/matching/pri_backlog_manager.go:367-369
    /\ owner' = [owner EXCEPT ![dispatch[p].owner].appendQueue = Append(@,
         [work |-> dispatch[p].work, call |-> 0, poller |-> p, parent |-> dispatch[p].id])]
    \* service/matching/pri_backlog_manager.go:367-369
    /\ dispatch' = [dispatch EXCEPT ![p].appendReply = "none", ![p].replacement = 0]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* Shutdown wins the replacement receipt selection; an already submitted store write may still commit.
RespoolTaskShutdown(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/pri_task_writer.go:72-96; service/matching/pri_backlog_manager.go:374-387
    /\ dispatch[p].call = 0 /\ owner[dispatch[p].owner].life = "stopped"
    \* service/matching/pri_task_writer.go:72-96; service/matching/pri_backlog_manager.go:374-387
    /\ (dispatch[p].pc = "replacement" \/
          (dispatch[p].pc = "finish" /\ dispatch[p].reply \in {"respool", "busy"}))
    \* service/matching/pri_task_writer.go:72-96; service/matching/pri_backlog_manager.go:374-387
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "replacementFailed"]
    \* service/matching/pri_task_writer.go:72-96; service/matching/pri_backlog_manager.go:374-387
    /\ owner' = [owner EXCEPT ![dispatch[p].owner].skipFinal = TRUE]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* Mark completion and pop only the completed minimum prefix. Reader lock remains held through GC/cache.
CompleteTaskAck(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/pri_task_reader.go:142-156,452-479
    /\ dispatch[p].pc = "finish" /\ dispatch[p].call = 0
    \* service/matching/pri_task_reader.go:142-156,452-479
    /\ dispatch[p].reply \in {"ok", "already", "obsolete", "expired", "replaced"}
    \* service/matching/pri_task_reader.go:142-156,452-479
    /\ LET o == dispatch[p].owner
           r == dispatch[p].id
           remaining == AckRemaining(o,r)
       IN /\ Alive(o) /\ ReaderFree(o) /\ r \in owner[o].outstanding \ owner[o].done
          /\ owner' = [owner EXCEPT ![o].ack = Max(@, MaxSet(owner[o].outstanding \ remaining)),
                ![o].outstanding = remaining, ![o].done = (owner[o].done \cup {r}) \cap remaining,
                ![o].loaded = @ - 1, ![o].readerLock = "ackDrain", ![o].cachePoller = p]
          /\ audit' = [audit EXCEPT
                !.releases = IF dispatch[p].reply = "replaced" THEN @ \cup {<<r, dispatch[p].replacement>>} ELSE @,
                !.badRelease = @ \/ (dispatch[p].reply = "replaced" /\
                     ~(dispatch[p].replacement \in audit.committed /\
                       catalog[dispatch[p].replacement].work = dispatch[p].work))]
    \* service/matching/pri_task_reader.go:142-156,452-479
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "ackCache"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history>>

\* The drained check acquires DB mutex while holding reader lock; keep its blocking boundary.
AckTaskLockedDrained(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:448-449,476-479; service/matching/db.go:120-129
    /\ owner[o].readerLock = "ackDrain" /\ Alive(o) /\ DBFree(o)
    \* service/matching/pri_task_reader.go:448-449,476-479; service/matching/db.go:120-129
    /\ owner' = [owner EXCEPT ![o].ack = IF owner[o].outstanding = {} /\ owner[o].read >= owner[o].maxRead
                                            THEN owner[o].read ELSE @,
                             ![o].readerLock = "ackGC"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Capture GC bound under the same reader lock; timer/gap eligibility abstracts scheduling.
MaybeGCLocked(o, launch) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ launch \in BOOLEAN
    \* service/matching/pri_task_reader.go:149-156,522-540
    /\ owner[o].readerLock = "ackGC" /\ Alive(o)
    \* service/matching/pri_task_reader.go:149-156,522-540
    /\ (launch => owner[o].gcPC = "idle" /\ owner[o].ack # owner[o].gcLast)
    \* service/matching/pri_task_reader.go:149-156,522-540
    /\ ((owner[o].gcPC = "idle" /\ owner[o].ack - owner[o].gcLast >= DeleteBatchSize) => launch)
    \* service/matching/pri_task_reader.go:149-156,522-540
    /\ owner' = [owner EXCEPT ![o].readerLock = "ackCache",
          ![o].notify = @ \/ owner[o].loaded = ReloadAt,
          ![o].gcPC = IF launch THEN "store" ELSE @,
          ![o].gcBound = IF launch THEN owner[o].ack ELSE @]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Completion updates cached ack under DB mutex; poll response can return only after callback completes.
UpdateAckLevelAndBacklogStats(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:156; service/matching/db.go:336-355
    /\ owner[o].readerLock = "ackCache" /\ Alive(o) /\ DBFree(o)
    \* service/matching/pri_task_reader.go:156; service/matching/db.go:336-355
    /\ owner' = [owner EXCEPT ![o].dirty = @ \/ owner[o].cachedAck # Max(owner[o].cachedAck, owner[o].ack),
          ![o].cachedAck = Max(@, owner[o].ack), ![o].readerLock = "free"]
    \* service/matching/pri_task_reader.go:156; service/matching/db.go:336-355
    /\ dispatch' = [dispatch EXCEPT ![owner[o].cachePoller].pc =
          IF @ = "ackCache" /\ dispatch[owner[o].cachePoller].reply = "ok" THEN "worker" ELSE "idle"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* Worker receives successful poll response after task.finish, separately from History acceptance.
PollTaskQueueResponse(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/matching_engine.go:885-887,1128-1130
    /\ dispatch[p].pc = "worker" /\ Alive(dispatch[p].owner)
    \* service/matching/matching_engine.go:885-887,1128-1130
    /\ history' = [history EXCEPT ![dispatch[p].work].worker = TRUE]
    \* service/matching/matching_engine.go:885-887,1128-1130
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "idle"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, audit>>

\* External transport loses Worker receipt; this does not revoke accepted History start.
PollTaskQueueResponseLost(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/matching_engine.go:885-887,1128-1130
    /\ dispatch[p].pc = "worker"
    \* service/matching/matching_engine.go:885-887,1128-1130
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "idle"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* Environment clock crosses the captured nonzero task expiry; SQL retains the row.
ExpireTask(w) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ w \in Work
    \* service/matching/task_validation.go:217-219
    /\ ~history[w].expired
    \* service/matching/task_validation.go:217-219
    /\ history' = [history EXCEPT ![w].expired = TRUE]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, calls, audit>>

\* External History marks this logical stamp obsolete; successor stamp is outside this work identity.
ObsoleteTask(w) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ w \in Work
    \* service/history/api/recordworkflowtaskstarted/api.go:68-78; service/history/api/recordactivitytaskstarted/api.go:178-183
    /\ ~history[w].obsolete
    \* service/history/api/recordworkflowtaskstarted/api.go:68-78; service/history/api/recordactivitytaskstarted/api.go:178-183
    /\ history' = [history EXCEPT ![w].obsolete = TRUE]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, dispatch, calls, audit>>

\* Observed legitimate expiry completes a previously loaded record.
FinishExpiredTask(o, r, p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ r \in owner[o].queued
    /\ p \in Pollers
    \* service/matching/pri_matcher.go:211-216,268-271; service/matching/pri_task_reader.go:364-366
    /\ Running(o) /\ dispatch[p].pc = "idle" /\ history[catalog[r].work].expired
    \* service/matching/pri_matcher.go:211-216,268-271; service/matching/pri_task_reader.go:364-366
    /\ owner' = [owner EXCEPT ![o].queued = @ \ {r}]
    \* service/matching/pri_matcher.go:211-216,268-271; service/matching/pri_task_reader.go:364-366
    /\ dispatch' = [dispatch EXCEPT ![p] = [IdleDispatch EXCEPT !.pc = "finish",
             !.owner = o, !.id = r, !.work = catalog[r].work, !.reply = "expired"]]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, calls, history, audit>>

\* Periodic metadata write or read-only ownership check; retain both idle-queue paths.
SyncStateBegin(o, kind) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    /\ kind \in {"sync", "verify"}
    \* service/matching/db.go:298-333
    /\ Running(o) /\ DBFree(o)
    \* service/matching/db.go:298-333
    /\ (kind = "sync" \/ ~owner[o].dirty)
    \* service/matching/db.go:298-333
    /\ metadata' = [metadata EXCEPT ![o] = [IdleMetadata EXCEPT !.pc = "store",
           !.kind = kind, !.expect = owner[o].range, !.newRange = owner[o].range,
           !.ack = owner[o].cachedAck]]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, dispatch, calls, history, audit>>

\* Reactive allocation-block renewal; no counter limit on normal ID exhaustion.
RenewLeaseBegin(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_writer.go:108-116,212-224; service/matching/db.go:152-165
    /\ Running(o) /\ DBFree(o) /\ writer[o].pc = "assign"
    \* service/matching/pri_task_writer.go:108-116,212-224; service/matching/db.go:152-165
    /\ owner[o].nextId > owner[o].endId
    \* service/matching/pri_task_writer.go:108-116,212-224; service/matching/db.go:152-165
    /\ metadata' = [metadata EXCEPT ![o] = [IdleMetadata EXCEPT !.pc = "store",
           !.kind = "renew", !.expect = owner[o].range, !.newRange = owner[o].range + 1,
           !.ack = owner[o].cachedAck]]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, dispatch, calls, history, audit>>

\* Fresh manager lifetime begins the supported conditional reacquisition path.
TakeOverTaskQueueBegin(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:152-159,176-183
    /\ owner[o].life = "cold"
    \* service/matching/db.go:152-159,176-183
    /\ owner' = [owner EXCEPT ![o].life = "acquiring"]
    \* service/matching/db.go:152-159,176-183
    /\ metadata' = [metadata EXCEPT ![o] = [IdleMetadata EXCEPT !.pc = "read", !.kind = "takeover"]]
    /\ UNCHANGED <<durable, catalog, writer, reader, dispatch, calls, history, audit>>

\* Capture persisted metadata before CAS; old owner SyncState may commit in between.
TakeOverTaskQueueSnapshot(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:179-196
    /\ metadata[o].pc = "read" /\ owner[o].life = "acquiring"
    \* service/matching/db.go:179-196
    /\ metadata' = [metadata EXCEPT ![o].pc = "store", ![o].expect = durable.range,
           ![o].newRange = durable.range + 1, ![o].ack = durable.ack]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, dispatch, calls, history, audit>>

\* Atomic metadata CAS. A takeover may overwrite a newer ack with its earlier safe snapshot.
UpdateTaskQueueCommit(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* common/persistence/sql/task_queues.go:86-127; service/matching/db.go:241-255
    /\ metadata[o].pc = "store" /\ metadata[o].kind # "verify"
    \* common/persistence/sql/task_queues.go:86-127; service/matching/db.go:241-255
    /\ metadata[o].expect = durable.range
    \* common/persistence/sql/task_queues.go:86-127; service/matching/db.go:241-255
    /\ durable' = [durable EXCEPT !.range = metadata[o].newRange, !.ack = metadata[o].ack]
    \* common/persistence/sql/task_queues.go:86-127; service/matching/db.go:241-255
    /\ metadata' = [metadata EXCEPT ![o].pc = "result", ![o].outcome = "ok"]
    \* common/persistence/sql/task_queues.go:86-127; service/matching/db.go:241-255
    /\ audit' = [audit EXCEPT !.fences = @ \cup {<<metadata[o].expect, durable.range>>}]
    /\ UNCHANGED <<catalog, owner, writer, reader, dispatch, calls, history>>

\* Unchanged metadata still checks owner range; mismatch is fatal.
VerifyOwnership(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:318-333
    /\ metadata[o].pc = "store" /\ metadata[o].kind = "verify"
    \* service/matching/db.go:318-333
    /\ metadata' = [metadata EXCEPT ![o].pc = "result",
          ![o].outcome = IF metadata[o].expect = durable.range THEN "ok" ELSE "condition"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, dispatch, calls, history, audit>>

\* Failed CAS cannot modify either durable range or metadata.
UpdateTaskQueueConditionFailed(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* common/persistence/sql/task_queues.go:97-106; common/persistence/sql/task_v1.go:187-205
    /\ metadata[o].pc = "store" /\ metadata[o].kind # "verify"
    \* common/persistence/sql/task_queues.go:97-106; common/persistence/sql/task_v1.go:187-205
    /\ metadata[o].expect # durable.range
    \* common/persistence/sql/task_queues.go:97-106; common/persistence/sql/task_v1.go:187-205
    /\ metadata' = [metadata EXCEPT ![o].pc = "result", ![o].outcome = "condition"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, dispatch, calls, history, audit>>

\* Store rejects/does not commit the metadata operation.
UpdateTaskQueueError(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:246-251,319-325
    /\ metadata[o].pc = "store"
    \* service/matching/db.go:246-251,319-325
    /\ metadata' = [metadata EXCEPT ![o].pc = "result", ![o].outcome = "error"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, dispatch, calls, history, audit>>

\* Committed metadata or lease response is lost; local range remains old.
UpdateTaskQueueReplyLost(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:246-255
    /\ metadata[o].pc = "result" /\ metadata[o].outcome = "ok"
    \* service/matching/db.go:246-255
    /\ metadata' = [metadata EXCEPT ![o].outcome = "error"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, dispatch, calls, history, audit>>

\* Apply lease response locally, initialize fresh reader from captured ack, or report failure.
UpdateTaskQueueReturn(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:196-207,241-255; service/matching/pri_task_writer.go:140-149,217-224; service/matching/pri_backlog_manager.go:108-116
    /\ metadata[o].pc = "result" /\ Alive(o)
    \* service/matching/db.go:196-207,241-255; service/matching/pri_task_writer.go:140-149,217-224; service/matching/pri_backlog_manager.go:108-116
    /\ LET ok == metadata[o].outcome = "ok"
           take == metadata[o].kind = "takeover"
           renew == metadata[o].kind = "renew"
           stop == owner[o].life = "stopping" /\ owner[o].stopStep = "wait"
       IN owner' = [owner EXCEPT
            ![o].dirty = IF ok /\ metadata[o].kind # "verify" THEN FALSE ELSE @,
            ![o].range = IF ok /\ (take \/ renew) THEN metadata[o].newRange ELSE @,
            ![o].nextId = IF ok /\ (take \/ renew) THEN (metadata[o].newRange-1)*RangeSize+1 ELSE @,
            ![o].endId = IF ok /\ (take \/ renew) THEN metadata[o].newRange*RangeSize ELSE @,
            ![o].read = IF ok /\ take THEN metadata[o].ack ELSE @,
            ![o].ack = IF ok /\ take THEN metadata[o].ack ELSE @,
            ![o].cachedAck = IF ok /\ take THEN metadata[o].ack ELSE @,
            ![o].maxRead = IF ok /\ take THEN (metadata[o].newRange-1)*RangeSize ELSE @,
            ![o].notify = @ \/ (ok /\ take),
            ![o].life = IF take THEN (IF ok THEN "ready" ELSE "cold")
                         ELSE IF metadata[o].outcome = "condition" /\ ~stop THEN "unload" ELSE @,
            ![o].skipFinal = @,
            ![o].stopStep = IF stop THEN "cancel" ELSE @]
    \* service/matching/db.go:196-207,241-255; service/matching/pri_task_writer.go:140-149,217-224; service/matching/pri_backlog_manager.go:108-116
    /\ writer' = IF metadata[o].kind = "renew" /\ metadata[o].outcome # "ok"
          THEN [writer EXCEPT ![o].pc = "renewError", ![o].reply =
              IF metadata[o].outcome = "condition" THEN "condition" ELSE "unknown"] ELSE writer
    /\ metadata' = [metadata EXCEPT ![o] = IdleMetadata]
    /\ UNCHANGED <<durable, catalog, reader, dispatch, calls, history, audit>>

\* External supported unload marks stopped status before final backlog synchronization.
StopBegin(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/physical_task_queue_manager.go:319-328
    /\ owner[o].life = "ready"
    \* service/matching/physical_task_queue_manager.go:319-328
    /\ owner' = [owner EXCEPT ![o].life = "stopping", ![o].stopStep = "cache"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Reactive fatal-conflict/replacement-failure unload skips final metadata write.
UnloadAfterError(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_backlog_manager.go:108-116,374-387; service/matching/physical_task_queue_manager.go:319-334
    /\ owner[o].life = "unload" /\ owner[o].skipFinal
    \* service/matching/pri_backlog_manager.go:108-116,374-387; service/matching/physical_task_queue_manager.go:319-334
    /\ owner' = [owner EXCEPT ![o].life = "stopping", ![o].stopStep = "cancel"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Refresh cached reader ack before the final SyncState; queue context is not yet canceled.
StopRefreshAck(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_backlog_manager.go:125-140
    /\ owner[o].life = "stopping" /\ owner[o].stopStep = "cache"
    \* service/matching/pri_backlog_manager.go:125-140
    /\ ReaderFree(o) /\ DBFree(o)
    \* service/matching/pri_backlog_manager.go:125-140
    /\ owner' = [owner EXCEPT ![o].dirty = @ \/ owner[o].cachedAck # Max(owner[o].cachedAck, owner[o].ack),
          ![o].cachedAck = Max(@, owner[o].ack), ![o].stopStep = "sync"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Start final metadata persistence; errors are ignored by Stop.
StopSyncState(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_backlog_manager.go:142-144
    /\ owner[o].life = "stopping" /\ owner[o].stopStep = "sync" /\ DBFree(o)
    \* service/matching/pri_backlog_manager.go:142-144
    /\ \E kind \in {"sync", "verify"} :
          /\ (kind = "sync" \/ ~owner[o].dirty)
          /\ metadata' = [metadata EXCEPT ![o] = [IdleMetadata EXCEPT !.pc = "store",
               !.kind = kind, !.expect = owner[o].range, !.newRange = owner[o].range,
               !.ack = owner[o].cachedAck]]
    \* service/matching/pri_backlog_manager.go:142-144
    /\ owner' = [owner EXCEPT ![o].stopStep = "wait"]
    /\ UNCHANGED <<durable, catalog, writer, reader, dispatch, calls, history, audit>>

\* Cancel queue after final update. In-flight store I/O and callbacks may still finish.
StopCancel(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/physical_task_queue_manager.go:327-334
    /\ owner[o].life = "stopping" /\ owner[o].stopStep = "cancel"
    \* service/matching/physical_task_queue_manager.go:327-334
    /\ owner' = [owner EXCEPT ![o].life = "stopped"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Process failure freezes local callbacks; durable effects already submitted may still commit.
Crash(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:176-207; service/matching/pri_task_writer.go:68-98
    /\ owner[o].life \in {"ready", "stopping", "unload", "acquiring"}
    \* service/matching/db.go:176-207; service/matching/pri_task_writer.go:68-98
    /\ owner' = [owner EXCEPT ![o].life = "crashed", ![o].queued = {},
           ![o].adding = {}, ![o].notify = FALSE]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Unfenced SQL deletion uses the captured exclusive bound gcBound+1 and row limit, even for an old owner.
CompleteTasksLessThan(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/db.go:741-765; common/persistence/sql/task_v1.go:158-184; common/persistence/sql/sqlplugin/sqlite/task_v1.go:28-31,77-96
    /\ owner[o].gcPC = "store"
    \* service/matching/db.go:741-765; common/persistence/sql/task_v1.go:158-184; common/persistence/sql/sqlplugin/sqlite/task_v1.go:28-31,77-96
    /\ LET deleted == First({r \in durable.rows : r <= owner[o].gcBound}, DeleteBatchSize)
       IN /\ durable' = [durable EXCEPT !.rows = @ \ deleted]
          /\ owner' = [owner EXCEPT ![o].gcPC = "result", ![o].gcCount = Cardinality(deleted)]
          /\ audit' = [audit EXCEPT !.deleted = @ \cup deleted,
                 !.badDelete = @ \/ (\E r \in deleted : ~Discharged(catalog[r].work)
                       /\ ~Covers(catalog[r].work, durable.rows \ deleted, durable.ack))]
    /\ UNCHANGED <<catalog, writer, reader, metadata, dispatch, calls, history>>

\* Clear inGC; exactly a full delete batch does not prove the captured interval is exhausted.
DoGCReturn(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:543-577
    /\ owner[o].gcPC = "result" /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:543-577
    /\ owner' = [owner EXCEPT ![o].gcPC = "idle",
          ![o].gcLast = IF owner[o].gcCount < DeleteBatchSize THEN owner[o].gcBound ELSE @]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* GC failure/lost result retains gcLast; durable deletion, if already committed, is not undone.
DoGCError(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_reader.go:550-568
    /\ owner[o].gcPC \in {"store", "result"} /\ Alive(o) /\ ReaderFree(o)
    \* service/matching/pri_task_reader.go:550-568
    /\ owner' = [owner EXCEPT ![o].gcPC = "idle"]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

\* Crash boundary: discard a local writer frame only after submitted store effect has resolved.
DiscardCrashedWriter(o) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ o \in Owners
    \* service/matching/pri_task_writer.go:68-98,152-179
    /\ owner[o].life = "crashed" /\ writer[o].pc \notin {"idle", "store"}
    \* service/matching/pri_task_writer.go:68-98,152-179
    /\ writer' = [writer EXCEPT ![o] = IdleWriter]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, calls, history, audit>>

\* Crashed Matching connection ends after any independently submitted History effect resolves.
PollerDisconnect(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/matching_engine.go:1002-1035,1128-1130
    /\ owner[dispatch[p].owner].life = "crashed"
    \* service/matching/matching_engine.go:1002-1035,1128-1130
    /\ dispatch[p].pc \notin {"idle", "history"}
    \* service/matching/matching_engine.go:1002-1035,1128-1130
    /\ writer[dispatch[p].owner].poller # p
    \* service/matching/matching_engine.go:1002-1035,1128-1130
    /\ dispatch' = [dispatch EXCEPT ![p] = IdleDispatch]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>

\* Failed completion callback returns to its poll invocation; a later poll can use this slot.
PollTaskErrorReturn(p) ==
    \* Parameter domains: finite actors/identities, or an actual queue membership.
    /\ p \in Pollers
    \* service/matching/pri_task_reader.go:137-139; service/matching/matching_engine.go:865-882,1113-1126
    /\ dispatch[p].pc = "replacementFailed" /\ Alive(dispatch[p].owner)
    \* service/matching/pri_task_reader.go:137-139; service/matching/matching_engine.go:865-882,1113-1126
    /\ dispatch' = [dispatch EXCEPT ![p].pc = "idle"]
    /\ UNCHANGED <<durable, catalog, owner, writer, reader, metadata, calls, history, audit>>


\* Type and identity checks are core; counts and cursor checks are structural.
OwnerLife == {"cold", "acquiring", "ready", "unload", "stopping", "stopped", "crashed"}
AppendRequestType == [work : Work, call : CallIds \cup {0}, poller : Pollers \cup {0}, parent : Nat]
OwnerType == [life : OwnerLife, range : Nat, nextId : Nat, endId : Nat,
  read : Nat, ack : Nat, cachedAck : Nat, maxRead : Nat, loaded : Int,
  outstanding : SUBSET (DOMAIN catalog), done : SUBSET (DOMAIN catalog),
  adding : SUBSET (DOMAIN catalog), queued : SUBSET (DOMAIN catalog),
  appendQueue : Seq(AppendRequestType), notify : BOOLEAN,
  readerLock : {"free", "gapCache", "ackDrain", "ackGC", "ackCache"},
  cacheRead : Nat, cachePoller : Pollers \cup {0}, backoff : BOOLEAN, skipFinal : BOOLEAN, dirty : BOOLEAN,
  stopStep : {"none", "cache", "sync", "wait", "cancel"},
  gcPC : {"idle", "store", "result"}, gcBound : Nat, gcLast : Nat, gcCount : Nat]
WriterType == [pc : {"idle", "assign", "renewError", "create", "store", "storeResult", "notify", "adding", "publish"},
  work : Work \cup {"none"}, call : CallIds \cup {0}, poller : Pollers \cup {0},
  parent : Nat, id : Nat, range : Nat, before : Nat,
  outcome : {"none", "commit", "condition", "limit", "noCommit"},
  reply : {"none", "ok", "condition", "definite", "unknown"}]
ReaderType == [pc : {"idle", "max", "issue", "store", "return", "process", "adding", "gap", "cache", "backoff"},
  low : Nat, max : Nat, upper : Nat, scans : Nat,
  rows : SUBSET (DOMAIN catalog), todo : SUBSET (DOMAIN catalog)]
MetadataType == [pc : {"idle", "read", "store", "result"},
  kind : {"none", "sync", "verify", "renew", "takeover"}, expect : Nat, newRange : Nat, ack : Nat,
  outcome : {"none", "ok", "condition", "error"}]
DispatchType == [pc : {"idle", "matched", "history", "historyReply", "finish", "replacement", "replacementFailed", "ackCache", "worker"},
  owner : Owners, id : Nat, call : CallIds \cup {0}, work : Work \cup {"none"},
  request : StartIds \cup {0}, result : {"none", "ok", "obsolete", "already", "transient", "respool", "busy"},
  reply : {"none", "ok", "obsolete", "already", "transient", "respool", "busy", "expired", "replaced"},
  replacement : Nat, appendReply : {"none", "ok", "condition", "definite", "unknown"}]
CallType == [pc : {"unused", "offer", "spool", "syncWait", "appendWait", "reply", "done"},
  owner : Owners, work : Work \cup {"none"}, buffer : {"none", "ok", "condition", "definite", "unknown", "busy"},
  response : {"none", "ok", "error"}, receipt : {"none", "ok", "error", "lost"}]

TypeOK ==
    /\ owner \in [Owners -> OwnerType] /\ writer \in [Owners -> WriterType]
    /\ reader \in [Owners -> ReaderType] /\ metadata \in [Owners -> MetadataType]
    /\ dispatch \in [Pollers -> DispatchType] /\ calls \in [CallIds -> CallType]
    /\ audit.badDelete \in BOOLEAN /\ audit.badRelease \in BOOLEAN
    /\ audit.fences \subseteq (Nat \X Nat) /\ audit.releases \subseteq (Nat \X Nat)
    /\ cursor \in [Owners -> [read : Nat, ack : Nat]]
    /\ durable.range \in Nat \ {0} /\ durable.ack \in Nat
    /\ durable.rows \subseteq DOMAIN catalog
    /\ \A r \in DOMAIN catalog : r \in Nat \ {0} /\ catalog[r].work \in Work
                                   /\ catalog[r].parent \in Nat
    /\ DOMAIN owner = Owners /\ DOMAIN writer = Owners /\ DOMAIN reader = Owners
    /\ DOMAIN metadata = Owners /\ DOMAIN dispatch = Pollers /\ DOMAIN calls = CallIds
    /\ DOMAIN history = Work /\ DOMAIN cursor = Owners
    /\ \A o \in Owners :
         /\ owner[o].life \in OwnerLife
         /\ owner[o].range \in Nat /\ owner[o].nextId \in Nat /\ owner[o].endId \in Nat
         /\ owner[o].read \in Nat /\ owner[o].ack \in Nat /\ owner[o].cachedAck \in Nat
         /\ owner[o].maxRead \in Nat /\ owner[o].loaded \in Int
         /\ owner[o].outstanding \subseteq DOMAIN catalog
         /\ owner[o].done \subseteq owner[o].outstanding
         /\ owner[o].adding \subseteq DOMAIN catalog /\ owner[o].queued \subseteq DOMAIN catalog
         /\ owner[o].notify \in BOOLEAN /\ owner[o].skipFinal \in BOOLEAN
         /\ owner[o].readerLock \in {"free", "gapCache", "ackDrain", "ackGC", "ackCache"}
         /\ owner[o].gcPC \in {"idle", "store", "result"}
         /\ writer[o].pc \in {"idle", "assign", "renewError", "create", "store", "storeResult", "notify", "adding", "publish"}
         /\ writer[o].id \in Nat /\ writer[o].parent \in Nat
         /\ reader[o].pc \in {"idle", "max", "issue", "store", "return", "process", "adding", "gap", "cache", "backoff"}
         /\ reader[o].rows \subseteq DOMAIN catalog /\ reader[o].todo \subseteq DOMAIN catalog
         /\ metadata[o].pc \in {"idle", "read", "store", "result"}
    /\ \A p \in Pollers : dispatch[p].pc \in {"idle", "matched", "history", "historyReply", "finish", "replacement", "replacementFailed", "ackCache", "worker"}
    /\ \A a \in CallIds : calls[a].pc \in {"unused", "offer", "spool", "syncWait", "appendWait", "reply", "done"}
    /\ \A w \in Work : history[w].start \in StartIds \cup {0}
                     /\ history[w].expired \in BOOLEAN /\ history[w].obsolete \in BOOLEAN
                     /\ history[w].worker \in BOOLEAN
    /\ audit.accepted \subseteq Work /\ audit.committed \subseteq DOMAIN catalog
    /\ audit.uncertain \subseteq audit.committed /\ audit.deleted \subseteq audit.committed

RecordIdentity ==
    /\ \A r \in DOMAIN catalog : catalog[r].parent # 0 =>
           /\ catalog[r].parent \in DOMAIN catalog
           /\ catalog[r].parent < r
           /\ catalog[catalog[r].parent].work = catalog[r].work
    /\ \A p \in Pollers : dispatch[p].id # 0 =>
                  catalog[dispatch[p].id].work = dispatch[p].work
    /\ \A o \in Owners : writer[o].id # 0 =>
                  catalog[writer[o].id].work = writer[o].work
ReaderAccounting ==
    \A o \in Owners : owner[o].loaded = Cardinality(owner[o].outstanding \ owner[o].done)
CursorOrder ==
    \A o \in Owners : /\ owner[o].ack <= Max(owner[o].read, owner[o].cacheRead)
                       /\ owner[o].cachedAck <= owner[o].ack
AcceptedWorkCovered == \A w \in audit.accepted : Discharged(w) \/ Recoverable(w)
AckPrefixSound ==
    \A o \in Owners : \A r \in audit.committed : r <= owner[o].ack =>
        Discharged(catalog[r].work) \/ Covers(catalog[r].work, durable.rows, owner[o].ack)
DeletionSound == ~audit.badDelete
RangeConditionalWrite == \A f \in audit.fences : f[1] = f[2]
ReplacementBeforeRelease ==
    /\ ~audit.badRelease
    /\ \A pair \in audit.releases : pair[2] \in audit.committed
                             /\ catalog[pair[1]].work = catalog[pair[2]].work
PerOwnerCursorMonotonic == \A o \in Owners : owner[o].read = cursor[o].read
                                            /\ owner[o].ack = cursor[o].ack
\* No unconditional Worker-receipt or strict scheduling-order claim is made.
EventuallyDischarged == \A w \in Work : (w \in audit.accepted) ~> Discharged(w)

\* The actual atomic skipFinalUpdate.Store(true), including errShutdown after Stop.
\* A retryable lease failure is retried inside allocTaskIDBlock; the retry budget is time.
RenewLeaseRetry(o) ==
    /\ o \in Owners /\ writer[o].pc = "renewError" /\ writer[o].reply = "unknown" /\ Running(o)
    /\ writer' = [writer EXCEPT ![o].pc = "assign", ![o].reply = "none"]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, calls, history, audit>>

\* Once allocation retry expires, the writer publishes the error without reserving an ID.
RenewLeaseFailure(o) ==
    /\ o \in Owners /\ writer[o].pc = "renewError" /\ Alive(o)
    /\ writer' = [writer EXCEPT ![o].pc = "publish"]
    /\ UNCHANGED <<durable, catalog, owner, reader, metadata, dispatch, calls, history, audit>>

SignalIfFatal(o) ==
    /\ o \in Owners /\ Alive(o)
    /\ owner[o].life \in {"unload", "stopped"}
    /\ owner' = [owner EXCEPT ![o].skipFinal = TRUE,
         ![o].life = IF @ = "ready" THEN "unload" ELSE @]
    /\ UNCHANGED <<durable, catalog, writer, reader, metadata, dispatch, calls, history, audit>>

RawNext ==
    \/ \E o \in Owners : RenewLeaseRetry(o) \/ RenewLeaseFailure(o)
    \/ \E a \in CallIds : SyncTaskReceive(a)
    \/ \E o \in Owners : SignalIfFatal(o)
    \/ \E a \in CallIds : \E w \in Work : \E o \in Owners : AddTask(a, w, o)
    \/ \E a \in CallIds : TrySyncMatchFallback(a)
    \/ \E a \in CallIds : \E p \in Pollers : TrySyncMatch(a, p)
    \/ \E a \in CallIds : SpoolTask(a)
    \/ \E o \in Owners : TaskWriterDequeue(o)
    \/ \E o \in Owners : AssignTaskIDs(o)
    \/ \E o \in Owners : CreateTasksBegin(o)
    \/ \E o \in Owners : CreateTasksCommit(o)
    \/ \E o \in Owners : CreateTasksConditionFailed(o)
    \/ \E o \in Owners : \E result \in {"limit", "noCommit"} : CreateTasksReject(o, result)
    \/ \E o \in Owners : \E reply \in {"ok", "definite", "unknown", "condition"} : CreateTasksReturn(o, reply)
    \/ \E o \in Owners : CreateTasksUncertainReturn(o)
    \/ \E o \in Owners : SignalNewTasksBypass(o)
    \/ \E o \in Owners : SignalNewTasksWake(o)
    \/ \E o \in Owners : \E r \in owner[o].adding : AddTaskToMatcher(o, r)
    \/ \E o \in Owners : \E r \in owner[o].adding : AddTaskToMatcherClosed(o, r)
    \/ \E o \in Owners : SignalReadersDone(o)
    \/ \E o \in Owners : TaskWriterPublish(o)
    \/ \E a \in CallIds : AppendTaskReceive(a)
    \/ \E a \in CallIds : AppendTaskShutdown(a)
    \/ \E a \in CallIds : AddTaskReply(a)
    \/ \E a \in CallIds : AddTaskReplyLost(a)
    \/ \E o \in Owners : GetTasksPump(o)
    \/ \E o \in Owners : GetTaskBatchMax(o)
    \/ \E o \in Owners : GetTasksIssue(o)
    \/ \E o \in Owners : GetTasksSnapshot(o)
    \/ \E o \in Owners : GetTasksError(o)
    \/ \E o \in Owners : BackoffSignal(o)
    \/ \E o \in Owners : GetTaskBatchReturn(o)
    \/ \E o \in Owners : ProcessTaskBatch(o)
    \/ \E o \in Owners : ProcessTaskBatchDone(o)
    \/ \E o \in Owners : SetReadLevelAfterGapStale(o)
    \/ \E o \in Owners : SetReadLevelAfterGap(o)
    \/ \E o \in Owners : SetReadLevelAfterGapAck(o)
    \/ \E o \in Owners : UpdateAckLevelAfterGap(o)
    \/ \E o \in Owners : \E r \in owner[o].queued : \E p \in Pollers : PollTask(o, r, p)
    \/ \E p \in Pollers : \E q \in StartIds : RecordTaskStartedBegin(p, q)
    \/ \E p \in Pollers : \E result \in {"transient", "respool", "busy"} : RecordTaskStartedPrecheckError(p, result)
    \/ \E p \in Pollers : RecordTaskStarted(p)
    \/ \E p \in Pollers : \E result \in {"transient", "respool", "busy"} : RecordTaskStartedError(p, result)
    \/ \E p \in Pollers : RecordTaskStartedReply(p)
    \/ \E p \in Pollers : RecordTaskStartedRetryRPC(p)
    \/ \E p \in Pollers : RecordTaskStartedReplyLost(p)
    \/ \E p \in Pollers : FinishSyncTask(p)
    \/ \E p \in Pollers : CompleteTaskTransient(p)
    \/ \E p \in Pollers : RespoolTaskAfterError(p)
    \/ \E o \in Owners : TaskWriterPublishReplacement(o)
    \/ \E p \in Pollers : RespoolTaskReturn(p)
    \/ \E p \in Pollers : RespoolTaskRetry(p)
    \/ \E p \in Pollers : RespoolTaskShutdown(p)
    \/ \E p \in Pollers : CompleteTaskAck(p)
    \/ \E o \in Owners : AckTaskLockedDrained(o)
    \/ \E o \in Owners : \E launch \in BOOLEAN : MaybeGCLocked(o, launch)
    \/ \E o \in Owners : UpdateAckLevelAndBacklogStats(o)
    \/ \E p \in Pollers : PollTaskQueueResponse(p)
    \/ \E p \in Pollers : PollTaskQueueResponseLost(p)
    \/ \E w \in Work : ExpireTask(w)
    \/ \E w \in Work : ObsoleteTask(w)
    \/ \E o \in Owners : \E r \in owner[o].queued : \E p \in Pollers : FinishExpiredTask(o, r, p)
    \/ \E o \in Owners : \E kind \in {"sync", "verify"} : SyncStateBegin(o, kind)
    \/ \E o \in Owners : RenewLeaseBegin(o)
    \/ \E o \in Owners : TakeOverTaskQueueBegin(o)
    \/ \E o \in Owners : TakeOverTaskQueueSnapshot(o)
    \/ \E o \in Owners : UpdateTaskQueueCommit(o)
    \/ \E o \in Owners : VerifyOwnership(o)
    \/ \E o \in Owners : UpdateTaskQueueConditionFailed(o)
    \/ \E o \in Owners : UpdateTaskQueueError(o)
    \/ \E o \in Owners : UpdateTaskQueueReplyLost(o)
    \/ \E o \in Owners : UpdateTaskQueueReturn(o)
    \/ \E o \in Owners : StopBegin(o)
    \/ \E o \in Owners : UnloadAfterError(o)
    \/ \E o \in Owners : StopRefreshAck(o)
    \/ \E o \in Owners : StopSyncState(o)
    \/ \E o \in Owners : StopCancel(o)
    \/ \E o \in Owners : Crash(o)
    \/ \E o \in Owners : CompleteTasksLessThan(o)
    \/ \E o \in Owners : DoGCReturn(o)
    \/ \E o \in Owners : DoGCError(o)
    \/ \E o \in Owners : DiscardCrashedWriter(o)
    \/ \E p \in Pollers : PollerDisconnect(p)
    \/ \E p \in Pollers : PollTaskErrorReturn(p)

Next == Track(RawNext)
Spec == Init /\ [][Next]_vars
=============================================================================
