------------------------------ MODULE base ------------------------------
EXTENDS Integers, Naturals, Sequences, FiniteSets, TLC
\* Category A. temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
\* Paths: Q = service/history/queues; H = service/history/shard;
\* SQL = common/persistence/sql; M = service/matching.
\* S1 publication, S2 slices/cursor, S3 checkpoint, S4 ownership, S5 outcomes.
\* Constants describe a finite population/capacity, not production defaults.
CONSTANTS TaskCount, OwnerCount, Groups, SliceSlots, ExecSlots, SnapshotSlots,
          BatchSize, MaxEpoch, MoveThreshold, PredicateLimit, ShrinkKeys,
          UnexpectedLimit, DLQEnabled
Tasks == 1..TaskCount
Owners == 1..OwnerCount
Readers == 0..1
Sids == 1..SliceSlots
Eids == 1..ExecSlots
Jids == 1..SnapshotSlots
Stride == TaskCount + 2
KeyMax == (MaxEpoch + 1) * Stride
Keys == 0..KeyMax
Min(S) == CHOOSE n \in S : \A m \in S : n <= m
Max(S) == CHOOSE n \in S : \A m \in S : n >= m
SS(q) == {q[i] : i \in 1..Len(q)}
RECURSIVE Sort(_)
Sort(S) == IF S = {} THEN <<>> ELSE <<Min(S)>> \o Sort(S \ {Min(S)})
Filter(q, P(_)) == SelectSeq(q, P)
Rg(a,b) == [lo |-> a, hi |-> b]
\* Q/iterator.go:92-104: touching/overlapping remaining ranges merge.
RECURSIVE Normalize(_)
Normalize(R) ==
  IF R = {} THEN {}
  ELSE LET a == CHOOSE a \in R : a.lo = Min({x.lo : x \in R})
           overlaps == {b \in R \ {a} : b.lo <= a.hi}
       IN IF overlaps = {} THEN {a} \cup Normalize(R \ {a})
          ELSE Normalize((R \ ({a} \cup overlaps)) \cup
                         {Rg(a.lo, Max({a.hi} \cup {b.hi : b \in overlaps}))})
Scope(a,b,p) == [lo |-> a, hi |-> b, pred |-> p]
ScopeOf(z) == Scope(z.lo,z.hi,z.pred)
Nonempty(z) == z.lo < z.hi /\ z.pred /= {}
EmptyScope == Scope(0,0,{})
EmptySlice == [id |-> 0, lo |-> 0, hi |-> 0, pred |-> {}, iters |-> {}, tracked |-> {}]
\* Q/slice.go:451-479. Predicate byte complexity is abstracted to group capacity.
Widen(p) == IF PredicateLimit > 0 /\ Cardinality(p) > PredicateLimit THEN Groups ELSE p
Slice(id,scope,iters,tracked) ==
  [id |-> id, lo |-> scope.lo, hi |-> scope.hi, pred |-> Widen(scope.pred),
   iters |-> iters, tracked |-> tracked]
EmptyQueueState == [high |-> Stride, readers |-> [r \in Readers |-> <<>>]]
QueueState(high,rs) == [high |-> high,
  readers |-> [r \in Readers |-> [i \in 1..Len(rs[r]) |-> ScopeOf(rs[r][i])]]]
QueueMin(qs) == Min({qs.high} \cup
  UNION {{z.lo : z \in SS(qs.readers[r])} : r \in Readers})
\* H/task_key_manager.go:45-53,72-118; S1/S4.
EmptyPub == [owner |-> 0, epoch |-> 0, key |-> 0, group |-> "none",
             kind |-> "none", phase |-> "unused", reply |-> "none", pending |-> FALSE]
\* Q/executable.go:273-298,584-802; S2/S4/S5.
EmptyExec == [task |-> 0, owner |-> 0, state |-> "free", pc |-> "idle",
              terminal |-> FALSE, unexpected |-> 0, result |-> "none"]
EmptySnap == [owner |-> 0, epoch |-> 0, data |-> EmptyQueueState,
              phase |-> "free", caller |-> "other"]
EmptyOwn == [epoch |-> 0, mode |-> "absent", next |-> 0, renewPC |-> "idle",
             expected |-> 0, renewData |-> EmptyQueueState, fresh |-> FALSE]
EmptyQ == [high |-> Stride, deleteMin |-> Stride, lastRange |-> 0,
  lists |-> [r \in Readers |-> <<>>], cursor |-> [r \in Readers |-> 0],
  detached |-> [r \in Readers |-> EmptySlice],
  pc |-> "idle", captured |-> EmptyQueueState, moveGroups |-> {}, moved |-> <<>>,
  deleteResult |-> "none", memory |-> EmptyQueueState,
  clearReader |-> 0, clearID |-> 0, cancelTodo |-> {}]
\* s.db: real durable state plus historical commit/deletion/fence receipts.
\* s.pub: per-request local state; singleton generated task per transaction.
\* s.own, s.q: independent volatile owner instances. No global cancellation.
\* s.ex: wrapper identities; s.snaps: copied shard snapshots outside shard lock.
\* s.notice: lossy queue hints, not eligibility. All S1-S5 fields in vars.
VARIABLE s
vars == <<s>>
\* Q/queue_base.go:178-221; H/task_key_manager.go:24-42. Fresh test bootstrap.
Init ==
  /\ s = [db |-> [range |-> 1, owner |-> 1, rows |-> {}, workflow |-> {},
       published |-> {}, matching |-> {}, started |-> {}, obsolete |-> {},
       terminal |-> {}, dlq |-> {}, completed |-> {}, deleted |-> {}, acked |-> {},
       protected |-> {}, queue |-> EmptyQueueState],
     pub |-> [t \in Tasks |-> EmptyPub],
     own |-> [o \in Owners |-> IF o = 1 THEN
       [EmptyOwn EXCEPT !.epoch = 1, !.mode = "active", !.next = Stride] ELSE EmptyOwn],
     q |-> [o \in Owners |-> EmptyQ], ex |-> [e \in Eids |-> EmptyExec],
     snaps |-> [j \in Jids |-> EmptySnap], notice |-> [o \in Owners |-> FALSE]]
TaskKey(t) == s.pub[t].key
Group(t) == s.pub[t].group
Contains(z,t) == z.lo <= TaskKey(t) /\ TaskKey(t) < z.hi /\ Group(t) \in z.pred
Attached(o,r) == {z.id : z \in SS(s.q[o].lists[r])}
SliceAt(o,r,id) == IF id \in Attached(o,r)
  THEN CHOOSE z \in SS(s.q[o].lists[r]) : z.id = id ELSE s.q[o].detached[r]
CursorSlice(o,r) == SliceAt(o,r,s.q[o].cursor[r])
ResetCursor(list) == IF {i \in 1..Len(list) : list[i].iters /= {}} = {} THEN 0
  ELSE list[Min({i \in 1..Len(list) : list[i].iters /= {}})].id
NextCursor(list,id) == IF id \notin {z.id : z \in SS(list)} THEN 0
  ELSE LET i == CHOOSE i \in 1..Len(list) : list[i].id = id
       IN IF i = Len(list) THEN 0 ELSE list[i+1].id
UsedSids(o) == UNION {Attached(o,r) \cup {s.q[o].cursor[r]} : r \in Readers}
                \cup {z.id : z \in SS(s.q[o].moved)}
FreeSids(o) == Sids \ UsedSids(o)
Tracked == UNION {UNION {UNION {z.tracked : z \in SS(s.q[o].lists[r])}
                     : r \in Readers} \cup UNION {z.tracked : z \in SS(s.q[o].moved)}
                     : o \in Owners}
FreeExec == {e \in Eids \ Tracked : s.ex[e].pc = "idle"}
ScopeCovered(qs,t) == TaskKey(t) >= qs.high \/
  \E r \in Readers : \E z \in SS(qs.readers[r]) : Contains(z,t)
Responsible(t) == t \in s.db.matching \cup s.db.started \cup s.db.obsolete \cup s.db.dlq
Unresolved == s.db.workflow \ {t \in Tasks : Responsible(t)}
\* Terminal Internal/DataLoss drops are observable exceptions, not responsibility.
ContractTasks == Tasks \ s.db.terminal
HighWatermark(o) == Min({s.own[o].next} \cup
  {TaskKey(t) : t \in {u \in Tasks : s.pub[u].owner = o /\ s.pub[u].pending}})
PendingExec(z) == {e \in z.tracked : s.ex[e].state /= "acked"}
\* Q/tracker.go:85-105; slice.go:320-362. Cancelled is NOT acked.
Shrink(z) == LET tr == PendingExec(z)
                lo == Min({z.hi} \cup {TaskKey(s.ex[e].task) : e \in tr}
                           \cup {i.lo : i \in z.iters})
                gp == {Group(s.ex[e].task) : e \in tr}
                pr == IF z.iters = {} /\ Cardinality(gp) <= ShrinkKeys THEN Widen(gp) ELSE z.pred
            IN [z EXCEPT !.lo = lo, !.pred = pr, !.tracked = tr]
\* Q/tracker.go:59-74: merge overwrites duplicate task-key map entries.
MergeTracker(a,b) == LET large == IF Cardinality(a) < Cardinality(b) THEN b ELSE a
                        small == IF Cardinality(a) < Cardinality(b) THEN a ELSE b
                    IN small \cup {e \in large : ~\E f \in small : s.ex[e].task = s.ex[f].task}

\* Q/slice.go:109-136: an empty iterator exactly at cut belongs to LEFT;
\* the if/continue order must not duplicate it into both halves.
SplitLeft(z,id,cut) == Slice(id,Scope(z.lo,cut,z.pred),
  {IF i.hi <= cut THEN i ELSE Rg(i.lo,cut) : i \in {j \in z.iters : j.lo <= cut}},
  {e \in z.tracked : TaskKey(s.ex[e].task) < cut})
SplitRight(z,id,cut) == Slice(id,Scope(cut,z.hi,z.pred),
  {IF i.lo >= cut THEN i ELSE Rg(cut,i.hi) : i \in {j \in z.iters : j.hi > cut}},
  {e \in z.tracked : TaskKey(s.ex[e].task) >= cut})
\* Q/slice.go:139-156: the predicate split copies remaining iterators.
SplitPredicate(z,id,p) == Slice(id,Scope(z.lo,z.hi,z.pred \cap p),z.iters,
  {e \in z.tracked : Group(s.ex[e].task) \in p})
KeepNonempty(ls) == SelectSeq(ls,LAMBDA z : Nonempty(z))
Boundaries(list) == UNION {{z.lo,z.hi} : z \in SS(list)}
\* Q/slice.go:165-228. These branches follow MergeWithSlice in source order.
MergeTwo(a,b) ==
  IF a.pred = b.pred THEN
    <<Slice(0,Scope(a.lo,Max({a.hi,b.hi}),a.pred),
         Normalize(a.iters \cup b.iters),MergeTracker(a.tracked,b.tracked))>>
  ELSE LET left == SplitLeft(a,0,b.lo)
           rest == SplitRight(a,0,b.lo)
       IN IF a.hi <= b.hi THEN
          LET midb == SplitLeft(b,0,a.hi) right == SplitRight(b,0,a.hi)
              mid == Slice(0,Scope(rest.lo,rest.hi,rest.pred \cup midb.pred),
                    Normalize(rest.iters \cup midb.iters),MergeTracker(rest.tracked,midb.tracked))
          IN KeepNonempty(<<left,mid,right>>)
       ELSE LET mida == SplitLeft(rest,0,b.hi) right == SplitRight(rest,0,b.hi)
                mid == Slice(0,Scope(mida.lo,mida.hi,mida.pred \cup b.pred),
                      Normalize(mida.iters \cup b.iters),MergeTracker(mida.tracked,b.tracked))
            IN KeepNonempty(<<left,mid,right>>)
\* Q/reader.go:242-263: at equal minima the incoming slice goes first.
RECURSIVE Interleave(_,_)
Interleave(a,b) == IF a = <<>> THEN b ELSE IF b = <<>> THEN a ELSE
  IF a[1].lo < b[1].lo THEN <<Head(a)>> \o Interleave(Tail(a),b)
  ELSE <<Head(b)>> \o Interleave(a,Tail(b))
\* Q/reader.go:536-560: only the last retained slice is merged with next input.
RECURSIVE MergeFold(_,_)
MergeFold(done,remaining) == IF remaining = <<>> THEN done ELSE
  LET z == Head(remaining) IN
  IF ~Nonempty(z) THEN MergeFold(done,Tail(remaining))
  ELSE IF done = <<>> THEN MergeFold(<<z>>,Tail(remaining))
  ELSE LET a == done[Len(done)] IN
    IF a.hi < z.lo THEN MergeFold(Append(done,z),Tail(remaining))
    ELSE MergeFold(SubSeq(done,1,Len(done)-1) \o MergeTwo(a,z),Tail(remaining))
MergeLists(existing,incoming,ids) ==
  LET ls == MergeFold(<<>>,Interleave(existing,incoming))
  IN [i \in 1..Len(ls) |-> [ls[i] EXCEPT !.id = ids[i]]]
Rebuild(qs) == LET counts == Len(qs.readers[0])
  IN [r \in Readers |-> [i \in 1..Len(qs.readers[r]) |->
    Slice(IF r = 0 THEN i ELSE counts+i,qs.readers[r][i],
          {Rg(qs.readers[r][i].lo,qs.readers[r][i].hi)}, {})]]

\* H/task_key_manager.go:45-53; H/task_request_tracker.go:36-67; S1
SetAndTrackTaskKeys(o,t,g,k) ==
  /\ s.own[o].mode = "active" /\ s.pub[t].phase = "unused"
  /\ s.own[o].next < (s.own[o].epoch+1)*Stride
  /\ s' = [s EXCEPT !.pub[t] = [owner |-> o, epoch |-> s.own[o].epoch,
      key |-> s.own[o].next, group |-> g, kind |-> k, phase |-> "allocated",
      reply |-> "none", pending |-> TRUE], !.own[o].next = @+1]

\* SQL/execution.go:338-348; S1
AppendHistoryNodes(t) ==
  /\ s.pub[t].phase = "allocated"
  /\ s' = [s EXCEPT !.pub[t].phase = "appended"]

\* SQL/execution.go:351-357,434-443; SQL/shard.go:152-174; S1/S4
UpdateWorkflowExecutionCommit(t) ==
  /\ s.pub[t].phase = "appended" /\ s.pub[t].epoch = s.db.range
  /\ s' = [s EXCEPT !.pub[t].phase = "committed", !.db.rows = @ \cup {t},
      !.db.workflow = @ \cup {t}, !.db.published = @ \cup {t},
      !.db.protected = @ \cup {<<s.pub[t].epoch,s.db.range>>}]

\* SQL/shard.go:158-174; S1/S4
UpdateWorkflowExecutionFenced(t) ==
  /\ s.pub[t].phase = "appended" /\ s.pub[t].epoch /= s.db.range
  /\ s' = [s EXCEPT !.pub[t].phase = "failed"]

\* SQL/execution.go:350-357,426-440; SQL/common.go:52-80; S1
UpdateWorkflowExecutionFail(t) ==
  /\ s.pub[t].phase = "appended"
  /\ s' = [s EXCEPT !.pub[t].phase = "failed"]

\* H/task_request_tracker.go:69-89; H/context_impl.go:1506-1538; S1
TaskRequestCompletion(t) ==
  /\ s.pub[t].reply = "none" /\ s.pub[t].phase \in {"committed","failed"}
  /\ LET o == s.pub[t].owner IN
     s' = [s EXCEPT !.pub[t].reply = IF s.pub[t].phase = "committed" THEN "ok" ELSE "error",
         !.pub[t].pending = FALSE,
         !.notice[o] = @ \/ s.pub[t].phase = "committed"]

\* H/task_request_tracker.go:73-85; H/context_impl.go:1540-1548; S1
TaskRequestTimeout(t) ==
  /\ s.pub[t].reply = "none" /\ s.pub[t].phase \in {"appended","committed","failed"}
  /\ LET o == s.pub[t].owner IN
     s' = [s EXCEPT !.pub[t].reply = "unknown",
        !.own[o].mode = IF s.own[o].mode = "active" /\ s.own[o].epoch = s.pub[t].epoch
                        THEN "lost" ELSE @]

\* Q/queue_immediate.go:124-175; lossy notification interface; S1
DropNotification(o) ==
  /\ s.notice[o]
  /\ s' = [s EXCEPT !.notice[o] = FALSE]

\* H/context_impl.go:2030-2082,1164-1186; S1/S4
AcquireShardBegin(o) ==
  /\ s.own[o].mode \in {"absent","lost"} /\ s.own[o].renewPC = "idle"
  /\ \A t \in Tasks : s.pub[t].owner = o => s.pub[t].reply /= "none"
  /\ s.db.range < MaxEpoch
  /\ s' = [s EXCEPT !.own[o].mode = "acquiring", !.own[o].renewPC = "store",
      !.own[o].fresh = s.own[o].epoch = 0,
      !.own[o].expected = IF s.own[o].epoch = 0 THEN s.db.range ELSE s.own[o].epoch,
      !.own[o].renewData = IF s.own[o].epoch = 0 THEN s.db.queue ELSE s.q[o].memory]

\* H/context_impl.go:1173-1186; SQL/shard.go:82-112; S1/S4
RenewRangeLockedCommit(o) ==
  /\ s.own[o].renewPC = "store" /\ s.own[o].expected = s.db.range
  /\ s' = [s EXCEPT !.db.range = @+1, !.db.owner = o, !.db.queue = s.own[o].renewData,
      !.db.protected = @ \cup {<<s.own[o].expected,s.db.range>>}, !.own[o].renewPC = "reply"]

\* SQL/shard.go:132-148; H/context_impl.go:1187-1195; S4
RenewRangeLockedFenced(o) ==
  /\ s.own[o].renewPC = "store" /\ s.own[o].expected /= s.db.range
  /\ s' = [s EXCEPT !.own[o].renewPC = "idle", !.own[o].mode = "stopped"]

\* H/context_impl.go:1198-1207,2084-2109; Q/queue_base.go:178-221; S1/S4
AcquireShardComplete(o) ==
  /\ s.own[o].renewPC = "reply"
  /\ LET epoch == s.own[o].expected+1
         lists == Rebuild(s.own[o].renewData)
         q == [EmptyQ EXCEPT !.high = s.own[o].renewData.high,
           !.deleteMin = QueueMin(s.own[o].renewData), !.lists = lists,
           !.cursor = [r \in Readers |-> ResetCursor(lists[r])], !.memory = s.own[o].renewData]
     IN s' = [s EXCEPT !.own[o].epoch = epoch, !.own[o].next = epoch*Stride,
        \* H/context_impl.go:1805-1825,2097-2104 rejects stopped completion.
        !.own[o].mode = IF @ = "acquiring" THEN "active" ELSE @,
        !.own[o].renewPC = "idle",
        !.q[o] = IF s.own[o].fresh /\ s.own[o].mode = "acquiring" THEN q ELSE @,
        !.pub = [t \in Tasks |-> IF s.pub[t].owner = o THEN [s.pub[t] EXCEPT !.pending = FALSE] ELSE s.pub[t]],
        !.notice[o] = IF s.own[o].mode = "acquiring" THEN TRUE ELSE @]

\* Q/queue_base.go:245-249; Q/reader.go:161-177; Q/rescheduler.go:105-117; S4
StopReaderGroup(o) ==
  /\ s.own[o].mode /= "absent" /\ s.own[o].mode /= "stopped"
  /\ s' = [s EXCEPT !.own[o].mode = "stopped"]
\* Q/reader.go:161-177; Q/rescheduler.go:105-117,254-265:
\* stop read/reschedule loops; no blanket executable cancellation occurs.

\* Q/queue_base.go:262-292; H/task_key_manager.go:88-118; S1/S2
ProcessNewRange(o,id) ==
  /\ s.own[o].mode \in {"active","lost"} /\ s.q[o].pc = "idle"
  /\ id \in FreeSids(o) /\ HighWatermark(o) > s.q[o].high
  /\ LET z == Slice(id,Scope(s.q[o].high,HighWatermark(o),Groups),
                     {Rg(s.q[o].high,HighWatermark(o))},{})
         ls == Append(s.q[o].lists[0],z)
     IN s' = [s EXCEPT !.q[o].high = HighWatermark(o), !.q[o].lists[0] = ls,
        !.q[o].cursor[0] = ResetCursor(ls), !.q[o].detached[0] = EmptySlice,
        !.notice[o] = FALSE]

\* Q/reader.go:438-486; Q/slice.go:365-408; Q/iterator.go:53-64; S2/S4
\* Successful reader-locked load projection. Prefetched pages and partial
\* read errors are not modeled; new persistence reads require an active shard
\* (H/context_impl.go:GetHistoryTasks,errorByState).
SelectTasks(o,r,es) ==
  /\ s.own[o].mode = "active" /\ s.q[o].cursor[r] /= 0
  /\ ~(s.q[o].pc = "clearCancel" /\ s.q[o].clearReader = r)
  /\ LET z == CursorSlice(o,r)
         available == {t \in s.db.rows : Contains(z,t) /\
                         \E i \in z.iters : i.lo <= TaskKey(t) /\ TaskKey(t) < i.hi}
         selected == {t \in available : Cardinality({u \in available : TaskKey(u) < TaskKey(t)}) < BatchSize}
         full == Cardinality(selected) = BatchSize
         cut == IF full THEN Max({TaskKey(t) : t \in selected})+1 ELSE z.hi
         ir == IF full THEN {Rg(Max({i.lo,cut}),i.hi) : i \in {j \in z.iters : j.hi >= cut}} ELSE {}
         \* SQLite ORDER BY task_id; logical identities need not follow allocation.
         ts == [i \in 1..Cardinality(selected) |-> CHOOSE t \in selected :
           Cardinality({u \in selected : TaskKey(u) < TaskKey(t)}) = i-1]
         fresh == {es[i] : i \in 1..Len(es)}
         tr == fresh \cup {e \in z.tracked : s.ex[e].task \notin selected}
         zz == [z EXCEPT !.iters = ir, !.tracked = tr]
     IN /\ Len(es) = Cardinality(selected) /\ fresh \subseteq FreeExec /\ Cardinality(fresh) = Len(es)
        /\ s' = [s EXCEPT
           !.q[o].lists[r] = [i \in 1..Len(@) |-> IF @[i].id = z.id THEN zz ELSE @[i]],
           !.q[o].detached[r] = IF z.id \notin Attached(o,r) THEN zz ELSE @,
           !.q[o].cursor[r] = IF ir /= {} THEN @ ELSE NextCursor(s.q[o].lists[r],z.id),
           !.ex = [e \in Eids |-> IF e \in fresh THEN
               [EmptyExec EXCEPT !.task = ts[CHOOSE i \in 1..Len(es) : es[i] = e],
                 !.owner = o, !.state = "pending", !.pc = "ready"] ELSE s.ex[e]]]

\* Q/reader.go:372-382,507-511; Q/queue_immediate.go:81; S2
NotifyReader(o,r) ==
  /\ s.own[o].mode = "active"
  /\ UNCHANGED s

\* Q/queue_immediate.go:155-156; Q/queue_base.go:295-299; S2/S3
CheckpointBegin(o) ==
  /\ s.own[o].mode \in {"active","lost"} /\ s.q[o].pc = "idle"
  /\ s' = [s EXCEPT !.q[o].pc = "shrink0"]

\* Q/reader.go:350-369; Q/slice.go:307-362; Q/tracker.go:85-105; S2/S3
ShrinkSlices(o,r) ==
  /\ s.q[o].pc = IF r = 0 THEN "shrink0" ELSE "shrink1"
  /\ LET shrunk == [i \in 1..Len(s.q[o].lists[r]) |-> Shrink(s.q[o].lists[r][i])]
         ls == SelectSeq(shrunk,LAMBDA z : Nonempty(z))
         removed == {z \in SS(shrunk) : ~Nonempty(z) /\ z.id = s.q[o].cursor[r]}
     IN s' = [s EXCEPT !.q[o].lists[r] = ls,
        !.q[o].detached[r] = IF removed /= {} THEN CHOOSE z \in removed : TRUE ELSE @,
        !.q[o].pc = IF r = 0 THEN "shrink1" ELSE "moveStats"]
  \* Deliberately leaves cursor unchanged: there is no reset call at reader.go:368.

\* Q/action_move_group.go:60-83; S2
MoveGroupCollect(o) ==
  /\ s.q[o].pc = "moveStats"
  /\ LET tr == UNION {z.tracked : z \in SS(s.q[o].lists[0])}
         groups == {g \in Groups : Cardinality({e \in tr : Group(s.ex[e].task) = g}) >= MoveThreshold}
     IN s' = [s EXCEPT !.q[o].moveGroups = groups,
         !.q[o].pc = IF groups = {} THEN "scope0" ELSE "moveSplit"]

\* Q/action_move_group.go:85-98; Q/reader.go:201-228; Q/slice.go:139-156; S2
MoveGroupSplit(o) ==
  /\ s.q[o].pc = "moveSplit"
  /\ LET old == s.q[o].lists[0] n == Len(old)
         ids == Sort(FreeSids(o))
         pass == [i \in 1..n |-> SplitPredicate(old[i],ids[i],s.q[o].moveGroups)]
         fail == [i \in 1..n |-> SplitPredicate(old[i],old[i].id,Groups \ s.q[o].moveGroups)]
         ls == SelectSeq(fail,LAMBDA z : Nonempty(z))
     IN /\ Len(ids) >= n
        /\ s' = [s EXCEPT !.q[o].lists[0] = ls, !.q[o].cursor[0] = ResetCursor(ls),
           !.q[o].detached[0] = EmptySlice,
           !.q[o].moved = SelectSeq(pass,LAMBDA z : Nonempty(z)), !.q[o].pc = "moveMerge"]

\* Q/action_move_group.go:100-102; Q/reader.go:230-271; Q/slice.go:165-257; S2
MoveGroupMerge(o) ==
  /\ s.q[o].pc = "moveMerge"
  /\ LET incoming == s.q[o].lists[1] \o s.q[o].moved
         ids == Sort(Sids \ (Attached(o,0) \cup {s.q[o].cursor[0]}))
     IN /\ Len(ids) >= Cardinality(Boundaries(incoming))
        /\ LET ls == MergeLists(s.q[o].lists[1],s.q[o].moved,ids) IN
           s' = [s EXCEPT !.q[o].lists[1] = ls, !.q[o].cursor[1] = ResetCursor(ls),
              !.q[o].detached[1] = EmptySlice, !.q[o].moved = <<>>, !.q[o].pc = "scope0"]

\* Q/queue_base.go:316-330; Q/reader.go:180-189; S3
CheckpointScopes(o,r) ==
  /\ s.q[o].pc = IF r = 0 THEN "scope0" ELSE "scope1"
  /\ s' = [s EXCEPT !.q[o].captured.high = s.q[o].high,
      !.q[o].captured.readers[r] = [i \in 1..Len(s.q[o].lists[r]) |-> ScopeOf(s.q[o].lists[r][i])],
      !.q[o].pc = IF r = 0 THEN "scope1" ELSE "deleteBegin"]

\* Q/queue_base.go:340-358,364-370; S3/S4
RangeCompleteTasksBegin(o) ==
  /\ s.q[o].pc = "deleteBegin"
  /\ LET high == QueueMin(s.q[o].captured)
         advance == high > s.q[o].deleteMin
         renew == s.q[o].lastRange < s.own[o].epoch /\ high > 0
     IN s' = [s EXCEPT !.q[o].pc = IF advance \/ renew THEN "deleteStore" ELSE "setState",
        !.q[o].lastRange = IF advance THEN @ ELSE s.own[o].epoch,
        !.q[o].deleteResult = "none"]

\* SQL/execution_tasks.go:361-372; SQL/sqlplugin/sqlite/execution.go:110,625-634; S3/S4
RangeCompleteTasksCommit(o) ==
  /\ s.q[o].pc = "deleteStore"
  /\ LET doomed == {t \in s.db.rows : s.q[o].deleteMin <= TaskKey(t) /\ TaskKey(t) < QueueMin(s.q[o].captured)}
     IN s' = [s EXCEPT !.db.rows = @ \ doomed, !.db.deleted = @ \cup doomed,
        !.q[o].pc = "deleteReply", !.q[o].deleteResult = "committed"]
  \* No RangeID fence here; the successor immediate-ID range is higher.

\* SQL/execution_tasks.go:365-370; Q/queue_base.go:351-354; S3
RangeCompleteTasksFail(o) ==
  /\ s.q[o].pc = "deleteStore"
  /\ s' = [s EXCEPT !.q[o].pc = "deleteReply", !.q[o].deleteResult = "failed"]

\* Q/queue_base.go:351-360; S3
RangeCompleteTasksReply(o) ==
  /\ s.q[o].pc = "deleteReply"
  /\ s' = [s EXCEPT !.q[o].pc = IF s.q[o].deleteResult = "committed" THEN "setState" ELSE "idle",
      !.q[o].deleteMin = IF s.q[o].deleteResult = "committed" THEN QueueMin(s.q[o].captured) ELSE @]

\* Q/queue_base.go:351-357; common/persistence/faultinjection/fault.go:42-47; S3
RangeCompleteTasksLostReply(o) ==
  /\ s.q[o].pc = "deleteReply" /\ s.q[o].deleteResult = "committed"
  /\ s' = [s EXCEPT !.q[o].pc = "idle", !.q[o].deleteResult = "unknown"]

\* Q/queue_base.go:397-411; H/context_impl.go:1232-1249; S3
SetQueueStateBatched(o) ==
  /\ s.q[o].pc = "setState" /\ s.own[o].mode = "active"
  /\ s' = [s EXCEPT !.q[o].memory = s.q[o].captured, !.q[o].pc = "idle"]

\* Q/queue_base.go:408-411; H/context_impl.go:1232-1281; S3
SetQueueStateSnapshot(o,j) ==
  /\ s.q[o].pc = "setState" /\ s.own[o].mode = "active" /\ s.snaps[j].phase = "free"
  /\ s' = [s EXCEPT !.q[o].memory = s.q[o].captured, !.q[o].pc = "stateReply",
      !.snaps[j] = [owner |-> o, epoch |-> s.own[o].epoch, data |-> s.q[o].captured,
                     phase |-> "store", caller |-> "checkpoint"]]

\* H/context_impl.go:1232-1235; S3/S4
SetQueueStateClosed(o) ==
  /\ s.q[o].pc = "setState" /\ s.own[o].mode /= "active"
  /\ s' = [s EXCEPT !.q[o].pc = "idle"]

\* H/context_impl.go:388-404,1228-1281; S3
UpdateShardInfoSnapshot(o,j) ==
  /\ s.own[o].mode = "active" /\ s.snaps[j].phase = "free"
  /\ s' = [s EXCEPT !.snaps[j] = [owner |-> o, epoch |-> s.own[o].epoch,
          data |-> s.q[o].memory, phase |-> "store", caller |-> "other"]]

\* H/context_impl.go:1283-1291; SQL/shard.go:82-112; S3/S4
UpdateShardCommit(j) ==
  /\ s.snaps[j].phase = "store" /\ s.snaps[j].epoch = s.db.range
  /\ s' = [s EXCEPT !.db.queue = s.snaps[j].data, !.snaps[j].phase = "committed",
      !.db.protected = @ \cup {<<s.snaps[j].epoch,s.db.range>>}]

\* SQL/shard.go:132-148; H/context_impl.go:1291-1298; S4
UpdateShardFenced(j) ==
  /\ s.snaps[j].phase = "store" /\ s.snaps[j].epoch /= s.db.range
  /\ s' = [s EXCEPT !.snaps[j].phase = "fenced"]

\* H/context_impl.go:1283-1298; SQL/common.go:52-80; S3
UpdateShardFail(j) ==
  /\ s.snaps[j].phase = "store"
  /\ s' = [s EXCEPT !.snaps[j].phase = "failed"]

\* H/context_impl.go:1291-1301,1506-1548; S3/S4
UpdateShardReply(j) ==
  /\ s.snaps[j].phase \in {"committed","failed","fenced"}
  /\ LET o == s.snaps[j].owner IN s' = [s EXCEPT
      !.q[o].pc = IF s.snaps[j].caller = "checkpoint" THEN "idle" ELSE @,
      !.own[o].mode = IF s.snaps[j].epoch /= s.own[o].epoch THEN @
          ELSE IF s.snaps[j].phase = "fenced" THEN "stopped"
          ELSE IF s.snaps[j].phase = "failed" /\ @ = "active" THEN "lost" ELSE @,
      !.snaps[j] = EmptySnap]

\* H/context_impl.go:1291-1298,1540-1548; S3
UpdateShardLostReply(j) ==
  /\ s.snaps[j].phase = "committed"
  /\ LET o == s.snaps[j].owner IN s' = [s EXCEPT
      !.q[o].pc = IF s.snaps[j].caller = "checkpoint" THEN "idle" ELSE @,
      !.own[o].mode = IF s.own[o].mode = "active" /\ s.snaps[j].epoch = s.own[o].epoch THEN "lost" ELSE @,
      !.snaps[j] = EmptySnap]

\* Q/queue_base.go:262-292; Q/reader.go:230-271; S1/S2
ProcessNewRangeMerge(o) ==
  /\ s.own[o].mode \in {"active","lost"} /\ s.q[o].pc = "idle"
  /\ HighWatermark(o) > s.q[o].high
  /\ LET z == Slice(0,Scope(s.q[o].high,HighWatermark(o),Groups),{Rg(s.q[o].high,HighWatermark(o))},{})
         incoming == Append(s.q[o].lists[0],z)
         ids == Sort(Sids \ (Attached(o,1) \cup {s.q[o].cursor[1]}))
     IN /\ Len(ids) >= Cardinality(Boundaries(incoming))
        /\ LET ls == MergeLists(s.q[o].lists[0],<<z>>,ids) IN s' = [s EXCEPT
            !.q[o].high = HighWatermark(o), !.q[o].lists[0] = ls,
            !.q[o].cursor[0] = ResetCursor(ls), !.q[o].detached[0] = EmptySlice,
            !.notice[o] = FALSE]

\* Q/reader.go:201-228; Q/slice.go:101-136; S2
SplitSlicesByRange(o,r,id,cut,fresh) ==
  /\ s.own[o].mode = "active" /\ s.q[o].pc = "idle"
  /\ id \in Attached(o,r) /\ fresh \in FreeSids(o)
  /\ LET z == SliceAt(o,r,id)
         i == CHOOSE i \in 1..Len(s.q[o].lists[r]) : s.q[o].lists[r][i].id = id
         ls == SubSeq(s.q[o].lists[r],1,i-1) \o
             <<SplitLeft(z,id,cut),SplitRight(z,fresh,cut)>> \o
             SubSeq(s.q[o].lists[r],i+1,Len(s.q[o].lists[r]))
     IN /\ z.lo < cut /\ cut < z.hi
        /\ s' = [s EXCEPT !.q[o].lists[r] = ls, !.q[o].cursor[r] = ResetCursor(ls),
            !.q[o].detached[r] = EmptySlice]

\* Q/reader.go:320-348; Q/slice.go:277-304; S2
CompactSlices(o,r,i) ==
  /\ s.own[o].mode = "active" /\ s.q[o].pc = "idle"
  /\ i \in 1..(Len(s.q[o].lists[r])-1)
  /\ LET a == s.q[o].lists[r][i] b == s.q[o].lists[r][i+1]
         z == Slice(a.id,Scope(a.lo,b.hi,a.pred \cup b.pred),Normalize(a.iters \cup b.iters),MergeTracker(a.tracked,b.tracked))
         ls == SubSeq(s.q[o].lists[r],1,i-1) \o <<z>> \o SubSeq(s.q[o].lists[r],i+2,Len(s.q[o].lists[r]))
     IN s' = [s EXCEPT !.q[o].lists[r] = ls, !.q[o].cursor[r] = ResetCursor(ls),
         !.q[o].detached[r] = EmptySlice]

\* Q/reader.go:306-318; Q/slice.go:425-433; S2/S4
ClearSlicesBegin(o,r,id) ==
  /\ s.own[o].mode = "active" /\ id \in Attached(o,r)
  /\ LET continuing == s.q[o].pc = "clearCancel"
         z == Shrink(SliceAt(o,r,id))
         index == CHOOSE i \in 1..Len(s.q[o].lists[r]) : s.q[o].lists[r][i].id = id
         priorIndex == IF continuing THEN
           CHOOSE i \in 1..Len(s.q[o].lists[r]) : s.q[o].lists[r][i].id = s.q[o].clearID
           ELSE 0
     IN /\ s.q[o].pc = "idle" \/
           (continuing /\ s.q[o].cancelTodo = {} /\ s.q[o].clearReader = r /\ index > priorIndex)
        /\ s' = [s EXCEPT !.q[o].pc = "clearCancel", !.q[o].clearReader = r,
           !.q[o].clearID = id, !.q[o].cancelTodo = z.tracked,
           !.q[o].lists[r] = [i \in 1..Len(@) |-> IF @[i].id = id
              THEN [z EXCEPT !.iters = {Rg(z.lo,z.hi)}]
              ELSE IF continuing /\ @[i].id = s.q[o].clearID
                   THEN [@[i] EXCEPT !.tracked = {}] ELSE @[i]]]
  \* ReaderImpl.ClearSlices loops in list order under one lock. Between
  \* selected slices tracker.clear has emptied the preceding tracker; the
  \* reader cursor resets only after the complete loop returns.

\* Q/tracker.go:108-111; Q/executable.go:733-740; S2/S4
ClearCancel(o,e) ==
  /\ s.q[o].pc = "clearCancel" /\ e \in s.q[o].cancelTodo
  /\ s' = [s EXCEPT !.q[o].cancelTodo = @ \ {e},
      !.ex[e].state = IF @ = "pending" THEN "cancelled" ELSE @]

\* Q/tracker.go:113-114; Q/reader.go:317,489-505; S2
ClearSlicesComplete(o) ==
  /\ s.q[o].pc = "clearCancel" /\ s.q[o].cancelTodo = {}
  /\ LET r == s.q[o].clearReader
         ls == [i \in 1..Len(s.q[o].lists[r]) |-> IF s.q[o].lists[r][i].id = s.q[o].clearID
                THEN [s.q[o].lists[r][i] EXCEPT !.tracked = {}] ELSE s.q[o].lists[r][i]]
     IN s' = [s EXCEPT !.q[o].lists[r] = ls, !.q[o].cursor[r] = ResetCursor(ls),
        !.q[o].detached[r] = EmptySlice, !.q[o].pc = "idle"]

\* Q/executable.go:273-298,385-402; S4/S5
Execute(e) ==
  /\ s.ex[e].pc = "ready"
  /\ s' = [s EXCEPT !.ex[e].pc = IF s.ex[e].state /= "pending" THEN "idle"
       ELSE IF s.ex[e].terminal THEN "dlq" ELSE "eligibility"]

\* service/history/transfer_queue_active_task_executor.go:250-286,302-347; S5
ProcessTransferTaskEligible(e) ==
  /\ s.ex[e].pc = "eligibility" /\ s.ex[e].task \notin s.db.obsolete
  /\ s' = [s EXCEPT !.ex[e].pc = "matching"]
  \* Workflow identity/stamp/normal-queue eligibility is the interface precondition.
  \* No durable owner check: a previously admitted cache/RPC path may finish late.

\* service/history/transfer_queue_active_task_executor.go:250-274,306-316; S5
ProcessTransferTaskObsolete(e) ==
  /\ s.ex[e].pc = "eligibility" /\ s.ex[e].task \in s.db.obsolete
  /\ s' = [s EXCEPT !.ex[e].pc = "handle", !.ex[e].result = "obsolete"]

\* Q/executable.go:511-558,623-625; S5
ExecuteRetryableError(e) ==
  /\ s.ex[e].pc \in {"eligibility","matching","dlq"}
  /\ s' = [s EXCEPT !.ex[e].pc = "handle", !.ex[e].result = "retry"]

\* Q/executable.go:627-681; S5
ExecuteUnexpectedError(e) ==
  /\ s.ex[e].pc \in {"eligibility","matching"}
  /\ s' = [s EXCEPT !.ex[e].pc = "handle", !.ex[e].result = "unexpected"]

\* Q/executable.go:561-578,646-665; S5
ExecuteTerminalError(e) ==
  /\ s.ex[e].pc \in {"eligibility","matching"}
  /\ s' = [s EXCEPT !.ex[e].pc = "handle", !.ex[e].result = "terminal"]

\* M/task_queue_partition_manager.go:555-700; M/backlog_manager.go:164-179; M/task_writer.go:141; S5
MatchingSpoolCommit(e) ==
  /\ s.ex[e].pc = "matching"
  /\ s' = [s EXCEPT !.db.matching = @ \cup {s.ex[e].task},
      !.ex[e].pc = "matchingReply", !.ex[e].result = "accepted"]

\* M/matching_engine.go:810-864,1037-1108; M/matching_engine.go:3527,3606; S4/S5
RecordTaskStarted(e) ==
  /\ s.ex[e].pc = "matching" /\ s.ex[e].task \notin s.db.obsolete
  /\ s' = [s EXCEPT !.db.started = @ \cup {s.ex[e].task},
      !.ex[e].pc = "matchingReply", !.ex[e].result = "accepted"]

\* M/matching_engine.go:810-818,1037-1045; M/task.go:373-397; S5
MatchingTerminalDiscard(e) ==
  /\ s.ex[e].pc = "matching"
  /\ s' = [s EXCEPT !.db.terminal = @ \cup {s.ex[e].task},
      !.ex[e].pc = "matchingReply", !.ex[e].result = "discarded"]

\* M/task.go:373-397; Q/executable.go:584-586; S5
MatchingReply(e) ==
  /\ s.ex[e].pc = "matchingReply"
  /\ s' = [s EXCEPT !.ex[e].pc = "handle"]

\* service/history/transfer_queue_active_task_executor.go:339-347,373; S4/S5 RPC interface
MatchingLostReply(e) ==
  /\ s.ex[e].pc = "matchingReply"
  /\ s' = [s EXCEPT !.ex[e].pc = "handle", !.ex[e].result = "unexpected"]

\* Q/executable.go:385-389,420-439; Q/dlq_writer.go:63-103; SQL/queue_v2.go:45-104; S5
EnqueueTaskCommit(e) ==
  /\ s.ex[e].pc = "dlq" /\ DLQEnabled
  /\ s' = [s EXCEPT !.db.dlq = @ \cup {s.ex[e].task},
      !.ex[e].pc = "dlqReply", !.ex[e].result = "dlqAccepted"]

\* Q/dlq_writer.go:93-103; Q/executable.go:426-439; S5
EnqueueTaskReply(e) ==
  /\ s.ex[e].pc = "dlqReply"
  /\ s' = [s EXCEPT !.ex[e].pc = "handle"]

\* SQL/queue_v2.go:96-104; Q/executable.go:434-439; S5
EnqueueTaskLostReply(e) ==
  /\ s.ex[e].pc = "dlqReply"
  /\ s' = [s EXCEPT !.ex[e].pc = "handle", !.ex[e].result = "retry"]

\* Q/executable.go:584-610; S5
HandleErrAck(e) ==
  /\ s.ex[e].pc = "handle" /\ s.ex[e].result \in {"accepted","obsolete","discarded","dlqAccepted"}
  /\ s' = [s EXCEPT !.ex[e].pc = "ack"]

\* Q/executable.go:612-625; S5
HandleErrRetry(e) ==
  /\ s.ex[e].pc = "handle" /\ s.ex[e].result = "retry"
  /\ s' = [s EXCEPT !.ex[e].pc = "nack"]

\* Q/executable.go:646-665; S5
HandleErrTerminal(e) ==
  /\ s.ex[e].pc = "handle" /\ s.ex[e].result = "terminal"
  /\ s' = [s EXCEPT !.ex[e].terminal = DLQEnabled,
      !.ex[e].pc = IF DLQEnabled THEN "nack" ELSE "ack",
      !.db.terminal = IF DLQEnabled THEN @ ELSE @ \cup {s.ex[e].task}]

\* Q/executable.go:627-629,668-681; S5
HandleErrUnexpected(e) ==
  /\ s.ex[e].pc = "handle" /\ s.ex[e].result = "unexpected"
  /\ LET n == Min({s.ex[e].unexpected+1,UnexpectedLimit}) IN
     s' = [s EXCEPT !.ex[e].unexpected = n, !.ex[e].terminal = DLQEnabled /\ n >= UnexpectedLimit,
         !.ex[e].pc = "nack"]

\* Q/executable.go:742-750; S2/S4/S5
Ack(e) ==
  /\ s.ex[e].pc = "ack"
  /\ s' = [s EXCEPT !.ex[e].pc = "idle", !.ex[e].state = IF @ = "pending" THEN "acked" ELSE @,
      !.db.acked = IF s.ex[e].state = "pending" THEN @ \cup {s.ex[e].task} ELSE @]

\* Q/executable.go:768-802; S2/S5
Nack(e) ==
  /\ s.ex[e].pc = "nack"
  /\ s' = [s EXCEPT !.ex[e].pc = IF s.ex[e].state = "pending" THEN "rescheduled" ELSE "idle"]

\* Q/rescheduler.go:208-240; Q/executable.go:794-802; S2/S5
Reschedule(e) ==
  /\ s.ex[e].pc = "rescheduled"
  /\ s' = [s EXCEPT !.ex[e].pc = IF s.ex[e].state = "pending" /\ s.own[s.ex[e].owner].mode /= "stopped" THEN "ready" ELSE "idle"]

\* service/history/transfer_queue_active_task_executor.go:250-274,306-316; S5 interface
WorkflowNoLongerNeedsTask(t) ==
  /\ t \in s.db.workflow /\ t \notin s.db.obsolete
  /\ s' = [s EXCEPT !.db.obsolete = @ \cup {t}]
  \* Environmental durable cancellation/completion or proved replacement only.

\* service/history/api/respondactivitytaskcompleted/api.go:50-133;
\* service/history/api/respondworkflowtaskcompleted/api.go:675-680; S5
WorkerComplete(t) ==
  /\ t \in s.db.started /\ t \notin s.db.completed
  /\ s' = [s EXCEPT !.db.completed = @ \cup {t}]
  \* Completion is an independent downstream observation, never inferred from ACK.


\* Finite executable ID sequences are a representation capacity, not a retry bound.
ExecSequences == UNION {[1..n -> Eids] : n \in 0..BatchSize}
Next ==
  \/ \E o \in Owners, t \in Tasks, g \in Groups, k \in {"Workflow","Activity"} : SetAndTrackTaskKeys(o,t,g,k)
  \/ \E t \in Tasks : AppendHistoryNodes(t)
  \/ \E t \in Tasks : UpdateWorkflowExecutionCommit(t)
  \/ \E t \in Tasks : UpdateWorkflowExecutionFenced(t)
  \/ \E t \in Tasks : UpdateWorkflowExecutionFail(t)
  \/ \E t \in Tasks : TaskRequestCompletion(t)
  \/ \E t \in Tasks : TaskRequestTimeout(t)
  \/ \E o \in Owners : DropNotification(o)
  \/ \E o \in Owners : AcquireShardBegin(o)
  \/ \E o \in Owners : RenewRangeLockedCommit(o)
  \/ \E o \in Owners : RenewRangeLockedFenced(o)
  \/ \E o \in Owners : AcquireShardComplete(o)
  \/ \E o \in Owners : StopReaderGroup(o)
  \/ \E o \in Owners, id \in Sids : ProcessNewRange(o,id)
  \/ \E o \in Owners, r \in Readers, es \in ExecSequences : SelectTasks(o,r,es)
  \/ \E o \in Owners, r \in Readers : NotifyReader(o,r)
  \/ \E o \in Owners : CheckpointBegin(o)
  \/ \E o \in Owners, r \in Readers : ShrinkSlices(o,r)
  \/ \E o \in Owners : MoveGroupCollect(o)
  \/ \E o \in Owners : MoveGroupSplit(o)
  \/ \E o \in Owners : MoveGroupMerge(o)
  \/ \E o \in Owners, r \in Readers : CheckpointScopes(o,r)
  \/ \E o \in Owners : RangeCompleteTasksBegin(o)
  \/ \E o \in Owners : RangeCompleteTasksCommit(o)
  \/ \E o \in Owners : RangeCompleteTasksFail(o)
  \/ \E o \in Owners : RangeCompleteTasksReply(o)
  \/ \E o \in Owners : RangeCompleteTasksLostReply(o)
  \/ \E o \in Owners : SetQueueStateBatched(o)
  \/ \E o \in Owners, j \in Jids : SetQueueStateSnapshot(o,j)
  \/ \E o \in Owners : SetQueueStateClosed(o)
  \/ \E o \in Owners, j \in Jids : UpdateShardInfoSnapshot(o,j)
  \/ \E j \in Jids : UpdateShardCommit(j)
  \/ \E j \in Jids : UpdateShardFenced(j)
  \/ \E j \in Jids : UpdateShardFail(j)
  \/ \E j \in Jids : UpdateShardReply(j)
  \/ \E j \in Jids : UpdateShardLostReply(j)
  \/ \E o \in Owners : ProcessNewRangeMerge(o)
  \/ \E o \in Owners, r \in Readers, id \in Sids, cut \in Keys, fresh \in Sids : SplitSlicesByRange(o,r,id,cut,fresh)
  \/ \E o \in Owners, r \in Readers, i \in 1..SliceSlots : CompactSlices(o,r,i)
  \/ \E o \in Owners, r \in Readers, id \in Sids : ClearSlicesBegin(o,r,id)
  \/ \E o \in Owners, e \in Eids : ClearCancel(o,e)
  \/ \E o \in Owners : ClearSlicesComplete(o)
  \/ \E e \in Eids : Execute(e)
  \/ \E e \in Eids : ProcessTransferTaskEligible(e)
  \/ \E e \in Eids : ProcessTransferTaskObsolete(e)
  \/ \E e \in Eids : ExecuteRetryableError(e)
  \/ \E e \in Eids : ExecuteUnexpectedError(e)
  \/ \E e \in Eids : ExecuteTerminalError(e)
  \/ \E e \in Eids : MatchingSpoolCommit(e)
  \/ \E e \in Eids : RecordTaskStarted(e)
  \/ \E e \in Eids : MatchingTerminalDiscard(e)
  \/ \E e \in Eids : MatchingReply(e)
  \/ \E e \in Eids : MatchingLostReply(e)
  \/ \E e \in Eids : EnqueueTaskCommit(e)
  \/ \E e \in Eids : EnqueueTaskReply(e)
  \/ \E e \in Eids : EnqueueTaskLostReply(e)
  \/ \E e \in Eids : HandleErrAck(e)
  \/ \E e \in Eids : HandleErrRetry(e)
  \/ \E e \in Eids : HandleErrTerminal(e)
  \/ \E e \in Eids : HandleErrUnexpected(e)
  \/ \E e \in Eids : Ack(e)
  \/ \E e \in Eids : Nack(e)
  \/ \E e \in Eids : Reschedule(e)
  \/ \E t \in Tasks : WorkflowNoLongerNeedsTask(t)
  \/ \E t \in Tasks : WorkerComplete(t)

Spec == Init /\ [][Next]_vars

\* Core safety: no ACK invents successful business execution; permitted duplicate
\* deliveries are represented by distinct wrappers, with set-valued responsibility.
NoPhantomEffect == s.db.matching \cup s.db.started \cup s.db.dlq \cup s.db.acked \subseteq s.db.workflow
CompletedWasStarted == s.db.completed \subseteq s.db.started
AckDisposition == s.db.acked \subseteq s.db.matching \cup s.db.started \cup s.db.obsolete \cup s.db.dlq \cup s.db.terminal
\* S1; SQL/execution.go:351-443. Historical ledger survives later deletion.
AtomicPublication == s.db.workflow = s.db.published /\ s.db.rows \subseteq s.db.published
\* S1/S4: unresolved admissible writes cannot appear below any retired frontier.
SafeReadFrontier == \A t \in Tasks :
  (s.pub[t].phase = "appended" /\ s.pub[t].epoch = s.db.range) =>
    /\ s.db.queue.high <= TaskKey(t)
    /\ \A o \in Owners : s.q[o].high <= TaskKey(t)
\* S1-S5: strict property deliberately includes terminal discard outcomes.
UnfinishedObligationCovered == \A t \in Unresolved :
  t \in s.db.rows /\ ScopeCovered(s.db.queue,t)
\* Explicit narrower assumption for production terminal-drop policy comparisons.
ContractObligationCovered == \A t \in Unresolved \cap ContractTasks :
  t \in s.db.rows /\ ScopeCovered(s.db.queue,t)
\* S3-S5: receipt is physical deletion of an original row, not API return.
SafeImmediateDeletion == \A t \in s.db.deleted : Responsible(t)
ContractImmediateDeletion == \A t \in s.db.deleted \cap ContractTasks : Responsible(t)
\* S1/S4: compare epochs recorded at protected store linearization points.
CurrentEpochWrites == \A pair \in s.db.protected : pair[1] = pair[2]
\* S2/S3: after the persisted read frontier, reconstruction follows stored scopes.
RecoverableScopeCoverage == \A t \in Unresolved \cap s.db.rows : ScopeCovered(s.db.queue,t)
\* S2/CR-1 diagnostic: detached cursor first, then nil with unread attached scopes.
LiveCursorSoundness == \A o \in Owners : \A r \in Readers :
  s.own[o].mode = "active" =>
    /\ s.q[o].cursor[r] = 0 \/ s.q[o].cursor[r] \in Attached(o,r)
    /\ s.q[o].cursor[r] = 0 => \A z \in SS(s.q[o].lists[r]) : z.iters = {}
\* Structural checks do NOT impose cross-reader predicate disjointness.
ReaderStructure == \A o \in Owners : \A r \in Readers :
  /\ Cardinality(Attached(o,r)) = Len(s.q[o].lists[r])
  /\ \A i \in 1..(Len(s.q[o].lists[r])-1) : s.q[o].lists[r][i].hi <= s.q[o].lists[r][i+1].lo
  /\ \A z \in SS(s.q[o].lists[r]) :
      /\ z.lo <= z.hi /\ z.pred \subseteq Groups /\ z.id \in Sids
      /\ \A e \in z.tracked : Contains(z,s.ex[e].task)
      /\ \A it \in z.iters : z.lo <= it.lo /\ it.lo <= it.hi /\ it.hi <= z.hi
TypeOK ==
  /\ s.db.range \in 1..MaxEpoch /\ s.db.owner \in Owners
  /\ s.db.rows \cup s.db.workflow \cup s.db.deleted \cup s.db.obsolete \cup s.db.terminal \subseteq Tasks
  /\ DOMAIN s.pub = Tasks /\ DOMAIN s.own = Owners /\ DOMAIN s.q = Owners
  /\ DOMAIN s.ex = Eids /\ DOMAIN s.snaps = Jids
  /\ \A t \in Tasks : s.pub[t].key \in Keys /\ s.pub[t].pending \in BOOLEAN
  /\ \A o \in Owners : s.own[o].epoch \in 0..MaxEpoch /\ s.q[o].high \in Keys /\ s.q[o].deleteMin \in Keys
  /\ \A e \in Eids : s.ex[e].task \in Tasks \cup {0} /\ s.ex[e].owner \in Owners \cup {0}

\* Progress is checked only under service fairness and finite fault assumptions.
\* No fairness on AcquireShardBegin: healthy live-reader abandonment must remain.
EligibleDispatchProgress == \A t \in Tasks :
  (t \in s.db.workflow /\ t \notin s.db.obsolete \cup s.db.terminal) ~> Responsible(t)
CompletedPrefix(t) == t \in s.db.rows /\
  \A u \in s.db.workflow : TaskKey(u) <= TaskKey(t) => Responsible(u)
EventualCleanup == \A t \in Tasks : CompletedPrefix(t) ~> (t \notin s.db.rows)
=============================================================================
