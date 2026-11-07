------------------------------ MODULE CommSJ_F ------------------------------
\* Group CommSJ, FINE variant. Process: SJ. Partition FED_COMM of the fedavg seed
\* (inputs/seeds/fedavg/spec/base.tla, pin c411a201): WFComm + ServerRunner task
\* request path, client-task publication / authority / resend, outbound filter,
\* task check, submission check / claim / acquire / dispatch / stamp / drop /
\* reject, retired history (LRU), task monitor and dead-client watch, direct
\* cancel, workflow close and communicator finalize.
\* Re-homing: s.task/ct/comm/runner/requested/completed/dead/mon -> commSJ_f.
\* Seed channel state s.net[t][c][n] and the ct.delivery transit half become
\* messages; the client oracles are replaced by source rules:
\*  * WFCommResendTask: resend iff the client task has no result_received_time
\*    (wf_comm_server.py:246-257), not "CJ result = none / delivery failed".
\*  * WFCommTaskUnavailable: complement of the real eligibility.
\*  * ClientCheckTask (folded SJ answer + CJ consume + upload) -> the SJ half
\*    only: the reply is a TASK_CHECK_REPLY message.
\*  * ServerRunnerTaskRequestActive: consumes a real GET_TASK message.
\*  * ClockAdvance (ENV) is a Faults-gated step of this group.
\* Payload: an envelope with refs is exposed in pCommSJ.envelopes; it is
\* dequeued only once the payload receiver materialized it (FOBS decode), or
\* answered RETRY if materialization failed (server_runner.py:503-507).
\* Slice profile: one task per round (t = round), Selected = Sites, MinSites =
\* |Sites|, RequiredSites = Sites, HistoryLimit 2; BeforeSendFailure /
\* AllocationFailure / OutboundFilter -> Faults "prepFail"; cancel / dead
\* reports -> "cancel" / "deadClient"; task timeout and min_responses exit ->
\* "taskTimeout" / "minClients".
EXTENDS Ports
VARIABLE commSJ_f

Tasks == 1..Rounds
Selected == Sites
MinSites == IF "wfTolerant" \in Profile /\ Cardinality(Sites) > 1
            THEN Cardinality(Sites) - 1 ELSE Cardinality(Sites)
RequiredSites == IF "wfTolerant" \in Profile THEN {} ELSE Sites
HistoryLimit == 2
MaxDeadReports == 1
NoId == <<0, None>>
Statuses == {"NEW", "LIVE", "OK", "ERROR", "CANCELLED", "CLIENT_DEAD", "TIMEOUT"}

EmptyRunner == [kind |-> "free", pc |-> "idle", client |-> None, id |-> NoId, key |-> None,
                receipt |-> "NONE"]
EmptyComm == [kind |-> "free", pc |-> "idle", id |-> NoId, exit |-> "LIVE",
              pending |-> {}, deadView |-> {}]
EmptyTask == [scheduled |-> FALSE, standing |-> FALSE, status |-> "NEW",
              assignedOrder |-> <<>>, age |-> 0, cleaned |-> FALSE,
              retiredStatus |-> "NEW", retiredOutstanding |-> {}]
EmptyClient == [assigned |-> FALSE, delivery |-> "none", replyTo |-> None,
                claimed |-> FALSE, ckey |-> None, receipt |-> FALSE]

InitValue == [
    task |-> [t \in Tasks |-> EmptyTask],
    ct |-> [t \in Tasks |-> [c \in Sites |-> EmptyClient]],
    comm |-> EmptyComm, runner |-> EmptyRunner,
    requested |-> [c \in Sites |-> None],
    checking |-> {}, queued |-> {}, handled |-> {}, dispatched |-> {},
    completed |-> <<>>, wfClosed |-> FALSE,
    dead |-> [c \in Sites |-> [reported |-> FALSE, age |-> 0, disconnected |-> FALSE, serial |-> 0]],
    mon |-> [pc |-> "idle", pending |-> {}, deadView |-> {},
             reportAges |-> [c \in Sites |-> 0], reportSerial |-> [c \in Sites |-> 0]]]
Init == commSJ_f = InitValue

\* Abstraction to CommSJ_C's private state.
\* a dead-client report has matured (disconnected, or aged through the grace)
Matured == \E c \in Sites : commSJ_f.dead[c].reported /\ (commSJ_f.dead[c].disconnected \/ commSJ_f.dead[c].age >= 2)
AbsC == [deadEarly |-> Matured, called |-> commSJ_f.dispatched,
         ckey |-> [c \in Sites |-> IF pCommSJ.round \in 1..Rounds
                                   THEN commSJ_f.ct[pCommSJ.round][c].ckey ELSE None]]
AbsCInit == [deadEarly |-> FALSE, called |-> {}, ckey |-> [c \in Sites |-> None]]

S == commSJ_f
P == pCommSJ
Aborted == pCommSJ.panic \/ pWfSJ.panic
WfOpen == pWfSJ.open /\ ~commSJ_f.wfClosed
CT(id) == S.ct[id[1]][id[2]]
TK(t) == S.task[t]
SeqSet(q) == {q[i] : i \in 1..Len(q)}
Outstanding(t) == {c \in Selected : ~S.ct[t][c].receipt}
Disconnected == {c \in Sites : S.dead[c].disconnected}
RunnerLockFree == S.runner.kind = "free"
CommNotMonitor == S.comm.kind /= "monitor" \/ S.comm.pc = "exitCleanup"
LiveMap(id) == TK(id[1]).standing /\ CT(id).assigned
Cleared(c) == [reported |-> FALSE, age |-> 0, disconnected |-> FALSE, serial |-> S.dead[c].serial]
IdOf(k) == <<M(k).body.assignment.attempt, M(k).body.assignment.site>>
Site(k) == M(k).body.assignment.site
\* Port projection of the current round's per-client facts.
IsCur(id) == id[1] = P.round

\* wf_comm_server.py:397-412 LRU (reduced capacity is a configuration abstraction)
Touch(q, id) == Append(SelectSeq(q, LAMBDA x : x /= id), id)
Trim(q) == IF Len(q) <= HistoryLimit THEN q ELSE SubSeq(q, Len(q)-HistoryLimit+1, Len(q))
Remember(t) == Trim(SelectSeq(S.completed, LAMBDA id : id \notin SeqSet(S.task[t].assignedOrder))
                    \o S.task[t].assignedOrder)
RememberOne(id) == Trim(Touch(S.completed, id))
KnownAssignment(id) == LiveMap(id) \/ id \in SeqSet(S.completed)
HistoryAfterLookup(id) ==
    IF LiveMap(id) /\ S.task[id[1]].status /= "LIVE" THEN RememberOne(id)
    ELSE IF ~LiveMap(id) /\ id \in SeqSet(S.completed) THEN Touch(S.completed, id)
    ELSE S.completed

Reply(kind, k, body) == Msg(kind, SJ, M(k).from, M(k).id, body)
TryAgainBody == [status |-> "TRY_AGAIN", assignment |-> None, input |-> None]

\* ================================================================ schedule
\* base_model_controller.py:153-169,199-232; wf_comm_server.py:682-726.
\* COMM half of the seed rendezvous: consumes SCHEDULE(t) = pWfSJ.scheduled.
WFCommScheduleTask ==
    /\ SJAlive /\ pWfSJ.scheduled \in Tasks /\ pWfSJ.scheduled > P.round
    /\ CommNotMonitor
    /\ LET t == pWfSJ.scheduled IN
       /\ ~TK(t).scheduled
       /\ commSJ_f' = [commSJ_f EXCEPT !.task[t].scheduled = TRUE, !.task[t].standing = TRUE,
                                       !.task[t].status = "LIVE"]
       /\ pCommSJ' = [pCommSJ EXCEPT !.round = t, !.standing = TRUE,
                        !.envelopes = [c \in Sites |-> None], !.claimed = {}, !.finished = {}]
    /\ UNCHANGED net

\* ================================================================ get task
\* server_runner.py:290-299,614-620; wf_comm_server.py:1405-1414.
\* A real GET_TASK arrival (seed: folded CJ send under ClientCanPoll).
ServerRunnerTaskRequestActive(c, k) ==
    /\ SJAlive /\ InInbox(k, SJ, "GET_TASK") /\ M(k).from = CJ(c) /\ k \notin S.handled
    /\ WfOpen /\ ~Aborted /\ RunnerLockFree /\ S.mon.pc /= "dead" /\ c \in Selected
    /\ S.requested[c] = None
    /\ \E t \in Tasks : TK(t).standing /\ ~S.ct[t][c].receipt
    /\ commSJ_f' = [commSJ_f EXCEPT !.dead[c] = Cleared(c), !.requested[c] = k,
                                    !.handled = @ \cup {k}]
    /\ UNCHANGED <<pCommSJ, net>>

\* server_runner.py:390-400
ServerRunnerAcquireTaskRequest(c) ==
    /\ SJAlive /\ S.requested[c] /= None /\ RunnerLockFree
    /\ commSJ_f' = [commSJ_f EXCEPT !.requested[c] = None,
          !.runner = [EmptyRunner EXCEPT !.kind = "request", !.pc = "commWait", !.client = c,
                                         !.key = S.requested[c]]]
    /\ UNCHANGED <<pCommSJ, net>>

\* server_runner.py:390-432; wf_comm_server.py:225-299; task_manager.py:61-70.
\* Seed task = wf.round shortcut replaced by the standing LIVE task.
WFCommProcessTaskRequest(c) ==
    /\ SJAlive /\ WfOpen /\ S.comm.kind = "free"
    /\ S.runner.kind = "request" /\ S.runner.pc = "commWait" /\ S.runner.client = c
    /\ c \in Selected
    /\ \E t \in Tasks :
         /\ TK(t).standing /\ TK(t).status = "LIVE"
         /\ ~S.ct[t][c].assigned /\ S.ct[t][c].delivery = "none"
         /\ commSJ_f' = [commSJ_f EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "request",
                                                   !.pc = "before", !.id = <<t, c>>]]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:246-257,293-395: resend the same ClientTask (same
\* authority) while result_received_time is None. Source rule, no CJ oracle;
\* an outbound filter of the previous publication must have finished.
WFCommResendTask(id) ==
    /\ SJAlive /\ WfOpen /\ S.comm.kind = "free" /\ LiveMap(id)
    /\ S.runner.kind = "request" /\ S.runner.pc = "commWait" /\ S.runner.client = id[2]
    /\ TK(id[1]).status = "LIVE" /\ ~CT(id).receipt
    /\ CT(id).delivery \in {"sent", "failed"}
    /\ commSJ_f' = [commSJ_f EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "request",
                                              !.pc = "before", !.id = id]]
    /\ UNCHANGED <<pCommSJ, net>>

\* base_model_controller.py:236-239; wf_comm_server.py:297-314
BasePrepareTaskData ==
    /\ SJAlive /\ S.comm.kind = "request" /\ S.comm.pc = "before"
    /\ commSJ_f' = [commSJ_f EXCEPT !.comm.pc = "snapshot"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:297-330 (fault prepFail)
BasePrepareTaskDataFailure ==
    /\ "prepFail" \in Faults /\ SJAlive /\ S.comm.kind = "request" /\ S.comm.pc = "before"
    /\ commSJ_f' = [commSJ_f EXCEPT !.task[S.comm.id[1]].status = "ERROR", !.comm.pc = "snapshot"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:321-340
WFCommProtectBroadcast ==
    /\ SJAlive /\ S.comm.kind = "request" /\ S.comm.pc = "snapshot"
    /\ commSJ_f' = [commSJ_f EXCEPT !.comm.pc = "canSend"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:329-340 (fault prepFail; deepcopy only on the first send)
WFCommProtectBroadcastFailure ==
    /\ "prepFail" \in Faults /\ SJAlive /\ S.comm.kind = "request" /\ S.comm.pc = "snapshot"
    /\ TK(S.comm.id[1]).assignedOrder = <<>>
    /\ commSJ_f' = [commSJ_f EXCEPT !.task[S.comm.id[1]].status = "ERROR", !.comm.pc = "canSend"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:343-361; base_model_controller.py:224-232
WFCommCheckCanSend ==
    /\ SJAlive /\ S.comm.kind = "request" /\ S.comm.pc = "canSend"
    /\ commSJ_f' = [commSJ_f EXCEPT !.comm.pc =
                      IF TK(S.comm.id[1]).status = "LIVE" THEN "publish" ELSE "tryAgain"]
    /\ UNCHANGED <<pCommSJ, net>>

\* Profile cseTasks: the client's own task is followed in the task list by the
\* other sites' tasks unless the client is last in the site order. A resend
\* (resend_task = True, no break) is then reset by the next task's iteration
\* (wf_comm_server.py:246-277: NO_BLOCK, the client is not a target), and the
\* publication appends the same ClientTask again (lines 366-375).
LastSite == CHOOSE c \in Sites : TRUE
DupOnResend(id) == "cseTasks" \in Profile /\ CT(id).assigned /\ id[2] /= LastSite

\* wf_comm_server.py:369-396; server_runner.py:419-430: ClientTask + authority.
WFCommPublishClientTask ==
    /\ SJAlive /\ S.comm.kind = "request" /\ S.comm.pc = "publish"
    /\ LET id == S.comm.id IN
       /\ commSJ_f' = [commSJ_f EXCEPT
             !.task[id[1]].assignedOrder = IF CT(id).assigned /\ ~DupOnResend(id) THEN @ ELSE Append(@, id),
             !.ct[id[1]][id[2]].assigned = TRUE,
             !.ct[id[1]][id[2]].delivery = "filter",
             !.ct[id[1]][id[2]].replyTo = S.runner.key,
             !.comm = EmptyComm, !.runner = EmptyRunner]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:356-361: TRY_AGAIN reply, no new client task.
WFCommTaskTryAgain ==
    /\ SJAlive /\ S.comm.kind = "request" /\ S.comm.pc = "tryAgain"
    /\ net' = Send(net, Reply("TASK_ASSIGNMENT", S.runner.key, TryAgainBody))
    /\ commSJ_f' = [commSJ_f EXCEPT !.comm = EmptyComm, !.runner = EmptyRunner]
    /\ UNCHANGED pCommSJ

\* server_runner.py:391-400; wf_comm_server.py:236-288: no eligible task.
Eligible(t, c) ==
    /\ WfOpen /\ TK(t).standing /\ TK(t).status = "LIVE" /\ ~S.ct[t][c].receipt
    /\ \/ ~S.ct[t][c].assigned /\ S.ct[t][c].delivery = "none"
       \/ S.ct[t][c].assigned /\ S.ct[t][c].delivery \in {"sent", "failed"}
WFCommTaskUnavailable ==
    /\ SJAlive /\ S.runner.kind = "request" /\ S.comm.kind = "free"
    /\ ~(\E t \in Tasks : Eligible(t, S.runner.client))
    /\ net' = Send(net, Reply("TASK_ASSIGNMENT", S.runner.key, TryAgainBody))
    /\ commSJ_f' = [commSJ_f EXCEPT !.runner = EmptyRunner]
    /\ UNCHANGED pCommSJ

\* server_runner.py:333-376: TASK_ASSIGNMENT (ASSIGNED) leaves the SJ.
ServerRunnerFilterTask(id) ==
    /\ SJAlive /\ CT(id).delivery = "filter"
    /\ net' = Send(net, Reply("TASK_ASSIGNMENT", CT(id).replyTo,
                 [status |-> "ASSIGNED", assignment |-> Assignment(id[2], id[1]),
                  input |-> TaskInput(Assignment(id[2], id[1]))]))
    /\ commSJ_f' = [commSJ_f EXCEPT !.ct[id[1]][id[2]].delivery = "sent"]
    /\ UNCHANGED pCommSJ

\* server_runner.py:337-354 (fault prepFail: outbound filter raises)
ServerRunnerFilterFailure(id) ==
    /\ "prepFail" \in Faults /\ SJAlive /\ CT(id).delivery = "filter"
    /\ commSJ_f' = [commSJ_f EXCEPT !.ct[id[1]][id[2]].delivery = "filterFailed"]
    /\ UNCHANGED <<pCommSJ, net>>

\* server_runner.py:354-360; wf_comm_server.py:397-415,945-963: cancel the task
\* if the client-task mapping still exists, reply TRY_AGAIN.
WFCommHandleException(id) ==
    /\ SJAlive /\ CT(id).delivery = "filterFailed" /\ RunnerLockFree /\ CommNotMonitor
    /\ net' = Send(net, Reply("TASK_ASSIGNMENT", CT(id).replyTo, TryAgainBody))
    /\ commSJ_f' = [commSJ_f EXCEPT !.task[id[1]].status =
                       IF WfOpen /\ LiveMap(id) THEN "CANCELLED" ELSE @,
                    !.ct[id[1]][id[2]].delivery = "failed"]
    /\ UNCHANGED pCommSJ

\* wf_comm_server.py:945-978 (fault cancel): mark-only, admitted work continues.
WFCommCancelTask(t) ==
    /\ "cancel" \in Faults /\ SJAlive /\ TK(t).standing /\ TK(t).status = "LIVE"
    /\ commSJ_f' = [commSJ_f EXCEPT !.task[t].status = "CANCELLED"]
    /\ UNCHANGED <<pCommSJ, net>>

\* fedavg.py:246-248; wf_comm_server.py:962-979: COMM half of CANCEL_ALL(ERROR).
WFCommCancelAllTasks ==
    /\ SJAlive /\ pWfSJ.cancelAll > P.cancelled
    /\ commSJ_f' = [commSJ_f EXCEPT !.task = [t \in Tasks |-> [S.task[t] EXCEPT !.status =
                       IF S.task[t].standing THEN "ERROR" ELSE @]]]
    /\ pCommSJ' = [pCommSJ EXCEPT !.cancelled = pWfSJ.cancelAll]
    /\ UNCHANGED net

\* ================================================================ submission
\* server_runner.py:617-628: TASK_CHECK arrival (activity clears dead state).
ServerRunnerCheckTaskActive(c, k) ==
    /\ SJAlive /\ InInbox(k, SJ, "TASK_CHECK") /\ M(k).from = CJ(c) /\ k \notin S.handled
    /\ RunnerLockFree /\ S.mon.pc /= "dead"
    /\ commSJ_f' = [commSJ_f EXCEPT !.handled = @ \cup {k}, !.checking = @ \cup {k},
                       !.dead[c] = IF WfOpen THEN Cleared(c) ELSE @]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:417-464; server_runner.py:627-672: SJ half of the seed's
\* ClientCheckTask: the authority-bound readiness reply.
ClientCheckTask(k) ==
    /\ SJAlive /\ k \in S.checking /\ RunnerLockFree /\ CommNotMonitor
    /\ LET id == IdOf(k)
           known == WfOpen /\ ~Aborted /\ KnownAssignment(id)
           received == known /\ CT(id).claimed
       IN /\ net' = Send(net, Reply("TASK_CHECK_REPLY", k,
                 IF ~known THEN "TASK_CLOSED" ELSE IF received THEN "RECEIVED" ELSE "RETRY"))
          /\ commSJ_f' = [commSJ_f EXCEPT !.checking = @ \ {k},
                 !.completed = IF WfOpen /\ ~Aborted THEN HistoryAfterLookup(id) ELSE @]
    /\ UNCHANGED pCommSJ

\* Cell-layer receive of SUBMIT_UPDATE: queued; refs handed to the receiver.
ServerRunnerReceiveSubmission(c, k) ==
    /\ SJAlive /\ InInbox(k, SJ, "RESULT_ENVELOPE") /\ M(k).from = CJ(c) /\ k \notin S.handled
    /\ commSJ_f' = [commSJ_f EXCEPT !.handled = @ \cup {k}, !.queued = @ \cup {k}]
    /\ pCommSJ' = IF (P.envelopes[c] = None /\ M(k).body.refs /= {}
                      /\ M(k).body.assignment.attempt = P.round /\ P.round \in Tasks
                      /\ CT(<<P.round, c>>).assigned)
                  THEN [pCommSJ EXCEPT !.envelopes[c] = [assignment |-> M(k).body.assignment,
                                                          refs |-> M(k).body.refs]]
                  ELSE pCommSJ
    /\ UNCHANGED net

\* The payload receiver attempt of this envelope's (site, round) (PayRcv port).
RxOf(k) == pPayRcv[Site(k)].rx[M(k).body.assignment.attempt]
Decoded(k) == \/ M(k).body.refs = {}
              \/ RxOf(k).status = "materialized" /\ RxOf(k).want \in M(k).body.refs
DecodeFailed(k) == /\ M(k).body.refs /= {} /\ RxOf(k).status = "failed"
                   /\ RxOf(k).want \in M(k).body.refs

\* server_runner.py:503-507: payload not fully downloaded -> RETRY receipt.
ServerRunnerRetryIncomplete(k) ==
    /\ SJAlive /\ k \in S.queued /\ DecodeFailed(k)
    /\ net' = Send(net, Reply("RESULT_RECEIPT", k, "RETRY"))
    /\ commSJ_f' = [commSJ_f EXCEPT !.queued = @ \ {k}]
    /\ UNCHANGED pCommSJ

\* server_runner.py:456-464: dequeue under wf_lock (closed when the workflow is
\* closed, aborted or the runner is done).
ServerRunnerProcessSubmission(k) ==
    /\ SJAlive /\ k \in S.queued /\ Decoded(k) /\ RunnerLockFree
    /\ commSJ_f' = [commSJ_f EXCEPT !.queued = @ \ {k},
          !.runner = [EmptyRunner EXCEPT !.kind = "submit",
                        !.pc = IF WfOpen /\ ~Aborted /\ ~pWfSJ.done THEN "activity" ELSE "closed",
                        !.id = IdOf(k), !.key = k, !.receipt = "TASK_CLOSED"]]
    /\ UNCHANGED <<pCommSJ, net>>

\* server_runner.py:458-467,614-620; wf_comm_server.py:1405-1414
ServerRunnerSubmissionActive ==
    /\ SJAlive /\ S.runner.kind = "submit" /\ S.runner.pc = "activity" /\ S.mon.pc /= "dead"
    /\ commSJ_f' = [commSJ_f EXCEPT !.dead[S.runner.id[2]] = Cleared(S.runner.id[2]),
                                    !.runner.pc = "admit"]
    /\ UNCHANGED <<pCommSJ, net>>

\* server_runner.py:456-464: RESULT_RECEIPT TASK_CLOSED for a closed runner.
ServerRunnerDropClosedSubmission ==
    /\ SJAlive /\ S.runner.kind = "submit" /\ S.runner.pc = "closed"
    /\ net' = Send(net, Reply("RESULT_RECEIPT", S.runner.key, S.runner.receipt))
    /\ commSJ_f' = [commSJ_f EXCEPT !.runner = EmptyRunner]
    /\ UNCHANGED pCommSJ

\* server_runner.py:492-524; wf_comm_server.py:503-560
ServerRunnerCheckSubmission ==
    /\ SJAlive /\ S.runner.kind = "submit" /\ S.runner.pc = "admit" /\ CommNotMonitor
    /\ LET id == S.runner.id
           known == KnownAssignment(id)
       IN commSJ_f' = [commSJ_f EXCEPT
             !.runner.pc = IF known /\ ~CT(id).claimed THEN "claim" ELSE "rejected",
             !.runner.receipt = IF known /\ CT(id).claimed THEN "RECEIVED" ELSE "TASK_CLOSED",
             !.completed = HistoryAfterLookup(id)]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:562-592: complete-result claim (before application work).
WFCommClaimSubmission ==
    /\ SJAlive /\ S.runner.kind = "submit" /\ S.runner.pc = "claim" /\ S.comm.kind = "free"
    /\ LET id == S.runner.id
           known == KnownAssignment(id)
       IN /\ commSJ_f' = [commSJ_f EXCEPT
                !.runner.pc = IF known /\ ~CT(id).claimed THEN "commWait" ELSE "rejected",
                !.ct[id[1]][id[2]].claimed = @ \/ known,
                !.ct[id[1]][id[2]].ckey = IF known /\ ~CT(id).claimed THEN M(S.runner.key).id ELSE @,
                !.runner.receipt = IF known THEN "RECEIVED" ELSE "TASK_CLOSED",
                !.completed = HistoryAfterLookup(id)]
          /\ pCommSJ' = IF known /\ IsCur(id) THEN [pCommSJ EXCEPT !.claimed = @ \cup {id[2]}]
                        ELSE pCommSJ
    /\ UNCHANGED net

\* server_runner.py:508-523: RESULT_RECEIPT for a rejected submission.
ServerRunnerRejectSubmission ==
    /\ SJAlive /\ S.runner.kind = "submit" /\ S.runner.pc = "rejected"
    /\ net' = Send(net, Reply("RESULT_RECEIPT", S.runner.key, S.runner.receipt))
    /\ commSJ_f' = [commSJ_f EXCEPT !.runner = EmptyRunner]
    /\ UNCHANGED pCommSJ

\* server_runner.py:595-605; wf_comm_server.py:616-633
WFCommAcquireSubmission ==
    /\ SJAlive /\ S.runner.kind = "submit" /\ S.runner.pc = "commWait" /\ S.comm.kind = "free"
    /\ commSJ_f' = [commSJ_f EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "submit",
                       !.pc = "dispatch", !.id = S.runner.id], !.runner.pc = "busy"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:632-661: APP_CALL(live | unknown) with the envelope body.
WFCommDispatchSubmission ==
    /\ SJAlive /\ S.comm.kind = "submit" /\ S.comm.pc = "dispatch"
    /\ LET id == S.comm.id
           k == S.runner.key
           live == LiveMap(id) /\ TK(id[1]).status = "LIVE"
       IN /\ commSJ_f' = [commSJ_f EXCEPT !.comm.pc = "inApp",
                             !.completed = HistoryAfterLookup(id),
                             !.dispatched = @ \cup {id}]
          /\ pCommSJ' = [pCommSJ EXCEPT !.call =
                [site |-> id[2], round |-> id[1], kind |-> IF live THEN "live" ELSE "unknown",
                 key |-> M(k).id, assignment |-> M(k).body.assignment,
                 value |-> IF M(k).body.refs = {} THEN None ELSE RxOf(k).materialized,
                 rc |-> M(k).body.rc, metricKind |-> "none"]]
    /\ UNCHANGED net

ReturnOf(id) == pWfSJ.ret = [site |-> id[2], round |-> id[1]]

\* wf_comm_server.py:594-618; server_runner.py:611-615: APP_RETURN consumed,
\* callback-finish stamp, RESULT_RECEIPT.
WFCommStampReceipt ==
    /\ SJAlive /\ S.comm.kind = "submit" /\ S.comm.pc = "inApp"
    /\ P.call /= None /\ P.call.kind = "live" /\ ReturnOf(S.comm.id)
    /\ LET id == S.comm.id IN
       /\ net' = Send(net, Reply("RESULT_RECEIPT", S.runner.key, S.runner.receipt))
       /\ commSJ_f' = [commSJ_f EXCEPT !.ct[id[1]][id[2]].receipt = LiveMap(id) \/ @,
             !.completed = IF LiveMap(id) /\ S.task[id[1]].status /= "LIVE" THEN RememberOne(id) ELSE @,
             !.comm = EmptyComm, !.runner = EmptyRunner]
       /\ pCommSJ' = [pCommSJ EXCEPT !.call = None,
             !.finished = IF LiveMap(id) /\ IsCur(id) THEN @ \cup {id[2]} ELSE @]

\* wf_comm_server.py:600-614,647-661: unknown-hook return.
WFCommDropSubmission ==
    /\ SJAlive /\ S.comm.kind = "submit" /\ S.comm.pc = "inApp"
    /\ P.call /= None /\ P.call.kind = "unknown" /\ ReturnOf(S.comm.id)
    /\ LET id == S.comm.id IN
       /\ net' = Send(net, Reply("RESULT_RECEIPT", S.runner.key, S.runner.receipt))
       /\ commSJ_f' = [commSJ_f EXCEPT !.ct[id[1]][id[2]].receipt = IF LiveMap(id) THEN TRUE ELSE @,
             !.completed = HistoryAfterLookup(id), !.comm = EmptyComm, !.runner = EmptyRunner]
       /\ pCommSJ' = [pCommSJ EXCEPT !.call = None,
             !.finished = IF LiveMap(id) /\ IsCur(id) THEN @ \cup {id[2]} ELSE @]

\* ================================================================ dead clients
\* wf_comm_server.py:191-202,82-85 (one report per site): HANDLE_DEAD_JOB from the
\* SP for this job's participant token (generation 1), sent by the cleanup
\* thread's notify_dead_client or by the heartbeat job sync (Reg, v8; a stale
\* token of a live CJ gives a false suspicion)
WFCommReportDeadClient(c) ==
    /\ SJAlive /\ WfOpen /\ S.mon.pc /= "dead"
    /\ ~S.dead[c].reported /\ S.dead[c].serial < MaxDeadReports
    /\ <<c, 1>> \in pReg.notified
    /\ commSJ_f' = [commSJ_f EXCEPT !.dead[c] = [reported |-> TRUE, age |-> 0,
                       disconnected |-> FALSE, serial |-> S.dead[c].serial+1]]
    /\ UNCHANGED <<pCommSJ, net>>

\* server_runner.py:614-629; wf_comm_server.py:1405-1414 (heartbeat input)
WFCommClientIsActive(c) ==
    /\ SJAlive /\ WfOpen /\ RunnerLockFree /\ S.mon.pc /= "dead"
    /\ S.dead[c].reported /\ \E l \in Launches : CJAlive(c, l)   \* JOB_HEART_BEAT from a live CJ
    /\ commSJ_f' = [commSJ_f EXCEPT !.dead[c] = Cleared(c)]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1190-1195,1316-1323: 30 s clock tick (task lead time 0..1,
\* report age 0..2). Seed ENV action; enabled only when a clock-driven
\* mechanism is in the fault profile.
ClockAdvance ==
    /\ \/ {"deadClient", "taskTimeout", "minClients"} \cap Faults /= {}
       \/ \E c \in Sites : S.dead[c].reported
    \* Timing T4 (v8; server_runner.py:153-172): after control_flow returns,
    \* stop_controller + finalize_run end the task monitor within seconds, so no
    \* 30 s tick (and no 60 s dead-client grace) elapses in between, unless the
    \* finalization is slow or a grace expiry lands in that window (slowFinalize).
    /\ TimingOK(Faults, "slowFinalize", T4Holds(pWfSJ.returned))
    /\ SJAlive /\ ~P.finalized
    /\ \/ \E t \in Tasks : S.task[t].scheduled /\ S.task[t].age = 0
       \/ \E c \in Sites : S.dead[c].reported /\ S.dead[c].age < 2
    /\ commSJ_f' = [commSJ_f EXCEPT
          !.task = [t \in Tasks |-> [S.task[t] EXCEPT !.age = IF S.task[t].scheduled THEN 1 ELSE @]],
          !.dead = [c \in Sites |-> [S.dead[c] EXCEPT !.age =
                      IF S.dead[c].reported /\ S.dead[c].age < 2 THEN @+1 ELSE @]]]
    /\ UNCHANGED <<pCommSJ, net>>

\* Stuttering reduction (documented, sound for safety): a monitor pass that can
\* change nothing (no dead report, every standing task LIVE, unanswered and
\* inside its lead time) only holds the communicator lock and returns; it is
\* skipped. Every pass that can retire a task or panic is kept.
MonitorWork == \/ \E c \in Sites : S.dead[c].reported
               \/ \E t \in Tasks : TK(t).standing /\
                                   (TK(t).status /= "LIVE" \/ Outstanding(t) = {} \/ TK(t).age = 1)

\* wf_comm_server.py:1178-1180
WFCommMonitorBegin ==
    /\ SJAlive /\ S.mon.pc = "idle" /\ ~P.finalized /\ MonitorWork
    /\ commSJ_f' = [commSJ_f EXCEPT
          !.mon.pc = IF \E c \in Sites : S.dead[c].reported THEN "clock" ELSE "policy",
          !.mon.pending = IF \E c \in Sites : S.dead[c].reported THEN {} ELSE Sites,
          !.mon.deadView = {}]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1182
WFCommMonitorClock ==
    /\ SJAlive /\ S.mon.pc = "clock"
    /\ commSJ_f' = [commSJ_f EXCEPT !.mon.pc = "deadLock",
          !.mon.reportAges = [c \in Sites |-> S.dead[c].age],
          !.mon.reportSerial = [c \in Sites |-> S.dead[c].serial]]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1183-1184
WFCommMonitorWatchList ==
    /\ SJAlive /\ S.mon.pc = "deadLock"
    /\ commSJ_f' = [commSJ_f EXCEPT !.mon.pc = "dead",
                       !.mon.pending = {c \in Sites : S.dead[c].reported}]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1182-1199
WFCommCheckDeadClient(c) ==
    /\ SJAlive /\ S.mon.pc = "dead" /\ c \in S.mon.pending
    /\ commSJ_f' = [commSJ_f EXCEPT !.dead[c].disconnected =
          @ \/ (S.dead[c].reported /\ S.mon.reportSerial[c] = S.dead[c].serial
                /\ S.mon.reportAges[c] = 2),
          !.mon.pending = @ \ {c}]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1204-1206,1373-1382
WFCommDeadCheckDone ==
    /\ SJAlive /\ S.mon.pc = "dead" /\ S.mon.pending = {}
    /\ commSJ_f' = [commSJ_f EXCEPT !.mon.pc = "policy", !.mon.pending = Sites, !.mon.deadView = {}]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1373-1382
WFCommReadPolicyClient(c) ==
    /\ SJAlive /\ S.mon.pc = "policy" /\ c \in S.mon.pending
    /\ commSJ_f' = [commSJ_f EXCEPT !.mon.pending = @ \ {c},
          !.mon.deadView = IF S.dead[c].disconnected THEN @ \cup {c} ELSE @]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1384-1403,1206-1212; server_runner.py:253-257,675-679 (PANIC)
WFCommJobPolicyDecision ==
    /\ SJAlive /\ S.mon.pc = "policy" /\ S.mon.pending = {}
    /\ LET bad == S.mon.deadView /= {} /\
             (S.mon.deadView = Sites \/ Cardinality(Sites \ S.mon.deadView) < MinSites
              \/ S.mon.deadView \cap RequiredSites /= {})
       IN /\ commSJ_f' = [commSJ_f EXCEPT !.mon.pc = IF bad THEN "stopped" ELSE "acquire"]
          /\ pCommSJ' = [pCommSJ EXCEPT !.panic = @ \/ bad]
    /\ UNCHANGED net

\* wf_comm_server.py:1215-1223
WFCommMonitorAcquire ==
    /\ SJAlive /\ S.mon.pc = "acquire" /\ S.comm.kind = "free"
    /\ commSJ_f' = [commSJ_f EXCEPT !.mon.pc = "locked",
                       !.comm = [EmptyComm EXCEPT !.kind = "monitor", !.pc = "select"]]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1222-1252; bcast_manager.py:52-75: terminal status, then
\* the manager exit (all responses; with "minClients" min_responses reached and
\* the wait time elapsed), then the task timeout ("taskTimeout"), then the
\* dead-client lead time.
WFCommMonitorSelect(t) ==
    /\ SJAlive /\ S.comm.kind = "monitor" /\ S.comm.pc = "select" /\ TK(t).standing
    /\ LET out == Outstanding(t)
           minExit == "minClients" \in Faults /\ out /= Selected /\ TK(t).age = 1
           timeout == "taskTimeout" \in Faults /\ TK(t).age = 1
       IN commSJ_f' = [commSJ_f EXCEPT !.comm.id = <<t, None>>,
            !.comm.pc = IF TK(t).status /= "LIVE" THEN "remove"
                        ELSE IF out = {} \/ minExit \/ timeout THEN "mark" ELSE "deadScan",
            !.comm.exit = IF out = {} \/ minExit THEN "OK" ELSE IF timeout THEN "TIMEOUT" ELSE "LIVE",
            !.comm.pending = IF TK(t).age = 1 THEN out ELSE {},
            !.comm.deadView = {}]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1325-1340
WFCommReadTaskDeadClient(c) ==
    /\ SJAlive /\ S.comm.kind = "monitor" /\ S.comm.pc = "deadScan" /\ c \in S.comm.pending
    /\ commSJ_f' = [commSJ_f EXCEPT
          !.comm.pending = IF S.dead[c].disconnected THEN @ \ {c} ELSE {},
          !.comm.deadView = IF S.dead[c].disconnected THEN @ \cup {c} ELSE {},
          !.comm.exit = IF ~S.dead[c].disconnected THEN "LIVE"
                        ELSE IF S.comm.pending = {c} THEN "CLIENT_DEAD" ELSE @]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1247-1253,1325-1342
WFCommTaskDeadCheckDone ==
    /\ SJAlive /\ S.comm.kind = "monitor" /\ S.comm.pc = "deadScan" /\ S.comm.pending = {}
    /\ commSJ_f' = IF S.comm.exit = "CLIENT_DEAD"
                   THEN [commSJ_f EXCEPT !.comm.pc = "mark"]
                   ELSE [commSJ_f EXCEPT !.comm = EmptyComm, !.mon.pc = "idle"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1234-1239,1247-1252
WFCommMonitorMarkTerminal ==
    /\ SJAlive /\ S.comm.kind = "monitor" /\ S.comm.pc = "mark"
    /\ commSJ_f' = [commSJ_f EXCEPT !.task[S.comm.id[1]].status = S.comm.exit, !.comm.pc = "remove"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1255-1264,464-497: removal, received and unreceived
\* client tasks enter the ordered finite history.
\* A ClientTask listed twice in client_tasks: the second
\* _client_task_map.pop(client_task.id) (line 1259, no default) raises
\* KeyError; the task is already off the list (standing FALSE), the locks are
\* released by their with-blocks, and _monitor_tasks (no handler) ends, so the
\* exit callbacks are skipped and the monitor never runs again.
WFCommMonitorRemove ==
    /\ SJAlive /\ S.comm.kind = "monitor" /\ S.comm.pc = "remove"
    /\ LET t == S.comm.id[1]
           dup == Len(S.task[t].assignedOrder) > Cardinality(SeqSet(S.task[t].assignedOrder)) IN
       /\ commSJ_f' = [commSJ_f EXCEPT !.task[t].standing = FALSE,
             !.task[t].retiredStatus = S.task[t].status,
             !.task[t].retiredOutstanding = Outstanding(t),
             !.completed = Remember(t),
             !.comm = IF dup THEN EmptyComm ELSE [S.comm EXCEPT !.pc = "exitCleanup"],
             !.mon.pc = IF dup THEN "crashed" ELSE @]
       /\ pCommSJ' = [pCommSJ EXCEPT !.standing = IF t = P.round THEN FALSE ELSE @,
                                     !.monitorCrashed = @ \/ dup]
    /\ UNCHANGED net

\* wf_comm_server.py:1271-1310
WFCommMonitorCleanup ==
    /\ SJAlive /\ S.comm.kind = "monitor" /\ S.comm.pc = "exitCleanup"
    /\ commSJ_f' = [commSJ_f EXCEPT !.task[S.comm.id[1]].cleaned = TRUE,
                       !.comm = EmptyComm, !.mon.pc = "idle"]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:1222-1225,1268-1269
WFCommMonitorNoTask ==
    /\ SJAlive /\ S.comm.kind = "monitor" /\ S.comm.pc = "select"
    /\ \A t \in Tasks : ~S.task[t].standing
    /\ commSJ_f' = [commSJ_f EXCEPT !.comm = EmptyComm, !.mon.pc = "idle"]
    /\ UNCHANGED <<pCommSJ, net>>

\* ================================================================ teardown
\* server_runner.py:158-172: after control_flow returns, current_wf := None
\* under wf_lock (the seed's WORKFLOW_RETURNED rendezvous, COMM half).
ServerRunnerCloseWorkflow ==
    /\ SJAlive /\ pWfSJ.returned /= "none" /\ ~S.wfClosed /\ RunnerLockFree
    /\ commSJ_f' = [commSJ_f EXCEPT !.wfClosed = TRUE]
    /\ UNCHANGED <<pCommSJ, net>>

\* wf_comm_server.py:980-1046; server_runner.py:171-179: drain standing tasks,
\* clear the retired history.
WFCommFinalizeRun ==
    /\ SJAlive /\ S.wfClosed /\ ~P.finalized /\ S.comm.kind = "free" /\ S.mon.pc /= "dead"
    /\ commSJ_f' = [commSJ_f EXCEPT !.task = [t \in Tasks |-> [S.task[t] EXCEPT
             !.status = IF S.task[t].standing /\ @ = "LIVE" THEN "CANCELLED" ELSE @,
             !.retiredStatus = IF S.task[t].standing
                     THEN IF S.task[t].status = "LIVE" THEN "CANCELLED" ELSE S.task[t].status ELSE @,
             !.retiredOutstanding = IF S.task[t].standing THEN Outstanding(t) ELSE @,
             !.standing = FALSE, !.cleaned = S.task[t].scheduled]],
             !.completed = <<>>, !.mon.pc = "stopped"]
    /\ pCommSJ' = [pCommSJ EXCEPT !.finalized = TRUE, !.standing = FALSE]
    /\ UNCHANGED net

\* ---------------------------------------------------------------- invariants
\* (seed base.tla:1157-1206, group-local; checked in mixes with CommSJ = F)
ClaimBeforeFinish == \A t \in Tasks, c \in Sites : S.ct[t][c].receipt => S.ct[t][c].claimed
OneStandingTask == Cardinality({t \in Tasks : S.task[t].standing}) <= 1
CompletedHistoryBound == Len(S.completed) <= HistoryLimit
    /\ Cardinality(SeqSet(S.completed)) = Len(S.completed)
    /\ \A id \in SeqSet(S.completed) : CT(id).assigned /\ S.task[id[1]].status /= "LIVE"
CallerLockDiscipline ==
    /\ (S.comm.kind = "request" => S.runner.kind = "request")
    /\ (S.comm.kind = "submit" => S.runner.kind = "submit")
\* APP_CALL outstanding only while the submission holds both locks.
CallFrame == pCommSJ.call /= None => S.comm.kind = "submit" /\ S.comm.pc = "inApp"
CommSafety == ClaimBeforeFinish /\ OneStandingTask /\ CompletedHistoryBound
              /\ CallerLockDiscipline /\ CallFrame

Next ==
    \/ WFCommScheduleTask \/ WFCommCancelAllTasks
    \/ BasePrepareTaskData \/ BasePrepareTaskDataFailure \/ WFCommProtectBroadcast
    \/ WFCommProtectBroadcastFailure \/ WFCommCheckCanSend \/ WFCommPublishClientTask
    \/ WFCommTaskTryAgain \/ WFCommTaskUnavailable
    \/ ServerRunnerSubmissionActive \/ ServerRunnerDropClosedSubmission
    \/ ServerRunnerCheckSubmission \/ WFCommClaimSubmission \/ ServerRunnerRejectSubmission
    \/ WFCommAcquireSubmission \/ WFCommDispatchSubmission \/ WFCommStampReceipt
    \/ WFCommDropSubmission
    \/ ClockAdvance \/ WFCommMonitorBegin \/ WFCommMonitorClock \/ WFCommMonitorWatchList
    \/ WFCommDeadCheckDone \/ WFCommJobPolicyDecision \/ WFCommMonitorAcquire
    \/ WFCommTaskDeadCheckDone \/ WFCommMonitorMarkTerminal \/ WFCommMonitorRemove
    \/ WFCommMonitorCleanup \/ WFCommMonitorNoTask
    \/ ServerRunnerCloseWorkflow \/ WFCommFinalizeRun
    \/ \E c \in Sites : ServerRunnerAcquireTaskRequest(c)
    \/ \E c \in Sites : WFCommProcessTaskRequest(c)
    \/ \E c \in Sites : WFCommReportDeadClient(c)
    \/ \E c \in Sites : WFCommClientIsActive(c)
    \/ \E c \in Sites : WFCommCheckDeadClient(c)
    \/ \E c \in Sites : WFCommReadPolicyClient(c)
    \/ \E c \in Sites : WFCommReadTaskDeadClient(c)
    \/ \E t \in 1..Rounds : WFCommCancelTask(t)
    \/ \E t \in 1..Rounds : WFCommMonitorSelect(t)
    \/ \E t \in 1..Rounds, c \in Sites : WFCommResendTask(<<t, c>>)
    \/ \E t \in 1..Rounds, c \in Sites : ServerRunnerFilterTask(<<t, c>>)
    \/ \E t \in 1..Rounds, c \in Sites : ServerRunnerFilterFailure(<<t, c>>)
    \/ \E t \in 1..Rounds, c \in Sites : WFCommHandleException(<<t, c>>)
    \/ \E k \in DOMAIN net : ClientCheckTask(k)
    \/ \E k \in DOMAIN net : ServerRunnerRetryIncomplete(k)
    \/ \E k \in DOMAIN net : ServerRunnerProcessSubmission(k)
    \/ \E c \in Sites, k \in DOMAIN net : ServerRunnerTaskRequestActive(c, k)
    \/ \E c \in Sites, k \in DOMAIN net : ServerRunnerCheckTaskActive(c, k)
    \/ \E c \in Sites, k \in DOMAIN net : ServerRunnerReceiveSubmission(c, k)
=============================================================================
