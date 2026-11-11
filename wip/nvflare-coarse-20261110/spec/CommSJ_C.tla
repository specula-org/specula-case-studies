------------------------------ MODULE CommSJ_C ------------------------------
\* Group CommSJ, COARSE variant. Process: SJ.
\* Mechanisms: SCHEDULE ack, GET_TASK replies (ASSIGNED / TRY_AGAIN), TASK_CHECK
\* replies, envelope exposure to the payload receiver, claim, APP_CALL dispatch /
\* completion, RESULT_RECEIPT, task retirement, CANCEL_ALL ack, dead-client
\* policy panic, communicator finalize.
\* Over-approximates CommSJ_F on pCommSJ + TASK_ASSIGNMENT / TASK_CHECK_REPLY /
\* RESULT_RECEIPT: runner/communicator locks, publication, outbound filter,
\* the monitor, the dead-client watch and the workflow close are collapsed;
\* replies are chosen from port state and net (nondeterministic where the fine
\* variant's choice depends on private state, e.g. whether the workflow is
\* already closed between control_flow return and finalize).
\* Writes: commSJ_c, pCommSJ, net (sender SJ).
\* Anchors: server_runner.py:158-179,264-440,456-612; wf_comm_server.py:225-726,962-1046,1179-1310.
EXTENDS Ports
VARIABLE commSJ_c

\* called: <<round, site>> pairs whose APP_CALL was dispatched;
\* ckey[c]: id of the envelope whose claim succeeded in the current round.
\* deadEarly (v8): a dead-client report has matured through the 60 s grace;
\* after the workflow returned only with slowFinalize (timing TA4, CommSJ_F)
\* seen: dead-job notifications already put on the watch list (one report puts the client on
\* the list once; while it is there further reports are discarded, wf_comm_server.py:197-205)
Init == commSJ_c = [deadEarly |-> FALSE, called |-> {}, ckey |-> [c \in Sites |-> None], seen |-> {}]
InitValue == [deadEarly |-> FALSE, called |-> {}, ckey |-> [c \in Sites |-> None], seen |-> {}]

P == pCommSJ
Aborted == pCommSJ.panic \/ pWfSJ.panic
Cur == pCommSJ.round
\* The workflow is open until control_flow returns and the runner unsets
\* current_wf (private to the fine variant): both answers allowed in between.
MaybeOpen == pWfSJ.open /\ ~P.finalized
MaybeClosed == pWfSJ.returned /= "none"
IsFrom(k, kind, c) == net[k].msg.kind = kind /\ net[k].msg.from = CJ(c)
IsEnv(k, c) == IsFrom(k, "RESULT_ENVELOPE", c)
Replied(kind, k) == MsgKey(kind, SJ, M(k).from, M(k).id) \in DOMAIN net
\* Receiver attempt of site c for round a (PayRcv port, one per (site, round)).
Rx(c, a) == pPayRcv[c].rx[a]
Materialized(c, a, refs) == Rx(c, a).status = "materialized" /\ Rx(c, a).want \in refs
RetireFaults == ({"cancel", "prepFail", "taskTimeout", "minClients", "deadClient"} \cap Faults /= {})
                \/ pReg.notified /= {}     \* v8: dead-client reports come from Reg
NonLiveFaults == {"cancel", "prepFail"} \cap Faults /= {} \/ P.cancelled = Cur
\* v11: a result callback of the current round raised; WFComm set the task's
\* completion status to ERROR, so the task exits (wf_comm_server.py:657-672).
CbRaised == RaiseTracked /\ Cur \in pWfSJ.raised
\* v11: standing groups of tasks whose resend may list a ClientTask twice
DupTasks == {"cseTasks", "cseServer"} \cap Profile /= {}
\* a resend: the server sent the current round's assignment to the same client twice (its first
\* ASSIGNED reply did not arrive and the client asked again); the second send lists the same
\* ClientTask again (wf_comm_server.py:340-380). The net is append-only, so the evidence stays.
Resent == \E k, k2 \in DOMAIN net :
            /\ k /= k2
            /\ net[k].msg.kind = "TASK_ASSIGNMENT" /\ net[k2].msg.kind = "TASK_ASSIGNMENT"
            /\ net[k].msg.body.status = "ASSIGNED" /\ net[k2].msg.body.status = "ASSIGNED"
            /\ net[k].msg.to = net[k2].msg.to
            /\ net[k].msg.body.assignment.attempt = Cur /\ net[k2].msg.body.assignment.attempt = Cur
\* (swarm, sampling) the round's task targets only pWfSJ.targets
Tgt == IF Has(pWfSJ, "targets") THEN pWfSJ.targets ELSE Sites

\* @L CommSJ.wfc.schedule
ScheduleTask ==
    /\ SJAlive /\ pWfSJ.scheduled > Cur /\ pWfSJ.scheduled \in 1..Rounds
    /\ pCommSJ' = [pCommSJ EXCEPT !.round = pWfSJ.scheduled, !.standing = TRUE,
                     !.envelopes = [c \in Sites |-> None], !.claimed = {}, !.finished = {}]
    /\ commSJ_c' = [commSJ_c EXCEPT !.ckey = [c \in Sites |-> None]]
    /\ UNCHANGED net

\* @L CommSJ.runner.taskReq
SendAssignment(c, k) ==
    /\ SJAlive /\ IsFrom(k, "GET_TASK", c) /\ ~Replied("TASK_ASSIGNMENT", k)
    /\ Cur >= 1 /\ pWfSJ.open /\ c \in Tgt
    /\ \E r \in 1..Cur :
         net' = Send(net, Msg("TASK_ASSIGNMENT", SJ, CJ(c), M(k).id,
                   [status |-> "ASSIGNED", assignment |-> Assignment(c, r),
                    input |-> TaskInput(Assignment(c, r))]))
    /\ UNCHANGED <<commSJ_c, pCommSJ>>

\* @L CommSJ.runner.taskReq
TryAgain(c, k) ==
    /\ SJAlive /\ IsFrom(k, "GET_TASK", c) /\ ~Replied("TASK_ASSIGNMENT", k) /\ Cur >= 1
    /\ \/ NonLiveFaults \/ MaybeClosed \/ ~P.standing \/ c \in P.finished \/ c \notin Tgt
       \/ \E k2 \in DOMAIN net : /\ net[k2].msg.kind = "TASK_ASSIGNMENT" /\ net[k2].msg.to = CJ(c)
                                 /\ net[k2].msg.body.status = "ASSIGNED"
       \/ \E k2 \in DOMAIN net : IsFrom(k2, "GET_TASK", c) /\ k2 /= k
    /\ net' = Send(net, Msg("TASK_ASSIGNMENT", SJ, CJ(c), M(k).id,
                 [status |-> "TRY_AGAIN", assignment |-> None, input |-> None]))
    /\ UNCHANGED <<commSJ_c, pCommSJ>>

\* Readiness check: RETRY while known and unclaimed, RECEIVED once claimed,
\* TASK_CLOSED when the workflow closed / aborted (or for another round).
\* @L CommSJ.runner.submission
AnswerCheck(c, k) ==
    /\ SJAlive /\ IsFrom(k, "TASK_CHECK", c) /\ ~Replied("TASK_CHECK_REPLY", k)
    /\ LET cur == M(k).body.assignment.attempt = Cur
           open == MaybeOpen /\ ~Aborted
           closed == MaybeClosed \/ Aborted \/ P.finalized \/ ~pWfSJ.open
       IN \E b \in {"RETRY", "RECEIVED", "TASK_CLOSED"} :
            /\ \/ b = "TASK_CLOSED" /\ (closed \/ ~cur)
               \/ b = "RECEIVED" /\ open /\ (c \in P.claimed \/ ~cur)
               \/ b = "RETRY" /\ open /\ (c \notin P.claimed \/ ~cur)
            /\ net' = Send(net, Msg("TASK_CHECK_REPLY", SJ, CJ(c), M(k).id, b))
    /\ UNCHANGED <<commSJ_c, pCommSJ>>

\* First envelope of the current round with source-backed refs is handed to
\* the payload receiver (lazy-ref decode).
\* @L CommSJ.runner.submission
RecvEnvelope(c, k) ==
    /\ SJAlive /\ IsEnv(k, c) /\ P.envelopes[c] = None
    /\ M(k).body.refs /= {} /\ M(k).body.assignment.attempt = Cur
    /\ pCommSJ' = [pCommSJ EXCEPT !.envelopes[c] = [assignment |-> M(k).body.assignment,
                                                    refs |-> M(k).body.refs]]
    /\ UNCHANGED <<commSJ_c, net>>

\* Claim of a complete (materialized) payload for a known, unclaimed assignment.
\* @L CommSJ.runner.submission
Claim(c, k) ==
    /\ SJAlive /\ c \notin P.claimed /\ ~P.finalized
    /\ IsEnv(k, c) /\ ~Replied("RESULT_RECEIPT", k) /\ M(k).body.assignment.attempt = Cur
    /\ M(k).body.refs = {} \/ Materialized(c, Cur, M(k).body.refs)
    /\ pCommSJ' = [pCommSJ EXCEPT !.claimed = @ \cup {c}]
    /\ commSJ_c' = [commSJ_c EXCEPT !.ckey[c] = M(k).id]
    /\ UNCHANGED net

EnvKey(c) == MsgKey("RESULT_ENVELOPE", CJ(c), SJ, commSJ_c.ckey[c])

\* APP_CALL for the claimed envelope: live for a standing LIVE task, unknown-result
\* hook otherwise.
\* @L CommSJ.runner.submission
Dispatch(c) ==
    /\ SJAlive /\ c \in P.claimed /\ P.call = None /\ <<Cur, c>> \notin commSJ_c.called
    /\ commSJ_c.ckey[c] /= None
    /\ LET k == EnvKey(c) IN
       \E kind \in (IF ~P.standing THEN {"unknown"}
                    ELSE IF NonLiveFaults THEN {"live", "unknown"} ELSE {"live"}) :
         pCommSJ' = [pCommSJ EXCEPT !.call =
               [site |-> c, round |-> Cur, kind |-> kind, key |-> M(k).id,
                assignment |-> M(k).body.assignment,
                value |-> IF M(k).body.refs = {} THEN None
                          ELSE Rx(c, M(k).body.assignment.attempt).materialized,
                rc |-> M(k).body.rc, metricKind |-> "none"]]
    /\ commSJ_c' = [commSJ_c EXCEPT !.called = @ \cup {<<Cur, c>>}]
    /\ UNCHANGED net

\* APP_RETURN consumed: callback-finish stamp and RECEIVED receipt.
\* @L CommSJ.runner.submission
Complete(c) ==
    /\ SJAlive /\ P.call /= None /\ P.call.site = c
    /\ pWfSJ.ret = [site |-> c, round |-> P.call.round]
    /\ net' = Send(net, Msg("RESULT_RECEIPT", SJ, CJ(c), P.call.key, "RECEIVED"))
    /\ pCommSJ' = [pCommSJ EXCEPT !.call = None,
          !.finished = IF P.standing /\ P.call.round = Cur THEN @ \cup {c} ELSE @]
    /\ UNCHANGED commSJ_c

\* Receipt for an envelope that is not the claimed one: duplicate (RECEIVED),
\* closed / aborted / unknown (TASK_CLOSED), undecodable payload (RETRY).
\* @L CommSJ.runner.submission
Reject(c, k) ==
    /\ SJAlive /\ IsEnv(k, c) /\ ~Replied("RESULT_RECEIPT", k)
    /\ M(k).id /= commSJ_c.ckey[c]
    \* one reply per submission: not the envelope whose APP_CALL is in progress
    \* (its receipt comes from Complete, possibly after a new round reset ckey)
    /\ IF P.call = None THEN TRUE ELSE M(k).id /= P.call.key
    /\ LET a == M(k).body.assignment
           cur == a.attempt = Cur
       IN \E b \in {"RECEIVED", "TASK_CLOSED", "RETRY"} :
            /\ \/ b = "RECEIVED" /\ (c \in P.claimed \/ ~cur)
               \/ b = "TASK_CLOSED" /\ (MaybeClosed \/ ~pWfSJ.open \/ Aborted \/ pWfSJ.done \/ ~cur)
               \/ b = "RETRY" /\ M(k).body.refs /= {}
                              /\ Rx(c, a.attempt).status = "failed" /\ Rx(c, a.attempt).want \in M(k).body.refs
            /\ net' = Send(net, Msg("RESULT_RECEIPT", SJ, CJ(c), M(k).id, b))
    /\ UNCHANGED <<commSJ_c, pCommSJ>>

\* Monitor retirement (no retirement while an APP_CALL holds the communicator).
\* Profile cseTasks: a retirement may find a ClientTask listed twice (after a
\* resend) and kill the monitor thread (fine WFCommMonitorRemove); a dead
\* monitor retires nothing and checks no dead-client policy.
\* @L CommSJ.wfc.resendDup, CommSJ.wfc.monitor
Retire ==
    /\ SJAlive /\ P.standing /\ P.call = None /\ P.monitorCrashed = "no"
    /\ Tgt \subseteq P.finished \/ RetireFaults \/ P.cancelled = Cur \/ CbRaised
    /\ \/ pCommSJ' = [pCommSJ EXCEPT !.standing = FALSE]
       \* a resend happens only after the client did not get the ASSIGNED reply (lost) or its
       \* get-task request timed out, and asks again (wf_comm_server.py:340-380)
       \/ /\ DupTasks /\ Resent /\ FedLossyIn(Faults)
          /\ pCommSJ' = [pCommSJ EXCEPT !.standing = FALSE, !.monitorCrashed = "CommSJ.wfc.resendDup"]
    /\ UNCHANGED <<commSJ_c, net>>

\* @L CommSJ.wfc.cancelAll
CancelAllAck ==
    /\ SJAlive /\ pWfSJ.cancelAll > P.cancelled
    /\ pCommSJ' = [pCommSJ EXCEPT !.cancelled = pWfSJ.cancelAll]
    /\ UNCHANGED <<commSJ_c, net>>

\* @L CommSJ.wfc.deadClients
PolicyPanic ==
    /\ SJAlive /\ commSJ_c.deadEarly /\ ~P.panic /\ ~P.finalized /\ P.monitorCrashed = "no"
    /\ pCommSJ' = [pCommSJ EXCEPT !.panic = TRUE,
                     !.panicBy = IF pWfSJ.returned /= "none" THEN "CommSJ.wfc.deadClients" ELSE @]
    /\ UNCHANGED <<commSJ_c, net>>

\* @L CommSJ.runner.finalize
FinalizeRun ==
    /\ SJAlive /\ pWfSJ.returned /= "none" /\ ~P.finalized /\ P.call = None
    /\ pCommSJ' = [pCommSJ EXCEPT !.finalized = TRUE, !.standing = FALSE]
    /\ UNCHANGED <<commSJ_c, net>>

\* @L CommSJ.wfc.deadClients, Timing.TA4
Mature ==
    /\ ~commSJ_c.deadEarly /\ SJAlive /\ pReg.notified \ commSJ_c.seen /= {}
    /\ TimingOK(Faults, "slowFinalize", TA4Holds(pWfSJ.returned))
    /\ commSJ_c' = [commSJ_c EXCEPT !.deadEarly = TRUE, !.seen = pReg.notified]
    /\ UNCHANGED <<pCommSJ, net>>
\* the client is active again (a request from it, wf_comm_server.py:1405-1415)
\* @L CommSJ.wfc.deadClients
Unmature ==
    /\ commSJ_c.deadEarly
    /\ commSJ_c' = [commSJ_c EXCEPT !.deadEarly = FALSE]
    /\ UNCHANGED <<pCommSJ, net>>

Next ==
    \/ Mature \/ Unmature
    \/ ScheduleTask \/ Retire \/ CancelAllAck \/ PolicyPanic \/ FinalizeRun
    \/ \E c \in Sites : Dispatch(c) \/ Complete(c)
    \/ \E c \in Sites, k \in DOMAIN net :
         SendAssignment(c, k) \/ TryAgain(c, k) \/ AnswerCheck(c, k) \/ RecvEnvelope(c, k)
         \/ Claim(c, k) \/ Reject(c, k)
=============================================================================
