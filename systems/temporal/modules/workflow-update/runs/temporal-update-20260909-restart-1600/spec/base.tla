------------------------------- MODULE base -------------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC

(* Temporal Update, Category A; source 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
   All source paths are relative to source-update/. See generation-notes.md.
   s is one record for explicit whole-state updates, NOT one atomic operation.
   pc serializes the Workflow lease; worker, persistence, timers and waiters
   continue independently. Each action is one observable semantic boundary.
   S1: db/history/cache/write/calls/observed; S2: task/timers/worker/ctx;
   S3: objects/effects/cancels/active/closed; S4: matching/callbacks/retry.
*)
CONSTANTS Updates, Values, Clients, Hosts, InitialHost,
          NamespaceID, WorkflowID, RunID, EventVersion, HostCacheEnabled
ASSUME /\ IsFiniteSet(Updates) /\ Updates # {} /\ IsFiniteSet(Values)
       /\ Values # {} /\ IsFiniteSet(Clients) /\ Clients # {}
       /\ IsFiniteSet(Hosts) /\ InitialHost \in Hosts
       /\ EventVersion \in Nat /\ HostCacheEnabled \in BOOLEAN
VARIABLE s
vars == <<s>>

None == "none"
Result(k, v) == [kind |-> k, value |-> v]
Pending == Result("pending", None)
RetryError == Result("retry", None)
CloseError == Result("closedError", None)
CloseFailure == Result("closing", None)
RejectFailure == Result("rejection", None)
WorkerKinds == {"success", "handlerFailure"}
TerminalKinds == WorkerKinds \cup {"closing", "rejection", "closedError", "taskError"}
Reply(stage, r) == [stage |-> stage, result |-> r]
NoReply == Reply("NONE", Pending)
NoInfo == [stage |-> "none", acceptedID |-> 0, eventID |-> 0,
           batchID |-> 0, result |-> Pending]
NoTask == [kind |-> "none", scheduled |-> 0, started |-> 0,
           startedTime |-> 0, attempt |-> 0, version |-> EventVersion,
           stamp |-> 0, transient |-> FALSE, route |-> "normal"]
Task(kind, sid, attempt, route) ==
    [NoTask EXCEPT !.kind = kind, !.scheduled = sid, !.attempt = attempt,
                  !.transient = (kind = "Normal" /\ attempt > 1), !.route = route]
NewObject(u, gen) == [uid |-> u, generation |-> gen, state |-> "Admitted",
                     accepted |-> "pending", outcome |-> Pending,
                     acceptedID |-> 0, callbacks |-> FALSE]
NewCall == [uid |-> None, op |-> "update", waitStage |-> "COMPLETED",
            status |-> "idle", oid |-> 0, expired |-> FALSE,
            reply |-> NoReply, active |-> FALSE]
NoEffect == [oid |-> 0, kind |-> "none", prev |-> "none", result |-> Pending]
Effect(o, k, prev, r) == [oid |-> o, kind |-> k, prev |-> prev, result |-> r]
NoWrite == [state |-> "none", returned |-> TRUE, error |-> "none",
            range |-> 0, rv |-> 0, next |-> 0, info |-> [u \in Updates |-> NoInfo],
            closed |-> FALSE, sticky |-> FALSE, task |-> NoTask,
            transfer |-> FALSE, events |-> <<>>]
SeqSet(q) == {q[i] : i \in 1..Len(q)}
RemoveAt(q, i) == SubSeq(q, 1, i-1) \o SubSeq(q, i+1, Len(q))
Filter(q, P(_)) == SelectSeq(q, P)
Key(eid) == [namespace |-> NamespaceID, workflow |-> WorkflowID,
            run |-> RunID, eventID |-> eid, version |-> EventVersion]
Event(eid, typ, u, r, batch) ==
    [key |-> Key(eid), type |-> typ, uid |-> u, result |-> r, batchID |-> batch]
Generic(eid, typ) == Event(eid, typ, None, Pending, eid)
Put(cache, e) == Filter(cache, LAMBDA x: x.key # e.key) \o <<e>>
CacheGet(cache, key) == CHOOSE e \in SeqSet(cache): e.key = key
HasKey(cache, key) == \E e \in SeqSet(cache): e.key = key
LiveObjects == {s.ctx.reg[u] : u \in Updates} \ {0}
CanLock == s.pc = "idle" /\ s.ctx.loaded /\ ~s.acquiring
WriteSettled == s.write.state \in {"none", "committed", "noncommit"} /\ s.write.returned
NeedSend == {u \in Updates: s.ctx.reg[u] # 0 /\
    s.objects[s.ctx.reg[u]].state \in {"Admitted", "Sent"}}
AcceptedObjects == {o \in LiveObjects: s.objects[o].state \in {"Accepted", "PA"}}
Timer(t, kind, speculative) ==
    [task |-> t, timeout |-> kind, speculative |-> speculative,
     eligible |-> FALSE, submitted |-> FALSE, cancelled |-> FALSE, consumed |-> FALSE]
CancelPointer(timers, p) == IF p = 0 THEN timers ELSE
    [timers EXCEPT ![p].cancelled = TRUE]

(* service/history/api/respondworkflowtaskcompleted/api.go:203-209:
   started ID/time/version are optional-token guards; generated tokens supply
   them, but these predicates retain the actual optional-field conditions.
   Stamp is checked on start/timer paths, not invented on completion. *)
CompletionMatches(token, current) ==
    /\ current.kind # "none" /\ token.scheduled = current.scheduled
    /\ current.started # 0
    /\ (token.started = 0 \/ token.started = current.started)
    /\ (token.startedTime = 0 \/ current.startedTime = 0 \/ token.startedTime = current.startedTime)
    /\ token.attempt = current.attempt
    /\ (token.version = 0 \/ token.version = current.version)
(* timer_queue_active_task_executor.go:403-458; no unconditional pointer guard. *)
TimerMatches(i) ==
    LET t == s.timers[i] IN
    /\ ~s.ctx.closed /\ s.ctx.task.kind # "none"
    /\ t.task.scheduled = s.ctx.task.scheduled
    /\ t.task.stamp = s.ctx.task.stamp
    /\ IF s.ctx.task.kind = "Speculative" THEN s.timerPointer = i
       ELSE /\ t.task.version = s.ctx.task.version
            /\ t.task.attempt = s.ctx.task.attempt
    /\ (t.timeout = "STC" \/ s.ctx.task.started = 0)

(* HistoryBuilder flush at WFTStarted: workflow_task_state_machine.go:606,
   808; UpdateCompletionInfo stores the following WFTCompleted batch start. *)
CurrentBatchID ==
    LET starts == SelectSeq(s.batch,LAMBDA e: e.type = "WFTCompleted") IN
    IF starts # <<>> THEN Head(starts).key.eventID
    ELSE IF s.batch = <<>> THEN s.ctx.next ELSE Head(s.batch).key.eventID

(* ContextImpl.LoadMutableState + NewRegistry: context.go:403-459;
   update/registry.go:189-221. Initial history prefix is a running Workflow
   after its first completed WFT (event 4), no Updates and no pending WFT. *)
Init ==
    s = [db |-> [next |-> 5, rv |-> 1, range |-> 1, closed |-> FALSE,
                 sticky |-> TRUE, task |-> NoTask, transfer |-> FALSE,
                 info |-> [u \in Updates |-> NoInfo], events |-> <<>>],
         ctx |-> [loaded |-> TRUE, host |-> InitialHost, generation |-> 1,
                  range |-> 1, rv |-> 1, next |-> 5, closed |-> FALSE,
                  sticky |-> TRUE, task |-> NoTask, transfer |-> FALSE,
                  info |-> [u \in Updates |-> NoInfo], reg |-> [u \in Updates |-> 0]],
         objects |-> <<>>, timers |-> <<>>, timerPointer |-> 0,
         matching |-> <<>>, workers |-> <<>>, dispatch |-> <<>>,
         cache |-> [h \in Hosts |-> <<>>], physicalHistory |-> <<>>,
         write |-> NoWrite, pc |-> "idle", returnPC |-> "idle",
         batch |-> <<>>, effects |-> <<>>, cancels |-> <<>>,
         active |-> NoEffect, second |-> "none", clearTodo |-> {},
         clearReturn |-> "idle", handler |-> "none", caller |-> None,
         selected |-> 0, inlineWorker |-> 0, commands |-> <<>>, closeCommand |-> FALSE,
         rejectTodo |-> {}, successor |-> FALSE, skip |-> FALSE,
         acquiring |-> FALSE, clock |-> 0, limitRaised |-> FALSE,
         calls |-> [c \in Clients |-> NewCall], observed |-> {},
         applied |-> {}, timeoutApplications |-> {}, everRequested |-> {}]

(* ENV: public client invocation, workflow_handler.go:5476-5626; S1/S4.
   Retries below reuse a call slot. Only new external invocations are bounded. *)
\* ACTION SOURCE: service/frontend/workflow_handler.go:5476-5626
UpdateWorkflowExecution(c, u, stage) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/frontend/workflow_handler.go:5476-5626
    /\ c \in Clients /\ u \in Updates /\ stage \in {"ACCEPTED","COMPLETED"}
    \* BLOCK SOURCE: service/frontend/workflow_handler.go:5476-5626
    /\ s.calls[c].status \in {"idle", "done"}
    \* BLOCK SOURCE: service/frontend/workflow_handler.go:5476-5626
    /\ s' = [s EXCEPT !.calls[c] = [NewCall EXCEPT !.uid = u,
         !.waitStage = stage, !.status = "request", !.active = TRUE],
         !.everRequested = @ \cup {u}]

(* Updater.ApplyRequest:118-187, update.Admit:320-368; Immediate effects.
   Admission and its no-future callback are lease-atomic; ordinary admission
   is volatile. No callback payload transport / CHASM state is modeled. *)
\* ACTION SOURCE: service/history/api/updateworkflow/api.go:157-187; service/history/workflow/update/update.go:320-368
UpdaterApplyRequestNew(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:157-187; service/history/workflow/update/update.go:320-368
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:157-187; service/history/workflow/update/update.go:320-368
    /\ CanLock /\ s.calls[c].status = "request" /\ s.calls[c].op = "update"
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:157-187; service/history/workflow/update/update.go:320-368
    /\ LET u == s.calls[c].uid IN
       /\ ~s.ctx.closed /\ s.ctx.reg[u] = 0 /\ s.ctx.info[u].stage = "none"
       /\ s' = [s EXCEPT !.objects = Append(@, NewObject(u, s.ctx.generation)),
            !.ctx.reg[u] = Len(s.objects)+1, !.calls[c].oid = Len(s.objects)+1,
            !.calls[c].status = "binding", !.pc = "admitSchedule", !.caller = c]

(* Updater.ApplyRequest:179-223; workflow_task_state_machine.go:312-395.
   Install schedule-to-start timer BEFORE releasing lease/direct Matching RPC. *)
\* ACTION SOURCE: service/history/api/updateworkflow/api.go:179-223; service/history/workflow/workflow_task_state_machine.go:312-395
AddWorkflowTaskScheduledEvent ==
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:179-223; service/history/workflow/workflow_task_state_machine.go:312-395
    /\ s.pc = "admitSchedule"
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:179-223; service/history/workflow/workflow_task_state_machine.go:312-395
    /\ LET t == Task("Speculative", s.ctx.next, 1,
                     IF s.ctx.sticky THEN "sticky" ELSE "normal") IN
       /\ s' = [s EXCEPT
            !.ctx.task = IF @.kind = "none" THEN t ELSE @,
            !.timers = IF s.ctx.task.kind = "none" THEN Append(@, Timer(t, "STS", TRUE)) ELSE @,
            !.timerPointer = IF s.ctx.task.kind = "none" THEN Len(s.timers)+1 ELSE @,
            !.dispatch = IF s.ctx.task.kind = "none" THEN Append(@, t) ELSE @,
            !.calls[s.caller].status = "wait", !.pc = "idle", !.caller = None]

(* Registry.Find:455-458 / Updater.ApplyRequest:168-187: duplicates bind to
   the SAME object and do not schedule work; do not repair a missing task here. *)
\* ACTION SOURCE: service/history/workflow/update/registry.go:455-458; service/history/api/updateworkflow/api.go:179-186
UpdaterApplyRequestExisting(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:455-458; service/history/api/updateworkflow/api.go:179-186
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:455-458; service/history/api/updateworkflow/api.go:179-186
    /\ CanLock /\ s.calls[c].status = "request"
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:455-458; service/history/api/updateworkflow/api.go:179-186
    /\ LET u == s.calls[c].uid IN
       /\ s.ctx.reg[u] # 0
       /\ s' = [s EXCEPT !.calls[c].oid = s.ctx.reg[u], !.calls[c].status = "wait"]

(* S4/CR-2: update.AttachCallbacks:411-444; Updater.ApplyRequest:168-176.
   A duplicate with buffered callbacks requests persistence despite no event.
   This real mutation also supplies the speculative->normal conversion path. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:411-432; service/history/api/updateworkflow/api.go:168-176
AttachCallbacks(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:411-432; service/history/api/updateworkflow/api.go:168-176
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/update/update.go:411-432; service/history/api/updateworkflow/api.go:168-176
    /\ CanLock /\ s.calls[c].status = "request" /\ s.calls[c].op = "update"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:411-432; service/history/api/updateworkflow/api.go:168-176
    /\ LET u == s.calls[c].uid IN
       /\ s.ctx.reg[u] # 0 /\ s.objects[s.ctx.reg[u]].state = "Sent"
       /\ ~s.objects[s.ctx.reg[u]].callbacks /\ WriteSettled
       /\ s' = [s EXCEPT !.objects[s.ctx.reg[u]].callbacks = TRUE,
            !.calls[c].oid = s.ctx.reg[u], !.calls[c].status = "wait",
            !.pc = "convert", !.handler = "options", !.batch = <<>>, !.returnPC = "idle"]

(* Registry.Find:463-479; mutable_state_impl.go:1555-1588; events/cache.go:110-143.
   Completion metadata chooses key; cache lookup checks EVENT TYPE, not UID.
   This deliberately preserves the MC-4 candidate; the property is elsewhere. *)
\* ACTION SOURCE: service/history/workflow/mutable_state_impl.go:1544-1588; service/history/events/cache.go:110-143; service/history/workflow/update/registry.go:455-479
GetUpdateOutcome(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/mutable_state_impl.go:1544-1588; service/history/events/cache.go:110-143; service/history/workflow/update/registry.go:455-479
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/mutable_state_impl.go:1544-1588; service/history/events/cache.go:110-143; service/history/workflow/update/registry.go:455-479
    /\ CanLock /\ s.calls[c].status = "request"
    \* BLOCK SOURCE: service/history/workflow/mutable_state_impl.go:1544-1588; service/history/events/cache.go:110-143; service/history/workflow/update/registry.go:455-479
    /\ LET u == s.calls[c].uid
           info == s.ctx.info[u]
           key == Key(info.eventID)
           hit == HasKey(s.cache[s.ctx.host], key)
           ev == IF hit THEN CacheGet(s.cache[s.ctx.host], key)
                 ELSE CacheGet(s.db.events, key)
       IN
       /\ s.ctx.reg[u] = 0 /\ info.stage = "Completed"
       /\ s' = [s EXCEPT !.cache[s.ctx.host] = IF hit THEN @ ELSE Put(@, ev),
            !.calls[c].reply = IF ev.type = "UpdateCompleted"
                 THEN Reply("COMPLETED", ev.result) ELSE Reply("ERROR", Result("lookupError", None)),
            !.calls[c].status = "reply"]

(* pollupdate/api.go:45-54 and Updater.ApplyRequest:118-124. *)
\* ACTION SOURCE: service/history/api/pollupdate/api.go:45-54; service/history/api/updateworkflow/api.go:118-124
RegistryFindMissing(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/pollupdate/api.go:45-54; service/history/api/updateworkflow/api.go:118-124
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/api/pollupdate/api.go:45-54; service/history/api/updateworkflow/api.go:118-124
    /\ CanLock /\ s.calls[c].status = "request"
    \* BLOCK SOURCE: service/history/api/pollupdate/api.go:45-54; service/history/api/updateworkflow/api.go:118-124
    /\ LET u == s.calls[c].uid IN
       /\ s.ctx.reg[u] = 0 /\ s.ctx.info[u].stage = "none"
       /\ (s.ctx.closed \/ s.calls[c].op = "poll")
       /\ s' = [s EXCEPT !.calls[c].reply = Reply("ERROR",
              IF s.ctx.closed THEN CloseError ELSE Result("notFound", None)),
              !.calls[c].status = "reply"]

(* ENV normal WFT source (already eligible internal task), S1 normal control;
   workflow_task_state_machine.go:312-395. Pending execution/task mutation
   still uses the same append/conditional-commit pipeline. *)
\* ACTION SOURCE: service/history/workflow/util.go:60-75; service/history/workflow/workflow_task_state_machine.go:312-395
ScheduleNormalWorkflowTask ==
    \* BLOCK SOURCE: service/history/workflow/util.go:60-75; service/history/workflow/workflow_task_state_machine.go:312-395
    /\ CanLock /\ WriteSettled /\ ~s.ctx.closed /\ s.ctx.task.kind = "none"
    \* BLOCK SOURCE: service/history/workflow/util.go:60-75; service/history/workflow/workflow_task_state_machine.go:312-395
    /\ LET t == Task("Normal", s.ctx.next, 1, IF s.ctx.sticky THEN "sticky" ELSE "normal") IN
       /\ s' = [s EXCEPT !.ctx.task = t, !.ctx.next = @+1, !.ctx.transfer = TRUE,
            !.batch = <<Generic(s.ctx.next, "WFTScheduled")>>,
            !.handler = "schedule", !.returnPC = "idle", !.pc = "persist"]

(* Updater.OnSuccess:227-261 / addWorkflowTaskToMatching:317-341.
   Unlocked RPC acceptance is separate from History RecordWFTStarted. *)
\* ACTION SOURCE: service/history/api/updateworkflow/api.go:317-341
AddWorkflowTaskToMatching(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:317-341
    /\ i \in 1..Len(s.dispatch)
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:317-341
    /\ i \in 1..Len(s.dispatch)
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:317-341
    /\ s' = [s EXCEPT !.matching = Append(@, s.dispatch[i]), !.dispatch = RemoveAt(@, i)]
(* Same RPC, injected Unavailable or execution+lost response; timer survives. *)
\* ACTION SOURCE: service/history/api/updateworkflow/api.go:235-261,317-341
AddWorkflowTaskToMatchingFailed(i, delivered) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:235-261,317-341
    /\ i \in 1..Len(s.dispatch) /\ delivered \in BOOLEAN
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:235-261,317-341
    /\ i \in 1..Len(s.dispatch)
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:235-261,317-341
    /\ s' = [s EXCEPT !.matching = IF delivered THEN Append(@, s.dispatch[i]) ELSE @,
         !.dispatch = RemoveAt(@, i)]
(* Updater.OnSuccess:237-244; sticky unavailable retries the normal queue. *)
\* ACTION SOURCE: service/history/api/updateworkflow/api.go:237-244
StickyWorkerUnavailable(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:237-244
    /\ i \in 1..Len(s.dispatch)
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:237-244
    /\ i \in 1..Len(s.dispatch) /\ s.dispatch[i].route = "sticky"
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:237-244
    /\ s' = [s EXCEPT !.dispatch[i].route = "normal"]
(* transfer_queue_active_task_executor.go, processWorkflowTask/pushWorkflowTask;
   persistent transfer eligibility is committed atomically with execution. *)
\* ACTION SOURCE: service/history/transfer_queue_active_task_executor.go:289-345
PushWorkflowTask ==
    \* BLOCK SOURCE: service/history/transfer_queue_active_task_executor.go:289-345
    /\ s.db.transfer /\ s.db.task.kind # "none"
    \* BLOCK SOURCE: service/history/transfer_queue_active_task_executor.go:289-345
    /\ s' = [s EXCEPT !.matching = Append(@, s.db.task), !.db.transfer = FALSE]

(* RecordWorkflowTaskStarted / workflow_task_state_machine.go:453-636.
   Fixed single-cluster version/stamp; start time is fresh across cache loss.
   Normal/transient start writes metadata/tasks; speculative start can skip. *)
\* ACTION SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:453-636
RecordWorkflowTaskStarted(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:453-636
    /\ i \in 1..Len(s.matching)
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:453-636
    /\ CanLock /\ WriteSettled /\ i \in 1..Len(s.matching)
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:453-636
    /\ ~s.ctx.closed /\ s.ctx.task.kind # "none" /\ s.ctx.task.started = 0
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:453-636
    /\ s.matching[i].scheduled = s.ctx.task.scheduled
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:453-636
    /\ s.matching[i].stamp = s.ctx.task.stamp
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:453-636
    /\ LET t == [s.ctx.task EXCEPT !.started = s.ctx.task.scheduled+1, !.startedTime = s.clock+1]
           spec == t.kind = "Speculative"
           real == ~spec /\ ~t.transient
       IN
       /\ s' = [s EXCEPT !.matching = RemoveAt(@, i), !.clock = @+1,
            !.ctx.task = t, !.ctx.next = IF real THEN @+1 ELSE @,
            !.ctx.transfer = FALSE,
            !.timers = Append(CancelPointer(@, s.timerPointer), Timer(t, "STC", spec)),
            !.timerPointer = IF spec THEN Len(s.timers)+1 ELSE 0,
            !.batch = IF real THEN <<Generic(s.ctx.next, "WFTStarted")>> ELSE <<>>,
            !.pc = "startResponse",
            !.returnPC = "idle", !.handler = "start"]

(* RecordWFTStarted response uses Registry.Send(true), registry.go:327-357;
   update.Send:549-589. Response construction precedes normal start commit.
   Worker visibility follows the later successful API return, outside the lease. *)
\* ACTION SOURCE: service/history/api/recordworkflowtaskstarted/api.go:375-406; service/history/workflow/update/registry.go:327-357
CreateRecordWorkflowTaskStartedResponse ==
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:375-406; service/history/workflow/update/registry.go:327-357
    /\ s.pc \in {"startResponse","successorResponse"}
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:375-406; service/history/workflow/update/registry.go:327-357
    /\ LET delivered == NeedSend
           known == {u \in Updates: s.ctx.info[u].stage = "Accepted"}
           w == [task |-> s.ctx.task, delivered |-> delivered, accepted |-> known,
                 plan |-> <<>>, closed |-> FALSE, status |-> IF s.pc = "successorResponse" THEN "pendingResponse"
                     ELSE IF s.ctx.task.kind = "Speculative" THEN "startResponse" ELSE "pendingStart"]
       IN
       /\ s' = [s EXCEPT !.objects = [o \in 1..Len(s.objects) |->
            IF o \in LiveObjects /\ s.objects[o].state = "Admitted"
            THEN [s.objects[o] EXCEPT !.state = "Sent"] ELSE s.objects[o]],
            !.workers = Append(@, w),
            !.inlineWorker = IF s.pc = "successorResponse" THEN Len(s.workers)+1 ELSE 0,
            !.pc = IF s.pc = "successorResponse" THEN "handlerReply"
                   ELSE IF s.ctx.task.kind = "Speculative" THEN "idle" ELSE "persist"]
(* recordworkflowtaskstarted.Invoke:258-287: the lease has been released;
   setHistoryForRecordWfTaskStartedResp completes before the successful return. *)
\* ACTION SOURCE: service/history/api/recordworkflowtaskstarted/api.go:258-287
RecordWorkflowTaskStartedReturn(i) ==
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:258-287
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:258-287
    /\ s.workers[i].status = "startResponse"
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:258-287
    /\ s' = [s EXCEPT !.workers[i].status = "working"]

(* Actual start validation rejects stale Matching work; no mutable-state write. *)
\* ACTION SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:465-473
RecordWorkflowTaskStartedNotFound(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:465-473
    /\ i \in 1..Len(s.matching)
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:465-473
    /\ CanLock /\ i \in 1..Len(s.matching)
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:465-473
    /\ (s.ctx.closed \/ s.ctx.task.kind = "none" \/ s.ctx.task.started # 0 \/
        s.matching[i].scheduled # s.ctx.task.scheduled \/ s.matching[i].stamp # s.ctx.task.stamp)
    \* BLOCK SOURCE: service/history/api/recordworkflowtaskstarted/api.go:35-268; service/history/workflow/workflow_task_state_machine.go:465-473
    /\ s' = [s EXCEPT !.matching = RemoveAt(@, i)]

(* ENV worker protocol, update.go:603-647,711-726,775-785;
   protocol commands can interleave across Updates but acceptance precedes
   response for each Update. Full worker message sequence freezes before RPC. *)
Planned(w, u, kinds) == \E m \in SeqSet(w.plan): m.uid = u /\ m.kind \in kinds
\* ACTION SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
WorkerAcceptance(i, u) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ u \in Updates
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "working"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ u \in s.workers[i].delivered
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ ~Planned(s.workers[i], u, {"accept", "reject"})
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ s' = [s EXCEPT !.workers[i].plan = Append(@, [uid |-> u, kind |-> "accept", result |-> Pending])]
\* ACTION SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
WorkerResponse(i, u, k, v) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ u \in Updates /\ k \in WorkerKinds /\ v \in Values
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "working"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ (u \in s.workers[i].accepted \/ Planned(s.workers[i], u, {"accept"}))
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ ~Planned(s.workers[i], u, {"complete"})
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ s' = [s EXCEPT !.workers[i].plan = Append(@, [uid |-> u, kind |-> "complete", result |-> Result(k,v)])]
\* ACTION SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
WorkerRejection(i, u) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ u \in Updates
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "working"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ u \in s.workers[i].delivered /\ ~Planned(s.workers[i], u, {"accept", "reject"})
    \* BLOCK SOURCE: service/history/workflow/update/update.go:603-647,711-731,775-788; tests/update_workflow_test.go
    /\ s' = [s EXCEPT !.workers[i].plan = Append(@, [uid |-> u, kind |-> "reject", result |-> RejectFailure])]
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
WorkerSendCompletion(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "working"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ \A u \in s.workers[i].delivered: Planned(s.workers[i], u, {"accept", "reject"})
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ s' = [s EXCEPT !.workers[i].status = "ready"]
(* S4: unsupported/ignoring worker is an environment fault, not a new guard. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
WorkerIgnoreUpdates(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "working"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ s' = [s EXCEPT !.workers[i].status = "ready"]
(* S3: final Workflow close is last in this valid command slice. No subsequent
   Update event can pass EventStore.CanAddEvent; handler.go:200-210. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
WorkerCloseWorkflow(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "working"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-210; tests/update_workflow_test.go
    /\ s' = [s EXCEPT !.workers[i].closed = TRUE, !.workers[i].status = "ready"]

(* respondworkflowtaskcompleted/api.go:133-213. Selection holds the lease;
   record the actual compared tuple for commands subsequently applied. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213
RespondWorkflowTaskCompleted(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213
    /\ CanLock /\ WriteSettled /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "ready"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213
    /\ ~s.ctx.closed /\ ~s.limitRaised /\ CompletionMatches(s.workers[i].task, s.ctx.task)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213
    /\ s' = [s EXCEPT !.pc = "completeEvent", !.handler = "completion", !.selected = i,
         !.commands = s.workers[i].plan, !.closeCommand = s.workers[i].closed,
         !.applied = @ \cup {[token |-> s.workers[i].task, current |-> s.ctx.task]},
         !.workers[i].status = "received", !.batch = <<>>, !.effects = <<>>, !.cancels = <<>>]
(* api.go:174-211: identity rejection still executes deferred sticky cleanup. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:174-212
RespondWorkflowTaskCompletedNotFound(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:174-212
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:174-212
    /\ CanLock /\ WriteSettled /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "ready"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:174-212
    /\ (s.ctx.closed \/ ~CompletionMatches(s.workers[i].task, s.ctx.task))
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:174-212
    /\ s' = [s EXCEPT !.workers[i].status = "notFound", !.selected = i,
         !.pc = IF s.ctx.task.scheduled = s.workers[i].task.scheduled /\
                    s.ctx.task.kind = "Speculative" /\ s.ctx.sticky THEN "stickyClear" ELSE "idle"]

(* workflow_task_state_machine.go:687-808, api.go:676-681.
   This slice has no intervening signals/history shipping; rejection-only
   discard is legal. Commands/acceptance/completion/closure force persistence.
   Normal and transient WFT events materialize according to their real branch. *)
\* ACTION SOURCE: service/history/workflow/workflow_task_state_machine.go:687-852
AddWorkflowTaskCompletedEvent ==
    \* BLOCK SOURCE: service/history/workflow/workflow_task_state_machine.go:687-852
    /\ s.pc = "completeEvent"
    \* BLOCK SOURCE: service/history/workflow/workflow_task_state_machine.go:687-852
    /\ LET t == s.ctx.task
           discard == t.kind = "Speculative" /\ ~s.closeCommand /\
                      \A m \in SeqSet(s.commands): m.kind = "reject"
           materialize == t.kind = "Speculative" \/ t.transient
           prefix == IF materialize THEN <<Generic(s.ctx.next, "WFTScheduled"),
                                          Generic(s.ctx.next+1, "WFTStarted")>> ELSE <<>>
           events == IF discard THEN <<>> ELSE prefix \o <<Generic(s.ctx.next+Len(prefix), "WFTCompleted")>>
       IN
       /\ s' = [s EXCEPT !.ctx.task = NoTask, !.ctx.next = @+Len(events), !.ctx.transfer = FALSE,
            !.timers = CancelPointer(@, s.timerPointer), !.timerPointer = 0,
            !.batch = events, !.skip = discard, !.pc = "commands"]

(* update/registry.go:238-280: valid acceptance/rejection with original request
   resurrects the ID after registry loss. Completion alone cannot resurrect. *)
\* ACTION SOURCE: service/history/workflow/update/registry.go:238-280
TryResurrect ==
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:238-280
    /\ s.pc = "commands" /\ Len(s.commands) > 0
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:238-280
    /\ LET m == Head(s.commands) IN
       /\ m.kind \in {"accept", "reject"} /\ s.ctx.reg[m.uid] = 0
       /\ s.ctx.info[m.uid].stage = "none" /\ ~s.ctx.closed
       /\ s' = [s EXCEPT !.objects = Append(@, NewObject(m.uid,s.ctx.generation)),
            !.ctx.reg[m.uid] = Len(s.objects)+1]

(* update.onAcceptanceMsg:617-703 / mutable_state_impl.go acceptance event.
   Metadata mutation, provisional state and effect registration occur under
   one lease; futures remain untouched until ordered after-commit execution. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:617-703; service/history/workflow/mutable_state_impl.go:5794-5831
OnAcceptanceMsg ==
    \* BLOCK SOURCE: service/history/workflow/update/update.go:617-703; service/history/workflow/mutable_state_impl.go:5794-5831
    /\ s.pc = "commands" /\ Len(s.commands) > 0
    \* BLOCK SOURCE: service/history/workflow/update/update.go:617-703; service/history/workflow/mutable_state_impl.go:5794-5831
    /\ LET m == Head(s.commands) o == s.ctx.reg[m.uid] IN
       /\ m.kind = "accept" /\ o # 0 /\ ~s.ctx.closed
       /\ s.objects[o].state \in {"Admitted", "Sent"}
       /\ LET e == Effect(o,"accept",s.objects[o].state,Pending) IN
          /\ s' = [s EXCEPT !.objects[o].state = "PA", !.objects[o].acceptedID = s.ctx.next,
               !.objects[o].callbacks = FALSE,
               !.cache[s.ctx.host] = Put(@,Event(s.ctx.next,"UpdateAccepted",m.uid,Pending,CurrentBatchID)),
               !.ctx.info[m.uid] = [NoInfo EXCEPT !.stage = "Accepted", !.acceptedID = s.ctx.next],
               !.batch = @ \o <<Event(s.ctx.next,"UpdateAccepted",m.uid,Pending,CurrentBatchID)>> \o
                   (IF s.objects[o].callbacks THEN <<Generic(s.ctx.next+1,"OptionsUpdated")>> ELSE <<>>),
               !.ctx.next = @+1+(IF s.objects[o].callbacks THEN 1 ELSE 0), !.effects = Append(@,e), !.cancels = Append(@,e),
               !.commands = Tail(@)]

(* update.onResponseMsg:775-814; mutable_state_impl.go:5852-5900.
   Cache insertion occurs BEFORE History append and execution commit. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:775-814; service/history/workflow/mutable_state_impl.go:5852-5900
OnResponseMsg ==
    \* BLOCK SOURCE: service/history/workflow/update/update.go:775-814; service/history/workflow/mutable_state_impl.go:5852-5900
    /\ s.pc = "commands" /\ Len(s.commands) > 0
    \* BLOCK SOURCE: service/history/workflow/update/update.go:775-814; service/history/workflow/mutable_state_impl.go:5852-5900
    /\ LET m == Head(s.commands) o == s.ctx.reg[m.uid] IN
       /\ m.kind = "complete" /\ o # 0 /\ ~s.ctx.closed
       /\ s.objects[o].state \in {"PA", "Accepted"}
       /\ LET e == Effect(o,"complete",s.objects[o].state,m.result)
              ev == Event(s.ctx.next,"UpdateCompleted",m.uid,m.result,CurrentBatchID)
          IN
          /\ s' = [s EXCEPT !.objects[o].state = "PC",
               !.ctx.info[m.uid] = [@ EXCEPT !.stage = "Completed", !.eventID = s.ctx.next,
                                               !.batchID = CurrentBatchID, !.result = m.result],
               !.cache[s.ctx.host] = Put(@,ev), !.batch = Append(@,ev), !.ctx.next = @+1,
               !.effects = Append(@,e), !.cancels = Append(@,e), !.commands = Tail(@)]

(* update.onRejectionMsg:715-731 clears pending callbacks before reject;
   update.reject:747-767 adds no durable rejection event in this scope. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:715-767
OnRejectionMsg ==
    \* BLOCK SOURCE: service/history/workflow/update/update.go:715-767
    /\ s.pc = "commands" /\ Len(s.commands) > 0
    \* BLOCK SOURCE: service/history/workflow/update/update.go:715-767
    /\ LET m == Head(s.commands) o == s.ctx.reg[m.uid] IN
       /\ m.kind = "reject" /\ o # 0 /\ s.objects[o].state \in {"Admitted", "Sent"}
       /\ LET e == Effect(o,"reject",s.objects[o].state,RejectFailure) IN
          /\ s' = [s EXCEPT !.objects[o].state = "PC", !.objects[o].callbacks = FALSE,
               !.effects = Append(@,e), !.cancels = Append(@,e), !.commands = Tail(@)]

(* handler.go handleCommands:200-210; api.go:456-474.
   Invalid protocol states follow a handler error, never stall silently. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:617-621,716-720,779-783; service/history/api/respondworkflowtaskcompleted/api.go:445-454
HandleMessageInvalid ==
    \* BLOCK SOURCE: service/history/workflow/update/update.go:617-621,716-720,779-783; service/history/api/respondworkflowtaskcompleted/api.go:445-454
    /\ s.pc = "commands" /\ Len(s.commands) > 0
    \* BLOCK SOURCE: service/history/workflow/update/update.go:617-621,716-720,779-783; service/history/api/respondworkflowtaskcompleted/api.go:445-454
    /\ LET m == Head(s.commands) o == s.ctx.reg[m.uid] IN
       /\ IF o = 0 THEN (m.kind = "complete" \/ s.ctx.info[m.uid].stage # "none")
          ELSE CASE m.kind = "accept" -> s.objects[o].state \notin {"Admitted", "Sent"}
                 [] m.kind = "complete" -> s.objects[o].state \notin {"PA", "Accepted"}
                 [] OTHER -> s.objects[o].state \notin {"Admitted", "Sent"}
       /\ s' = [s EXCEPT !.pc = "errorClear", !.clearReturn = "cancel"]

(* Final close command / api.go:468-474; all modeled Update commands precede
   closure. AbortAccepted runs afterward and Go map order is nondeterministic. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-227; service/history/api/respondworkflowtaskcompleted/api.go:456-474
HandleCommandsDone ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-227; service/history/api/respondworkflowtaskcompleted/api.go:456-474
    /\ s.pc = "commands" /\ s.commands = <<>>
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:200-227; service/history/api/respondworkflowtaskcompleted/api.go:456-474
    /\ s' = [s EXCEPT !.ctx.closed = s.closeCommand,
         !.batch = IF s.closeCommand THEN Append(@,Generic(s.ctx.next,"WorkflowClosed")) ELSE @,
         !.ctx.next = IF s.closeCommand THEN @+1 ELSE @,
         !.rejectTodo = IF s.closeCommand THEN {} ELSE {o \in LiveObjects: s.objects[o].state = "Sent"},
         !.pc = "reject"]
(* Registry.RejectUnprocessed:297-315: abort enumeration at FIRST callback
   error. Do not assume remaining Updates were rejected. S4/CR-2. *)
\* ACTION SOURCE: service/history/workflow/update/registry.go:297-315; service/history/workflow/update/update.go:739-767
RejectUnprocessed(o) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:297-315; service/history/workflow/update/update.go:739-767
    /\ o \in 1..Len(s.objects)
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:297-315; service/history/workflow/update/update.go:739-767
    /\ s.pc = "reject" /\ o \in s.rejectTodo
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:297-315; service/history/workflow/update/update.go:739-767
    /\ LET e == Effect(o,"reject",s.objects[o].state,RejectFailure) IN
       /\ IF s.objects[o].callbacks
          THEN s' = [s EXCEPT !.rejectTodo = {}]
          ELSE s' = [s EXCEPT !.objects[o].state = "PC", !.rejectTodo = @ \ {o},
                          !.effects = Append(@,e), !.cancels = Append(@,e)]
(* api.go:468-474 and update.abort:262-312. *)
\* ACTION SOURCE: service/history/workflow/update/registry.go:289-294; service/history/workflow/update/update.go:262-312
AbortAccepted(o) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:289-294; service/history/workflow/update/update.go:262-312
    /\ o \in 1..Len(s.objects)
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:289-294; service/history/workflow/update/update.go:262-312
    /\ s.pc = "reject" /\ s.rejectTodo = {} /\ s.ctx.closed /\ o \in AcceptedObjects
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:289-294; service/history/workflow/update/update.go:262-312
    /\ LET e == Effect(o,"abort",s.objects[o].state,CloseFailure) IN
       /\ s' = [s EXCEPT !.objects[o].state = "PX", !.objects[o].callbacks = FALSE,
            !.effects = Append(@,e), !.cancels = Append(@,e)]
(* api.go:551-586,676-726. ReturnNewWorkflowTask=true, no heartbeat/extra
   normal successor reason in this slice; callback-Sent still needs successor. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:551-586,676-726
PrepareWorkflowMutation ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:551-586,676-726
    /\ s.pc = "reject" /\ s.rejectTodo = {}
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:551-586,676-726
    /\ (~s.ctx.closed \/ AcceptedObjects = {})
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:551-586,676-726
    /\ s' = [s EXCEPT !.successor = ~s.ctx.closed /\ NeedSend # {},
         !.pc = IF s.skip THEN "apply" ELSE "persist", !.returnPC = "afterEffects",
         !.cancels = IF s.skip THEN <<>> ELSE @]

(* MutableState.convertSpeculativeWorkflowTaskToNormal:1526-1594, S2/S4.
   Sent callback attachment requests a real transaction; pointer is cancelled
   but an already-submitted timer remains executable. Identity is preserved. *)
\* ACTION SOURCE: service/history/workflow/workflow_task_state_machine.go:1526-1594
ConvertSpeculativeWorkflowTaskToNormal ==
    \* BLOCK SOURCE: service/history/workflow/workflow_task_state_machine.go:1526-1594
    /\ s.pc = "convert"
    \* BLOCK SOURCE: service/history/workflow/workflow_task_state_machine.go:1526-1594
    /\ LET t == s.ctx.task
           materialize == t.kind = "Speculative"
           evs == IF ~materialize THEN <<>> ELSE
               <<Generic(s.ctx.next,"WFTScheduled")>> \o
               (IF t.started = 0 THEN <<>> ELSE <<Generic(s.ctx.next+1,"WFTStarted")>>)
       IN
       /\ s' = [s EXCEPT !.ctx.task.kind = IF materialize THEN "Normal" ELSE @,
            !.ctx.next = @+Len(evs), !.batch = @ \o evs,
            !.timers = IF materialize THEN Append(CancelPointer(@,s.timerPointer),
                Timer([t EXCEPT !.kind = "Normal"], IF t.started = 0 THEN "STS" ELSE "STC", t.started = 0)) ELSE @,
            !.timerPointer = IF materialize THEN (IF t.started = 0 THEN Len(s.timers)+1 ELSE 0) ELSE @, !.pc = "persist"]

(* context.go:911-930,1004-1060 / SQL execution.go:334-357. Snapshot once;
   record version/range and all internal task metadata belong to one commit. *)
(* MutableState.closeTransaction:7895-7898 advances the in-memory version
   before backend submission. write.rv retains the expected OLD database
   version; SQL lockAndCheckExecution:653-654 compares mutation version minus 1. *)
\* ACTION SOURCE: service/history/workflow/context.go:888-930,1004-1060
UpdateWorkflowExecutionWithNew ==
    \* BLOCK SOURCE: service/history/workflow/context.go:888-930,1004-1060
    /\ s.pc = "persist" /\ WriteSettled
    \* BLOCK SOURCE: service/history/workflow/context.go:888-930,1004-1060
    /\ s' = [s EXCEPT !.write = [state |-> "prepared", returned |-> FALSE, error |-> "none",
         range |-> s.ctx.range, rv |-> s.ctx.rv, next |-> s.ctx.next,
         info |-> s.ctx.info, closed |-> s.ctx.closed, sticky |-> s.ctx.sticky,
         task |-> s.ctx.task, transfer |-> s.ctx.transfer, events |-> s.batch],
         !.ctx.rv = @+1, !.pc = "writeWait"]
(* SQL execution.go:338-348 / Cassandra execution_store.go:114-123.
   This is PHYSICAL history evidence, never execution commitment. *)
\* ACTION SOURCE: common/persistence/sql/execution.go:338-348; common/persistence/cassandra/execution_store.go:114-123
AppendHistoryNodes ==
    \* BLOCK SOURCE: common/persistence/sql/execution.go:338-348; common/persistence/cassandra/execution_store.go:114-123
    /\ s.write.state = "prepared"
    \* BLOCK SOURCE: common/persistence/sql/execution.go:338-348; common/persistence/cassandra/execution_store.go:114-123
    /\ s' = [s EXCEPT !.physicalHistory = IF s.write.events = <<>> THEN @ ELSE Append(@,[range |-> s.write.range,
          rv |-> s.write.rv, events |-> s.write.events]), !.write.state = "appended"]
(* SQL execution.go:40-57 and execution_util.go:44-79,629-661;
   Cassandra mutable_state_store.go:715-735. Keep transaction atomic.
   A late write can commit AFTER timeout until a newer range fences it. *)
\* ACTION SOURCE: common/persistence/sql/execution.go:40-57; common/persistence/sql/execution_util.go:44-79,629-661; common/persistence/cassandra/mutable_state_store.go:715-735
ExecutionTransactionCommit ==
    \* BLOCK SOURCE: common/persistence/sql/execution.go:40-57; common/persistence/sql/execution_util.go:44-79,629-661; common/persistence/cassandra/mutable_state_store.go:715-735
    /\ s.write.state = "executing" /\ s.write.range = s.db.range /\ s.write.rv = s.db.rv
    \* BLOCK SOURCE: common/persistence/sql/execution.go:40-57; common/persistence/sql/execution_util.go:44-79,629-661; common/persistence/cassandra/mutable_state_store.go:715-735
    /\ s' = [s EXCEPT !.db = [next |-> s.write.next, rv |-> s.write.rv+1,
         range |-> s.db.range, closed |-> s.write.closed, sticky |-> s.write.sticky,
         task |-> s.write.task, transfer |-> s.write.transfer, info |-> s.write.info,
         events |-> s.db.events \o s.write.events], !.write.state = "committed"]
(* The failed conditional write is reactive, NOT fault-counter limited. *)
\* ACTION SOURCE: common/persistence/sql/execution.go:48-50; common/persistence/sql/execution_util.go:629-661; service/history/shard/context_impl.go:1522-1538
ExecutionTransactionFenced ==
    \* BLOCK SOURCE: common/persistence/sql/execution.go:48-50; common/persistence/sql/execution_util.go:629-661; service/history/shard/context_impl.go:1522-1538
    /\ s.write.state = "executing" /\ (s.write.range # s.db.range \/ s.write.rv # s.db.rv)
    \* BLOCK SOURCE: common/persistence/sql/execution.go:48-50; common/persistence/sql/execution_util.go:629-661; service/history/shard/context_impl.go:1522-1538
    /\ s' = [s EXCEPT !.write.state = "noncommit", !.write.error = "condition"]
(* ENV known-noncommit execution failure, shard/context_impl.go:1522-1532. *)
\* ACTION SOURCE: service/history/shard/context_impl.go:1522-1532; common/persistence/faultinjection/fault.go:42-47,61-72
ExecutionTransactionNoncommit ==
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1522-1532; common/persistence/faultinjection/fault.go:42-47,61-72
    /\ s.write.state \in {"prepared", "appended", "executing"}
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1522-1532; common/persistence/faultinjection/fault.go:42-47,61-72
    /\ (~s.write.returned \/ s.write.state = "executing")
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1522-1532; common/persistence/faultinjection/fault.go:42-47,61-72
    /\ s' = [s EXCEPT !.write.state = "noncommit", !.write.error = IF s.write.returned THEN @ ELSE "knownNoncommit"]
(* ENV common/persistence/faultinjection/fault.go:42-47,61-72 and shard
   context_impl.go:1540-1548. Timeout does NOT decide whether DB committed. *)
\* ACTION SOURCE: common/persistence/faultinjection/fault.go:42-47,61-72; service/history/shard/context_impl.go:1540-1548
ExecutionTransactionTimeout ==
    \* BLOCK SOURCE: common/persistence/faultinjection/fault.go:42-47,61-72; service/history/shard/context_impl.go:1540-1548
    /\ s.pc = "writeWait" /\ ~s.write.returned
    \* BLOCK SOURCE: common/persistence/faultinjection/fault.go:42-47,61-72; service/history/shard/context_impl.go:1540-1548
    /\ s.write.state \in {"executing", "committed"}
    \* BLOCK SOURCE: common/persistence/faultinjection/fault.go:42-47,61-72; service/history/shard/context_impl.go:1540-1548
    /\ s' = [s EXCEPT !.write.returned = TRUE, !.write.error = "uncertain",
         !.acquiring = TRUE, !.pc = "errorClear", !.clearReturn = "cancel"]
(* ENV History-append timeout is a distinct retriable, no-execution-commit
   class, shard/context_impl.go:1518-1520; physical batch may exist. *)
\* ACTION SOURCE: service/history/shard/context_impl.go:1518-1520; common/persistence/sql/execution.go:338-348
AppendHistoryTimeout ==
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1518-1520; common/persistence/sql/execution.go:338-348
    /\ s.pc = "writeWait" /\ s.write.state \in {"prepared", "appended"}
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1518-1520; common/persistence/sql/execution.go:338-348
    /\ ~s.write.returned
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1518-1520; common/persistence/sql/execution.go:338-348
    /\ s' = [s EXCEPT !.write.state = "noncommit", !.write.error = "appendTimeout"]
(* Context.Update... deferred Clear precedes caller effects.Cancel on error:
   context.go:898-900, api.go:684-685. Successful effects publish immediately. *)
\* ACTION SOURCE: service/history/workflow/context.go:898-900; service/history/api/respondworkflowtaskcompleted/api.go:684-726
HandleWriteResult ==
    \* BLOCK SOURCE: service/history/workflow/context.go:898-900; service/history/api/respondworkflowtaskcompleted/api.go:684-726
    /\ s.pc = "writeWait" /\ ~s.write.returned
    \* BLOCK SOURCE: service/history/workflow/context.go:898-900; service/history/api/respondworkflowtaskcompleted/api.go:684-726
    /\ s.write.state \in {"committed", "noncommit"}
    \* BLOCK SOURCE: service/history/workflow/context.go:898-900; service/history/api/respondworkflowtaskcompleted/api.go:684-726
    /\ IF s.write.state = "committed"
       THEN s' = [s EXCEPT !.write.returned = TRUE,
            !.batch = <<>>, !.cancels = <<>>, !.pc = "apply"]
       ELSE s' = [s EXCEPT !.write.returned = TRUE, !.pc = "errorClear", !.clearReturn = "cancel"]

(* common/effect/buffer.go:32-39 FIFO, update.go:660-694,748-760,790-807,
   276-305. Each future Set is split, so unlocked waiters can run between them.
   Acceptance in a combined batch defers its future until outcome publication. *)
\* ACTION SOURCE: common/effect/buffer.go:32-39; service/history/workflow/update/update.go:276-305,660-694,748-760,790-807
BufferApplyFirst ==
    \* BLOCK SOURCE: common/effect/buffer.go:32-39; service/history/workflow/update/update.go:276-305,660-694,748-760,790-807
    /\ s.pc = "apply" /\ s.second = "none" /\ Len(s.effects) > 0
    \* BLOCK SOURCE: common/effect/buffer.go:32-39; service/history/workflow/update/update.go:276-305,660-694,748-760,790-807
    /\ LET e == Head(s.effects) o == e.oid st == s.objects[o].state
           valid == CASE e.kind = "accept" -> st \in {"PA", "PC", "PX"}
                       [] e.kind = "complete" -> st \in {"PC", "PCA"}
                       [] e.kind = "reject" -> st = "PC"
                       [] OTHER -> st \in {"PX", "PCA"}
           second == IF ~valid \/ e.kind = "accept" THEN "none"
                     ELSE IF e.kind = "reject" THEN "outcome"
                     ELSE IF st = "PCA" THEN "accepted"
                     ELSE IF e.kind = "abort" /\ e.prev \in {"Admitted", "Sent", "PA"} THEN "abortAccepted"
                     ELSE "remove"
           obj == IF ~valid THEN s.objects[o]
              ELSE CASE e.kind = "accept" ->
                   [s.objects[o] EXCEPT !.state = IF st = "PA" THEN "Accepted" ELSE "PCA",
                        !.accepted = IF st = "PA" THEN "accepted" ELSE @]
                [] e.kind = "reject" -> [s.objects[o] EXCEPT !.state = "Completed", !.accepted = "rejected"]
                [] OTHER -> [s.objects[o] EXCEPT !.state = IF e.kind = "abort" THEN "Aborted" ELSE "Completed",
                                                !.outcome = e.result]
       IN
       /\ s' = [s EXCEPT !.effects = Tail(@), !.objects[o] = obj,
            !.active = e, !.second = second]
(* update.go:295-304,758-760,805-807: second future then remover.
   Failure/error before acceptance differs from a successful accepted future. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:295-304,758-760,805-807
BufferApplySecond ==
    \* BLOCK SOURCE: service/history/workflow/update/update.go:295-304,758-760,805-807
    /\ s.pc = "apply" /\ s.second # "none"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:295-304,758-760,805-807
    /\ LET o == s.active.oid u == s.objects[o].uid IN
       /\ s' = [s EXCEPT !.objects[o].accepted = CASE s.second = "accepted" -> "accepted"
              [] s.second = "abortAccepted" -> IF s.active.result.kind = "closing" THEN "rejected" ELSE IF s.active.result.kind = "closedError" THEN "closedError" ELSE "retry"
              [] OTHER -> @,
            !.objects[o].outcome = IF s.second = "outcome" THEN s.active.result ELSE @,
            !.ctx.reg[u] = IF s.active.kind \in {"complete", "reject"} /\ @ = o THEN 0 ELSE @,
            !.second = "none", !.active = NoEffect]
(* effects.Apply completion, api.go:726-747. *)
\* ACTION SOURCE: common/effect/buffer.go:32-40; service/history/api/respondworkflowtaskcompleted/api.go:724-747
BufferApplyDone ==
    \* BLOCK SOURCE: common/effect/buffer.go:32-40; service/history/api/respondworkflowtaskcompleted/api.go:724-747
    /\ s.pc = "apply" /\ s.effects = <<>> /\ s.second = "none"
    \* BLOCK SOURCE: common/effect/buffer.go:32-40; service/history/api/respondworkflowtaskcompleted/api.go:724-747
    /\ s' = [s EXCEPT !.pc = s.returnPC, !.active = NoEffect, !.cancels = <<>>,
         !.workers = [i \in 1..Len(s.workers) |->
             IF s.handler = "start" /\ s.workers[i].status = "pendingStart"
             THEN [s.workers[i] EXCEPT !.status = "startResponse"] ELSE s.workers[i]]]
(* Post-commit registry abort for newly admitted Updates, api.go:728-745.
   Use the same future-splitting machinery with immediate abort effects. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:728-745; service/history/api/update_workflow_util.go:114-124; service/history/workflow/update/registry.go:283-286
RegistryAbortAfterClose(o) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:728-745; service/history/api/update_workflow_util.go:114-124; service/history/workflow/update/registry.go:283-286
    /\ o \in 1..Len(s.objects)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:728-745; service/history/api/update_workflow_util.go:114-124; service/history/workflow/update/registry.go:283-286
    /\ s.pc = "afterEffects" /\ s.ctx.closed /\ o \in LiveObjects
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:728-745; service/history/api/update_workflow_util.go:114-124; service/history/workflow/update/registry.go:283-286
    /\ s.objects[o].state \notin {"Aborted", "Completed"}
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:728-745; service/history/api/update_workflow_util.go:114-124; service/history/workflow/update/registry.go:283-286
    /\ LET r == IF s.objects[o].accepted = "accepted" THEN CloseFailure ELSE CloseError
           e == Effect(o,"abort",s.objects[o].state,r) IN
       /\ s' = [s EXCEPT !.objects[o].state = "PX", !.objects[o].callbacks = FALSE,
            !.effects = <<e>>, !.returnPC = "afterEffects", !.pc = "apply"]
(* api.go:749-777: speculative successor after commit, inline start/response
   separate actions; timer installed by the real start path. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:749-754
AddSuccessorWorkflowTask ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:749-754
    /\ s.pc = "afterEffects" /\ ~s.ctx.closed /\ s.successor
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:749-754
    /\ LET t == Task("Speculative",s.ctx.next,1,IF s.ctx.sticky THEN "sticky" ELSE "normal") IN
       /\ s' = [s EXCEPT !.ctx.task = t, !.successor = FALSE, !.pc = "successorStart"]
(* api.go:762-776; inline start remains inside the SAME workflow lease. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:762-776
StartSuccessorWorkflowTask ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:762-776
    /\ s.pc = "successorStart"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:762-776
    /\ LET t == [s.ctx.task EXCEPT !.started = s.ctx.task.scheduled+1, !.startedTime = s.clock+1] IN
       /\ s' = [s EXCEPT !.ctx.task = t, !.clock = @+1,
            !.timers = Append(@,Timer(t,"STC",TRUE)), !.timerPointer = Len(s.timers)+1,
            !.pc = "successorResponse"]
(* api.go:793-825: response assembly is later than future publication. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:793-825
CreateRespondWorkflowTaskCompletedResponse ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:793-825
    /\ s.pc = "afterEffects" /\ s.handler = "completion" /\ (~s.successor \/ s.ctx.closed)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:793-825
    /\ \A o \in LiveObjects: ~s.ctx.closed \/ s.objects[o].state \in {"Aborted","Completed"}
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:793-825
    /\ s' = [s EXCEPT !.pc = "handlerReply"]
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:793-825
RespondWorkflowTaskCompletedReturn ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:793-825
    /\ s.pc = "handlerReply"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:793-825
    /\ s' = [s EXCEPT !.pc = "idle", !.handler = "none", !.selected = 0,
         !.successor = FALSE, !.commands = <<>>,
         !.workers = IF s.inlineWorker = 0 THEN @ ELSE [@ EXCEPT ![s.inlineWorker].status = "working"],
         !.inlineWorker = 0]
(* ENV later response assembly error, api.go:750-805, deferred context clear.
   Effects already published; cancellation must not roll back a committed DB. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:750-805
RespondWorkflowTaskCompletedLateError ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:750-805
    /\ s.pc \in {"afterEffects", "successorStart", "successorResponse", "handlerReply"}
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:750-805
    /\ s.handler = "completion"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:750-805
    /\ s' = [s EXCEPT !.pc = "errorClear", !.clearReturn = "cancel"]

(* ContextImpl.Clear:174-185; update.Registry.Clear:360-365; abort matrix:36-49.
   MS clearing cancels the pointer but not a timer already submitted. Registry
   object lifetime extends through old waiters. Host event cache is untouched. *)
\* ACTION SOURCE: service/history/workflow/context.go:174-185; service/history/api/respondworkflowtaskcompleted/api.go:1169-1174
ContextClearBegin ==
    \* BLOCK SOURCE: service/history/workflow/context.go:174-185; service/history/api/respondworkflowtaskcompleted/api.go:1169-1174
    /\ s.pc \in {"errorClear","stickyClear","cacheClear","shardClear","limitClear"}
    \* BLOCK SOURCE: service/history/workflow/context.go:174-185; service/history/api/respondworkflowtaskcompleted/api.go:1169-1174
    /\ s' = [s EXCEPT !.clearTodo = LiveObjects, !.pc = "clearing",
         !.clearReturn = CASE s.pc = "stickyClear" -> "stickyReload"
             [] s.pc = "limitClear" -> "limitReload" [] OTHER -> @,
         !.timers = CancelPointer(@,s.timerPointer), !.timerPointer = 0,
         !.ctx.loaded = FALSE,
         !.workers = [i \in 1..Len(s.workers) |-> IF s.workers[i].status \in {"pendingResponse","pendingStart"}
                        THEN [s.workers[i] EXCEPT !.status = "lost"] ELSE s.workers[i]], !.inlineWorker = 0]
(* Clear's immediate Abort callback, first outcome Set, update.go:274-286. *)
\* ACTION SOURCE: service/history/workflow/update/registry.go:360-365; service/history/workflow/update/abort_reason.go:36-49; service/history/workflow/update/update.go:274-286
RegistryClearAbort(o) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:360-365; service/history/workflow/update/abort_reason.go:36-49; service/history/workflow/update/update.go:274-286
    /\ o \in 1..Len(s.objects)
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:360-365; service/history/workflow/update/abort_reason.go:36-49; service/history/workflow/update/update.go:274-286
    /\ s.pc = "clearing" /\ s.second = "none" /\ o \in s.clearTodo
    \* BLOCK SOURCE: service/history/workflow/update/registry.go:360-365; service/history/workflow/update/abort_reason.go:36-49; service/history/workflow/update/update.go:274-286
    /\ IF s.objects[o].state \in {"Completed","Aborted","PX"}
       THEN s' = [s EXCEPT !.clearTodo = @ \ {o}]
       ELSE s' = [s EXCEPT !.objects[o].state = "Aborted", !.objects[o].outcome = RetryError,
            !.objects[o].callbacks = FALSE, !.active = Effect(o,"clear",s.objects[o].state,RetryError),
            !.second = "clearAccepted"]
(* Clear's second Set only for preaccepted states; Future.Set does not
   replace an already-ready accepted future. update.go:300-304. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:300-304
RegistryClearAbortSecond ==
    \* BLOCK SOURCE: service/history/workflow/update/update.go:300-304
    /\ s.pc = "clearing" /\ s.second = "clearAccepted"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:300-304
    /\ LET o == s.active.oid IN
       /\ s' = [s EXCEPT !.objects[o].accepted = IF @ = "pending" THEN "retry" ELSE @,
            !.clearTodo = @ \ {o}, !.second = "none", !.active = NoEffect]
\* ACTION SOURCE: service/history/workflow/context.go:181-185
ContextClearDone ==
    \* BLOCK SOURCE: service/history/workflow/context.go:181-185
    /\ s.pc = "clearing" /\ s.clearTodo = {} /\ s.second = "none"
    \* BLOCK SOURCE: service/history/workflow/context.go:181-185
    /\ s' = [s EXCEPT !.ctx.reg = [u \in Updates |-> 0], !.ctx.task = NoTask,
         !.pc = s.clearReturn, !.batch = <<>>]
(* common/effect/buffer.go:46-53 LIFO with original guarded rollback states,
   update.go:696-702,762-766,809-813,307-311. Clear may already have aborted. *)
\* ACTION SOURCE: common/effect/buffer.go:46-53; service/history/workflow/update/update.go:696-702,762-766,809-813,307-311
BufferCancel ==
    \* BLOCK SOURCE: common/effect/buffer.go:46-53; service/history/workflow/update/update.go:696-702,762-766,809-813,307-311
    /\ s.pc = "cancel" /\ Len(s.cancels) > 0
    \* BLOCK SOURCE: common/effect/buffer.go:46-53; service/history/workflow/update/update.go:696-702,762-766,809-813,307-311
    /\ LET e == s.cancels[Len(s.cancels)] o == e.oid
           expected == CASE e.kind = "accept" -> "PA" [] e.kind = "abort" -> "PX" [] OTHER -> "PC"
       IN
       /\ s' = [s EXCEPT !.effects = <<>>, !.cancels = SubSeq(@,1,Len(@)-1),
            !.objects[o] = IF @.state # expected THEN @ ELSE
               [@ EXCEPT !.state = e.prev,
                    !.acceptedID = IF e.kind = "accept" THEN 0 ELSE @,
                    !.callbacks = IF e.kind = "accept" THEN FALSE ELSE @]]
\* ACTION SOURCE: common/effect/buffer.go:46-54
BufferCancelDone ==
    \* BLOCK SOURCE: common/effect/buffer.go:46-54
    /\ s.pc = "cancel" /\ s.cancels = <<>>
    \* BLOCK SOURCE: common/effect/buffer.go:46-54
    /\ s' = [s EXCEPT !.effects = <<>>, !.pc = "idle", !.handler = "none",
         !.successor = FALSE, !.selected = 0, !.second = "none", !.active = NoEffect]

(* ENV cache eviction is allowed only outside a held workflow lease. *)
\* ACTION SOURCE: service/history/workflow/context.go:174-185
EvictWorkflowContext ==
    \* BLOCK SOURCE: service/history/workflow/context.go:174-185
    /\ CanLock
    \* BLOCK SOURCE: service/history/workflow/context.go:174-185
    /\ s' = [s EXCEPT !.pc = "cacheClear", !.clearReturn = "idle"]
(* Shard write-error reacquisition / ownership movement, context_impl.go:1534-1548.
   The active holder becomes unavailable; outstanding DB write is independent. *)
\* ACTION SOURCE: service/history/shard/context_impl.go:1534-1548
LoseShardOwnership ==
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1534-1548
    /\ ~s.acquiring /\ s.pc = "idle"
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1534-1548
    /\ s' = [s EXCEPT !.acquiring = TRUE, !.pc = "shardClear", !.clearReturn = "idle"]
(* New RangeID fences unresolved old writes; don't equate it with event version.
   No two active leases are modeled, but both hosts retain independent caches. *)
\* ACTION SOURCE: service/history/shard/context_impl.go:1540-1548,2258-2261
AcquireShard(h) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1540-1548,2258-2261
    /\ h \in Hosts
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1540-1548,2258-2261
    /\ s.acquiring /\ s.pc = "idle" /\ ~s.ctx.loaded
    \* BLOCK SOURCE: service/history/shard/context_impl.go:1540-1548,2258-2261
    /\ s' = [s EXCEPT !.db.range = @+1, !.ctx.range = s.db.range+1,
         !.ctx.host = h, !.cache[h] = IF HostCacheEnabled THEN @ ELSE <<>>, !.acquiring = FALSE]
(* Context.LoadMutableState and NewRegistry reconstruct accepted, not completed
   objects; completed results remain lazy cache-backed lookups. *)
\* ACTION SOURCE: service/history/workflow/context.go:408-459,1408-1422; service/history/workflow/update/registry.go:189-221
LoadMutableState ==
    \* BLOCK SOURCE: service/history/workflow/context.go:408-459,1408-1422; service/history/workflow/update/registry.go:189-221
    /\ ~s.ctx.loaded /\ ~s.acquiring /\ s.pc \in {"idle","stickyReload","limitReload"}
    \* BLOCK SOURCE: service/history/workflow/context.go:408-459,1408-1422; service/history/workflow/update/registry.go:189-221
    /\ LET us == {u \in Updates: s.db.info[u].stage = "Accepted"}
           order == CHOOSE q \in [1..Cardinality(us) -> us]: SeqSet(q) = us
           fresh == [i \in 1..Len(order) |->
               [NewObject(order[i],s.ctx.generation+1) EXCEPT !.state = IF s.db.closed THEN "Aborted" ELSE "Accepted",
                 !.accepted = "accepted", !.acceptedID = s.db.info[order[i]].acceptedID,
                 !.outcome = IF s.db.closed THEN CloseFailure ELSE Pending]]
       IN
       /\ s' = [s EXCEPT !.objects = @ \o fresh,
            !.ctx = [loaded |-> TRUE, host |-> s.ctx.host, generation |-> s.ctx.generation+1,
                 range |-> s.db.range, rv |-> s.db.rv, next |-> s.db.next, closed |-> s.db.closed,
                 sticky |-> s.db.sticky, task |-> s.db.task, transfer |-> s.db.transfer,
                 info |-> s.db.info, reg |-> [u \in Updates |->
                     IF u \in us THEN Len(s.objects)+(CHOOSE i \in 1..Len(order): order[i]=u) ELSE 0]],
            !.pc = CASE s.pc = "stickyReload" -> "stickyWrite"
                     [] s.pc = "limitReload" -> "limitTerminate" [] OTHER -> "idle"]
(* clearStickyTaskQueue api.go:1169-1183: clear+reload precedes actual write. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:1169-1183
ClearStickyTaskQueue ==
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:1169-1183
    /\ s.pc = "stickyWrite" /\ WriteSettled
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:1169-1183
    /\ s' = [s EXCEPT !.ctx.sticky = FALSE, !.batch = <<>>, !.pc = "persist",
         !.handler = "sticky", !.returnPC = "idle"]
(* events/cache.go:76-94,158-165: TTL/eviction is independent of shard life. *)
\* ACTION SOURCE: service/history/events/cache.go:76-94,158-165
EvictHostEvent(h, i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/events/cache.go:76-94,158-165
    /\ h \in Hosts /\ i \in 1..Len(s.cache[h])
    \* BLOCK SOURCE: service/history/events/cache.go:76-94,158-165
    /\ i \in 1..Len(s.cache[h])
    \* BLOCK SOURCE: service/history/events/cache.go:76-94,158-165
    /\ s' = [s EXCEPT !.cache[h] = RemoveAt(@,i)]
(* Process loss unlike shard replacement also discards the host event cache.
   Restrict to an already-detached host; active-host loss = LoseShard then this. *)
\* ACTION SOURCE: service/history/shard/context_impl.go:2258-2261; service/history/events/cache.go:56-94
RestartHistoryHost(h) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/shard/context_impl.go:2258-2261; service/history/events/cache.go:56-94
    /\ h \in Hosts
    \* BLOCK SOURCE: service/history/shard/context_impl.go:2258-2261; service/history/events/cache.go:56-94
    /\ h # s.ctx.host \/ (~s.ctx.loaded /\ s.pc = "idle")
    \* BLOCK SOURCE: service/history/shard/context_impl.go:2258-2261; service/history/events/cache.go:56-94
    /\ s.cache[h] # <<>>
    \* BLOCK SOURCE: service/history/shard/context_impl.go:2258-2261; service/history/events/cache.go:56-94
    /\ s' = [s EXCEPT !.cache[h] = <<>>]

(* Queue eligibility and submission are independent; queues/memory_scheduled_queue.go:140-155.
   STS eligibility is required timer progress; STC expiration is worker delay. *)
\* ACTION SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
ScheduleToStartTimerEligible(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ i \in 1..Len(s.timers)
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ i \in 1..Len(s.timers) /\ ~s.timers[i].eligible /\ ~s.timers[i].cancelled
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ s.timers[i].timeout = "STS"
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ (s.timers[i].speculative \/ s.db.task = s.timers[i].task)
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ s' = [s EXCEPT !.timers[i].eligible = TRUE]
\* ACTION SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
StartToCloseTimerEligible(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ i \in 1..Len(s.timers)
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ i \in 1..Len(s.timers) /\ ~s.timers[i].eligible /\ ~s.timers[i].cancelled
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ s.timers[i].timeout = "STC"
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ (s.timers[i].speculative \/ s.db.task = s.timers[i].task)
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155; service/history/workflow/mutable_state_impl.go:7461-7475
    /\ s' = [s EXCEPT !.timers[i].eligible = TRUE]
\* ACTION SOURCE: service/history/queues/memory_scheduled_queue.go:140-155
MemoryScheduledQueueSubmit(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155
    /\ i \in 1..Len(s.timers)
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155
    /\ i \in 1..Len(s.timers) /\ s.timers[i].eligible /\ ~s.timers[i].cancelled
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155
    /\ ~s.timers[i].submitted /\ ~s.timers[i].consumed
    \* BLOCK SOURCE: service/history/queues/memory_scheduled_queue.go:140-155
    /\ s' = [s EXCEPT !.timers[i].submitted = TRUE]
(* Timer guard is checked after acquiring the workflow lease. A cancelled,
   submitted old task is still evaluated against current task. S2/CR-6. *)
\* ACTION SOURCE: service/history/timer_queue_active_task_executor.go:395-458
ExecuteWorkflowTaskTimeoutTaskStale(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:395-458
    /\ i \in 1..Len(s.timers)
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:395-458
    /\ CanLock /\ i \in 1..Len(s.timers) /\ s.timers[i].submitted /\ ~s.timers[i].consumed
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:395-458
    /\ ~TimerMatches(i)
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:395-458
    /\ s' = [s EXCEPT !.timers[i].consumed = TRUE]
(* timer_queue_active_task_executor.go:408-477; task state machine:267-301,
   980-1031. Timeout mutation and successor scheduling precede the SAME write.
   First STC timeout advances attempt (transient); STS schedules normal attempt1. *)
\* ACTION SOURCE: service/history/timer_queue_active_task_executor.go:408-477,1015-1029; service/history/workflow/workflow_task_state_machine.go:267-301,981-1031
ExecuteWorkflowTaskTimeoutTask(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:408-477,1015-1029; service/history/workflow/workflow_task_state_machine.go:267-301,981-1031
    /\ i \in 1..Len(s.timers)
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:408-477,1015-1029; service/history/workflow/workflow_task_state_machine.go:267-301,981-1031
    /\ CanLock /\ WriteSettled /\ i \in 1..Len(s.timers)
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:408-477,1015-1029; service/history/workflow/workflow_task_state_machine.go:267-301,981-1031
    /\ s.timers[i].submitted /\ ~s.timers[i].consumed /\ TimerMatches(i)
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:408-477,1015-1029; service/history/workflow/workflow_task_state_machine.go:267-301,981-1031
    /\ LET old == s.ctx.task sts == s.timers[i].timeout = "STS"
           prefix == IF old.kind # "Speculative" THEN <<>> ELSE
                     <<Generic(s.ctx.next,"WFTScheduled")>> \o
                     (IF old.started = 0 THEN <<>> ELSE <<Generic(s.ctx.next+1,"WFTStarted")>>)
           timeoutEvents == IF old.transient /\ ~sts THEN <<>> ELSE
                            <<Generic(s.ctx.next+Len(prefix),"WFTTimedOut")>>
           attempt == IF sts THEN 1 ELSE old.attempt+1
           sid == s.ctx.next+Len(prefix)+Len(timeoutEvents)
           t == Task("Normal",sid,attempt,"normal")
           evs == prefix \o timeoutEvents \o (IF t.transient THEN <<>> ELSE <<Generic(sid,"WFTScheduled")>>)
       IN
       /\ s' = [s EXCEPT !.timers = [CancelPointer(@,s.timerPointer) EXCEPT ![i].consumed = TRUE],
            !.timerPointer = 0, !.ctx.task = t, !.ctx.next = @+Len(evs),
            !.ctx.sticky = IF sts THEN FALSE ELSE @, !.ctx.transfer = TRUE,
            !.batch = evs, !.pc = "persist", !.handler = "timeout", !.returnPC = "idle",
            !.timeoutApplications = @ \cup {[timerTask |-> s.timers[i].task, current |-> old,
                                            pointerMatched |-> s.timerPointer = i]}]

(* S3/CR-5, context.go:1575-1584: forced limit termination aborts registry
   BEFORE clearing/reloading/persisting. Runtime limit restoration is explicit.
   Contract adjudication belongs to Phase4, not a durable-close assumption. *)
\* ACTION SOURCE: service/history/workflow/context.go:1440-1533,1566-1578
ForceTerminateWorkflow ==
    \* BLOCK SOURCE: service/history/workflow/context.go:1440-1533,1566-1578
    /\ CanLock /\ WriteSettled /\ ~s.ctx.closed
    \* BLOCK SOURCE: service/history/workflow/context.go:1440-1533,1566-1578
    /\ s' = [s EXCEPT !.limitRaised = TRUE, !.pc = "forceAbort", !.handler = "limit"]
\* ACTION SOURCE: service/history/workflow/context.go:1575-1578; service/history/workflow/update/registry.go:283-286
ForceTerminateAbort(o) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/context.go:1575-1578; service/history/workflow/update/registry.go:283-286
    /\ o \in 1..Len(s.objects)
    \* BLOCK SOURCE: service/history/workflow/context.go:1575-1578; service/history/workflow/update/registry.go:283-286
    /\ s.pc = "forceAbort" /\ o \in LiveObjects /\ s.objects[o].state \notin {"Completed","Aborted"}
    \* BLOCK SOURCE: service/history/workflow/context.go:1575-1578; service/history/workflow/update/registry.go:283-286
    /\ LET e == Effect(o,"abort",s.objects[o].state,
             IF s.objects[o].state \in {"Accepted","PA","PC","PCA"} THEN CloseFailure ELSE CloseError) IN
       /\ s' = [s EXCEPT !.objects[o].state = "PX", !.objects[o].callbacks = FALSE,
            !.effects = <<e>>, !.returnPC = "forceAbort", !.pc = "apply"]
\* ACTION SOURCE: service/history/workflow/context.go:1580-1584
ForceTerminateClear ==
    \* BLOCK SOURCE: service/history/workflow/context.go:1580-1584
    /\ s.pc = "forceAbort" /\ \A o \in LiveObjects: s.objects[o].state \in {"Completed","Aborted"}
    \* BLOCK SOURCE: service/history/workflow/context.go:1580-1584
    /\ s' = [s EXCEPT !.pc = "limitClear"]
\* ACTION SOURCE: service/history/workflow/context.go:1583-1605; service/history/workflow/util.go:95-130
ForceTerminatePersist ==
    \* BLOCK SOURCE: service/history/workflow/context.go:1583-1605; service/history/workflow/util.go:95-130
    /\ s.pc = "limitTerminate" /\ WriteSettled
    \* BLOCK SOURCE: service/history/workflow/context.go:1583-1605; service/history/workflow/util.go:95-130
    /\ LET failed == s.ctx.task.started # 0 /\ ~s.ctx.task.transient
           evs == (IF failed THEN <<Generic(s.ctx.next,"WFTFailed")>> ELSE <<>>) \o
                  <<Generic(s.ctx.next+(IF failed THEN 1 ELSE 0),"WorkflowTerminated")>> IN
       /\ s' = [s EXCEPT !.ctx.closed = TRUE, !.ctx.task = NoTask, !.ctx.transfer = FALSE,
            !.batch = evs, !.ctx.next = @+Len(evs), !.pc = "persist", !.returnPC = "idle"]
(* ENV runtime-limit restoration used in CR-5's executed recovery fixture. *)
\* ACTION SOURCE: tests/update_analysis_commit_test.go:172-263; service/history/workflow/context.go:1440-1533
RestoreHistoryLimit ==
    \* BLOCK SOURCE: tests/update_analysis_commit_test.go:172-263; service/history/workflow/context.go:1440-1533
    /\ s.limitRaised /\ s.pc = "idle"
    \* BLOCK SOURCE: tests/update_analysis_commit_test.go:172-263; service/history/workflow/context.go:1440-1533
    /\ s' = [s EXCEPT !.limitRaised = FALSE]

(* workflow/util.go:30-58,95-130: external termination first fails a started
   WFT, materializing a speculative pair if necessary; one transaction follows.
   No cross-run timeout retry/cron behavior is included. *)
ExternalCloseEvents(kind) ==
    LET t == s.ctx.task
        pair == IF t.kind = "Speculative" /\ t.started # 0 THEN
                   <<Generic(s.ctx.next,"WFTScheduled"),Generic(s.ctx.next+1,"WFTStarted")>> ELSE <<>>
        failed == t.started # 0 /\ ~t.transient
        prefix == pair \o (IF failed THEN <<Generic(s.ctx.next+Len(pair),"WFTFailed")>> ELSE <<>>)
    IN prefix \o <<Generic(s.ctx.next+Len(prefix),kind)>>
\* ACTION SOURCE: service/history/api/terminateworkflow/api.go:67-79; service/history/workflow/util.go:95-130
TerminateWorkflowExecution ==
    \* BLOCK SOURCE: service/history/api/terminateworkflow/api.go:67-79; service/history/workflow/util.go:95-130
    /\ CanLock /\ WriteSettled /\ ~s.ctx.closed
    \* BLOCK SOURCE: service/history/api/terminateworkflow/api.go:67-79; service/history/workflow/util.go:95-130
    /\ LET evs == ExternalCloseEvents("WorkflowTerminated") IN
       /\ s' = [s EXCEPT !.ctx.closed = TRUE, !.ctx.task = NoTask, !.ctx.transfer = FALSE,
            !.ctx.next = @+Len(evs), !.batch = evs, !.effects = <<>>, !.cancels = <<>>,
            !.timers = CancelPointer(@,s.timerPointer), !.timerPointer = 0,
            !.pc = "persist", !.handler = "externalClose", !.returnPC = "afterEffects", !.successor = FALSE]
(* timer_queue_active_task_executor.go:720-738,843-857: eligible final timeout,
   no retry/cron new run; abort registry only after persistence returned success. *)
\* ACTION SOURCE: service/history/timer_queue_active_task_executor.go:720-738,843-857; service/history/workflow/util.go:78-92
TimeoutWorkflowExecution ==
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:720-738,843-857; service/history/workflow/util.go:78-92
    /\ CanLock /\ WriteSettled /\ ~s.ctx.closed
    \* BLOCK SOURCE: service/history/timer_queue_active_task_executor.go:720-738,843-857; service/history/workflow/util.go:78-92
    /\ LET evs == ExternalCloseEvents("WorkflowTimedOut") IN
       /\ s' = [s EXCEPT !.ctx.closed = TRUE, !.ctx.task = NoTask, !.ctx.transfer = FALSE,
            !.ctx.next = @+Len(evs), !.batch = evs, !.effects = <<>>, !.cancels = <<>>,
            !.timers = CancelPointer(@,s.timerPointer), !.timerPointer = 0,
            !.pc = "persist", !.handler = "externalClose", !.returnPC = "afterEffects", !.successor = FALSE]
(* api/update_workflow_util.go:114-124 / timer executor:737-738,857-858. *)
\* ACTION SOURCE: service/history/api/update_workflow_util.go:114-124; service/history/timer_queue_active_task_executor.go:737-738,857-858
ExternalCloseReturn ==
    \* BLOCK SOURCE: service/history/api/update_workflow_util.go:114-124; service/history/timer_queue_active_task_executor.go:737-738,857-858
    /\ s.pc = "afterEffects" /\ s.handler = "externalClose"
    \* BLOCK SOURCE: service/history/api/update_workflow_util.go:114-124; service/history/timer_queue_active_task_executor.go:737-738,857-858
    /\ \A o \in LiveObjects: s.objects[o].state \in {"Aborted","Completed"}
    \* BLOCK SOURCE: service/history/api/update_workflow_util.go:114-124; service/history/timer_queue_active_task_executor.go:737-738,857-858
    /\ s' = [s EXCEPT !.pc = "idle", !.handler = "none"]

(* WaitLifecycleStage:173-194; no Workflow lease. Capture an outcome before
   separately checking acceptance, matching the actual thread-safe futures. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:173-194
WaitLifecycleStageOutcome(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:173-194
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/update/update.go:173-194
    /\ s.calls[c].status = "wait" /\ s.calls[c].oid # 0
    \* BLOCK SOURCE: service/history/workflow/update/update.go:173-194
    /\ LET r == s.objects[s.calls[c].oid].outcome IN
       /\ (r.kind # "pending" \/ s.calls[c].waitStage = "ACCEPTED" \/ s.calls[c].expired)
       /\ s' = [s EXCEPT !.calls[c].status = IF r.kind \in {"pending","retry"} THEN "acceptedCheck" ELSE "reply",
            !.calls[c].reply = IF r.kind \in WorkerKinds \cup {"closing","rejection"}
                 THEN Reply("COMPLETED",r) ELSE IF r.kind = "pending" THEN NoReply ELSE Reply("ERROR",r)]
(* WaitLifecycleStage:197-205,221-247. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:197-205,221-247
WaitLifecycleStageAccepted(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:197-205,221-247
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/update/update.go:197-205,221-247
    /\ s.calls[c].status = "acceptedCheck"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:197-205,221-247
    /\ LET a == s.objects[s.calls[c].oid].accepted IN
       /\ (a # "pending" \/ s.calls[c].expired)
       /\ s' = [s EXCEPT !.calls[c].status = IF a = "accepted" THEN "outcomeRecheck" ELSE "reply",
            !.calls[c].reply = CASE a = "rejected" -> Reply("COMPLETED",RejectFailure)
                 [] a = "retry" -> Reply("ERROR",RetryError)
                 [] a = "closedError" -> Reply("ERROR",CloseError)
                 [] OTHER -> Reply("ADMITTED",Pending)]
(* WaitLifecycleStage:206-218, outcome-before-acceptance combined transitions. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:206-218
WaitLifecycleStageOutcomeRecheck(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:206-218
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/update/update.go:206-218
    /\ s.calls[c].status = "outcomeRecheck"
    \* BLOCK SOURCE: service/history/workflow/update/update.go:206-218
    /\ LET r == s.objects[s.calls[c].oid].outcome IN
       /\ s' = [s EXCEPT !.calls[c].status = "reply", !.calls[c].reply =
            IF r.kind \in WorkerKinds \cup {"closing","rejection"}
            THEN Reply("COMPLETED",r) ELSE Reply("ACCEPTED",Pending)]
(* ENV soft long-poll timeout; does not discard the Update. update.go:244-247. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:168-169,244-247
WaitLifecycleStageSoftTimeout(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:168-169,244-247
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/update/update.go:168-169,244-247
    /\ s.calls[c].status \in {"wait","acceptedCheck"} /\ ~s.calls[c].expired
    \* BLOCK SOURCE: service/history/workflow/update/update.go:168-169,244-247
    /\ s' = [s EXCEPT !.calls[c].expired = TRUE]
(* Updater.CreateResponse:344-361 / pollupdate/api.go:69-81; server return and
   network receipt remain separate from future publication and each other. *)
\* ACTION SOURCE: service/history/api/updateworkflow/api.go:272-276,344-361; service/history/api/pollupdate/api.go:64-81
CreateUpdateResponse(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:272-276,344-361; service/history/api/pollupdate/api.go:64-81
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:272-276,344-361; service/history/api/pollupdate/api.go:64-81
    /\ s.calls[c].status = "reply"
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:272-276,344-361; service/history/api/pollupdate/api.go:64-81
    /\ s' = [s EXCEPT !.calls[c].status = "wire"]
\* ACTION SOURCE: service/history/api/updateworkflow/api.go:344-361; tests/update_workflow_test.go
ReceiveUpdateResponse(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:344-361; tests/update_workflow_test.go
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:344-361; tests/update_workflow_test.go
    /\ s.calls[c].status = "wire"
    \* BLOCK SOURCE: service/history/api/updateworkflow/api.go:344-361; tests/update_workflow_test.go
    /\ s' = [s EXCEPT !.observed = @ \cup {[client |-> c, uid |-> s.calls[c].uid,
          stage |-> s.calls[c].reply.stage, result |-> s.calls[c].reply.result]},
         !.calls[c].status = "done",
         !.calls[c].active = s.calls[c].reply.stage # "COMPLETED" /\
             s.calls[c].reply.result.kind \notin {"closedError","taskError"}]
(* ENV response loss after server returned; a retriable call can later readback. *)
\* ACTION SOURCE: tests/update_analysis_commit_test.go; service/history/api/updateworkflow/api.go:272-313
LoseUpdateResponse(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: tests/update_analysis_commit_test.go; service/history/api/updateworkflow/api.go:272-313
    /\ c \in Clients
    \* BLOCK SOURCE: tests/update_analysis_commit_test.go; service/history/api/updateworkflow/api.go:272-313
    /\ s.calls[c].status = "wire"
    \* BLOCK SOURCE: tests/update_analysis_commit_test.go; service/history/api/updateworkflow/api.go:272-313
    /\ s' = [s EXCEPT !.calls[c].status = "done", !.calls[c].reply = Reply("ERROR",RetryError)]
(* API retry guidance in docs/architecture/workflow-update.md, Timeouts;
   update.go:234-239. Polling never recreates volatile ordinary admission. *)
\* ACTION SOURCE: service/history/workflow/update/update.go:234-239; docs/architecture/workflow-update.md
RetryUpdateWorkflowExecution(c) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/workflow/update/update.go:234-239; docs/architecture/workflow-update.md
    /\ c \in Clients
    \* BLOCK SOURCE: service/history/workflow/update/update.go:234-239; docs/architecture/workflow-update.md
    /\ s.calls[c].status = "done" /\ s.calls[c].active
    \* BLOCK SOURCE: service/history/workflow/update/update.go:234-239; docs/architecture/workflow-update.md
    /\ s' = [s EXCEPT !.calls[c].status = "request", !.calls[c].oid = 0,
         !.calls[c].expired = FALSE, !.calls[c].op = IF s.calls[c].reply.stage = "ACCEPTED" THEN "poll" ELSE "update",
         !.calls[c].waitStage = "COMPLETED", !.calls[c].reply = NoReply]

(* SQL execution.go:351-357: database execution call is now in flight.
   Split to distinguish process loss before submitting the execution mutation. *)
\* ACTION SOURCE: common/persistence/sql/execution.go:351-357; common/persistence/cassandra/mutable_state_store.go:715-735
ExecutionTransactionBegin ==
    \* BLOCK SOURCE: common/persistence/sql/execution.go:351-357; common/persistence/cassandra/mutable_state_store.go:715-735
    /\ s.write.state = "appended"
    \* BLOCK SOURCE: common/persistence/sql/execution.go:351-357; common/persistence/cassandra/mutable_state_store.go:715-735
    /\ s' = [s EXCEPT !.write.state = "executing"]
(* ENV process loss, S1. Completed server futures do not imply a client receipt.
   An execution transaction already submitted to the backend may still settle;
   one not submitted cannot execute after its process died. *)
\* ACTION SOURCE: service/history/workflow/context.go:174-185; common/persistence/sql/execution.go:338-357
CrashHistoryProcess ==
    \* BLOCK SOURCE: service/history/workflow/context.go:174-185; common/persistence/sql/execution.go:338-357
    /\ s.ctx.loaded /\ ~s.acquiring
    \* BLOCK SOURCE: service/history/workflow/context.go:174-185; common/persistence/sql/execution.go:338-357
    /\ s' = [s EXCEPT !.ctx.loaded = FALSE, !.ctx.reg = [u \in Updates |-> 0], !.ctx.task = NoTask,
         !.cache[s.ctx.host] = <<>>,
         !.workers = [i \in 1..Len(s.workers) |->
             IF s.workers[i].status \in {"pendingResponse","pendingStart","startResponse"}
             THEN [s.workers[i] EXCEPT !.status = "lost"] ELSE s.workers[i]],
         !.inlineWorker = 0,
         !.timers = [i \in 1..Len(s.timers) |-> IF s.timers[i].speculative
             THEN [s.timers[i] EXCEPT !.cancelled = TRUE, !.consumed = TRUE] ELSE s.timers[i]], !.timerPointer = 0,
         !.effects = <<>>, !.cancels = <<>>, !.active = NoEffect, !.second = "none",
         !.clearTodo = {}, !.batch = <<>>, !.commands = <<>>, !.pc = "idle", !.acquiring = TRUE,
         !.write.state = IF @ \in {"prepared","appended"} THEN "noncommit" ELSE @,
         !.write.returned = TRUE, !.write.error = "processLost",
         !.calls = [c \in Clients |-> IF s.calls[c].status \in {"idle","done","wire"}
            THEN s.calls[c] ELSE [s.calls[c] EXCEPT !.status = "reply", !.reply = Reply("ERROR",RetryError)]]]
(* ENV retry of a lost/late worker RPC retains the ORIGINAL task token. *)
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
DuplicateWorkerCompletion(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status \in {"received","notFound"}
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
    /\ s' = [s EXCEPT !.workers = Append(@,[s.workers[i] EXCEPT !.status = "ready"])]
\* ACTION SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
LoseWorkerCompletion(i) ==
    \* Parameter domains are identical to Next, including direct trace calls.
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
    /\ i \in 1..Len(s.workers)
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
    /\ i \in 1..Len(s.workers) /\ s.workers[i].status = "ready"
    \* BLOCK SOURCE: service/history/api/respondworkflowtaskcompleted/api.go:133-213; tests/update_analysis_identity_test.go
    /\ s' = [s EXCEPT !.workers[i].status = "lost"]

(* Fundamental storage safety, SQL execution_util.go:44-79 and
   mutable_state_impl.go:1544-1588. Physical uncommitted tails are excluded. *)
DurableMetadataReferencesCommittedHistory ==
    \A u \in Updates:
        /\ (s.db.info[u].stage \in {"Accepted","Completed"} =>
              \E e \in SeqSet(s.db.events): e.type = "UpdateAccepted" /\ e.uid = u /\ e.key.eventID = s.db.info[u].acceptedID)
        /\ (s.db.info[u].stage = "Completed" =>
              \E e \in SeqSet(s.db.events): e.type = "UpdateCompleted" /\ e.uid = u /\
                    e.key.eventID = s.db.info[u].eventID /\ e.result = s.db.info[u].result)
NoSpeculativeTaskPersisted == s.db.task.kind # "Speculative"
(* Brief section5 safety properties. Observations are ACTUAL client receipts. *)
AcceptedReceiptHasDurableAcceptance ==
    \A r \in s.observed: r.stage = "ACCEPTED" => s.db.info[r.uid].stage \in {"Accepted","Completed"}
SuccessfulOutcomeMatchesCommittedResult ==
    \A r \in s.observed: r.result.kind = "success" =>
        s.db.info[r.uid].stage = "Completed" /\ r.result = s.db.info[r.uid].result
SuccessfulOutcomesAgree ==
    \A a,b \in s.observed:
        (a.uid = b.uid /\ a.result.kind = "success" /\ b.result.kind = "success") => a.result = b.result
CurrentTaskOwnsAcceptedCompletion ==
    \A a \in s.applied: CompletionMatches(a.token,a.current)
(* Review-analysis medium correction: include durable handler failures.
   Synthetic closing/rejection/RPC errors are NOT persisted worker outcomes. *)
DurableOutcomeMatchesCommittedResult ==
    \A r \in s.observed: r.result.kind \in WorkerKinds =>
        s.db.info[r.uid].stage = "Completed" /\ r.result = s.db.info[r.uid].result
DurableOutcomesAgree ==
    \A a,b \in s.observed:
        (a.uid = b.uid /\ a.result.kind \in WorkerKinds /\ b.result.kind \in WorkerKinds) => a.result = b.result
(* Structural checks, not scenario hunts. *)
RegistryObjectsHaveCurrentGeneration ==
    \A u \in Updates: s.ctx.reg[u] # 0 =>
        s.objects[s.ctx.reg[u]].uid = u /\ s.objects[s.ctx.reg[u]].generation = s.ctx.generation
OutcomeBeforeCombinedAcceptance ==
    \A o \in 1..Len(s.objects): s.objects[o].state = "PCA" => s.objects[o].accepted = "pending"
TypeOK ==
    /\ s.db.next \in Nat /\ s.db.rv \in Nat /\ s.db.range \in Nat
    /\ s.ctx.host \in Hosts /\ s.ctx.generation \in Nat
    /\ s.ctx.loaded \in BOOLEAN /\ s.acquiring \in BOOLEAN
    /\ DOMAIN s.db.info = Updates /\ DOMAIN s.ctx.reg = Updates /\ DOMAIN s.calls = Clients
    /\ \A u \in Updates:
        /\ s.db.info[u].stage \in {"none","Accepted","Completed"}
        /\ s.ctx.reg[u] \in 0..Len(s.objects)
    /\ \A o \in 1..Len(s.objects):
        /\ s.objects[o].uid \in Updates
        /\ s.objects[o].state \in {"Admitted","Sent","PA","Accepted","PC","PCA","PX","Completed","Aborted"}
        /\ s.objects[o].accepted \in {"pending","accepted","rejected","retry","closedError"}
        /\ s.objects[o].callbacks \in BOOLEAN
    /\ s.write.state \in {"none","prepared","appended","executing","committed","noncommit"}
    /\ s.timerPointer \in 0..Len(s.timers)
    /\ \A c \in Clients: s.calls[c].oid \in 0..Len(s.objects)
    /\ s.everRequested \subseteq Updates
    /\ \A c \in Clients:
        /\ s.calls[c].uid \in Updates \cup {None}
        /\ s.calls[c].waitStage \in {"ACCEPTED","COMPLETED"}

(* Conditional liveness goals; MC adds explicit action fairness and finite
   disruption assumptions. There is no claim under arbitrary hostile workers.
   A completed result requires a still-interested caller; no invented polling
   of Updates for which every client has permanently stopped. *)
Obtained(u) == \E r \in s.observed: r.uid = u /\ r.result.kind \in WorkerKinds /\ r.result = s.db.info[u].result
Interested(u) == \E c \in Clients: s.calls[c].uid = u /\ s.calls[c].active
CommittedResultRemainsQueryable ==
    \A u \in Updates: (s.db.info[u].stage = "Completed" /\ Interested(u)) ~> Obtained(u)
Progressed(u) == \E r \in s.observed: r.uid = u /\
    (r.stage = "ACCEPTED" \/ r.stage = "COMPLETED" \/ r.result.kind \in {"closedError","taskError"})
RetriedEligibleUpdateMakesProgress ==
    \A u \in Updates: (u \in s.everRequested /\ Interested(u)) ~> Progressed(u)

Next ==
    \/ \E c \in Clients, u \in Updates, stage \in {"ACCEPTED","COMPLETED"}: UpdateWorkflowExecution(c,u,stage)
    \/ \E c \in Clients: UpdaterApplyRequestNew(c) \/ UpdaterApplyRequestExisting(c) \/ AttachCallbacks(c)
          \/ GetUpdateOutcome(c) \/ RegistryFindMissing(c) \/ WaitLifecycleStageOutcome(c)
          \/ WaitLifecycleStageAccepted(c) \/ WaitLifecycleStageOutcomeRecheck(c)
          \/ WaitLifecycleStageSoftTimeout(c) \/ CreateUpdateResponse(c) \/ ReceiveUpdateResponse(c)
          \/ LoseUpdateResponse(c) \/ RetryUpdateWorkflowExecution(c)
    \/ \E i \in 1..Len(s.dispatch): AddWorkflowTaskToMatching(i) \/ StickyWorkerUnavailable(i)
          \/ (\E delivered \in BOOLEAN: AddWorkflowTaskToMatchingFailed(i,delivered))
    \/ \E i \in 1..Len(s.matching): RecordWorkflowTaskStarted(i) \/ RecordWorkflowTaskStartedNotFound(i)
    \/ \E i \in 1..Len(s.workers):
          \/ (\E u \in Updates: WorkerAcceptance(i,u) \/ WorkerRejection(i,u)
                 \/ (\E k \in WorkerKinds, v \in Values: WorkerResponse(i,u,k,v)))
          \/ WorkerSendCompletion(i) \/ WorkerIgnoreUpdates(i) \/ WorkerCloseWorkflow(i)
          \/ RespondWorkflowTaskCompleted(i) \/ RespondWorkflowTaskCompletedNotFound(i)
          \/ DuplicateWorkerCompletion(i) \/ LoseWorkerCompletion(i) \/ RecordWorkflowTaskStartedReturn(i)
    \/ \E o \in 1..Len(s.objects): RejectUnprocessed(o) \/ AbortAccepted(o)
          \/ RegistryAbortAfterClose(o) \/ RegistryClearAbort(o) \/ ForceTerminateAbort(o)
    \/ \E i \in 1..Len(s.timers): ScheduleToStartTimerEligible(i) \/ StartToCloseTimerEligible(i)
          \/ MemoryScheduledQueueSubmit(i) \/ ExecuteWorkflowTaskTimeoutTask(i) \/ ExecuteWorkflowTaskTimeoutTaskStale(i)
    \/ \E h \in Hosts: AcquireShard(h) \/ RestartHistoryHost(h) \/ (\E i \in 1..Len(s.cache[h]): EvictHostEvent(h,i))
    \/ AddWorkflowTaskScheduledEvent \/ ScheduleNormalWorkflowTask \/ PushWorkflowTask
    \/ CreateRecordWorkflowTaskStartedResponse \/ AddWorkflowTaskCompletedEvent \/ TryResurrect
    \/ OnAcceptanceMsg \/ OnResponseMsg \/ OnRejectionMsg \/ HandleMessageInvalid \/ HandleCommandsDone
    \/ PrepareWorkflowMutation \/ ConvertSpeculativeWorkflowTaskToNormal \/ UpdateWorkflowExecutionWithNew
    \/ AppendHistoryNodes \/ ExecutionTransactionBegin \/ ExecutionTransactionCommit \/ ExecutionTransactionFenced
    \/ ExecutionTransactionNoncommit \/ ExecutionTransactionTimeout \/ AppendHistoryTimeout \/ HandleWriteResult
    \/ BufferApplyFirst \/ BufferApplySecond \/ BufferApplyDone \/ AddSuccessorWorkflowTask \/ StartSuccessorWorkflowTask
    \/ CreateRespondWorkflowTaskCompletedResponse \/ RespondWorkflowTaskCompletedReturn \/ RespondWorkflowTaskCompletedLateError
    \/ ContextClearBegin \/ RegistryClearAbortSecond \/ ContextClearDone \/ BufferCancel \/ BufferCancelDone
    \/ EvictWorkflowContext \/ LoseShardOwnership \/ LoadMutableState \/ ClearStickyTaskQueue \/ CrashHistoryProcess
    \/ TerminateWorkflowExecution \/ TimeoutWorkflowExecution \/ ExternalCloseReturn
    \/ ForceTerminateWorkflow \/ ForceTerminateClear \/ ForceTerminatePersist \/ RestoreHistoryLimit
Spec == Init /\ [][Next]_vars
=============================================================================
