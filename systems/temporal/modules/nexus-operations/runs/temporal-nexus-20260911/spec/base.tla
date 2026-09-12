------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

(***************************************************************************
Category A: one Workflow Run, one cluster, legacy HSM Nexus operations.
Source: temporalio/temporal 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
Source abbreviations in comments:
  nx/ = service/history/hsm/nexusoperations/; wf/ = service/history/workflow/
  hist/ = service/history/; sql/ = common/persistence/sql/
SQLite transaction semantics, including definite failure and uncertain receipt.
The brief's B1 and B2 are preserved, not repaired in this implementation model.

S1: endpoint, calls, messages, replies, observations distinguish effect/knowledge.
S2: child cancellation, transition outputs, actual persisted logical timers.
S3: retained physical node vs terminal history; Ops may contain two identities.
S4: initial HSM identity, task generation, serialized attempt, delayed work.
S5: v is a locked transaction workspace; d is the atomic durable snapshot.
raw stores append receipts, not the committed visible history. queue publication
is atomic with d; notification, response receipt and reload are separate steps.

Every semantic state field is inside s, so vars covers the complete state.
Deleted op fields are a last-transition observation ledger, NOT persisted nodes.
Task sets quotient identical deliveries; DuplicateOutboundTask models extra copies.
Time units represent ordered instants, not seconds; zero duration means absent.
The base has no attempt, message, fault, or time bounds. MC adds fault counters.
***************************************************************************)
CONSTANTS Ops, Capacity, S2C, S2S, STC, RequestTimeout, MinRequestTimeout,
          RetryDelay, StartModes, RemoteResults
VARIABLE s
vars == <<s>>

Terminal == {"Succeeded", "Failed", "Canceled", "TimedOut"}
Active == {"Scheduled", "BackingOff", "Started"}
TaskKinds == {"Invoke", "Backoff", "S2C", "S2S", "STC", "Cancel", "CancelBackoff", "Wake"}
Min(a,b) == IF a < b THEN a ELSE b
Max(a,b) == IF a > b THEN a ELSE b
Elems(q) == {q[i] : i \in 1..Len(q)}
Event(o,k) == [op |-> o, kind |-> k, rid |-> o]
TerminalEvents(d,o) == SelectSeq(d.history \o d.buffer,
                                LAMBDA e: e.op = o /\ e.kind \in Terminal)
Live(d,o) == d.open /\ d.ops[o].node /\ d.ops[o].state \in Active
NodeCount(d) == Cardinality({o \in Ops : d.ops[o].node})
PendingCount(d) == Cardinality({o \in Ops : Live(d,o)})

\* nx/statemachine.go:91-95,128-181,428-449,537-555; S1-S4.
EmptyOp == [node |-> FALSE, state |-> "Absent", rid |-> "", token |-> "",
            initial |-> 0, attempt |-> 0, scheduled |-> 0, started |-> 0,
            next |-> 0, cancel |-> "Absent", cancelAttempt |-> 0, cancelInitial |-> 0,
            cancelNext |-> 0, cancelRequested |-> FALSE]
EmptyDB == [ops |-> [o \in Ops |-> EmptyOp], history |-> <<>>, buffer |-> <<>>,
            timers |-> {}, wakeScheduled |-> {}, open |-> TRUE, wft |-> "Idle", version |-> 0, gen |-> 0]
EmptyTask == [op |-> "", kind |-> "Wake", initial |-> 0, attempt |-> 0,
              gen |-> 0, at |-> 0, origin |-> 0, copy |-> 0]
EmptyTx == [phase |-> "Idle", source |-> "", op |-> "", work |-> 0,
            ticket |-> EmptyTask, expected |-> 0, range |-> 0,
            emitted |-> {}, wakes |-> {}, deleted |-> {}, cutoff |-> 0, processed |-> 0,
            consumed |-> {},
            outcome |-> "", trigger |-> FALSE]
EmptyRemote == [accepted |-> FALSE, mode |-> "", token |-> "",
                outcome |-> "", started |-> 0, cancelSeen |-> FALSE]

\* wf/task_generator.go:965-1002; initial identity and serialized Attempt differ.
Task(d,o,k,at) == [op |-> o, kind |-> k, initial |-> IF k \in {"Cancel","CancelBackoff"}
                                  THEN d.ops[o].cancelInitial ELSE d.ops[o].initial,
                   attempt |-> IF k \in {"Cancel","CancelBackoff"}
                              THEN d.ops[o].cancelAttempt ELSE d.ops[o].attempt,
                   gen |-> d.gen, at |-> at, origin |-> d.version + 1, copy |-> 0]
\* nx/tasks.go:50-66,98-103,143-148,179-184,224-229,261-283,315-333.
\* No serialized Attempt equality and no deadline equality in these validators.
Eligible(d,t) ==
    /\ t.op \in Ops
    /\ d.open /\ d.ops[t.op].node
    /\ t.initial = IF t.kind \in {"Cancel","CancelBackoff"}
                    THEN d.ops[t.op].cancelInitial ELSE d.ops[t.op].initial
    /\ CASE t.kind = "Invoke" -> d.ops[t.op].state = "Scheduled"
         [] t.kind = "Backoff" -> d.ops[t.op].state = "BackingOff"
         [] t.kind = "S2C" -> d.ops[t.op].state \in Active
         [] t.kind = "S2S" -> d.ops[t.op].state \in {"Scheduled","BackingOff"}
         [] t.kind = "STC" -> d.ops[t.op].state = "Started"
         [] t.kind = "Cancel" -> d.ops[t.op].cancel = "Scheduled"
         [] t.kind = "CancelBackoff" -> d.ops[t.op].cancel = "BackingOff"
         [] OTHER -> FALSE
\* hist/ndc_task_util.go:235-255; timer inner refs and callbacks have TaskID=0.
OutboundValid(d,t) == t.gen >= d.gen /\ Eligible(d,t)
\* nx/statemachine.go:140-169; zero duration suppresses creation.
Creation(d,o) ==
    (IF S2C > 0 THEN {Task(d,o,"S2C",d.ops[o].scheduled + S2C)} ELSE {})
    \cup (IF S2S > 0 THEN {Task(d,o,"S2S",d.ops[o].scheduled + S2S)} ELSE {})
StartTimer(d,o) ==
    IF STC > 0 /\ d.ops[o].started > 0
    THEN {Task(d,o,"STC",d.ops[o].started + STC)} ELSE {}
\* nx/statemachine.go:128-137,172-181,543-555; filter is applied at publication.
Regenerate(d,o) ==
    Creation(d,o) \cup StartTimer(d,o)
    \cup (CASE d.ops[o].state = "Scheduled" -> {Task(d,o,"Invoke",0)}
            [] d.ops[o].state = "BackingOff" -> {Task(d,o,"Backoff",d.ops[o].next)}
            [] OTHER -> {})
    \cup (CASE d.ops[o].cancel = "Scheduled" -> {Task(d,o,"Cancel",0)}
            [] d.ops[o].cancel = "BackingOff" -> {Task(d,o,"CancelBackoff",d.ops[o].cancelNext)}
            [] OTHER -> {})
\* wf/task_generator.go:333; state_machine_timers.go:AddNextStateMachineTimerTask.
Wake(d) ==
    IF d.timers = {} THEN {} ELSE
    LET at == CHOOSE n \in {t.at : t \in d.timers} : \A t \in d.timers : n <= t.at
    IN IF at \in d.wakeScheduled THEN {}
       ELSE {[EmptyTask EXCEPT !.at = at, !.gen = d.gen, !.origin = d.version + 1]}

\* hist/historybuilder/event_store.go:161-199; command events precede the buffer.
AddEvents(d,ev,command) ==
    IF ~command
    THEN [d EXCEPT !.buffer = @ \o ev]
    ELSE [d EXCEPT !.history = @ \o ev]
FinishWFT(d) == [d EXCEPT !.wft = "Idle"]
\* historybuilder/event_store.go:Finish and mutable_state_impl.go:prepareEvents
\* flush bufferable events at transaction close when no WFT is started.
FlushEvents(d) ==
    IF d.wft = "Started" THEN d
    ELSE [d EXCEPT !.history = @ \o d.buffer, !.buffer = <<>>]
\* nx/statemachine.go:364-389; the caller decides whether STC is emitted.
Started(d,o,tok,ts) ==
    [d EXCEPT !.ops[o].state = "Started", !.ops[o].token = tok,
              !.ops[o].started = ts, !.ops[o].attempt = @ + 1,
              !.ops[o].cancel = IF @ = "Unspecified" THEN "Scheduled" ELSE @]
\* nx/events.go:164-175,193-205,228-242; timeout executor does NOT use this helper.
Completed(d,o,result) == [d EXCEPT !.ops[o].state = result, !.ops[o].node = FALSE]
\* hist/statemachine_environment.go:363-410; a workflow write holds the lock.
Ready == s.cache /\ s.shard = "Ready" /\ s.tx.phase = "Idle"
Tx(source,o,work,ticket) ==
    [EmptyTx EXCEPT !.phase = "Mutated", !.source = source, !.op = o,
                   !.work = work, !.ticket = ticket,
                   !.expected = s.d.version, !.range = s.range]
\* nx/executors.go:223-233,287-289,715-749; normalized timeouts are inputs.
StartBudget(d,o) ==
    IF S2S > 0 THEN Min(RequestTimeout, d.ops[o].scheduled + S2S - s.now)
    ELSE IF S2C > 0 THEN Min(RequestTimeout, d.ops[o].scheduled + S2C - s.now)
    ELSE RequestTimeout
CancelBudget(d,o) ==
    Min(IF STC > 0 THEN Min(RequestTimeout,d.ops[o].started + STC - s.now)
        ELSE RequestTimeout,
        IF S2C > 0 THEN d.ops[o].scheduled + S2C - s.now ELSE RequestTimeout)
Message(kind,id,o,rid,tok,initial,result) ==
    [kind |-> kind, id |-> id, op |-> o, rid |-> rid, token |-> tok,
     initial |-> initial, result |-> result]
Reply(id,o,result,status) == [id |-> id, op |-> o, result |-> result, status |-> status]

Init ==
    \* Begin after the first normal WFT has started, before its schedule command.
    \* All 21 implementation bootstrap DB readbacks observe this boundary.
    s = [d |-> [EmptyDB EXCEPT !.wft = "Started"],
         v |-> [EmptyDB EXCEPT !.wft = "Started"], tx |-> EmptyTx,
         cache |-> TRUE, shard |-> "Ready", range |-> 1, now |-> 1,
         queue |-> {}, published |-> {}, calls |-> <<>>, messages |-> {},
         remote |-> [o \in Ops |-> EmptyRemote], callbackSeq |-> 0,
         replies |-> {}, observed |-> {}, raw |-> <<>>, notified |-> {},
         sealed |-> [o \in Ops |-> {}], admission |-> "", readback |-> 0]

HandleScheduleCommand(o) ==
    \* nx/workflow/commands.go:184-241; fixed valid command/endpoint, capacity first.
    /\ Ready /\ s.d.open /\ s.d.ops[o].state = "Absent"
    /\ NodeCount(s.d) < Capacity
    /\ LET op == [EmptyOp EXCEPT !.node = TRUE, !.state = "Scheduled", !.rid = o,
                                 !.initial = s.d.version + 1, !.scheduled = s.now]
           d1 == [s.d EXCEPT !.ops[o] = op]
           d2 == FinishWFT(AddEvents(d1,<<Event(o,"Scheduled")>>,TRUE))
       IN s' = [s EXCEPT !.v = d2, !.admission = "Accepted",
                         !.tx = [Tx("Schedule",o,0,EmptyTask) EXCEPT
                           !.emitted = Creation(d2,o) \cup {Task(d2,o,"Invoke",0)}]]

HandleScheduleCommandLimit(o) ==
    \* nx/workflow/commands.go:184-191; failure is observed, no operation is created.
    /\ Ready /\ s.d.open /\ s.d.ops[o].state = "Absent"
    /\ NodeCount(s.d) >= Capacity /\ s.admission /= "LimitExceeded"
    /\ s' = [s EXCEPT !.admission = "LimitExceeded"]

HandleCancelCommand(o) ==
    \* nx/workflow/commands.go:259-299; buffered terminal makes a late command legal.
    /\ Ready /\ s.d.open /\ ~s.d.ops[o].cancelRequested
    /\ Live(s.d,o) \/ (\E e \in Elems(s.d.buffer): e.op = o /\ e.kind \in Terminal)
    /\ LET d1 == [s.d EXCEPT !.ops[o].cancelRequested = TRUE,
                    !.ops[o].cancelInitial = IF s.d.ops[o].node THEN s.d.version + 1 ELSE @,
                    !.ops[o].cancel = IF ~s.d.ops[o].node THEN @
                      ELSE IF s.d.ops[o].state = "Started" THEN "Scheduled"
                      ELSE "Unspecified"]
           d2 == FinishWFT(AddEvents(d1,<<Event(o,"CancelRequested")>>,TRUE))
       \* nx/statemachine.go:428-449; missing node is ignored at commands.go:318-320.
       IN s' = [s EXCEPT !.v = d2,
                    !.tx = [Tx("CancelCommand",o,0,EmptyTask) EXCEPT
                        !.emitted = IF d2.ops[o].cancel = "Scheduled"
                                    THEN {Task(d2,o,"Cancel",0)} ELSE {}]]

loadOperationArgs(t) ==
    \* nx/executors.go:364-408; locked validated read, no Attempt increment.
    /\ Ready /\ t \in s.queue /\ t.kind = "Invoke" /\ OutboundValid(s.d,t)
    /\ ~\E c \in Elems(s.calls): c.task = t /\ c.phase /= "Done"
    /\ s' = [s EXCEPT !.calls = Append(@,
         [op |-> t.op, rid |-> s.d.ops[t.op].rid, token |-> "",
          initial |-> t.initial, task |-> t, phase |-> "Loaded", result |-> "",
          budget |-> 0])]

executeInvocationTask(i) ==
    \* nx/executors.go:261-311; unlocked call can follow terminal local completion.
    /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Loaded"
    /\ s.calls[i].task.kind = "Invoke" /\ StartBudget(s.d,s.calls[i].op) >= MinRequestTimeout
    /\ LET c == s.calls[i] IN
       s' = [s EXCEPT !.calls[i].budget = StartBudget(s.d,s.calls[i].op), !.calls[i].phase = "Waiting",
              !.messages = @ \cup {Message("StartRequest",i,c.op,c.rid,"",c.initial,"")}]

executeInvocationTaskBelowMin(i) ==
    \* nx/executors.go:287-289,554-556; no endpoint call, timeout through saveResult.
    /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Loaded"
    /\ s.calls[i].task.kind = "Invoke" /\ StartBudget(s.d,s.calls[i].op) < MinRequestTimeout
    /\ s' = [s EXCEPT !.calls[i].budget = StartBudget(s.d,s.calls[i].op), !.calls[i].phase = "Received", !.calls[i].result = "BelowMin"]

EndpointAccept(m,mode) ==
    \* S1 endpoint contract at nx/executors.go:261-268,311. Environment assumption:
    \* stable request-ID dedup, stable async token and retained response semantics.
    /\ m \in s.messages /\ m.kind = "StartRequest" /\ mode \in StartModes
    /\ LET old == s.remote[m.op]
           r == IF old.accepted THEN old ELSE
                [old EXCEPT !.accepted = TRUE, !.mode = mode,
                   !.token = IF mode = "Async" THEN m.rid ELSE "",
                   !.outcome = IF mode = "Async" THEN "Pending" ELSE mode,
                   !.started = s.now]
           result == IF r.mode = "Async" THEN "Async" ELSE r.mode
       IN s' = [s EXCEPT !.remote[m.op] = r,
                 !.messages = (@ \ {m}) \cup
                   {Message("StartResponse",m.id,m.op,m.rid,r.token,m.initial,result)}]

EndpointStartFailure(m,result) ==
    \* nx/executors.go:534-575; remote retry/refusal before acceptance is a fault.
    /\ m \in s.messages /\ m.kind = "StartRequest"
    /\ ~s.remote[m.op].accepted /\ result \in {"Retryable","Refused"}
    /\ s' = [s EXCEPT !.messages = (@ \ {m}) \cup
          {Message("StartResponse",m.id,m.op,m.rid,"",m.initial,result)}]

ReceiveStartResponse(m) ==
    \* nx/executors.go:311-339; receipt precedes a new write-side validation.
    /\ m \in s.messages /\ m.kind = "StartResponse"
    /\ s.calls[m.id].phase = "Waiting"
    /\ s' = [s EXCEPT !.messages = @ \ {m}, !.calls[m.id].phase = "Received",
                       !.calls[m.id].result = m.result, !.calls[m.id].token = m.token]

LoseResponse(m) ==
    \* S1 transport fault across nx/executors.go:311,783 and callback response.
    /\ m \in s.messages /\ m.kind \in {"StartResponse","CancelResponse"}
    /\ s' = [s EXCEPT !.messages = @ \ {m}]

RequestDeadlineExceeded(i) ==
    \* nx/executors.go:256-257,557-559,726-727; request may still be accepted later.
    /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Waiting"
    /\ s' = [s EXCEPT !.calls[i].phase = "Received", !.calls[i].result = "Retryable"]

DiscardLateResponse(m) ==
    \* nx/executors.go:256-257,726-727; closed call context cannot receive a result.
    /\ m \in s.messages /\ m.kind \in {"StartResponse","CancelResponse"}
    /\ s.calls[m.id].phase /= "Waiting"
    /\ s' = [s EXCEPT !.messages = @ \ {m}]

saveStartedResult(i) ==
    \* nx/executors.go:416-425,452-480; InvocationTask.Validate is rechecked.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].result = "Async" /\ OutboundValid(s.d,s.calls[i].task)
    /\ LET o == s.calls[i].op
           d1 == Started(s.d,o,s.calls[i].token,s.now)
           d2 == AddEvents(d1,<<Event(o,"Started")>>,FALSE)
       \* nx/statemachine.go:378-398; preserve the early return (B1).
       IN s' = [s EXCEPT !.v = d2, !.calls[i].phase = "Saving",
                 !.tx = [Tx("Start",o,i,s.calls[i].task) EXCEPT !.trigger = TRUE,
                    !.emitted = IF s.d.ops[o].cancel /= "Absent"
                                THEN {Task(d2,o,"Cancel",0)} ELSE StartTimer(d2,o)]]

handleStartOperationErrorRetryable(i) ==
    \* nx/executors.go:528-575; attempt increments on committed retryable failure.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Invoke" /\ s.calls[i].result = "Retryable"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ LET o == s.calls[i].op
           d1 == [s.d EXCEPT !.ops[o].state = "BackingOff",
                     !.ops[o].attempt = @ + 1, !.ops[o].next = s.now + RetryDelay]
       IN s' = [s EXCEPT !.v = d1, !.calls[i].phase = "Saving",
                !.tx = [Tx("Start",o,i,s.calls[i].task) EXCEPT
                        !.emitted = {Task(d1,o,"Backoff",d1.ops[o].next)}]]

\* Shared update expression, not a transition: callers retain distinct implementation branches.
TerminalCallUpdate(i,result,retain) ==
    LET o == s.calls[i].op
        d1 == IF retain THEN [s.d EXCEPT !.ops[o].state = result]
              ELSE Completed(s.d,o,result)
        d2 == AddEvents(d1,<<Event(o,result)>>,FALSE)
    IN [s EXCEPT !.v = d2, !.calls[i].phase = "Saving",
          !.tx = [Tx("Start",o,i,s.calls[i].task) EXCEPT !.trigger = TRUE,
                   !.deleted = IF retain THEN {} ELSE {o}]]

saveResultSucceeded(i) ==
    \* nx/executors.go:426-429; nx/completion.go:23-43; nx/events.go:164-175.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Invoke" /\ s.calls[i].result = "Succeeded"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ s' = TerminalCallUpdate(i,"Succeeded",FALSE)

handleOperationErrorFailed(i) ==
    \* nx/executors.go:540-541; nx/completion.go:75-89; nx/events.go:193-205.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Invoke" /\ s.calls[i].result = "Failed"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ s' = TerminalCallUpdate(i,"Failed",FALSE)

handleOperationErrorCanceled(i) ==
    \* nx/executors.go:540-541; nx/completion.go:90-114; nx/events.go:228-242.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Invoke" /\ s.calls[i].result = "Canceled"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ s' = TerminalCallUpdate(i,"Canceled",FALSE)

handleNonRetryableStartOperationError(i) ==
    \* nx/executors.go:542-553,578-603; nx/events.go:193-205.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Invoke" /\ s.calls[i].result = "Refused"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ s' = TerminalCallUpdate(i,"Failed",FALSE)

handleStartOperationErrorBelowMin(i) ==
    \* nx/executors.go:554-556,645-676; preserve retained timeout node (B2).
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Invoke" /\ s.calls[i].result = "BelowMin"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ s' = TerminalCallUpdate(i,"TimedOut",TRUE)

RejectStaleCall(i) ==
    \* hist/statemachine_environment.go:230-288; nx/executors.go:829-832 on cancel read.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ ~OutboundValid(s.d,s.calls[i].task)
    /\ s' = [s EXCEPT !.calls[i].phase = "Done", !.queue = @ \ {s.calls[i].task}]

EndpointComplete(o,result) ==
    \* S1 environment of nx/completion.go:181-223; cancel ACK does not determine result.
    /\ s.remote[o].accepted /\ s.remote[o].mode = "Async"
    /\ s.remote[o].outcome = "Pending" /\ result \in RemoteResults
    /\ s' = [s EXCEPT !.remote[o].outcome = result]

SendCompletionCallback(o) ==
    \* nx/executors.go:202-218; callback has stable initial identity, no attempt fence.
    /\ s.remote[o].mode = "Async" /\ s.remote[o].outcome \in Terminal
    /\ LET i == s.callbackSeq + 1
           initial == CHOOSE c \in Elems(s.calls): c.op = o /\ c.task.kind = "Invoke"
       IN s' = [s EXCEPT !.callbackSeq = i,
                 !.messages = @ \cup {Message("Callback",i,o,o,s.remote[o].token,
                                               initial.initial,s.remote[o].outcome)}]

CompletionHandlerHandle(m) ==
    \* nx/completion.go:199-223; callback fabricates Started before terminal processing.
    /\ Ready /\ m \in s.messages /\ m.kind = "Callback" /\ Live(s.d,m.op)
    /\ m.initial = s.d.ops[m.op].initial /\ m.rid = s.d.ops[m.op].rid
    /\ LET o == m.op
           fabricate == s.d.ops[o].state \in {"Scheduled","BackingOff"}
           d1 == IF fabricate THEN Started(s.d,o,m.token,s.remote[o].started) ELSE s.d
           ev == (IF fabricate THEN <<Event(o,"Started")>> ELSE <<>>) \o <<Event(o,m.result)>>
           d2 == AddEvents(Completed(d1,o,m.result),ev,FALSE)
       \* nx/events.go:164-175,193-205,228-242; deleted outputs filtered at close.
       IN s' = [s EXCEPT !.v = d2, !.messages = @ \ {m},
                  !.tx = [Tx("Callback",o,m.id,EmptyTask) EXCEPT
                            !.trigger = TRUE, !.deleted = {o}]]

CompletionHandlerReject(m) ==
    \* nx/completion.go:200-217,224-250; same-run fallback can end in NotFound.
    /\ Ready /\ m \in s.messages /\ m.kind = "Callback"
    /\ ~Live(s.d,m.op) \/ m.initial /= s.d.ops[m.op].initial \/ m.rid /= s.d.ops[m.op].rid
    /\ s' = [s EXCEPT !.messages = @ \ {m},
                  !.replies = @ \cup {Reply(m.id,m.op,m.result,"NotFound")}]

loadArgsForCancelation(t) ==
    \* nx/executors.go:823-859; child validation AND parent terminal check on read.
    /\ Ready /\ t \in s.queue /\ t.kind = "Cancel" /\ OutboundValid(s.d,t)
    /\ Live(s.d,t.op)
    /\ ~\E c \in Elems(s.calls): c.task = t /\ c.phase /= "Done"
    /\ s' = [s EXCEPT !.calls = Append(@,
          [op |-> t.op, rid |-> s.d.ops[t.op].rid, token |-> s.d.ops[t.op].token,
           initial |-> t.initial, task |-> t, phase |-> "Loaded", result |-> "",
           budget |-> 0])]

executeCancelationTask(i) ==
    \* nx/executors.go:745-783; unlocked cancel uses the token captured by read.
    /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Loaded"
    /\ s.calls[i].task.kind = "Cancel" /\ CancelBudget(s.d,s.calls[i].op) >= MinRequestTimeout
    /\ LET c == s.calls[i] IN
       s' = [s EXCEPT !.calls[i].budget = CancelBudget(s.d,s.calls[i].op), !.calls[i].phase = "Waiting",
                !.messages = @ \cup {Message("CancelRequest",i,c.op,c.rid,c.token,c.initial,"")}]

executeCancelationTaskBelowMin(i) ==
    \* nx/executors.go:747-749,869-893; child fails, parent is not timed out here.
    /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Loaded"
    /\ s.calls[i].task.kind = "Cancel" /\ CancelBudget(s.d,s.calls[i].op) < MinRequestTimeout
    /\ s' = [s EXCEPT !.calls[i].budget = CancelBudget(s.d,s.calls[i].op), !.calls[i].phase = "Received", !.calls[i].result = "Refused"]

EndpointCancelAck(m) ==
    \* nx/executors.go:783,902-904; accepting cancellation need not cancel the operation.
    /\ m \in s.messages /\ m.kind = "CancelRequest"
    /\ s.remote[m.op].accepted /\ m.token = s.remote[m.op].token
    /\ s' = [s EXCEPT !.remote[m.op].cancelSeen = TRUE,
           !.messages = (@ \ {m}) \cup
                    {Message("CancelResponse",m.id,m.op,m.rid,m.token,m.initial,"Ack")}]

EndpointCancelFailure(m,result) ==
    \* nx/executors.go:866-900; remote refusal/retry is independent of parent completion.
    /\ m \in s.messages /\ m.kind = "CancelRequest" /\ result \in {"Refused","Retryable"}
    /\ s' = [s EXCEPT !.messages = (@ \ {m}) \cup
               {Message("CancelResponse",m.id,m.op,m.rid,m.token,m.initial,result)}]

ReceiveCancelResponse(m) ==
    \* nx/executors.go:783-801; saveCancelationResult will reacquire the lock.
    /\ m \in s.messages /\ m.kind = "CancelResponse" /\ s.calls[m.id].phase = "Waiting"
    /\ s' = [s EXCEPT !.messages = @ \ {m}, !.calls[m.id].phase = "Received",
                       !.calls[m.id].result = m.result]

saveCancelationResultAck(i) ==
    \* nx/executors.go:864-865,902-921; revalidate child, ACK event flag is enabled.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Cancel" /\ s.calls[i].result = "Ack"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ LET o == s.calls[i].op
           d1 == [s.d EXCEPT !.ops[o].cancel = "Succeeded", !.ops[o].cancelAttempt = @ + 1]
           d2 == AddEvents(d1,<<Event(o,"CancelAck")>>,FALSE)
       \* No parent terminal guard is invented for the WRITE: timeout can retain child.
       IN s' = [s EXCEPT !.v = d2, !.calls[i].phase = "Saving",
                !.tx = [Tx("Cancel",o,i,s.calls[i].task) EXCEPT !.trigger = TRUE]]

saveCancelationResultFailed(i) ==
    \* nx/executors.go:869-893; permanent failure produces an ACK-failure history event.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Cancel" /\ s.calls[i].result = "Refused"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ LET o == s.calls[i].op
           d1 == [s.d EXCEPT !.ops[o].cancel = "Failed", !.ops[o].cancelAttempt = @ + 1]
           d2 == AddEvents(d1,<<Event(o,"CancelFailed")>>,FALSE)
       IN s' = [s EXCEPT !.v = d2, !.calls[i].phase = "Saving",
                !.tx = [Tx("Cancel",o,i,s.calls[i].task) EXCEPT !.trigger = TRUE]]

saveCancelationResultRetryable(i) ==
    \* nx/executors.go:895-900; nx/statemachine.go:626-637.
    /\ Ready /\ i \in 1..Len(s.calls) /\ s.calls[i].phase = "Received"
    /\ s.calls[i].task.kind = "Cancel" /\ s.calls[i].result = "Retryable"
    /\ OutboundValid(s.d,s.calls[i].task)
    /\ LET o == s.calls[i].op
           d1 == [s.d EXCEPT !.ops[o].cancel = "BackingOff",
                    !.ops[o].cancelAttempt = @ + 1, !.ops[o].cancelNext = s.now + RetryDelay]
       IN s' = [s EXCEPT !.v = d1, !.calls[i].phase = "Saving",
                !.tx = [Tx("Cancel",o,i,s.calls[i].task) EXCEPT
                       !.emitted = {Task(d1,o,"CancelBackoff",d1.ops[o].cancelNext)}]]

executeStateMachineTimerTask(w) ==
    \* hist/timer_queue_active_task_executor.go:861-891; lock covers the whole batch.
    /\ Ready /\ w \in s.queue /\ w.kind = "Wake" /\ w.at <= s.now /\ w.gen >= s.d.gen
    /\ s' = [s EXCEPT !.v = s.d,
                 !.tx = [Tx("Timer","",0,w) EXCEPT !.phase = "Timers", !.cutoff = s.now]]

NextTimer(t) ==
    \* hist/timer_queue_task_executor_base.go:306-317; earliest persisted logical group.
    /\ s.tx.phase = "Timers" /\ t \in s.v.timers \ s.tx.consumed
    /\ t.at <= Max(s.now,s.tx.cutoff)
    /\ \A u \in s.v.timers \ s.tx.consumed: t.at <= u.at

executeBackoffTask(t) ==
    \* nx/executors.go:606-611; timer batch does not publish new invocation yet.
    /\ NextTimer(t) /\ t.kind = "Backoff" /\ Eligible(s.v,t)
    /\ LET o == t.op
           d1 == [s.v EXCEPT !.ops[o].state = "Scheduled", !.ops[o].next = 0]
       IN s' = [s EXCEPT !.v = d1, !.tx.emitted = @ \cup {Task(d1,o,"Invoke",0)},
                         !.tx.consumed = @ \cup {t},
                         !.tx.processed = @ + 1]

executeCancelationBackoffTask(t) ==
    \* nx/executors.go:926-931; parent terminal status is not a child validator fence.
    /\ NextTimer(t) /\ t.kind = "CancelBackoff" /\ Eligible(s.v,t)
    /\ LET o == t.op
           d1 == [s.v EXCEPT !.ops[o].cancel = "Scheduled", !.ops[o].cancelNext = 0]
       IN s' = [s EXCEPT !.v = d1, !.tx.emitted = @ \cup {Task(d1,o,"Cancel",0)},
                         !.tx.consumed = @ \cup {t},
                         !.tx.processed = @ + 1]

executeOperationTimeout(t) ==
    \* nx/executors.go:614-676; typed S2C/S2S/STC validators are in Eligible.
    /\ NextTimer(t) /\ t.kind \in {"S2C","S2S","STC"} /\ Eligible(s.v,t)
    /\ LET d1 == [s.v EXCEPT !.ops[t.op].state = "TimedOut"]
       \* No DeleteChild at executors.go:673-676: retained node reproduces B2.
       IN s' = [s EXCEPT !.v = AddEvents(d1,<<Event(t.op,"TimedOut")>>,FALSE),
                         !.tx.consumed = @ \cup {t},
                         !.tx.trigger = TRUE, !.tx.processed = @ + 1]

SkipStaleTimer(t) ==
    \* hist/timer_queue_task_executor_base.go:317-340; stale ref/closed run skipped.
    /\ NextTimer(t) /\ ~Eligible(s.v,t)
    /\ s' = [s EXCEPT !.tx.consumed = @ \cup {t}, !.tx.processed = @ + 1]

FinishStateMachineTimers ==
    \* hist/timer_queue_task_executor_base.go:343-347; end batch before one commit.
    /\ s.tx.phase = "Timers"
    /\ ~\E t \in s.v.timers \ s.tx.consumed: t.at <= Max(s.now,s.tx.cutoff)
    /\ s' = IF s.tx.processed > 0 THEN
                [s EXCEPT !.tx.phase = "Mutated", !.v.timers = @ \ s.tx.consumed,
                    !.v.wakeScheduled = @ \cap {t.at : t \in s.v.timers \ s.tx.consumed}]
            ELSE [s EXCEPT !.tx = EmptyTx, !.v = s.d, !.queue = @ \ {s.tx.ticket}]

GenerateDirtySubStateMachineTasks ==
    \* wf/task_generator.go:297-333,976-1002; filter outputs against FINAL node state.
    /\ s.tx.phase = "Mutated"
    /\ LET closed == FlushEvents(s.v)
           emitted == {t \in s.tx.emitted: Eligible(closed,t)}
           fresh == {t \in emitted: t.kind \notin {"Invoke","Cancel"}}
           timers == {u \in s.v.timers: u.op \notin s.tx.deleted /\
                       ~\E t \in fresh: t.op = u.op /\ t.kind = u.kind /\ t.at = u.at} \cup fresh
           d1 == [closed EXCEPT !.timers = timers,
                     !.wakeScheduled = @ \cap {t.at : t \in timers},
                     !.wft = IF s.tx.trigger /\ s.v.open /\ @ /= "Started" THEN "Pending" ELSE @]
           wakes == Wake(d1)
           d2 == [d1 EXCEPT !.wakeScheduled = @ \cup {w.at : w \in wakes}]
       \* wf/state_machine_timers.go:18-40,47-69: publish only unscheduled first group.
       IN s' = [s EXCEPT !.v = d2, !.tx.emitted = emitted,
                          !.tx.wakes = @ \cup wakes,
                          !.tx.phase = "Prepared"]

AppendHistoryNodes ==
    \* sql/execution.go:338-348; raw append is outside the mutable-state transaction.
    /\ s.tx.phase = "Prepared"
    /\ s' = [s EXCEPT !.raw = IF s.v.history = s.d.history THEN @ ELSE Append(@,s.v.history), !.tx.phase = "Appended"]

WriteCondition == s.tx.expected = s.d.version /\ s.tx.range = s.range /\ s.shard = "Ready"
Committed(outcome) == outcome \in {"Success","UnknownCommitted"}
PossiblySucceeded(outcome) == outcome \in {"Success","UnknownCommitted","UnknownNotCommitted"}

UpdateWorkflowExecution(outcome) ==
    \* sql/execution.go:350-357; sql/execution_util.go:44-82,155-175,629-664.
    /\ (s.tx.phase = "Appended"
         \/ (s.tx.phase = "Prepared" /\ outcome = "DefiniteFailure"))
    /\ WriteCondition
    /\ outcome \in {"Success","DefiniteFailure","UnknownCommitted","UnknownNotCommitted"}
    /\ LET commit == Committed(outcome)
           d1 == [s.v EXCEPT !.version = s.d.version + 1]
           pub == {t \in s.tx.emitted: t.kind \in {"Invoke","Cancel"}} \cup s.tx.wakes
       \* Atomic d/timer/buffer/task publication; error receipt is NOT a noncommit oracle.
       IN s' = [s EXCEPT !.d = IF commit THEN d1 ELSE @,
                 !.queue = IF commit THEN @ \cup pub ELSE @,
                 !.published = IF commit THEN @ \cup pub ELSE @,
                 !.sealed = IF commit THEN [o \in Ops |-> s.sealed[o] \cup
                      {e.kind : e \in Elems(TerminalEvents(d1,o))}] ELSE @,
                 !.tx.outcome = outcome, !.tx.phase = "Written"]

ConditionalWriteRejected ==
    \* sql/execution_util.go:629-664; shard range and DB-record checks reject old writers.
    /\ s.tx.phase = "Appended" /\ ~WriteCondition
    /\ s' = [s EXCEPT !.tx.outcome = "DefiniteFailure", !.tx.phase = "Written"]

NotifyOnExecutionMutation ==
    \* wf/transaction_impl.go:201-206; notifications can accompany a noncommitted unknown.
    /\ s.tx.phase = "Written"
    /\ s' = [s EXCEPT !.tx.phase = "Notified",
          !.notified = IF PossiblySucceeded(s.tx.outcome)
                         THEN @ \cup {[version |-> s.tx.expected + 1, source |-> s.tx.source]}
                         ELSE @]

AccessReturn ==
    \* hist/statemachine_environment.go:380-410; nx/completion.go:249-255.
    /\ s.tx.phase = "Notified"
    /\ LET good == s.tx.outcome = "Success"
           isCall == s.tx.source \in {"Start","Cancel"}
           isCB == s.tx.source = "Callback"
           result == IF isCB THEN s.v.ops[s.tx.op].state ELSE ""
           unknown == s.tx.outcome \in {"UnknownCommitted","UnknownNotCommitted"}
       \* hist/shard/context_impl.go:1530-1548; uncertain writes require reacquisition.
       IN s' = [s EXCEPT !.tx = EmptyTx, !.v = s.d,
                    !.cache = good /\ s.shard = "Ready",
                    !.shard = IF unknown THEN "Lost" ELSE @,
                    !.calls = IF isCall THEN [@ EXCEPT ![s.tx.work].phase = "Done"] ELSE @,
                    !.queue = IF good THEN @ \ {s.tx.ticket} ELSE @,
                    !.replies = IF isCB THEN @ \cup
                         {Reply(s.tx.work,s.tx.op,result,IF good THEN "Accepted" ELSE "Error")}
                         ELSE @]

ReceiveCompletionReply(r) ==
    \* nx/completion.go:249-255; independent caller receipt, not just server return.
    /\ r \in s.replies
    /\ s' = [s EXCEPT !.replies = @ \ {r}, !.observed = @ \cup {r}]

LoseCompletionReply(r) ==
    \* S1/S5 transport loss after CompletionHandler.Handle returned.
    /\ r \in s.replies
    /\ s' = [s EXCEPT !.replies = @ \ {r}]

CacheLoss ==
    \* hist/statemachine_environment.go:203-219; ordinary eviction changes no DB fields.
    /\ s.tx.phase = "Idle" /\ s.cache
    /\ s' = [s EXCEPT !.cache = FALSE, !.v = EmptyDB]

LoseShard ==
    \* hist/shard/context_impl.go:1534-1547; ownership can change with a write in flight.
    /\ s.shard = "Ready"
    /\ s' = [s EXCEPT !.shard = "Lost", !.cache = FALSE]

ReacquireShard ==
    \* hist/shard/context_impl.go:1541-1547; new RangeID fences the previous writer.
    /\ s.shard = "Lost"
    /\ s' = [s EXCEPT !.shard = "Ready", !.range = @ + 1]

LoadMutableState ==
    \* hist/statemachine_environment.go:186-219; sql/execution.go:295-330.
    /\ s.tx.phase = "Idle" /\ ~s.cache /\ s.shard = "Ready"
    /\ s' = [s EXCEPT !.v = s.d, !.cache = TRUE, !.readback = s.d.version]

RefreshWorkflowTasks ==
    \* wf/task_refresher.go:64-72,699-730; explicit refresh, NOT LoadMutableState.
    /\ Ready /\ s.d.open
    /\ LET d1 == [s.d EXCEPT !.gen = @ + 1, !.timers = {}, !.wakeScheduled = {}]
           generated == UNION {Regenerate(d1,o) : o \in {p \in Ops: d1.ops[p].node}}
           emitted == {t \in generated: Eligible(d1,t)}
           d2 == [d1 EXCEPT !.timers = {t \in emitted: t.kind \notin {"Invoke","Cancel"}}]
           wakes == Wake(d2)
           d3 == [d2 EXCEPT !.wakeScheduled = {w.at : w \in wakes}]
       IN s' = [s EXCEPT !.v = d3,
                  !.tx = [Tx("Refresh","",0,EmptyTask) EXCEPT
                              !.emitted = emitted, !.wakes = wakes]]

DropStaleOutboundTask(t) ==
    \* hist/ndc_task_util.go:242-253 and nx/executors.go:829-832.
    /\ Ready /\ t \in s.queue /\ t.kind \in {"Invoke","Cancel"}
    /\ ~OutboundValid(s.d,t) \/ (t.kind = "Cancel" /\ ~Live(s.d,t.op))
    /\ ~\E c \in Elems(s.calls): c.task = t /\ c.phase /= "Done"
    /\ s' = [s EXCEPT !.queue = @ \ {t}]

DropStaleWake(w) ==
    \* hist/ndc_task_util.go:242-253; old physical wake does not resurrect logical tasks.
    /\ Ready /\ w \in s.queue /\ w.kind = "Wake" /\ w.gen < s.d.gen
    /\ s' = [s EXCEPT !.queue = @ \ {w}]

DuplicateOutboundTask(t) ==
    \* S4 queue redelivery after uncertain acknowledgment; payload/identity unchanged.
    /\ t \in s.queue /\ t.kind \in {"Invoke","Cancel"}
    /\ LET copy == [t EXCEPT !.copy = @ + 1]
       IN /\ copy \notin s.queue
          /\ s' = [s EXCEPT !.queue = @ \cup {copy}, !.published = @ \cup {copy}]

StartWorkflowTask ==
    \* wf/workflow_task_state_machine.go:453-479; one in-flight normal WFT.
    \* Signal/request plus WFT-start metadata is projected to this locked boundary.
    /\ Ready /\ s.d.open /\ s.d.wft /= "Started"
    /\ s' = [s EXCEPT !.v = [s.d EXCEPT !.wft = "Started"],
                       !.tx = Tx("WFTStart","",0,EmptyTask)]

CompleteWorkflowTask ==
    \* wf/workflow_task_state_machine.go:761-772,1322-1324;
    \* hist/historybuilder/event_store.go:178-197 appends buffer after commands.
    /\ Ready /\ s.d.open /\ s.d.wft = "Started"
    /\ s' = [s EXCEPT !.v = FinishWFT(s.d), !.tx = Tx("WFTComplete","",0,EmptyTask)]

CloseWorkflowExecution ==
    \* hsm/tree.go:495-512 guards subsequent Nexus work; no cross-run recovery here.
    \* hist/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:803-805: no unhandled buffer.
    /\ Ready /\ s.d.open /\ s.d.buffer = <<>>
    /\ s' = [s EXCEPT !.v = [s.d EXCEPT !.open = FALSE, !.wft = "Idle"],
                       !.tx = Tx("Close","",0,EmptyTask)]

ClockDomain == Nat
AdvanceTime(to) ==
    \* S2/S4 environment clock for nx/executors.go:228,231,719,723 and timer queues.
    /\ to \in Nat /\ to > s.now
    /\ s' = [s EXCEPT !.now = to]

(****************************** Properties ********************************)
OpType(o) ==
    /\ o.node \in BOOLEAN /\ o.state \in Active \cup Terminal \cup {"Absent"}
    /\ o.rid \in Ops \cup {""} /\ o.token \in Ops \cup {""}
    /\ o.initial \in Nat /\ o.attempt \in Nat /\ o.scheduled \in Nat /\ o.started \in Nat
    /\ o.next \in Nat /\ o.cancelNext \in Nat /\ o.cancelAttempt \in Nat /\ o.cancelInitial \in Nat
    /\ o.cancelRequested \in BOOLEAN
    /\ o.cancel \in {"Absent","Unspecified","Scheduled","BackingOff","Succeeded","Failed"}
DBType(d) ==
    /\ DOMAIN d.ops = Ops /\ \A o \in Ops: OpType(d.ops[o])
    /\ d.open \in BOOLEAN /\ d.wft \in {"Idle","Pending","Started"}
    /\ d.version \in Nat /\ d.gen \in Nat /\ d.wakeScheduled \subseteq Nat
    /\ \A e \in Elems(d.history \o d.buffer):
           e.op \in Ops /\ e.rid = e.op /\ e.kind \in
           Terminal \cup {"Scheduled","Started","CancelRequested","CancelAck","CancelFailed"}
    /\ \A t \in d.timers: t.op \in Ops /\ t.kind \in TaskKinds /\ t.at \in Nat
TypeOK ==
    /\ DBType(s.d) /\ DBType(s.v) /\ s.cache \in BOOLEAN
    /\ s.shard \in {"Ready","Lost"} /\ s.now \in Nat /\ s.range \in Nat
    /\ s.tx.phase \in {"Idle","Mutated","Timers","Prepared","Appended","Written","Notified"}
    /\ \A t \in s.tx.consumed: t.kind \in TaskKinds /\ t.at \in Nat
    /\ \A c \in Elems(s.calls): c.op \in Ops /\ c.phase \in
                  {"Loaded","Waiting","Received","Saving","Done"}
    /\ \A m \in s.messages: m.op \in Ops /\ m.id \in Nat /\ m.kind \in
                  {"StartRequest","StartResponse","CancelRequest","CancelResponse","Callback"}
    /\ \A o \in Ops: s.remote[o].accepted \in BOOLEAN
    /\ \A t \in s.queue: t.kind \in TaskKinds /\ t.gen \in Nat /\ t.copy \in Nat
TerminalOutcomeUnique == \A o \in Ops: Len(TerminalEvents(s.d,o)) <= 1
StableReconnectIdentity ==
    /\ \A c \in Elems(s.calls):
        /\ c.rid = s.d.ops[c.op].rid
        /\ c.initial = IF c.task.kind = "Cancel" THEN s.d.ops[c.op].cancelInitial
                        ELSE s.d.ops[c.op].initial
        /\ c.task.kind = "Cancel" => c.token = s.remote[c.op].token
    /\ \A m \in s.messages: m.rid = s.d.ops[m.op].rid
    /\ \A o \in Ops: s.remote[o].accepted /\ s.remote[o].mode = "Async" =>
           /\ s.remote[o].token = s.d.ops[o].rid
           /\ s.d.ops[o].state = "Started" => s.d.ops[o].token = s.remote[o].token
RequiredTimerPublished ==
    \A o \in Ops: Live(s.d,o) /\ s.d.ops[o].state = "Started" /\ STC > 0 =>
        \E t \in s.d.timers: t.op = o /\ t.kind = "STC" /\ Eligible(s.d,t)
                              /\ t.at = s.d.ops[o].started + STC
TerminalCapacityReclaimed ==
    s.d.open => \A o \in Ops: Len(TerminalEvents(s.d,o)) > 0 => ~s.d.ops[o].node
CommittedObservation ==
    \A r \in s.observed: r.status = "Accepted" =>
        \E e \in Elems(TerminalEvents(s.d,r.op)): e.kind = r.result
NoTerminalRevival ==
    \A o \in Ops: s.sealed[o] /= {} =>
        /\ s.d.ops[o].state \in s.sealed[o]
        /\ s.sealed[o] = {e.kind : e \in Elems(TerminalEvents(s.d,o))}
        /\ s.d.ops[o].state \in Terminal
CancelIntentAccountedFor ==
    \A o \in Ops: s.d.ops[o].cancelRequested /\ Live(s.d,o) =>
        CASE s.d.ops[o].state \in {"Scheduled","BackingOff"} -> s.d.ops[o].cancel = "Unspecified"
          [] s.d.ops[o].cancel \in {"Succeeded","Failed"} -> TRUE
          [] s.d.ops[o].cancel = "Scheduled" ->
                 \E t \in s.queue: t.op = o /\ t.kind = "Cancel" /\ OutboundValid(s.d,t)
          [] s.d.ops[o].cancel = "BackingOff" ->
                 \E t \in s.d.timers: t.op = o /\ t.kind = "CancelBackoff" /\ Eligible(s.d,t)
          [] OTHER -> FALSE
PublishedTasksHaveCommit == s.queue \subseteq s.published
HistoryAppendBacked == s.d.history = <<>> \/
    (\E h \in Elems(s.raw): Len(h) >= Len(s.d.history) /\ s.d.history = SubSeq(h,1,Len(s.d.history)))
TerminalNodeConsistency == \A o \in Ops:
    (Len(TerminalEvents(s.d,o)) > 0) = (s.d.ops[o].state \in Terminal)

\* S2-S5 liveness obligation, separate from safety/finite trace matching.
\* Requires unbounded time, finite failures, eventual shard/readback availability,
\* fair per-operation task execution/commit, open workflow or allowed closure.
\* No guarantee that a cancel ACK causes a remote Canceled outcome.
EligibleProgress ==
    \A o \in Ops:
      /\ (Live(s.d,o) /\ s.d.ops[o].state = "Started" /\ STC > 0)
           ~> (~s.d.open \/ s.d.ops[o].state \in Terminal)
      /\ (Live(s.d,o) /\ S2C > 0)
           ~> (~s.d.open \/ s.d.ops[o].state \in Terminal)

Next ==
    \/ \E o \in Ops: HandleScheduleCommand(o) \/ HandleScheduleCommandLimit(o)
          \/ HandleCancelCommand(o) \/ SendCompletionCallback(o)
          \/ (\E result \in RemoteResults: EndpointComplete(o,result))
    \/ \E t \in s.queue: loadOperationArgs(t) \/ loadArgsForCancelation(t)
          \/ executeStateMachineTimerTask(t) \/ DropStaleOutboundTask(t)
          \/ DropStaleWake(t) \/ DuplicateOutboundTask(t)
    \/ \E i \in 1..Len(s.calls): executeInvocationTask(i) \/ executeInvocationTaskBelowMin(i)
          \/ RequestDeadlineExceeded(i) \/ saveStartedResult(i)
          \/ handleStartOperationErrorRetryable(i) \/ saveResultSucceeded(i) \/ handleOperationErrorFailed(i)
          \/ handleOperationErrorCanceled(i) \/ handleNonRetryableStartOperationError(i)
          \/ handleStartOperationErrorBelowMin(i) \/ RejectStaleCall(i)
          \/ executeCancelationTask(i) \/ executeCancelationTaskBelowMin(i)
          \/ saveCancelationResultAck(i) \/ saveCancelationResultFailed(i) \/ saveCancelationResultRetryable(i)
    \/ \E m \in s.messages: ReceiveStartResponse(m) \/ LoseResponse(m) \/ DiscardLateResponse(m)
          \/ CompletionHandlerHandle(m) \/ CompletionHandlerReject(m)
          \/ EndpointCancelAck(m) \/ ReceiveCancelResponse(m)
          \/ (\E mode \in StartModes: EndpointAccept(m,mode))
          \/ (\E result \in {"Retryable","Refused"}: EndpointStartFailure(m,result) \/ EndpointCancelFailure(m,result))
    \/ \E t \in s.v.timers: executeBackoffTask(t) \/ executeCancelationBackoffTask(t)
          \/ executeOperationTimeout(t) \/ SkipStaleTimer(t)
    \/ \E r \in s.replies: ReceiveCompletionReply(r) \/ LoseCompletionReply(r)
    \/ FinishStateMachineTimers \/ GenerateDirtySubStateMachineTasks \/ AppendHistoryNodes
    \/ (\E outcome \in {"Success","DefiniteFailure","UnknownCommitted","UnknownNotCommitted"}:
           UpdateWorkflowExecution(outcome))
    \/ ConditionalWriteRejected \/ NotifyOnExecutionMutation \/ AccessReturn
    \/ CacheLoss \/ LoseShard \/ ReacquireShard \/ LoadMutableState \/ RefreshWorkflowTasks
    \/ StartWorkflowTask \/ CompleteWorkflowTask \/ CloseWorkflowExecution \/ (\E to \in ClockDomain: AdvanceTime(to))

Spec == Init /\ [][Next]_vars
=============================================================================
