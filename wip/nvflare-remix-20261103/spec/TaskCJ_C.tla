------------------------------ MODULE TaskCJ_C ------------------------------
\* Group TaskCJ, COARSE variant. Process: CJ(c), per launch l.
\* Mechanisms: client runner task fetch (GET_TASK), assignment receipt,
\* in-process executor handshake with the Trainer group (input / trainerSignal),
\* result submission loop (TASK_CHECK, serialization = payload source
\* registration, RESULT_ENVELOPE, retry), END_RUN abort of the submission.
\* Over-approximates TaskCJ_F on pTaskCJ + GET_TASK / TASK_CHECK / RESULT_ENVELOPE:
\* reply / receipt consumption, local timeouts and the END_RUN reaction are
\* port-invisible in the fine variant and are not modeled here; a submission
\* may be retried (up to FedMaxTryIn(Faults)) regardless of replies, and the next GET_TASK
\* may follow as soon as a final reply for the current task exists in net.
\* Writes: taskCJ_c, pTaskCJ, net (sender CJ(c)).
\* Anchors: client_runner.py:245-277,585-789,1084-1089; in_process_backend.py:152-260.
\* taskMode (v10): results come from pWorker[c].out[l]; abort / receipt / fatal
\* port fields as in TaskCJ_F.
EXTENDS Ports
VARIABLE taskCJ_c

\* asg: assignment in hand; task: tasks received in this launch; got: poll whose
\* reply was taken; result: [rc, value] once the first TASK_CHECK was sent.
Init == taskCJ_c = [c \in Sites |-> [l \in Launches |->
                      [asg |-> None, task |-> 0, got |-> 0, result |-> None]]]
InitValue == [c \in Sites |-> [l \in Launches |->
                      [asg |-> None, task |-> 0, got |-> 0, result |-> None]]]

T(c, l) == taskCJ_c[c][l]
Pt(c, l) == pTaskCJ[c][l]
Running(c, l) == CJAlive(c, l) /\ pRunCJ[c][l].ready /\ pRunCJ[c][l].state = "running"
Sent(kind, c, l) == {k \in DOMAIN net : net[k].msg.kind = kind /\ net[k].msg.from = CJ(c)
                                        /\ net[k].msg.id[3] = l}
SentForTask(kind, c, l) == {k \in Sent(kind, c, l) : net[k].msg.id[4] = T(c, l).task}
Tries(c, l) == Cardinality(SentForTask("TASK_CHECK", c, l))
Polls(c, l) == Cardinality(Sent("GET_TASK", c, l))
SubmitId(c, l, n) == <<JobId, c, l, T(c, l).task, n>>
\* taskMode: the worker outcome of the current task (None if stale or absent).
WorkerOut(c, l) == IF pWorker[c].out[l] /= None /\ pWorker[c].out[l].gen = T(c, l).task
                   THEN pWorker[c].out[l] ELSE None
\* The readiness check of try n was answered RETRY (the fine variant uploads only then).
RetryAnswered(c, l, n) ==
    LET k == MsgKey("TASK_CHECK_REPLY", SJ, CJ(c), SubmitId(c, l, n))
    IN k \in DOMAIN net /\ net[k].msg.body = "RETRY"
EndRunTo(c) == MsgKey("END_RUN", SJ, CJ(c), <<JobId, c>>) \in DOMAIN net
\* A final reply (RECEIVED / TASK_CLOSED) for the current task exists, or the run ended.
FinalReply(c, l) ==
    \/ EndRunTo(c)
    \/ \E k \in DOMAIN net :
         /\ net[k].msg.kind \in {"RESULT_RECEIPT", "TASK_CHECK_REPLY"} /\ net[k].msg.to = CJ(c)
         /\ net[k].msg.id[3] = l /\ net[k].msg.id[4] = T(c, l).task
         /\ net[k].msg.body \in {"RECEIVED", "TASK_CLOSED"}

\* Finite-instance hook for the generic deadlock check (see TaskCJ_F).
AtBound == \E c \in Sites, l \in Launches :
    \/ Running(c, l) /\ (T(c, l).asg = None \/ FinalReply(c, l)) /\ Polls(c, l) >= FedMaxPollIn(Faults)
    \* TASK_CHECK retries exhausted (the real client retries without bound)
    \/ Running(c, l) /\ T(c, l).asg /= None /\ ~FinalReply(c, l) /\ Tries(c, l) >= FedMaxTryIn(Faults)

RequestTask(c, l) ==
    /\ Running(c, l) /\ (T(c, l).asg = None \/ FinalReply(c, l))
    /\ Polls(c, l) < FedMaxPollIn(Faults)
    /\ LET p == Polls(c, l) + 1 IN
       net' = Send(net, Msg("GET_TASK", CJ(c), SJ, <<JobId, c, l, p>>, [launch |-> l, poll |-> p]))
    /\ UNCHANGED <<taskCJ_c, pTaskCJ>>

\* Reply to the latest poll; a new task resets the per-task port field.
RecvAssignment(c, l, k) ==
    /\ CJAlive(c, l) /\ InInbox(k, CJ(c), "TASK_ASSIGNMENT") /\ M(k).body.status = "ASSIGNED"
    /\ M(k).id[3] = l /\ M(k).id[4] = Polls(c, l) /\ Polls(c, l) > T(c, l).got
    /\ T(c, l).asg = None \/ FinalReply(c, l)
    /\ taskCJ_c' = [taskCJ_c EXCEPT ![c][l].task = @ + 1, ![c][l].got = Polls(c, l),
                                    ![c][l].asg = M(k).body.assignment, ![c][l].result = None]
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].submission = None]
    /\ UNCHANGED net

\* Executor publishes the task data to the in-process trainer (GLOBAL_RESULT).
PublishInput(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).asg /= None
    /\ IF Pt(c, l).input = None THEN TRUE ELSE Pt(c, l).input.gen < T(c, l).task
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].input =
          [gen |-> T(c, l).task, assignment |-> T(c, l).asg, value |-> TaskInput(T(c, l).asg)]]
    /\ UNCHANGED <<taskCJ_c, net>>

\* TOPIC_ABORT (END_RUN, result wait timeout) or TOPIC_STOP (finalize after END_RUN).
SignalTrainer(c, l) ==
    /\ CJAlive(c, l)
    /\ \E s \in {"abort", "stop"} :
         /\ s /= Pt(c, l).trainerSignal
         /\ s = "abort" => T(c, l).asg /= None /\ ("resultWaitTimeout" \in Faults \/ EndRunTo(c))
         /\ s = "stop" => EndRunTo(c)
         /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].trainerSignal = s]
    /\ UNCHANGED <<taskCJ_c, net>>

\* Result taken (trainer publication or EXECUTION_EXCEPTION) and first TASK_CHECK.
FirstCheck(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).asg /= None /\ Tries(c, l) = 0
    /\ \E rc \in {"OK", "EXECUTION_EXCEPTION"} :
         /\ ~TaskMode =>
              /\ rc = "OK" => pTrainer[c][l].published /= None
              /\ rc /= "OK" => "resultWaitTimeout" \in Faults \/ pTrainer[c][l].stopped
                               \/ pTrainer[c][l].err >= T(c, l).task   \* v11 Attach (Trainer_A)
         /\ TaskMode =>
              /\ WorkerOut(c, l) /= None
              /\ rc = "OK" => WorkerOut(c, l).kind = "result"
              /\ rc /= "OK" => WorkerOut(c, l).kind \in {"error", "aborted"}
         /\ taskCJ_c' = [taskCJ_c EXCEPT ![c][l].result =
               [rc |-> rc, value |-> IF rc /= "OK" THEN None
                                     ELSE IF TaskMode THEN <<"result", c, T(c, l).task>>
                                     ELSE pTrainer[c][l].published.value]]
    /\ net' = Send(net, Msg("TASK_CHECK", CJ(c), SJ, SubmitId(c, l, 1),
                 [assignment |-> T(c, l).asg, try |-> 1]))
    /\ UNCHANGED pTaskCJ

\* TaskExecutionInterrupted: the CJ exits nonzero (no reply).
WorkerInterrupted(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ T(c, l).asg /= None /\ Tries(c, l) = 0
    /\ WorkerOut(c, l) /= None /\ WorkerOut(c, l).kind = "interrupted"
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].fatal = TRUE]
    /\ UNCHANGED <<taskCJ_c, net>>
\* END_RUN latches run_abort_signal.
LatchAbort(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ EndRunTo(c) /\ ~Pt(c, l).abort
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].abort = TRUE]
    /\ UNCHANGED <<taskCJ_c, net>>
\* The final RECEIVED / TASK_CLOSED reply of the current task (AFTER_SEND_TASK_RESULT).
RecordReceipt(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ T(c, l).asg /= None
    /\ Pt(c, l).receipt = None \/ Pt(c, l).receipt.gen < T(c, l).task
    /\ \E k \in DOMAIN net :
         /\ net[k].msg.kind \in {"RESULT_RECEIPT", "TASK_CHECK_REPLY"} /\ net[k].msg.to = CJ(c)
         /\ net[k].msg.id[3] = l /\ net[k].msg.id[4] = T(c, l).task
         /\ net[k].msg.body \in {"RECEIVED", "TASK_CLOSED"}
         /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].receipt = [gen |-> T(c, l).task, body |-> net[k].msg.body]]
    /\ UNCHANGED <<taskCJ_c, net>>

RetryCheck(c, l) ==
    /\ Running(c, l) /\ Tries(c, l) >= 1 /\ Tries(c, l) < FedMaxTryIn(Faults)
    /\ net' = Send(net, Msg("TASK_CHECK", CJ(c), SJ, SubmitId(c, l, Tries(c, l) + 1),
                 [assignment |-> T(c, l).asg, try |-> Tries(c, l) + 1]))
    /\ UNCHANGED <<taskCJ_c, pTaskCJ>>

\* Serialization registers the payload source transaction (one per task).
Serialize(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).result /= None /\ T(c, l).result.rc = "OK"
    /\ Pt(c, l).submission = None /\ Tries(c, l) >= 1 /\ RetryAnswered(c, l, Tries(c, l))
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].submission =
          [assignment |-> T(c, l).asg, value |-> T(c, l).result.value,
           tx |-> Tx(c, l, T(c, l).asg.attempt)]]
    /\ UNCHANGED <<taskCJ_c, net>>

\* The registered transaction of this task's round (Tx(c, l, attempt), PaySrc port).
TxReg(c, l) == pPaySrc[c][l].tx[T(c, l).asg.attempt].registered

SendEnvelope(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).result /= None /\ Tries(c, l) >= 1
    /\ RetryAnswered(c, l, Tries(c, l))
    /\ MsgKey("RESULT_ENVELOPE", CJ(c), SJ, SubmitId(c, l, Tries(c, l))) \notin DOMAIN net
    /\ T(c, l).result.rc = "OK" =>
         /\ Pt(c, l).submission /= None /\ TxReg(c, l) /= None
         /\ TxReg(c, l).ref = Ref(c, l, T(c, l).asg.attempt)
    /\ net' = Send(net, Msg("RESULT_ENVELOPE", CJ(c), SJ, SubmitId(c, l, Tries(c, l)),
          [assignment |-> T(c, l).asg, rc |-> T(c, l).result.rc,
           refs |-> IF T(c, l).result.rc = "OK"
                    THEN {[ref |-> TxReg(c, l).ref, source |-> TxReg(c, l).source, launch |-> l]}
                    ELSE {}]))
    /\ UNCHANGED <<taskCJ_c, pTaskCJ>>

Next == \E c \in Sites, l \in Launches :
    \/ RequestTask(c, l) \/ PublishInput(c, l) \/ SignalTrainer(c, l) \/ FirstCheck(c, l)
    \/ RetryCheck(c, l) \/ Serialize(c, l) \/ SendEnvelope(c, l)
    \/ WorkerInterrupted(c, l) \/ LatchAbort(c, l) \/ RecordReceipt(c, l)
    \/ \E k \in DOMAIN net : RecvAssignment(c, l, k)
=============================================================================
