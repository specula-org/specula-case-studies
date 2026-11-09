------------------------------ MODULE PortsFed ------------------------------
\* Port shapes, message kinds and faults of the FEDAVG/task component groups
\* (TaskCJ, CommSJ, WfSJ). Owned by the fedavg component; others only read.
\* Message protocol (all variants use identical keys and bodies):
\*   GET_TASK         CJ(c)->SJ  id <<JobId,c,l,p>>     body [launch, poll]
\*   TASK_ASSIGNMENT  SJ->CJ(c)  id = GET_TASK id       body [status ASSIGNED|TRY_AGAIN, assignment, input]
\*   TASK_CHECK       CJ(c)->SJ  id <<JobId,c,l,k,n>>   body [assignment, try]
\*   TASK_CHECK_REPLY SJ->CJ(c)  id = TASK_CHECK id     body RETRY|RECEIVED|TASK_CLOSED
\*   RESULT_ENVELOPE  CJ(c)->SJ  id <<JobId,c,l,k,n>>   body [assignment, refs, rc]
\*   RESULT_RECEIPT   SJ->CJ(c)  id = RESULT_ENVELOPE id  body RECEIVED|TASK_CLOSED|RETRY
\*   END_RUN          SJ->CJ(c)  id <<JobId,c>>         body None
\* (l = CJ launch, p = poll number, k = task number within the launch,
\*  n = submission try; the server attempt is assignment.attempt = round.)
\* CTRL/COMM blocking call: CommSJ posts pCommSJ.call (APP_CALL), WfSJ runs the
\* result callback and posts pWfSJ.ret (APP_RETURN); CommSJ then continues.
EXTENDS Consts
FedKinds == {"GET_TASK", "TASK_ASSIGNMENT", "TASK_CHECK", "TASK_CHECK_REPLY",
             "RESULT_ENVELOPE", "RESULT_RECEIPT", "END_RUN"}
\* sjCrash: SJ process crash.          taskTimeout: server task timeout (monitor TIMEOUT).
\* submitTimeout: CJ local get-task / task-check / submit_task_result timeouts.
\* prepFail: before_task_sent_cb, broadcast deepcopy or outbound filter failure.
\* cbFail: conversion / weighted-helper / metric failure inside the result callback.
\* cancel: direct mark-only cancel_task.  deadClient: dead-job reports + heartbeat.
\* minClients: bcast min_responses < targets (task may exit OK with stragglers).
\* resultWaitTimeout: in-process executor result_wait_timeout.
\* taskDataFail (v11 G): the CJ fails to download a task's input payload and asks again.
FedFaults == {"sjCrash", "taskTimeout", "submitTimeout", "prepFail", "cbFail", "cancel",
              "deadClient", "minClients", "resultWaitTimeout", "slowFinalize", "taskDataFail"}
\* FedAvg rounds = the attempt bound (mkmc.py --attempt N). Round r uses server
\* attempt r, result transaction Tx(c, l, r) and ref Ref(c, l, r).
Rounds == MaxAttempt
\* Per-launch bounds on GET_TASK polls and on submission tries (finite instances).
\* These bounds take the fault set as a parameter (call them with Faults). TLC
\* precomputes zero-arity constant-level definitions of modules the root also
\* extends and reuses that value inside an INSTANCE ... WITH Faults <- ..., so a
\* zero-arity FedLossy ignored the substitution in MixR's G_V__N pricing instances
\* and the TaskCJ timeouts it gates were priced free (v7; .build/x7/toy).
FedLossyIn(fs) == {"netLoss", "submitTimeout"} \cap fs /= {}
\* Poll budget: one successful GET_TASK per round plus one TRY_AGAIN per round
\* (the gap before the next round is scheduled); the real client polls without
\* bound. With only Rounds polls, a single TRY_AGAIN exhausted the budget and the
\* generic deadlock check reported a model-bound hang (blind2, 03:10).
FedMaxPollIn(fs) == 2 * Rounds + (IF FedLossyIn(fs) \/ "prepFail" \in fs THEN 1 ELSE 0)
                              + (IF "taskDataFail" \in fs THEN 1 ELSE 0)
FedMaxTryIn(fs) == 1 + (IF FedLossyIn(fs) \/ {"pullTimeout", "txTimeout", "taskTimeout"} \cap fs /= {}
                        THEN 1 ELSE 0)
\* Global model generation broadcast with round r's task.
TaskInput(a) == <<"global", a.attempt - 1>>
\* Port fields are those read by another group or by Props; everything else is private.
\* pTaskCJ: input / trainerSignal (Trainer), submission (PaySrc). The receipt of
\* the current submission (incl. "aborted" on END_RUN, H30) is TaskCJ_F-private.
\* taskMode (v10) adds abort (run_abort_signal latched at END_RUN; the task
\* abort_signal is its child), receipt ([gen, body] of the final RECEIVED /
\* TASK_CLOSED reply, AFTER_SEND_TASK_RESULT -> _record_receipt) and fatal
\* (TaskExecutionInterrupted ends the CJ with a nonzero exit).
TaskCJPortInit == [c \in Sites |-> [l \in Launches |->
                  IF TaskMode
                  THEN [input |-> None, trainerSignal |-> "none", submission |-> None,
                        abort |-> FALSE, receipt |-> None, fatal |-> FALSE]
                  ELSE [input |-> None, trainerSignal |-> "none", submission |-> None]]]
\* round: latest scheduled task round (0 = none); standing: that task is standing;
\* call: None or [site, round, kind live|unknown, key, assignment, value, rc, metricKind];
\* cancelled: last round whose CANCEL_ALL(ERROR) was applied; finalized:
\* communicator.finalize_run done (after current_wf was unset); monitorCrashed:
\* the task monitor thread (_monitor_tasks) died of an exception, so no task
\* is retired, timed out or checked for dead clients any more.
CommSJPortInit == [round |-> 0, envelopes |-> [c \in Sites |-> None],
                   claimed |-> {}, finished |-> {}, standing |-> FALSE,
                   call |-> None, cancelled |-> 0, panic |-> FALSE, finalized |-> FALSE,
                   monitorCrashed |-> FALSE]
\* scheduled: last round whose SCHEDULE was requested; ret: None or [site, round];
\* returned: control_flow return outcome; done: runner status "done" (END_RUN phase);
\* dsShutdown: SJ-local DownloadService.shutdown() done (after END_RUN + readiness).
\* errored (taskMode, v10): <<round, site>> pairs whose live result reached the
\* result callback with a non-OK return code (base_model_controller.py:262-284).
WfSJPortBase == [open |-> FALSE, scheduled |-> 0, accepted |-> {},
                 aggregate |-> None, saved |-> FALSE, cancelAll |-> 0,
                 ret |-> None, panic |-> FALSE, returned |-> "none",
                 done |-> FALSE, dsShutdown |-> FALSE, sj |-> "none"]
\* v11 (DESIGN 16.3), each field only under its switch:
\*   mcall / mseq (sjModel): the call to the Model group and its call counter;
\*   raised (sjModel or sag/cyclic/cseServer): rounds whose result callback
\*     raised (WFComm sets the task's completion status ERROR, no abort);
\*   wfDone (cyclic): _stop_workflow latched (_is_done).
\*   targets (swarm, sampling): the sites the current round's task targets;
\*   cw (swarm): the CCWF server controller's phase init | monitor | ending.
RaiseTracked == SJModel \/ WfPolicy \in {"sag", "cyclic", "cseServer"}
Targeted == WfPolicy = "swarm" \/ "sampling" \in Profile
WfSJExtra == (IF TaskMode THEN {"errored"} ELSE {}) \cup (IF SJModel THEN {"mcall", "mseq"} ELSE {})
             \cup (IF RaiseTracked THEN {"raised"} ELSE {}) \cup (IF WfPolicy = "cyclic" THEN {"wfDone"} ELSE {})
             \cup (IF Targeted THEN {"targets"} ELSE {}) \cup (IF WfPolicy = "swarm" THEN {"cw"} ELSE {})
WfSJExtraInit(f) == CASE f \in {"errored", "raised"} -> {}
                      [] f = "mcall" -> None
                      [] f = "mseq" -> 0
                      [] f = "wfDone" -> FALSE
                      [] f = "targets" -> Sites
                      [] f = "cw" -> "init"
WfSJPortInit == IF WfSJExtra = {} THEN WfSJPortBase
                ELSE [f \in DOMAIN WfSJPortBase \cup WfSJExtra |->
                        IF f \in WfSJExtra THEN WfSJExtraInit(f) ELSE WfSJPortBase[f]]
=============================================================================
