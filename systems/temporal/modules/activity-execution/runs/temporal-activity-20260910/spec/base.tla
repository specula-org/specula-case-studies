------------------------------ MODULE base ------------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS ActivityCount, Workers, NamespaceVersion, IncrementRetryStamp,
          HasRetryPolicy, MaximumAttempts, InitialInterval, BackoffCoefficient,
          MaximumInterval, ScheduleToStart, StartToClose, ScheduleToClose,
          Heartbeat, WorkflowExpiration, KeepInitialWFT, InitialDBVersion

(***************************************************************************
 Category A. Pinned Temporal 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
 Source paths abbreviated below are relative to service/history, except
 common/* and service/matching/*. See model-notes.md for the abstraction map.
 s.cache is lease-protected Mutable State; s.db excludes volatile watermark.
 s.writes are immutable backend requests, independently completed after timeout.
 All SQL execution/ActivityInfo/buffer/task changes occur in ONE action.
 Scenario 1: transport, tokens, lastCheck. 2: timer mask, watermark, task cues.
 Scenario 3: cache/db, writes/receipts, historyAppends, ownership, API outcomes.
 Scenario 4: history/buffer, WFT seen/consumed. 5: readback and trace endpoint.
***************************************************************************)
VARIABLE s
vars == <<s>>
Activities == 1..ActivityCount
Kinds == {"STC", "STS", "SCT", "HB"}
TermKinds == {"Completed", "Failed", "Canceled"} \cup Kinds
Max(a,b) == IF a >= b THEN a ELSE b
Min(a,b) == IF a <= b THEN a ELSE b
ToSet(q) == {q[i] : i \in 1..Len(q)}
TermSeq(w) == SelectSeq(w.history \o w.buffer, LAMBDA e: e.kind \in TermKinds)
TermSet(w) == ToSet(TermSeq(w))
OrderedBuffer(q) == SelectSeq(q,LAMBDA e: e.kind \notin TermKinds) \o
                    SelectSeq(q,LAMBDA e: e.kind \in TermKinds)
Event(a,k,n) == [a |-> a, kind |-> k, attempt |-> n]

\* workflow/mutable_state_impl.go:4348-4371,2227-2234: absent AI is an empty map entry.
EmptyAI == [present |-> FALSE, attempt |-> 0, started |-> "No", request |-> 0,
            version |-> 0, startVersion |-> 0, stamp |-> 0,
            first |-> -1, scheduled |-> -1, startTime |-> -1,
            heartbeatTime |-> -1, details |-> 0, cancel |-> FALSE, mask |-> {}]
EmptyWF == [ai |-> [a \in Activities |-> EmptyAI], scheduled |-> {},
            history |-> <<>>, buffer |-> <<>>, wft |-> "Started",
            seen |-> {}, consumed |-> {}, open |-> TRUE]
EmptyToken == [a |-> 0, attempt |-> 0, version |-> 0, startVersion |-> 0,
               worker |-> "none", request |-> 0]
EmptyReply == [id |-> 0, kind |-> "Internal", status |-> "None",
               token |-> EmptyToken, outcome |-> {}, cancel |-> FALSE,
               details |-> 0, metadata |-> FALSE]
EmptyTx == [id |-> 0, attempt |-> 1, expected |-> 0, range |-> 0,
            reply |-> EmptyReply, cue |-> 0, makeWFT |-> FALSE, result |-> "Pending"]
EmptyCheck == [stale |-> FALSE, beforeAI |-> EmptyAI, afterAI |-> EmptyAI,
               beforeTerms |-> {}, afterTerms |-> {}]

\* workflow/context.go:408-435; bootstrap is before the first schedule command,
\* with its initial normal WFT already started. Observation-only counters normalize IDs.
Init == s = [now |-> 1, cache |-> EmptyWF, db |-> EmptyWF, valid |-> TRUE,
  watermark |-> [a \in Activities |-> -1], dbVersion |-> InitialDBVersion,
  range |-> 1, owner |-> 1, needFence |-> FALSE, phase |-> "Idle", tx |-> EmptyTx,
  newTasks |-> <<>>, tasks |-> {}, claimed |-> {}, ackable |-> {},
  copies |-> {}, matching |-> {}, dispatchReturns |-> {},
  startCalls |-> {}, startMsgs |-> {}, polls |-> {}, lostStarts |-> {}, pollReplies |-> {},
  tokens |-> {}, requests |-> {}, issuedRequests |-> {},
  replies |-> {}, observed |-> {}, acknowledged |-> {}, cancelObserved |-> {},
  writes |-> {}, receipts |-> {}, historyAppends |-> {}, committedOutcomes |-> {},
  notifyPending |-> {}, notified |-> {}, nextTxn |-> 1, nextTask |-> 1,
  nextDelivery |-> 1, nextRequest |-> 1, lastCheck |-> EmptyCheck,
  readback |-> [version |-> 0, range |-> 0, outcomes |-> {}], traceComplete |-> FALSE, keyFloor |-> 0, appended |-> {}]

\* workflow/context.go:143-164; no local mutation/inspection by a second lease.
Ready == s.phase = "Idle" /\ s.valid /\ ~s.needFence /\ s.owner = s.range
\* api/update_workflow_util.go:70-117; workflow/context.go:973-1001.
BeginMutation(x,w,r,cue) == [x EXCEPT !.cache = w, !.phase = "Mutated",
  !.newTasks = <<>>, !.tx = [EmptyTx EXCEPT !.id = x.nextTxn,
    !.expected = x.dbVersion, !.range = x.owner, !.reply = r, !.cue = cue],
  !.nextTxn = @ + 1]
\* workflow/task_generator.go:560-581. IDs assigned later by shard/context_impl.go:638.
GenerateTask(x,k,a,n,stamp,v,due) == [x EXCEPT !.newTasks = Append(@,
  [id |-> 0, kind |-> k, a |-> a, attempt |-> n, stamp |-> stamp,
   version |-> v, due |-> due, logical |-> due])]
\* historybuilder/event_store.go:161-199; buffer behind an in-flight WFT.
AddEvent(w,e) == [w EXCEPT !.buffer = Append(@,e)]
\* mutable_state_impl.go:4414-4455,4613-4636,4662-4686,4714-4738,4895-4956.
FinishActivity(x,a,k) ==
  LET ai == x.cache.ai[a]
      w1 == IF ai.started = "Transient"
            THEN AddEvent(x.cache,Event(a,"Started",ai.attempt)) ELSE x.cache
      w2 == AddEvent(w1,Event(a,k,ai.attempt))
  IN [x EXCEPT !.cache = [w2 EXCEPT !.ai[a] = EmptyAI],
       !.watermark[a] = -1, !.tx.makeWFT = TRUE]

\* EventStore buffers Activity callbacks first, then Finish flushes when no WFT is started.
FlushWithoutStartedWFT(w) == IF w.wft = "Started" THEN w ELSE
  [w EXCEPT !.history = @ \o OrderedBuffer(w.buffer), !.buffer = <<>>]
PrepareWFT(x) ==
  LET need == x.cache.open /\ (x.cache.wft = "Pending" \/
               (x.tx.makeWFT /\ x.cache.wft = "None"))
      y == IF need THEN [x EXCEPT !.cache = [FlushWithoutStartedWFT(x.cache) EXCEPT !.wft = "Pending"]] ELSE x
  IN IF need /\ ~\E t \in ToSet(y.newTasks): t.kind = "WFT"
     THEN GenerateTask(y,"WFT",0,0,0,NamespaceVersion,-1) ELSE y

\* workflow/timer_sequence.go:295-444. Integer-ms timestamps preserve queues/
\* queue_scheduled.go:286-300; FirstScheduledTime is present in newly scheduled AIs.
Deadline(ai,k) == CASE k = "SCT" -> ai.first + ScheduleToClose
  [] k = "STS" -> ai.scheduled + ScheduleToStart
  [] k = "STC" -> ai.startTime + StartToClose
  [] k = "HB" -> Max(ai.startTime,ai.heartbeatTime) + Heartbeat
Applicable(ai,k) == ai.present /\ CASE
  k = "SCT" -> ScheduleToClose > 0
  [] k = "STS" -> ai.started = "No" /\ ScheduleToStart > 0
  [] k = "STC" -> ai.started # "No" /\ StartToClose > 0
  [] k = "HB" -> ai.started # "No" /\ Heartbeat > 0
Deadlines(w) == UNION {{[a |-> a, kind |-> k, due |-> Deadline(w.ai[a],k),
    attempt |-> w.ai[a].attempt] : k \in {j \in Kinds: Applicable(w.ai[a],j)}}
    : a \in Activities}
\* timer_sequence.go:486-505; protobuf TimeoutType order: STC=1,SCT=2,STS=3,HB=4.
KindOrder(k) == CASE k = "STC" -> 1 [] k = "STS" -> 2 [] k = "SCT" -> 3 [] k = "HB" -> 4
Earlier(d,e) == d.due < e.due \/ (d.due = e.due /\
  (d.a < e.a \/ (d.a = e.a /\ KindOrder(d.kind) < KindOrder(e.kind))))
First(ds) == CHOOSE d \in ds: \A e \in ds: ~Earlier(e,d)
RECURSIVE Sorted(_)
Sorted(ds) == IF ds = {} THEN <<>> ELSE <<First(ds)>> \o Sorted(ds \ {First(ds)})

\* mutable_state_impl.go:6888-6914,6942-6961; workflow/retry.go:95-111.
\* Positive integer policy parameters; no custom application nextRetryDelay in this slice.
RetryDelay(n) == LET d == InitialInterval * (BackoffCoefficient ^ (n-1))
                IN IF MaximumInterval = 0 THEN d ELSE Min(d,MaximumInterval)
RetryState(x,a,reason) == LET ai == x.cache.ai[a] IN
  IF ~HasRetryPolicy THEN "NoPolicy"
  ELSE IF ai.cancel THEN "CancelRequested"
  ELSE IF reason \in {"STS","SCT"} THEN "Timeout"
  ELSE IF reason = "NonRetryable" THEN "NonRetryable"
  ELSE IF MaximumAttempts > 0 /\ ai.attempt >= MaximumAttempts THEN "MaxAttempts"
  ELSE IF ScheduleToClose > 0 /\ x.now + RetryDelay(ai.attempt) > ai.first + ScheduleToClose
       THEN "Timeout" ELSE "InProgress"
\* mutable_state_impl.go:6964-6975; workflow/activity.go:51-89. Preserve heartbeat
\* details/time and global SCT bit; clear start identity and per-attempt timer bits.
RetryActivity(x,a,reason) ==
  LET ai == x.cache.ai[a]
      next == [ai EXCEPT !.attempt = @+1, !.version = NamespaceVersion,
        !.scheduled = x.now + RetryDelay(ai.attempt), !.started = "No",
        !.startVersion = 0, !.request = 0, !.startTime = -1,
        !.mask = @ \cap {"SCT"}, !.stamp = @ + IF IncrementRetryStamp THEN 1 ELSE 0]
      y == [x EXCEPT !.cache.ai[a] = next]
  IN GenerateTask(y,"Retry",a,next.attempt,next.stamp,next.version,next.scheduled)

\* timer_queue_active_task_executor.go:251-278,299-305: immutable sorted snapshot,
\* skip deleted or overtaken entries; entire scan shares one Workflow lease/transaction.
RECURSIVE ProcessSingleActivityTimeoutTask(_,_,_)
ProcessSingleActivityTimeoutTask(x,q,i) == IF i > Len(q) THEN x ELSE
  LET d == q[i]
      ai == x.cache.ai[d.a]
      state == IF ai.present THEN RetryState(x,d.a,d.kind) ELSE "Absent"
      reason == IF state = "Timeout" /\ d.kind # "STS" THEN "SCT" ELSE d.kind
      y == IF ~ai.present \/ d.attempt < ai.attempt THEN x
           ELSE IF state = "InProgress" THEN RetryActivity(x,d.a,d.kind)
           ELSE FinishActivity(x,d.a,reason)
           \* timer_queue_active_task_executor.go:310-324,352-378.
  IN ProcessSingleActivityTimeoutTask(y,q,i+1)

\* timer_sequence.go:118-164; ONE globally earliest cue, not one per deadline.
CreateNextActivityTimer(x) ==
  LET ds == Deadlines(x.cache) IN IF ~x.cache.open \/ ds = {} THEN x ELSE
  LET d == First(ds) ai == x.cache.ai[d.a] IN
  IF (WorkflowExpiration > 0 /\ d.due > WorkflowExpiration) \/ d.kind \in ai.mask
  THEN x ELSE
  LET y == [x EXCEPT !.cache.ai[d.a].mask = @ \cup {d.kind},
             !.watermark[d.a] = IF d.kind = "HB" THEN d.due ELSE @]
  IN GenerateTask(y,d.kind,d.a,ai.attempt,ai.stamp,ai.version,d.due)

\* mutable_state_impl.go:4306-4401; api/respondworkflowtaskcompleted/api.go:558.
\* One schedule command batch; keepWFT corresponds to ForceCreateNewWorkflowTask.
AddActivityTaskScheduledEvent ==
  /\ Ready /\ s.cache.open /\ s.cache.scheduled = {} /\ s.cache.wft = "Started"
  /\ LET w == [s.cache EXCEPT
       !.ai = [a \in Activities |-> [EmptyAI EXCEPT !.present = TRUE,
          !.attempt = 1, !.version = NamespaceVersion, !.first = s.now, !.scheduled = s.now]],
       !.scheduled = Activities, !.wft = IF KeepInitialWFT THEN "Pending" ELSE "None",
       !.history = [a \in Activities |-> Event(a,"Scheduled",1)]]
         x == BeginMutation(s,w,EmptyReply,0)
         taskseq == [a \in Activities |-> [id |-> 0,kind |-> "Transfer",a |-> a,
           attempt |-> 1,stamp |-> 0,version |-> NamespaceVersion,due |-> -1,logical |-> -1]]
         y == [x EXCEPT !.newTasks = taskseq]
     IN s' = IF KeepInitialWFT THEN GenerateTask(y,"WFT",0,0,0,NamespaceVersion,-1) ELSE y

\* transfer_queue_active_task_executor.go:256-284; timer_queue_active_task_executor.go:563-621.
\* No attempt or not-before field crosses this handoff. Retry producer has a '<' check.
DispatchValid(t) == LET ai == s.cache.ai[t.a] IN
  ai.present /\ s.cache.open /\ t.stamp = ai.stamp /\ t.version = ai.version /\
  (t.kind = "Transfer" \/ (t.attempt >= ai.attempt /\ ai.started = "No"))
TaskReady(t) == t \in s.tasks /\ t.id \notin s.claimed /\ t.id \notin s.ackable /\ t.due <= s.now
CopyDispatch(t) == [s EXCEPT !.claimed = @ \cup {t.id}, !.nextDelivery = @+1,
  !.copies = @ \cup {[id |-> s.nextDelivery, origin |-> t.id, a |-> t.a, stamp |-> t.stamp, sent |-> s.now, expires |-> -1]}]
ProcessActivityTask(t) ==
  /\ Ready /\ TaskReady(t) /\ t.kind = "Transfer"
                          /\ DispatchValid(t) /\ s' = CopyDispatch(t)
ExecuteActivityRetryTimerTask(t) ==
  /\ Ready /\ TaskReady(t) /\ t.kind = "Retry"
                                   /\ DispatchValid(t) /\ s' = CopyDispatch(t)
DiscardObsoleteActivityTask(t) ==
  /\ Ready /\ TaskReady(t) /\ t.kind \in {"Transfer","Retry"}
  /\ ~DispatchValid(t) /\ s' = [s EXCEPT !.ackable = @ \cup {t.id}]
\* service/matching/matching_engine.go:646-693; task_queue_partition_manager.go:607-673.
\* Abstract successful spooling. Queue internals/routing are excluded, accepted start is later.
MatchingCreationTimes == 0..s.now
AddActivityTaskAt(d,created) ==
  /\ d \in s.copies /\ created \in Nat /\ created >= d.sent /\ created <= s.now
  /\ LET queued == [d EXCEPT !.expires = IF ScheduleToStart > 0 THEN created+ScheduleToStart ELSE -1]
     IN s' = [s EXCEPT !.copies = @ \ {d}, !.matching = @ \cup {queued},
             !.dispatchReturns = @ \cup {d.origin}]
AddActivityTask(d) == \E created \in MatchingCreationTimes: AddActivityTaskAt(d,created)
DropExpiredMatchingTask(d) ==
  /\ d \in s.matching /\ d.expires >= 0 /\ s.now >= d.expires
  /\ s' = [s EXCEPT !.matching = @ \ {d}]
\* timer_queue_active_task_executor.go:623-639; return reception precedes queue Ack.
DeliverAddActivityTaskResponse(id) ==
  /\ id \in s.dispatchReturns
  /\ s' = [s EXCEPT !.dispatchReturns = @ \ {id}, !.ackable = @ \cup {id}]
\* Same RPC can be redelivered after an uncertain AddActivityTask response (Scenario 1).
LoseAddActivityTaskResponse(id) ==
  /\ id \in s.dispatchReturns
  /\ s' = [s EXCEPT !.dispatchReturns = @ \ {id}, !.claimed = @ \ {id}]
\* service/matching/matching_engine.go:3587-3606: fresh RequestID per concrete poll dispatch.
PollActivityTaskQueue(d,w) ==
  /\ d \in s.matching /\ w \in Workers
  /\ LET r == [id |-> s.nextRequest, a |-> d.a, stamp |-> d.stamp, worker |-> w, sent |-> d.sent, expires |-> d.expires]
     IN s' = [s EXCEPT !.matching = @ \ {d}, !.startMsgs = @ \cup {r},
         !.startCalls = @ \cup {r}, !.polls = @ \cup {r}, !.nextRequest = @+1]
\* client/history/retryable_client_gen.go:674-686: same request object, no fabricated token.
RetryRecordActivityTaskStarted(r) ==
  /\ r \in s.polls /\ r \notin s.startMsgs
  /\ s' = [s EXCEPT !.startMsgs = @ \cup {r}]
StartToken(r,ai,duplicate) == [a |-> r.a, attempt |-> ai.attempt,
  version |-> IF duplicate THEN 0 ELSE ai.version,
  startVersion |-> IF duplicate THEN 0 ELSE ai.startVersion,
  worker |-> r.worker, request |-> r.id]
\* recordactivitytaskstarted/api.go:118-184,294-310; mutable_state_impl.go:4502-4565.
RecordActivityTaskStarted(r) ==
  /\ Ready /\ r \in s.startMsgs /\ s.cache.open
  /\ LET ai == s.cache.ai[r.a] IN ai.present /\ ai.started = "No" /\ ai.stamp = r.stamp
  /\ LET ai == [s.cache.ai[r.a] EXCEPT !.started = IF HasRetryPolicy THEN "Transient" ELSE "Event",
           !.request = r.id, !.startTime = s.now, !.version = NamespaceVersion,
           !.startVersion = NamespaceVersion]
         w0 == [s.cache EXCEPT !.ai[r.a] = ai]
         w == IF HasRetryPolicy THEN w0 ELSE AddEvent(w0,Event(r.a,"Started",ai.attempt))
         reply == [EmptyReply EXCEPT !.id = r.id, !.kind = "Start", !.status = "OK",
             !.token = StartToken(r,ai,FALSE), !.details = ai.details, !.metadata = TRUE]
     IN s' = BeginMutation([s EXCEPT !.startMsgs = @ \ {r}],w,reply,0)
\* recordactivitytaskstarted/api.go:150-165; Invoke:71-77 still persists (Noop=false).
RecordActivityTaskStartedDuplicate(r) ==
  /\ Ready /\ r \in s.startMsgs /\ s.cache.open
  /\ LET ai == s.cache.ai[r.a] IN ai.present /\ ai.started # "No" /\ ai.request = r.id
  /\ LET reply == [EmptyReply EXCEPT !.id = r.id, !.kind = "Start", !.status = "OK",
         !.token = StartToken(r,s.cache.ai[r.a],TRUE)]
     IN s' = BeginMutation([s EXCEPT !.startMsgs = @ \ {r}],s.cache,reply,0)
\* recordactivitytaskstarted/api.go:124-136,168-184; already-started check precedes stamp.
RecordActivityTaskStartedRejected(r) ==
  /\ Ready /\ r \in s.startMsgs
  /\ LET ai == s.cache.ai[r.a] IN ~s.cache.open \/ ~ai.present \/
       (ai.started # "No" /\ ai.request # r.id) \/ (ai.started = "No" /\ ai.stamp # r.stamp)
  /\ s' = [s EXCEPT !.startMsgs = @ \ {r}, !.replies = @ \cup
       {[EmptyReply EXCEPT !.id = r.id, !.kind = "Start", !.status = "NotFound"]}]

\* api/activity_util.go:58-79. Ordinary scheduled ID is always nonzero; no ByID branch.
TokenValid(ai,t) == ai.present /\ ai.started # "No" /\ ai.attempt = t.attempt /\
  IF t.startVersion # 0 /\ ai.startVersion # 0 THEN t.startVersion = ai.startVersion
  ELSE t.version = 0 \/ t.version = ai.version
\* worker RPC environment: only tokens actually delivered by Matching may be used.
SendActivityRequest(t,k,detail) ==
  /\ t \in s.tokens
  /\ k \in {"Completed","Failed","NonRetryable","Heartbeat","Canceled"} /\ detail \in {-1,0,1}
  /\ s' = [s EXCEPT !.requests = @ \cup {[id |-> s.nextRequest, token |-> t,
          kind |-> k, details |-> detail]},
      !.issuedRequests = @ \cup {[id |-> s.nextRequest,token |-> t,kind |-> k,details |-> detail]}, !.nextRequest = @+1]
RequestReply(r,outcome,cancel) == [EmptyReply EXCEPT !.id = r.id, !.kind = r.kind,
  !.status = "OK", !.token = r.token, !.outcome = outcome, !.cancel = cancel]
CheckResult(x,r,before) == [x EXCEPT !.lastCheck =
  [stale |-> ~before.ai[r.token.a].present \/ before.ai[r.token.a].attempt # r.token.attempt,
   beforeAI |-> before.ai[r.token.a], afterAI |-> x.cache.ai[r.token.a],
   beforeTerms |-> TermSet(before), afterTerms |-> TermSet(x.cache)]]
\* respondactivitytaskcompleted/api.go:74-126: CancelRequested is NOT a completion veto.
RespondActivityTaskCompleted(r) ==
  /\ Ready /\ r \in s.requests /\ r.kind = "Completed"
  /\ s.cache.open /\ TokenValid(s.cache.ai[r.token.a],r.token)
  /\ LET e == Event(r.token.a,"Completed",r.token.attempt)
         x == BeginMutation([s EXCEPT !.requests = @ \ {r}],s.cache,RequestReply(r,{e},FALSE),0)
     IN s' = CheckResult(FinishActivity(x,r.token.a,"Completed"),r,s.cache)
\* respondactivitytaskfailed/api.go:88-125. Final heartbeat details are included;
\* failure kind selects retryable ApplicationFailure versus NonRetryable=true.
RespondActivityTaskFailed(r) ==
  /\ Ready /\ r \in s.requests /\ r.kind \in {"Failed","NonRetryable"}
  /\ s.cache.open /\ TokenValid(s.cache.ai[r.token.a],r.token)
  /\ LET a == r.token.a
         w == IF r.details = -1 THEN s.cache ELSE [s.cache EXCEPT
              !.ai[a].heartbeatTime = s.now, !.ai[a].details = Max(0,r.details), !.ai[a].version = NamespaceVersion]
         x == BeginMutation([s EXCEPT !.requests = @ \ {r}],w,RequestReply(r,{},FALSE),0)
         retry == RetryState(x,a,r.kind) = "InProgress"
         y == IF retry THEN RetryActivity(x,a,r.kind) ELSE FinishActivity(x,a,"Failed")
         z == IF retry THEN y ELSE [y EXCEPT !.tx.reply.outcome = {Event(a,"Failed",r.token.attempt)}]
     IN s' = CheckResult(z,r,s.cache)
\* respondactivitytaskcanceled/api.go:82-108: token AND prior cancellation request.
RespondActivityTaskCanceled(r) ==
  /\ Ready /\ r \in s.requests /\ r.kind = "Canceled"
  /\ s.cache.open /\ TokenValid(s.cache.ai[r.token.a],r.token) /\ s.cache.ai[r.token.a].cancel
  /\ LET e == Event(r.token.a,"Canceled",r.token.attempt)
         x == BeginMutation([s EXCEPT !.requests = @ \ {r}],s.cache,RequestReply(r,{e},FALSE),0)
     IN s' = CheckResult(FinishActivity(x,r.token.a,"Canceled"),r,s.cache)
\* recordactivitytaskheartbeat/api.go:73-101; mutable_state_impl.go:2117-2127.
RecordActivityTaskHeartbeat(r) ==
  /\ Ready /\ r \in s.requests /\ r.kind = "Heartbeat"
  /\ s.cache.open /\ TokenValid(s.cache.ai[r.token.a],r.token)
  /\ LET a == r.token.a
         w == [s.cache EXCEPT !.ai[a].heartbeatTime = s.now, !.ai[a].details = Max(0,r.details),
                            !.ai[a].version = NamespaceVersion]
         x == BeginMutation([s EXCEPT !.requests = @ \ {r}],w,
                    RequestReply(r,{},s.cache.ai[a].cancel),0)
     IN s' = CheckResult(x,r,s.cache)
\* All four token API guards above; rejected calls have no mutation or success guarantee.
RejectActivityRequest(r) ==
  /\ Ready /\ r \in s.requests
  /\ (~s.cache.open \/ ~TokenValid(s.cache.ai[r.token.a],r.token) \/
         (r.kind = "Canceled" /\ ~s.cache.ai[r.token.a].cancel))
  /\ LET reply == [RequestReply(r,{},FALSE) EXCEPT !.status = "NotFound"]
         x == [s EXCEPT !.requests = @ \ {r}, !.replies = @ \cup {reply}]
     IN s' = CheckResult(x,r,s.cache)

\* timer_queue_active_task_executor.go:230-280: HB dedup is task.due >= volatile
\* watermark, ignores Activity stamp, then recomputes/sorts all current deadlines.
ExecuteActivityTimeoutTask(t) ==
  /\ Ready /\ TaskReady(t) /\ t.kind \in Kinds /\ s.cache.open
  /\ LET clearHB == t.kind = "HB" /\ s.cache.ai[t.a].present /\ t.due >= s.watermark[t.a]
         w == IF clearHB THEN [s.cache EXCEPT !.ai[t.a].mask = @ \ {"HB"}] ELSE s.cache
         q == Sorted({d \in Deadlines(w): d.due <= Max(s.now,t.due)})
         x == BeginMutation([s EXCEPT !.claimed = @ \cup {t.id}],w,EmptyReply,t.id)
         y == ProcessSingleActivityTimeoutTask(x,q,1)
     IN s' = IF clearHB \/ y.cache # w THEN y
        ELSE [s EXCEPT !.ackable = @ \cup {t.id}]
\* timer_queue_active_task_executor.go:221-227; queues/executable.go:742-770.
DiscardClosedWorkflowTimer(t) ==
  /\ Ready /\ TaskReady(t) /\ t.kind \in Kinds /\ ~s.cache.open
  /\ s' = [s EXCEPT !.ackable = @ \cup {t.id}]

\* workflow_task_state_machine.go:453-479: durable accepted WFT start captures
\* only already-visible terminal events; buffered results require a subsequent WFT.
RecordWorkflowTaskStarted ==
  /\ Ready /\ s.cache.open /\ s.cache.wft = "Pending"
  /\ LET w == [s.cache EXCEPT !.wft = "Started", !.seen =
                  {e \in ToSet(s.cache.history): e.kind \in TermKinds}]
     IN s' = BeginMutation(s,w,EmptyReply,0)
\* api/respondworkflowtaskcompleted/api.go:384,557-566; event_store.go:178-199.
CompleteWFT(w) == [w EXCEPT !.consumed = @ \cup w.seen, !.seen = {},
  !.history = @ \o OrderedBuffer(w.buffer), !.buffer = <<>>,
  !.wft = IF Len(w.buffer) > 0 THEN "Pending" ELSE "None"]
RespondWorkflowTaskCompleted ==
  /\ Ready /\ s.cache.open /\ s.cache.scheduled # {}
  /\ s.cache.wft = "Started"
  /\ LET x == BeginMutation(s,CompleteWFT(s.cache),EmptyReply,0)
     IN s' = IF x.cache.wft = "Pending"
             THEN GenerateTask(x,"WFT",0,0,0,NamespaceVersion,-1) ELSE x
\* workflow_task_completed_handler.go:692-717; canceled-scheduled is same command
\* transaction as WFT completion. Running request does not mean canceled outcome.
HandleCommandRequestCancelActivity(a) ==
  /\ Ready /\ a \in Activities /\ s.cache.open
  /\ s.cache.wft = "Started" /\ s.cache.ai[a].present /\ ~s.cache.ai[a].cancel
  /\ LET w0 == CompleteWFT(s.cache)
         w == [w0 EXCEPT !.ai[a].cancel = TRUE, !.ai[a].version = NamespaceVersion,
           !.history = Append(@,Event(a,"CancelRequested",s.cache.ai[a].attempt))]
         x == BeginMutation(s,w,EmptyReply,0)
     IN s' = PrepareWFT(IF w.ai[a].started = "No" THEN FinishActivity(x,a,"Canceled") ELSE x)
\* mutable_state_impl.go:4751-4763: competing cancel when terminal was buffered
\* records request but cannot create another terminal outcome.
HandleCommandCancelBufferedActivity(a) ==
  /\ Ready /\ a \in Activities /\ s.cache.open
  /\ s.cache.wft = "Started" /\ ~s.cache.ai[a].present
  /\ \E e \in ToSet(s.cache.buffer): e.a = a /\ e.kind \in TermKinds
  /\ LET w == CompleteWFT(s.cache)
     IN s' = BeginMutation(s,[w EXCEPT !.history = Append(@,Event(a,"CancelRequested",0))],EmptyReply,0)
\* workflow_task_completed_handler.go:804-805, event_store.go:168-175:
\* a preexisting buffer blocks close; same-command immediate cancellation may vanish.
HandleCommandCompleteWorkflow ==
  /\ Ready /\ s.cache.open /\ s.cache.wft = "Started"
  /\ s.cache.scheduled # {} /\ s.cache.buffer = <<>>
  /\ s' = BeginMutation(s,[CompleteWFT(s.cache) EXCEPT !.open = FALSE, !.wft = "None"],EmptyReply,0)
HandleCommandCancelAndCompleteWorkflow(a) ==
  /\ Ready /\ a \in Activities /\ s.cache.open
  /\ s.cache.wft = "Started" /\ s.cache.buffer = <<>>
  /\ s.cache.ai[a].present /\ ~s.cache.ai[a].cancel
  /\ LET w == [CompleteWFT(s.cache) EXCEPT !.open = FALSE, !.wft = "None",
        !.ai[a] = IF @.started = "No" THEN EmptyAI ELSE [@ EXCEPT !.cancel = TRUE],
        !.history = Append(@,Event(a,"CancelRequested",s.cache.ai[a].attempt))]
     IN s' = BeginMutation([s EXCEPT !.watermark[a] = IF w.ai[a].present THEN @ ELSE -1],w,EmptyReply,0)
\* workflow_task_completed_handler.go:804-805; respondworkflowtaskcompleted/
\* api.go:490-529,1124-1166: rejection cancels tentative WFT completion and clears cache.
HandleCommandCompleteWorkflowRejected ==
  /\ Ready /\ s.cache.open /\ s.cache.wft = "Started" /\ s.cache.buffer # <<>>
  /\ LET x == BeginMutation(s,EmptyWF,EmptyReply,0)
     IN s' = [x EXCEPT !.valid = FALSE, !.watermark = [a \in Activities |-> -1],
                        !.phase = "RejectedClose"]
\* Same held lease; explicit DB read and conservative watermark reconstruction.
\* respondworkflowtaskcompleted/api.go:1133-1141; mutable_state_impl.go:471-477.
ReloadAfterRejectedWorkflowClose ==
  /\ s.phase = "RejectedClose" /\ s.owner = s.range /\ ~s.needFence
  /\ s' = [s EXCEPT !.valid = TRUE, !.cache = s.db, !.phase = "CloseReloaded",
       !.watermark = [a \in Activities |-> IF "HB" \in s.db.ai[a].mask THEN 0 ELSE -1],
       !.readback = [version |-> s.dbVersion,range |-> s.range,outcomes |-> TermSet(s.db)]]
\* respondworkflowtaskcompleted/api.go:1141-1154,529,557-566; event_store.go:178-199.
\* Failure flushes buffered results and renews WFT work, without asserting consumption.
FailWorkflowTaskAfterRejectedClose ==
  /\ s.phase = "CloseReloaded"
  /\ LET x == [s EXCEPT !.cache.history = @ \o OrderedBuffer(s.cache.buffer), !.cache.buffer = <<>>,
       !.cache.wft = "Pending", !.cache.seen = {}, !.tx.makeWFT = TRUE, !.phase = "Mutated"]
     IN s' = PrepareWFT(x)

\* Timer coverage may be delegated to an actual Workflow expiration task. Initial
\* configurations disable this optional interface; no Activity terminal fabricated.
\* timer_queue_active_task_executor.go:executeWorkflowRunTimeoutTask; workflow/util.go:72-92,28-49; WorkflowExpiration denotes an existing durable run timer.
ExecuteWorkflowRunTimeoutTask ==
  /\ Ready /\ s.cache.open /\ WorkflowExpiration > 0
  /\ s.now >= WorkflowExpiration
  /\ s' = BeginMutation(s,[s.cache EXCEPT !.open = FALSE, !.wft = "None",
      !.history = @ \o OrderedBuffer(s.cache.buffer), !.buffer = <<>>, !.seen = {}],EmptyReply,0)

\* api/update_workflow_util.go:80-89; mutable_state_impl.go:9055-9066.
\* WFT transfer responsibility coalesces; no fresh WFT is required for every terminal.
CloseTransactionAsMutation ==
  /\ s.phase = "Mutated"
  /\ LET need == s.cache.open /\ s.tx.makeWFT /\ s.cache.wft = "None"
         w == IF need THEN [s.cache EXCEPT !.wft = "Pending"] ELSE s.cache
         x == [s EXCEPT !.cache = FlushWithoutStartedWFT(w)]
         addWFT == w.open /\ w.wft = "Pending" /\ s.db.wft # "Pending" /\
                   ~\E t \in ToSet(s.newTasks): t.kind = "WFT"
         y == IF addWFT THEN GenerateTask(x,"WFT",0,0,0,NamespaceVersion,-1) ELSE x
         z == CreateNextActivityTimer(y)
     IN s' = [z EXCEPT !.phase = "Closed"]
\* shard/context_impl.go:623-649: task-key allocation and ownership snapshot before IO.
TaskKeyFloors == Nat
TaskVisibility(t,minimum) == IF t.kind \in {"Transfer","WFT"} THEN s.now
  ELSE IF t.logical+1 < minimum THEN minimum+1 ELSE t.logical+1
SetAndTrackTaskKeysAt(minimum) ==
  /\ s.phase = "Closed" /\ s.owner = s.range /\ ~s.needFence
  /\ minimum \in Nat /\ minimum >= s.now /\ minimum >= s.keyFloor
  /\ s' = [s EXCEPT !.newTasks = [i \in 1..Len(s.newTasks) |->
         [s.newTasks[i] EXCEPT !.id = s.nextTask+i-1, !.due = TaskVisibility(s.newTasks[i],minimum)]],
       !.keyFloor = minimum, !.nextTask = @ + Len(s.newTasks), !.tx.range = s.owner, !.phase = "Prepared"]
SetAndTrackTaskKeys == \E minimum \in TaskKeyFloors: SetAndTrackTaskKeysAt(minimum)
\* execution_manager.go submits the immutable invocation above the fault wrapper.
SubmitWorkflowMutation ==
  /\ s.phase = "Prepared"
  /\ LET write == [id |-> s.tx.id, attempt |-> s.tx.attempt, expected |-> s.tx.expected,
          range |-> s.tx.range, wf |-> s.cache, tasks |-> ToSet(s.newTasks)]
     IN s' = [s EXCEPT !.phase = "Waiting", !.writes = @ \cup {write}]
\* The SQL delegate can append after the caller has timed out or lost ownership.
AppendHistoryNodesFor(w) ==
  /\ w \in s.writes
  /\ [id |-> w.id,attempt |-> w.attempt] \notin s.appended
  /\ LET previous == {h \in s.historyAppends: h.id = w.id}
         events == IF previous # {} THEN (CHOOSE h \in previous: TRUE).events
                   ELSE SubSeq(w.wf.history,Len(s.db.history)+1,Len(w.wf.history))
     IN s' = [s EXCEPT !.appended = @ \cup {[id |-> w.id,attempt |-> w.attempt]},
        !.historyAppends = @ \cup {[id |-> w.id, events |-> events]}]
AppendHistoryNodes == \E w \in s.writes: AppendHistoryNodesFor(w)
\* common/persistence/sql/execution_util.go:23-190,629-695; sql/shard.go:152-176.
\* This is the SQL atomicity boundary, including all generated task categories.
ApplyWorkflowMutationTx(w) ==
  /\ w \in s.writes /\ w.range = s.range /\ w.expected = s.dbVersion
  /\ [id |-> w.id,attempt |-> w.attempt] \in s.appended
  /\ s' = [s EXCEPT !.db = w.wf, !.dbVersion = @+1, !.tasks = @ \cup w.tasks,
      !.committedOutcomes = @ \cup TermSet(w.wf), !.writes = @ \ {w},
      !.receipts = @ \cup {[id |-> w.id, attempt |-> w.attempt, status |-> "Commit"]}]
\* The range and record-version fences reject this backend attempt only, not any
\* earlier committed attempt of the same logical request.
RejectWorkflowMutationTx(w) ==
  /\ w \in s.writes /\ (w.range # s.range \/ w.expected # s.dbVersion)
  /\ [id |-> w.id,attempt |-> w.attempt] \in s.appended
  /\ s' = [s EXCEPT !.writes = @ \ {w}, !.receipts = @ \cup
      {[id |-> w.id, attempt |-> w.attempt,
        status |-> IF w.range # s.range THEN "Ownership" ELSE "Condition"]}]
\* common/persistence/sql/common.go:57-74: definitely uncommitted attempt.
RejectPersistenceWrite(w) ==
  /\ w \in s.writes
  /\ s' = [s EXCEPT !.writes = @ \ {w}, !.receipts = @ \cup
              {[id |-> w.id, attempt |-> w.attempt, status |-> "Rejected"]}]
\* common/persistence/faultinjection/fault.go:40-47,61-71: Timeout skips execution;
\* the caller still sees an unknown outcome. Contrast ExecuteAndTimeout below.
PersistenceTimeoutBeforeWrite ==
  /\ s.phase = "Waiting"
  /\ [id |-> s.tx.id,attempt |-> s.tx.attempt] \notin s.appended
  /\ s' = [s EXCEPT !.writes = {w \in @: w.id # s.tx.id \/ w.attempt # s.tx.attempt},
      !.receipts = @ \cup {[id |-> s.tx.id,attempt |-> s.tx.attempt,status |-> "Aborted"]},
      !.tx.result = "Unknown", !.phase = "Waiting"]
\* SQL commit error/lost transport response; shard/context_impl.go:1540-1548.
\* Pending detached write remains executable until its RangeID is fenced.
PersistenceResponseTimeout ==
  /\ s.phase = "Waiting" /\ s.tx.result = "Pending"
  /\ s' = [s EXCEPT !.tx.result = "Unknown"]
\* common/persistence/persistence_retryable_clients.go:252-264; sql/common.go:77-78.
\* Same payload/CAS after unavailable commit response: expected version is NOT refreshed.
RetryPersistenceAfterUnavailable ==
  /\ s.phase = "Waiting" /\ s.tx.attempt = 1
  /\ [id |-> s.tx.id,attempt |-> 1,status |-> "Commit"] \in s.receipts
  /\ s' = [s EXCEPT !.tx.attempt = 2, !.phase = "Prepared"]
\* workflow/transaction_impl.go:184-214: result classification follows store response.
ReturnPersistenceResult ==
  /\ s.phase = "Waiting"
  /\ LET results == IF s.tx.result = "Unknown" THEN {"Unknown"}
          ELSE {IF r.status = "Commit" THEN "OK" ELSE r.status :
            r \in {r \in s.receipts: r.id = s.tx.id /\ r.attempt = s.tx.attempt /\ r.status # "Aborted"}}
     IN \E result \in results:
       s' = [s EXCEPT !.phase = "Result", !.tx.result = result,
         !.notifyPending = IF result \in {"OK","Unknown"} THEN @ \cup {s.tx.id} ELSE @]
\* workflow/context.go:888-909; workflow/cache/cache.go:373-409; transaction_impl.go:201-214.
\* Notification runs synchronously inside TransactionImpl before cache release.
\* Success frees the lease before a worker receives its response. Unknown may notify.
FinishUpdateWorkflowExecution ==
  /\ s.phase = "Result"
  /\ s.tx.id \notin s.notifyPending
  /\ (s.tx.result \in {"OK","Unknown"} => s.tx.id \in s.notified)
  /\ LET ok == s.tx.result = "OK"
         r == [s.tx.reply EXCEPT !.status = IF ok THEN @ ELSE s.tx.result]
     IN s' = [s EXCEPT !.phase = "Idle", !.valid = ok,
       !.cache = IF ok THEN @ ELSE EmptyWF,
       !.watermark = IF ok THEN @ ELSE [a \in Activities |-> -1],
       !.needFence = @ \/ (s.tx.result \in {"Unknown","Ownership"} /\ s.range = s.tx.range),
       !.replies = IF r.kind = "Internal" THEN @ ELSE @ \cup {r},
       !.ackable = IF ok /\ s.tx.cue # 0 THEN @ \cup {s.tx.cue} ELSE @,
       !.claimed = IF ~ok THEN @ \ {s.tx.cue} ELSE @,
       !.newTasks = <<>>, !.tx = EmptyTx]
\* Context cache loss is distinct from shard loss; it cannot undo committed SQL.
\* workflow/context.go:174-185.
ClearWorkflowCache ==
  /\ (s.phase = "Idle" \/ (s.phase = "Result" /\ s.tx.result # "OK"))
  /\ s' = [s EXCEPT !.valid = FALSE, !.cache = EmptyWF, !.watermark = [a \in Activities |-> -1]]
\* shard/context_impl.go:handleWriteErrorLocked,transition(contextRequestLost).
\* Reacquisition starts in the background; the same engine and active lease
\* continue unwinding. This event is not a process crash or an engine stop.
LoseShardContext ==
  /\ ~s.needFence
  /\ s' = [s EXCEPT !.needFence = TRUE]
\* shard/context_impl.go:1541-1547 and SQL shard row lock: the fence precedes readback.
ReacquireShard ==
  /\ s.needFence
  /\ s.owner = s.range
  /\ s' = [s EXCEPT !.range = @+1]
ShardReady ==
  /\ s.needFence /\ s.range > s.owner
  /\ s' = [s EXCEPT !.owner = s.range, !.needFence = FALSE]
\* workflow/context.go:416-435,474-497; mutable_state_impl.go:471-477.
\* Same namespace version/no speculative WFT makes StartTransaction flush unnecessary.
LoadMutableState ==
  /\ s.phase = "Idle" /\ ~s.valid /\ ~s.needFence /\ s.owner = s.range
  /\ s' = [s EXCEPT !.valid = TRUE, !.cache = s.db,
        !.watermark = [a \in Activities |-> IF "HB" \in s.db.ai[a].mask THEN 0 ELSE -1],
        !.readback = [version |-> s.dbVersion,range |-> s.range,outcomes |-> TermSet(s.db)]]
\* Independent quiesced DB/task read, not DescribeMutableState's cache projection.
\* common/persistence/sql/execution.go:210-330; api/describemutablestate/api.go:52-65.
ReadWorkflowExecution ==
  /\ (s.phase \in {"Idle","RejectedClose"} \/ (s.phase = "Waiting" /\
       \E r \in s.receipts: r.id = s.tx.id /\ r.attempt = s.tx.attempt /\ r.status = "Condition"))
  /\ ~s.needFence /\ s.owner = s.range
  /\ s' = [s EXCEPT !.readback = [version |-> s.dbVersion,range |-> s.range,outcomes |-> TermSet(s.db)]]
\* workflow/transaction_impl.go:201-214: notification is separate from durable task rows.
NotifyOnExecutionMutation(id) ==
  /\ id \in s.notifyPending
  /\ s' = [s EXCEPT !.notifyPending = @ \ {id}, !.notified = @ \cup {id}]
\* Queue ack/delete is later than execution; old tasks can survive successful commits.
\* queues/queue_base.go:373-394; common/persistence/sql/execution_tasks.go:66-97.
\* Individual modeled retirements project a successful category/range batch;
\* executable Ack alone only changes memory and must not supply this observation.
TaskCategory(t) == IF t.kind \in {"Transfer","WFT"} THEN "Immediate" ELSE "Scheduled"
TaskKeyLE(t,u) == IF TaskCategory(t) = "Immediate" THEN t.id <= u.id
                 ELSE t.due <= u.due
\* queues/queue_base.go:373-390: scheduled deletion uses time with TaskID=0;
\* all rows in a retired time bucket go together, across Activities in this Run.
RetirementBatches == {{t \in s.tasks: TaskCategory(t) = TaskCategory(u) /\ TaskKeyLE(t,u)} : u \in s.tasks}
RangeCompleteHistoryTasks(ts) ==
  /\ ts \in RetirementBatches /\ ts # {}
  /\ \A t \in ts: t.id \in s.ackable \/ t.kind = "WFT"
  /\ s' = [s EXCEPT !.tasks = @ \ ts, !.ackable = @ \ {t.id: t \in ts},
                               !.claimed = @ \ {t.id: t \in ts}]
\* WFT queue transport is an interface abstraction: its durable Pending/Started
\* responsibility is modeled; this retirement event denotes observed successful
\* Matching acceptance/obsolete disposition and batch deletion, not an invented Ack.
\* Queue redelivery is a fault/schedule input, never a reverted source guard.
RedeliverTask(t) ==
  /\ t \in s.tasks /\ t.id \in s.ackable
  /\ s' = [s EXCEPT !.ackable = @ \ {t.id}, !.claimed = @ \ {t.id}]
\* matching_engine.go:1117-1130; backlog_manager.go:230-270. Error rewrite
\* preserves Matching responsibility; its persistence internals are outside scope.
ReceiveRecordActivityTaskStartedResponse(r) ==
  /\ r \in s.replies /\ r.kind = "Start"
  /\ LET ps == {p \in s.polls: p.id = r.id}
         retry == ps # {} /\ r.status \notin {"OK","NotFound"}
         p == CHOOSE p \in ps: TRUE
     IN s' = [s EXCEPT !.replies = @ \ {r}, !.polls = @ \ ps,
       !.lostStarts = @ \ {r.id},
       !.pollReplies = IF ps # {} /\ r.status = "OK" THEN @ \cup {r} ELSE @,
       !.matching = IF retry THEN @ \cup {[id |-> s.nextDelivery,origin |-> 0,a |-> p.a,stamp |-> p.stamp,sent |-> p.sent,expires |-> p.expires]} ELSE @,
       !.nextDelivery = IF retry THEN @+1 ELSE @]
\* matching_engine.go:3587-3624,1117-1126; backlog_manager.go:230-259.
\* A lost History reply eventually expires the child request and rewrites work.
ExpireRecordActivityTaskStarted(r) ==
  /\ r \in s.polls /\ r.id \in s.lostStarts
  /\ s' = [s EXCEPT !.polls = @ \ {r}, !.lostStarts = @ \ {r.id},
       !.matching = @ \cup {[id |-> s.nextDelivery,origin |-> 0,a |-> r.a,stamp |-> r.stamp,sent |-> r.sent,expires |-> r.expires]},
       !.nextDelivery = @+1]
\* pri_task_reader.go:completeTask retains transient-failure work in the matcher.
RetryMatchingActivityTask(r) == ExpireRecordActivityTaskStarted(r)
\* service/matching/matching_engine.go:3435-3478: worker token is the response token.
DeliverPollActivityTaskQueueResponse(r) ==
  /\ r \in s.pollReplies
  /\ s' = [s EXCEPT !.pollReplies = @ \ {r}, !.observed = @ \cup {r},
         !.tokens = IF r.status = "OK" THEN @ \cup {r.token} ELSE @]
\* recordactivitytaskheartbeat/api.go:93-101; ordinary terminal API return after update helper.
DeliverActivityResponse(r) ==
  /\ r \in s.replies /\ r.kind # "Start" /\ r.status # "Condition"
  /\ s' = [s EXCEPT !.replies = @ \ {r}, !.observed = @ \cup {r},
      !.acknowledged = IF r.status = "OK" THEN @ \cup r.outcome ELSE @,
      !.cancelObserved = IF r.status = "OK" /\ r.kind = "Heartbeat" /\ r.cancel
                        THEN @ \cup {r.token} ELSE @]
\* History converts a condition failure to Unavailable; its client may retry
\* the same ordinary request before the outer caller observes any response.
RetryActivityRequest(r) ==
  /\ r \in s.issuedRequests
  /\ \E reply \in s.replies: reply.id = r.id /\ reply.kind = r.kind
       /\ reply.status = "Condition" /\ reply.token = r.token
       /\ s' = [s EXCEPT !.replies = @ \ {reply}, !.requests = @ \cup {r}]

\* RPC loss changes observation only; successful server mutation stays committed (Scenario 3).
LoseAPIResponse(r) ==
  /\ r \in s.replies \cup s.pollReplies
  /\ s' = [s EXCEPT !.replies = @ \ {r}, !.pollReplies = @ \ {r},
       !.lostStarts = IF r \in s.replies /\ r.kind = "Start" THEN @ \cup {r.id} ELSE @]
\* Timer environment: observed monotone milliseconds; no interpolation of hidden state.
\* MC enumerates a bounded grid; trace wrappers pass the actual observed next time.
TimeSuccessors == Nat
AdvanceTime(to) == /\ to \in Nat /\ to > s.now /\ s' = [s EXCEPT !.now = to]

\* Scenario 5 observer endpoint, no hidden server transitions. Source anchors for
\* independent terminal consumption: respondworkflowtaskcompleted/api.go:384,557-566.
CompleteEndpoint ==
  /\ Ready /\ s.db.scheduled = Activities
  /\ \A a \in Activities: \E e \in TermSet(s.db): e.a = a
  /\ TermSet(s.db) \subseteq s.db.consumed /\ s.db.buffer = <<>> /\ s.db.wft = "None"
  /\ s.readback = [version |-> s.dbVersion,range |-> s.range,outcomes |-> TermSet(s.db)]
  /\ s.writes = {} /\ s.requests = {} /\ s.startMsgs = {} /\ s.replies = {}
  /\ s.polls = {} /\ s.pollReplies = {}
  /\ s.copies = {} /\ s.matching = {}
FinishTrace ==
  /\ ~s.traceComplete /\ CompleteEndpoint /\ s' = [s EXCEPT !.traceComplete = TRUE]

(*************************** Safety and structure *************************)
\* AI structure is checked against source fields, not only the lifecycle label.
AIType(ai) ==
  /\ ai.present \in BOOLEAN /\ ai.attempt \in Nat
  /\ ai.started \in {"No","Transient","Event"} /\ ai.request \in Nat
  /\ ai.version \in Int /\ ai.startVersion \in Int /\ ai.stamp \in Nat
  /\ ai.first \in Int /\ ai.scheduled \in Int /\ ai.startTime \in Int
  /\ ai.heartbeatTime \in Int /\ ai.details \in {0,1} /\ ai.cancel \in BOOLEAN
  /\ ai.mask \subseteq Kinds
EventType(e) == e.a \in Activities /\ e.kind \in TermKinds \cup {"Scheduled","Started","CancelRequested"}
               /\ e.attempt \in Nat
WFType(w) ==
  /\ DOMAIN w.ai = Activities /\ \A a \in Activities: AIType(w.ai[a])
  /\ w.open \in BOOLEAN /\ w.scheduled \subseteq Activities
  /\ w.wft \in {"None","Pending","Started"}
  /\ \A e \in ToSet(w.history \o w.buffer): EventType(e)
  /\ w.seen \subseteq TermSet(w) /\ w.consumed \subseteq TermSet(w)
TypeOK ==
  /\ s.now \in Nat /\ WFType(s.db) /\ WFType(s.cache)
  /\ s.valid \in BOOLEAN /\ s.needFence \in BOOLEAN /\ s.traceComplete \in BOOLEAN
  /\ s.dbVersion \in Nat /\ s.range \in Nat /\ s.owner \in Nat
  /\ s.phase \in {"Idle","Mutated","Closed","Prepared","Waiting","Result","RejectedClose","CloseReloaded"}
  /\ DOMAIN s.watermark = Activities /\ \A a \in Activities: s.watermark[a] \in Int
  /\ \A t \in s.tasks: t.id \in Nat /\ t.kind \in Kinds \cup {"Transfer","Retry","WFT"}
      /\ t.a \in Activities \cup {0} /\ t.attempt \in Nat /\ t.due \in Nat
  /\ \A t \in s.tokens: t.a \in Activities /\ t.attempt > 0 /\ t.worker \in Workers
SingleTerminalOutcome == \A a \in Activities:
  Len(SelectSeq(TermSeq(s.db), LAMBDA e: e.a = a)) <= 1
StaleTokenDoesNotMutateCurrentAttempt == s.lastCheck.stale =>
  (s.lastCheck.beforeAI = s.lastCheck.afterAI /\ s.lastCheck.beforeTerms = s.lastCheck.afterTerms)
AcknowledgedOutcomeSurvivesFencedReload ==
  s.acknowledged \cup s.committedOutcomes \subseteq TermSet(s.db)
TerminalResultHasWorkflowResponsibility ==
  /\ s.committedOutcomes \subseteq TermSet(s.db)
  /\ s.db.open => (TermSet(s.db) \ s.db.consumed # {} => s.db.wft \in {"Pending","Started"})
\* A shared earlier cue covers all later deadlines by rescanning and regeneration.
\* Ackable (finished) cues are excluded: they no longer promise future execution.
LiveCue(t) == t \in s.tasks /\ t.id \notin s.ackable /\ t.kind \in Kinds
DeadlineCovered(d) ==
  (WorkflowExpiration > 0 /\ WorkflowExpiration <= d.due) \/
  \E t \in s.tasks: LiveCue(t) /\ t.logical <= d.due
DispatchCovered(a) == LET ai == s.db.ai[a] IN
  \/ \E t \in s.tasks: t.id \notin s.ackable /\ t.a = a /\ t.stamp = ai.stamp /\
         (t.kind = "Transfer" \/ (t.kind = "Retry" /\ t.attempt >= ai.attempt))
  \/ \E d \in s.copies \cup s.matching: d.a = a /\ d.stamp = ai.stamp
  \/ \E r \in s.startMsgs \cup s.polls: r.a = a /\ r.stamp = ai.stamp
TimerAndRetryWorkCovered == s.db.open =>
  /\ \A d \in Deadlines(s.db): DeadlineCovered(d)
  /\ \A a \in Activities: (s.db.ai[a].present /\ s.db.ai[a].started = "No") =>
       (DispatchCovered(a) \/ \E d \in Deadlines(s.db):
          d.a = a /\ d.due <= s.now /\ DeadlineCovered(d))
FencedReadbackAgrees == (s.readback.version = s.dbVersion /\ s.readback.range = s.range) =>
                       s.readback.outcomes = TermSet(s.db)
CacheMatchesDurableWhenIdle == Ready => s.cache = s.db
TerminalActivityInfoDeleted == \A e \in TermSet(s.db): ~s.db.ai[e.a].present
TaskIDsUnique == Cardinality({t.id: t \in s.tasks}) = Cardinality(s.tasks)

ReactiveNext ==
  \/ \E r \in s.issuedRequests: RetryActivityRequest(r)
  \/ AddActivityTaskScheduledEvent
  \/ \E t \in s.tasks: ProcessActivityTask(t) \/ ExecuteActivityRetryTimerTask(t)
       \/ DiscardObsoleteActivityTask(t) \/ ExecuteActivityTimeoutTask(t)
       \/ DiscardClosedWorkflowTimer(t)
  \/ \E ts \in RetirementBatches: RangeCompleteHistoryTasks(ts)
  \/ \E d \in s.copies: AddActivityTask(d)
  \/ \E d \in s.matching: DropExpiredMatchingTask(d)
  \/ \E id \in s.dispatchReturns: DeliverAddActivityTaskResponse(id)
  \/ \E d \in s.matching,w \in Workers: PollActivityTaskQueue(d,w)
  \/ \E r \in s.startMsgs: RecordActivityTaskStarted(r) \/ RecordActivityTaskStartedDuplicate(r)
       \/ RecordActivityTaskStartedRejected(r)
  \/ \E r \in s.requests: RespondActivityTaskCompleted(r) \/ RespondActivityTaskFailed(r)
       \/ RespondActivityTaskCanceled(r) \/ RecordActivityTaskHeartbeat(r) \/ RejectActivityRequest(r)
  \/ RecordWorkflowTaskStarted \/ RespondWorkflowTaskCompleted \/ ExecuteWorkflowRunTimeoutTask
  \/ CloseTransactionAsMutation \/ SetAndTrackTaskKeys \/ SubmitWorkflowMutation \/ AppendHistoryNodes
  \/ \E w \in s.writes: ApplyWorkflowMutationTx(w) \/ RejectWorkflowMutationTx(w)
  \/ ReturnPersistenceResult \/ FinishUpdateWorkflowExecution \/ ReacquireShard \/ ShardReady \/ LoadMutableState
  \/ ReloadAfterRejectedWorkflowClose \/ FailWorkflowTaskAfterRejectedClose
  \/ ReadWorkflowExecution \/ FinishTrace
  \/ \E id \in s.notifyPending: NotifyOnExecutionMutation(id)
  \/ \E r \in s.replies: ReceiveRecordActivityTaskStartedResponse(r) \/ DeliverActivityResponse(r)
  \/ \E r \in s.pollReplies: DeliverPollActivityTaskQueueResponse(r)
  \/ \E r \in s.polls: ExpireRecordActivityTaskStarted(r) \/ RetryMatchingActivityTask(r)
EnvironmentNext ==
  \/ (\E to \in TimeSuccessors: AdvanceTime(to))
  \/ ClearWorkflowCache \/ LoseShardContext
  \/ PersistenceTimeoutBeforeWrite \/ PersistenceResponseTimeout \/ RetryPersistenceAfterUnavailable
  \/ \E w \in s.writes: RejectPersistenceWrite(w)
  \/ \E r \in s.replies \cup s.pollReplies: LoseAPIResponse(r)
  \/ \E t \in s.tasks: RedeliverTask(t)
  \/ \E id \in s.dispatchReturns: LoseAddActivityTaskResponse(id)
  \/ \E r \in s.startCalls: RetryRecordActivityTaskStarted(r)
  \/ \E t \in s.tokens,k \in {"Completed","Failed","NonRetryable","Heartbeat","Canceled"},d \in {-1,0,1}:
       SendActivityRequest(t,k,d)
  \/ \E a \in Activities: HandleCommandRequestCancelActivity(a) \/ HandleCommandCancelBufferedActivity(a)
       \/ HandleCommandCancelAndCompleteWorkflow(a)
  \/ HandleCommandCompleteWorkflow \/ HandleCommandCompleteWorkflowRejected
Next == ReactiveNext \/ EnvironmentNext
Spec == Init /\ [][Next]_vars
=============================================================================
