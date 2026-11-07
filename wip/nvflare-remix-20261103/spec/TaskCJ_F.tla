------------------------------ MODULE TaskCJ_F ------------------------------
\* Group TaskCJ, FINE variant. Process: CJ(c), per launch l. Partition
\* FED_CLIENT of the fedavg seed (inputs/seeds/fedavg/spec/base.tla, pin
\* c411a201) plus the in-process executor (in_process_backend.py:152-260).
\* Client runner pull loop (client_runner.py:585-654), task receipt, executor
\* handshake with the Trainer group, result submission loop
\* (_send_task_result / _try_send_result_once / _check_task_once,
\* client_runner.py:656-789), END_RUN abort (client_runner.py:1084-1089).
\* Re-encoding of the seed: s.ct[t][c].delivery/result and s.net[t][c][n]
\* (stage, outcome, receipt) become CJ-local state plus messages:
\*  * ClientProcessTask(id, "params", "none"): the result now comes from the
\*    Trainer group's publication (pTrainer), not a nondeterministic choice;
\*  * ClientCheckTask (CJ half): consumption of TASK_CHECK_REPLY;
\*  * ServerCommandDispatchAck: consumption of RESULT_RECEIPT;
\*  * ClientLoseDispatchAck: local submit timeout (Faults submitTimeout / netLoss),
\*    guarded only by the CJ-local "receipt waiting" state, not the SJ stage;
\*  * TaskDeliveryFailure (ENV): lost TASK_ASSIGNMENT (Net L) + get-task timeout.
\* Slice: one result transaction per (site, launch, server attempt = round):
\* each round's submission registers Tx(c, l, round); later submission tries of
\* the same round reuse its registered descriptor.
EXTENDS Ports
VARIABLE taskCJ_f

\* phase: idle | got | published | waitResult | result | check | send | wait | retry | done
EmptyLaunch == [poll |-> 0, pollWait |-> FALSE, task |-> 0, asg |-> None, data |-> None,
                phase |-> "idle", baseline |-> 0, result |-> None, try |-> 0,
                abort |-> FALSE, endRun |-> FALSE, finalized |-> FALSE, handled |-> {},
                chandled |-> {}, done |-> FALSE, receipt |-> "none", got |-> 0]
InitValue == [c \in Sites |-> [l \in Launches |-> EmptyLaunch]]
Init == taskCJ_f = InitValue

T(c, l) == taskCJ_f[c][l]
Pt(c, l) == pTaskCJ[c][l]
Tr(c, l) == pTrainer[c][l]
Running(c, l) == CJAlive(c, l) /\ pRunCJ[c][l].ready /\ pRunCJ[c][l].state = "running"
Lossy == FedLossyIn(Faults)
SubmitId(c, l, n) == <<JobId, c, l, T(c, l).task, n>>
PubSeq(c, l) == IF Tr(c, l).published = None THEN 0 ELSE Tr(c, l).published.seq
Active(c, l) == T(c, l).phase \in {"result", "check", "send", "wait", "retry"}
Upd(c, l, r) == [taskCJ_f EXCEPT ![c][l] = r]

\* Abstraction to TaskCJ_C's private state.
AbsC == [c \in Sites |-> [l \in Launches |->
           [asg |-> T(c, l).asg, task |-> T(c, l).task, got |-> T(c, l).got,
            result |-> IF T(c, l).try >= 1 THEN T(c, l).result ELSE None]]]
AbsCInit == [c \in Sites |-> [l \in Launches |->
           [asg |-> None, task |-> 0, got |-> 0, result |-> None]]]

\* Finite-instance hook for the generic deadlock check: the client would poll
\* again (idle, no poll in flight) but its per-launch poll budget is used up.
\* The real client polls without bound, so such a state is "bounded out".
AtBound == \E c \in Sites, l \in Launches :
    \/ /\ Running(c, l) /\ ~T(c, l).endRun /\ T(c, l).phase \in {"idle", "done"}
       /\ ~T(c, l).pollWait /\ T(c, l).poll >= FedMaxPollIn(Faults)
    \* the real _send_task_result retries TASK_CHECK without bound
    \* (client_runner.py:656-678); the model stops at FedMaxTryIn(Faults) tries
    \/ /\ Running(c, l) /\ ~T(c, l).endRun /\ T(c, l).phase = "retry" /\ T(c, l).try >= FedMaxTryIn(Faults)

\* ---------------------------------------------------------------- pull loop
\* client_runner.py:613-617: get_task_assignment (GET_TASK), only when idle.
ClientGetTask(c, l) ==
    /\ Running(c, l) /\ ~T(c, l).endRun /\ T(c, l).phase \in {"idle", "done"}
    /\ ~T(c, l).pollWait /\ T(c, l).poll < FedMaxPollIn(Faults)
    /\ LET p == T(c, l).poll + 1 IN
       /\ net' = Send(net, Msg("GET_TASK", CJ(c), SJ, <<JobId, c, l, p>>, [launch |-> l, poll |-> p]))
       /\ taskCJ_f' = [taskCJ_f EXCEPT ![c][l].poll = p, ![c][l].pollWait = TRUE]
    /\ UNCHANGED pTaskCJ

PollReply(c, l, k) == /\ InInbox(k, CJ(c), "TASK_ASSIGNMENT") /\ k \notin T(c, l).handled
                      /\ M(k).id = <<JobId, c, l, T(c, l).poll>> /\ T(c, l).pollWait

\* client_runner.py:245-277,620-648 (seed ClientReceiveTask): assignment decoded.
ClientReceiveTask(c, l, k) ==
    /\ CJAlive(c, l) /\ PollReply(c, l, k) /\ M(k).body.status = "ASSIGNED"
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.handled = @ \cup {k}, !.chandled = @ \cup {k},
                     !.pollWait = FALSE, !.task = @ + 1, !.asg = M(k).body.assignment, !.data = M(k).body.input,
                     !.phase = "got", !.result = None, !.try = 0, !.done = FALSE,
                     !.receipt = "none", !.got = T(c, l).poll])
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].submission = None]
    /\ UNCHANGED net

\* client_runner.py:629-637: TRY_AGAIN -> poll again later.
ClientReceiveTryAgain(c, l, k) ==
    /\ CJAlive(c, l) /\ PollReply(c, l, k) /\ M(k).body.status = "TRY_AGAIN"
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.handled = @ \cup {k}, !.pollWait = FALSE])
    /\ UNCHANGED <<pTaskCJ, net>>

\* get_task_timeout: no reply (lost or late assignment, seed TaskDeliveryFailure).
ClientGetTaskTimeout(c, l) ==
    /\ Lossy /\ CJAlive(c, l) /\ T(c, l).pollWait
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.pollWait = FALSE])
    /\ UNCHANGED <<pTaskCJ, net>>

\* ---------------------------------------------------------------- executor
\* in_process_backend.py:152-192: execute(); stale result dropped (baseline),
\* GLOBAL_RESULT published to the trainer.
ExecutorPublishTask(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "got" /\ ~T(c, l).endRun /\ ~T(c, l).abort
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "published", !.baseline = PubSeq(c, l)])
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].input =
          [gen |-> T(c, l).task, assignment |-> T(c, l).asg, value |-> T(c, l).data]]
    /\ UNCHANGED net

\* in_process_backend.py:162-173: latched _abort -> EXECUTION_EXCEPTION, fail fast.
ExecutorFailFast(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "got" /\ ~T(c, l).endRun /\ T(c, l).abort
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "result",
                     !.result = [rc |-> "EXECUTION_EXCEPTION", value |-> None]])
    /\ UNCHANGED <<pTaskCJ, net>>

\* in_process_backend.py:155-157,212-216: abort_signal (END_RUN) -> TOPIC_ABORT,
\* TASK_ABORTED; the submission loop then stops at once (client_runner.py:661-663).
ExecutorAbortSignal(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).endRun /\ T(c, l).phase \in {"got", "waitResult"}
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "done"])
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].trainerSignal = "abort"]
    /\ UNCHANGED net

\* DataBus publish returns once the trainer callback accepted the input.
ExecutorPublished(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "published" /\ Tr(c, l).received >= T(c, l).task
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "waitResult"])
    /\ UNCHANGED <<pTaskCJ, net>>

\* in_process_backend.py:200-212 + seed ClientProcessTask: a newer LOCAL_RESULT
\* publication (any generation) is the task result; the runner then starts
\* _send_task_result with TASK_CHECK try 1.
ClientProcessTask(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "waitResult" /\ ~T(c, l).endRun /\ ~T(c, l).abort
    /\ PubSeq(c, l) > T(c, l).baseline
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "check", !.try = 1,
                     !.result = [rc |-> "OK", value |-> Tr(c, l).published.value]])
    /\ net' = Send(net, Msg("TASK_CHECK", CJ(c), SJ, SubmitId(c, l, 1),
                 [assignment |-> T(c, l).asg, try |-> 1]))
    /\ UNCHANGED pTaskCJ

\* in_process_backend.py:220-226: trainer thread gone without a result.
ExecutorTrainerExited(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "waitResult" /\ ~T(c, l).endRun
    /\ Tr(c, l).stopped /\ PubSeq(c, l) <= T(c, l).baseline
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "result", !.abort = TRUE,
                     !.result = [rc |-> "EXECUTION_EXCEPTION", value |-> None]])
    /\ UNCHANGED <<pTaskCJ, net>>

\* in_process_backend.py:228-236 (fault resultWaitTimeout): TOPIC_ABORT to the
\* trainer, EXECUTION_EXCEPTION; the trainer is gone for the rest of the job.
ExecutorResultTimeout(c, l) ==
    /\ "resultWaitTimeout" \in Faults /\ CJAlive(c, l) /\ T(c, l).phase = "waitResult"
    /\ ~T(c, l).endRun /\ PubSeq(c, l) <= T(c, l).baseline
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "result", !.abort = TRUE,
                     !.result = [rc |-> "EXECUTION_EXCEPTION", value |-> None]])
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].trainerSignal = "abort"]
    /\ UNCHANGED net

\* Error reply submitted like any result (seed ClientExecutionError): TASK_CHECK 1.
ClientExecutionError(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "result" /\ ~T(c, l).endRun
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "check", !.try = 1])
    /\ net' = Send(net, Msg("TASK_CHECK", CJ(c), SJ, SubmitId(c, l, 1),
                 [assignment |-> T(c, l).asg, try |-> 1]))
    /\ UNCHANGED pTaskCJ

\* ---------------------------------------------------------------- submission
\* client_runner.py:743-789 _check_task_once (seed ClientCheckTask, CJ half).
ClientCheckTask(c, l, k) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "check"
    /\ InInbox(k, CJ(c), "TASK_CHECK_REPLY") /\ k \notin T(c, l).handled
    /\ M(k).id = SubmitId(c, l, T(c, l).try)
    /\ IF M(k).body = "RETRY"
       THEN /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.handled = @ \cup {k}, !.phase = "send"])
            /\ UNCHANGED pTaskCJ
       ELSE /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.handled = @ \cup {k},
                                       !.chandled = @ \cup {k}, !.phase = "done", !.done = TRUE,
                                       !.receipt = M(k).body])
            /\ UNCHANGED pTaskCJ
    /\ UNCHANGED net

\* _check_task_once -> TRY_AGAIN on a missing reply (task_check_timeout).
ClientCheckTimeout(c, l) ==
    /\ Lossy /\ CJAlive(c, l) /\ T(c, l).phase = "check"
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "retry"])
    /\ UNCHANGED <<pTaskCJ, net>>

\* client_runner.py:712-720: serialization of the result registers the
\* DownloadService transaction (handed to PaySrc through pTaskCJ.submission).
ClientSerializeResult(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "send" /\ ~T(c, l).endRun
    /\ T(c, l).result.rc = "OK" /\ Pt(c, l).submission = None
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].submission =
          [assignment |-> T(c, l).asg, value |-> T(c, l).result.value,
           tx |-> Tx(c, l, T(c, l).asg.attempt)]]
    /\ UNCHANGED <<taskCJ_f, net>>

\* client_runner.py:722-741: send_task_result (RESULT_ENVELOPE); the envelope
\* carries only the source-backed descriptor.
TxReg(c, l) == pPaySrc[c][l].tx[T(c, l).asg.attempt].registered
ClientSendResult(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "send" /\ ~T(c, l).endRun
    /\ T(c, l).result.rc = "OK" =>
         Pt(c, l).submission /= None /\ TxReg(c, l) /= None
         /\ TxReg(c, l).ref = Ref(c, l, T(c, l).asg.attempt)
    /\ net' = Send(net, Msg("RESULT_ENVELOPE", CJ(c), SJ, SubmitId(c, l, T(c, l).try),
          [assignment |-> T(c, l).asg, rc |-> T(c, l).result.rc,
           refs |-> IF T(c, l).result.rc = "OK"
                    THEN {[ref |-> TxReg(c, l).ref, source |-> TxReg(c, l).source, launch |-> l]}
                    ELSE {}]))
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "wait", !.receipt = "waiting"])
    /\ UNCHANGED pTaskCJ

\* client_runner.py:726-741 (seed ServerCommandDispatchAck): the reply's receipt.
ServerCommandDispatchAck(c, l, k) ==
    /\ CJAlive(c, l) /\ T(c, l).phase = "wait" /\ T(c, l).receipt = "waiting"
    /\ InInbox(k, CJ(c), "RESULT_RECEIPT") /\ k \notin T(c, l).handled
    /\ M(k).id = SubmitId(c, l, T(c, l).try)
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.handled = @ \cup {k}, !.chandled = @ \cup {k},
                     !.phase = IF M(k).body = "RETRY" THEN "retry" ELSE "done",
                     !.done = (M(k).body /= "RETRY"), !.receipt = M(k).body])
    /\ UNCHANGED pTaskCJ
    /\ UNCHANGED net

\* client_runner.py:709-726 (seed ClientLoseDispatchAck): submit timeout; the
\* server copy of the envelope keeps being processed.
ClientLoseDispatchAck(c, l) ==
    /\ Lossy /\ CJAlive(c, l) /\ T(c, l).phase = "wait" /\ T(c, l).receipt = "waiting"
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "retry", !.receipt = "timeout"])
    /\ UNCHANGED <<pTaskCJ, net>>

\* client_runner.py:656-678 (seed ClientRetryResult): next try, TASK_CHECK n+1.
ClientRetryResult(c, l) ==
    /\ Running(c, l) /\ T(c, l).phase = "retry" /\ ~T(c, l).endRun /\ T(c, l).try < FedMaxTryIn(Faults)
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.phase = "check", !.try = @ + 1])
    /\ net' = Send(net, Msg("TASK_CHECK", CJ(c), SJ, SubmitId(c, l, T(c, l).try + 1),
                 [assignment |-> T(c, l).asg, try |-> T(c, l).try + 1]))
    /\ UNCHANGED pTaskCJ

\* ---------------------------------------------------------------- END_RUN
\* client_runner.py:1084-1089: END_RUN triggers run_abort_signal. An active
\* submission loop is abandoned: an in-flight send is interrupted
\* (communicator.py:617), otherwise the loop returns at its next abort check.
ClientEndRun(c, l, k) ==
    /\ CJAlive(c, l) /\ InInbox(k, CJ(c), "END_RUN") /\ k \notin T(c, l).handled
    /\ IF Active(c, l)
       THEN /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.handled = @ \cup {k}, !.chandled = @ \cup {k},
                                       !.endRun = TRUE,
                                       !.phase = "done", !.pollWait = FALSE, !.done = TRUE,
                                       !.receipt = "aborted"])
            /\ UNCHANGED pTaskCJ
       ELSE /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.handled = @ \cup {k}, !.chandled = @ \cup {k},
                                       !.endRun = TRUE,
                                       !.pollWait = FALSE])
            /\ UNCHANGED pTaskCJ
    /\ UNCHANGED net

\* in_process_backend.py:250-260 finalize: TOPIC_STOP once execute() returned.
ExecutorFinalize(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).endRun /\ ~T(c, l).finalized
    /\ T(c, l).phase \notin {"published", "waitResult", "got"}
    /\ taskCJ_f' = Upd(c, l, [T(c, l) EXCEPT !.finalized = TRUE])
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c][l].trainerSignal = "stop"]
    /\ UNCHANGED net

Next == \E c \in Sites, l \in Launches :
    \/ ClientGetTask(c, l) \/ ClientGetTaskTimeout(c, l)
    \/ ExecutorPublishTask(c, l) \/ ExecutorFailFast(c, l) \/ ExecutorAbortSignal(c, l)
    \/ ExecutorPublished(c, l) \/ ClientProcessTask(c, l) \/ ExecutorTrainerExited(c, l)
    \/ ExecutorResultTimeout(c, l) \/ ClientExecutionError(c, l)
    \/ ClientCheckTimeout(c, l) \/ ClientSerializeResult(c, l) \/ ClientSendResult(c, l)
    \/ ClientLoseDispatchAck(c, l) \/ ClientRetryResult(c, l) \/ ExecutorFinalize(c, l)
    \/ \E k \in DOMAIN net :
         \/ ClientReceiveTask(c, l, k) \/ ClientReceiveTryAgain(c, l, k)
         \/ ClientCheckTask(c, l, k) \/ ServerCommandDispatchAck(c, l, k)
         \/ ClientEndRun(c, l, k)
=============================================================================
