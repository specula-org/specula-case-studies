------------------------------ MODULE WfSJ_F ------------------------------
\* Group WfSJ, FINE variant. Process: SJ. Partition FED_CTRL of the fedavg seed
\* (inputs/seeds/fedavg/spec/base.tla, pin c411a201): controller round loop,
\* round guard aggr.locked/failed/closed, the application result-callback body
\* (accept / convert / aggregate per key / metrics / publish acceptance / clear,
\* unknown-result hook), close / reject-empty round, aggregate build, model
\* update / save, workflow return, run end (server_runner.py:205-237), SJ exit.
\* Re-homing: s.wf/aggr/scratch/used/committed/saved/unknownSeen -> wfSJ_f;
\* callback-local comm.pc/key/accepted -> wfSJ_f.app; ct.decision/invocations ->
\* wfSJ_f.decision/invocations. Cross-group effects:
\*   SCHEDULE(t)       pWfSJ.scheduled := t,  ack pCommSJ.round = t
\*   CANCEL_ALL(ERROR) pWfSJ.cancelAll := t,  ack pCommSJ.cancelled = t
\*   standing query    pCommSJ.standing (current task pCommSJ.round)
\*   APP_CALL          pCommSJ.call (envelope body travels in the call)
\*   APP_RETURN        pWfSJ.ret
\*   PANIC             pWfSJ.panic (runner abort latch = pWfSJ.panic \/ pCommSJ.panic)
\*   WORKFLOW_RETURNED pWfSJ.returned; runner close/finalize ack pCommSJ.finalized
\* Slice profile (vertical-slice FedAvgRefinement.tla): NumKeys 1, strict errors,
\* MetricKinds {"none"}, AllowEmpty/ShapeMismatch/LazyOffload FALSE.
\* Seed failure flags ConversionFailure / AllocationFailure become Faults "cbFail".
EXTENDS Ports
VARIABLE wfSJ_f

NumKeys == 1
Keys == 1..NumKeys
Tasks == 1..Rounds
\* base_model_controller.py:330-375, error_handling_utils.py:18-61. FedAvg's
\* default (None, dynamic) sends without min_responses, so min_responses =
\* num_targets and any error panics, as in strict mode.
ErrorMode == IF "errResilient" \in Profile THEN "resilient" ELSE "strict"
NoId == <<0, None>>

EmptyAggregate(t) == [task |-> t, applied |-> [k \in Keys |-> <<>>],
    stats |-> [k \in Keys |-> <<>>], paramHistory |-> <<>>,
    metricApplied |-> <<>>, metricStats |-> <<>>, metricHistory |-> <<>>,
    allMetrics |-> TRUE, receivedCount |-> 0, counted |-> <<>>, failedClients |-> {},
    failed |-> FALSE, closed |-> FALSE, locked |-> FALSE]
EmptyUsed == [params |-> [k \in Keys |-> <<>>], stats |-> [k \in Keys |-> <<>>],
    paramHistory |-> <<>>, metrics |-> <<>>, metricStats |-> <<>>,
    metricHistory |-> <<>>, allMetrics |-> TRUE, count |-> 0, counted |-> <<>>]
EmptyApp == [pc |-> "idle", id |-> NoId, key |-> 1, accepted |-> FALSE, call |-> None]

InitValue == [
    wf |-> [round |-> 0, pc |-> "init", sourceVersion |-> 0, started |-> {},
            outcome |-> "running"],
    aggr |-> EmptyAggregate(0), scratch |-> EmptyUsed,
    used |-> [t \in Tasks |-> EmptyUsed], committed |-> {}, saved |-> {},
    app |-> EmptyApp, calls |-> {},
    value |-> [t \in Tasks |-> [c \in Sites |-> None]],
    decision |-> [t \in Tasks |-> [c \in Sites |-> "pending"]],
    invocations |-> [t \in Tasks |-> [c \in Sites |-> 0]],
    unknownSeen |-> {}, teardown |-> "none", closedAs |-> "none"]
Init == wfSJ_f = InitValue

S == wfSJ_f
Aborted == pCommSJ.panic \/ pWfSJ.panic
A == S.app
Body == S.app.call
CurId == S.app.id
SeqSet(q) == {q[i] : i \in 1..Len(q)}
EndRunSent(c) == MsgKey("END_RUN", SJ, CJ(c), <<JobId, c>>) \in DOMAIN net

\* Abstraction to WfSJ_C's private state.
AbsC == [round |-> S.wf.round,
         counted |-> {<<id[2], S.value[id[1]][id[2]]>> :
                        id \in {x \in SeqSet(S.aggr.counted) : x[1] = S.wf.round}},
         saved |-> IF S.saved = {} THEN 0 ELSE CHOOSE r \in S.saved : \A x \in S.saved : x <= r,
         closed |-> S.closedAs]
AbsCInit == [round |-> 0, counted |-> {}, saved |-> 0, closed |-> "none"]

\* ---------------------------------------------------------------- workflow
\* server_runner.py:131-150: initialize_run, START_WORKFLOW, current_wf := wf.
WorkflowOpened ==
    /\ pJobSP.sjLaunched /\ pWfSJ.sj = "none" /\ SJAlive /\ S.wf.pc = "init"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "start"]
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "running", !.open = TRUE]
    /\ UNCHANGED net

\* nvflare/app_common/workflows/fedavg.py:194-203
FedAvgRoundStarted ==
    /\ SJAlive /\ S.wf.pc = "start" /\ S.wf.round < Rounds
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.round = @+1, !.wf.pc = "reset",
                               !.wf.started = @ \cup {S.wf.round+1}, !.closedAs = "none"]
    \* per-round port fields are reset with `scheduled` (WFCommScheduleTaskCall)
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/fedavg.py:206-224
FedAvgResetAggregation ==
    /\ SJAlive /\ S.wf.pc = "reset"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr = [EmptyAggregate(S.wf.round) EXCEPT
                                           !.failedClients = S.aggr.failedClients],
                               !.scratch = EmptyUsed, !.wf.pc = "broadcast"]
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/base_model_controller.py:160-166
BaseResetFailedClients ==
    /\ SJAlive /\ S.wf.pc = "broadcast"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.failedClients = {}, !.wf.pc = "schedule"]
    /\ UNCHANGED <<pWfSJ, net>>

\* base_model_controller.py:153-169,199-232 (broadcast_model): CTRL half of the
\* seed rendezvous WFCommScheduleTask; CommSJ!WFCommScheduleTask acks it.
WFCommScheduleTaskCall ==
    /\ SJAlive /\ S.wf.pc = "schedule"
    \* per-round port fields belong to the round now scheduled
    /\ pWfSJ' = [pWfSJ EXCEPT !.scheduled = S.wf.round, !.accepted = {}, !.aggregate = None]
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "scheduleWait"]
    /\ UNCHANGED net

WFCommScheduleTaskReturn ==
    /\ SJAlive /\ S.wf.pc = "scheduleWait" /\ pCommSJ.round = S.wf.round
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "wait"]
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/fedavg.py:245-260 (get_num_standing_tasks)
\* Stuttering reduction (documented, sound for safety): a poll cycle that finds
\* the task standing, the round not failed and no abort returns to "wait"
\* unchanged; the cycle starts only when one of them can change the outcome.
FedAvgPollStanding ==
    /\ SJAlive /\ S.wf.pc = "wait"
    /\ ~(pCommSJ.round = S.wf.round /\ pCommSJ.standing) \/ S.aggr.failed \/ Aborted
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc =
                    IF pCommSJ.round = S.wf.round /\ pCommSJ.standing THEN "failPoll" ELSE "close"]
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/fedavg.py:246-248
FedAvgPollFailed ==
    /\ SJAlive /\ S.wf.pc = "failPoll"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = IF S.aggr.failed THEN "failedCancel" ELSE "abortPoll"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:246-248; wf_comm_server.py:962-979 cancel_all_tasks(ERROR): CTRL half.
FedAvgCancelFailedTasks ==
    /\ SJAlive /\ S.wf.pc = "failedCancel"
    /\ pWfSJ' = [pWfSJ EXCEPT !.cancelAll = S.wf.round]
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "cancelWait"]
    /\ UNCHANGED net

FedAvgCancelFailedTasksReturn ==
    /\ SJAlive /\ S.wf.pc = "cancelWait" /\ pCommSJ.cancelled = S.wf.round
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "close"]
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/fedavg.py:249-254 (abort_signal = runner abort latch)
FedAvgPollAbort ==
    /\ SJAlive /\ S.wf.pc = "abortPoll"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = IF Aborted THEN "abortClose" ELSE "wait"]
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/fedavg.py:250-260
FedAvgCloseRound ==
    /\ SJAlive /\ S.wf.pc \in {"close", "abortClose"} /\ ~S.aggr.locked
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.closed = TRUE,
         !.wf.pc = IF S.wf.pc = "abortClose" THEN "returned"
                   ELSE IF S.aggr.failed THEN "raise" ELSE "aggregate",
         !.wf.outcome = IF S.wf.pc = "abortClose" THEN "aborted" ELSE @,
         !.closedAs = IF S.wf.pc = "abortClose" THEN "aborted"
                      ELSE IF S.aggr.failed THEN "failed" ELSE "ok"]
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = IF S.wf.pc = "abortClose" THEN "aborted" ELSE @]
    /\ UNCHANGED net

\* nvflare/app_common/workflows/fedavg.py:389-390
FedAvgRejectEmptyRound ==
    /\ SJAlive /\ S.wf.pc = "aggregate" /\ S.aggr.receivedCount = 0
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "raise"]
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/base_model_controller.py:389-401 (system_panic)
BaseModelControllerRunException ==
    /\ SJAlive /\ S.wf.pc = "raise"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "returned", !.wf.outcome = "error"]
    /\ pWfSJ' = [pWfSJ EXCEPT !.returned = "error", !.panic = TRUE]
    /\ UNCHANGED net

\* fedavg.py:262-265,388-396; weighted_aggregation_helper.py:288-311
FedAvgGetAggregationStats ==
    /\ SJAlive /\ S.wf.pc = "aggregate" /\ S.aggr.receivedCount > 0
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.scratch.stats = S.aggr.stats,
          !.scratch.paramHistory = S.aggr.paramHistory, !.wf.pc = "params"]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:272-286; fedavg.py:396
WeightedGetParamResult ==
    /\ SJAlive /\ S.wf.pc = "params"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.scratch.params = S.aggr.applied,
          !.aggr.applied = [k \in Keys |-> <<>>], !.aggr.stats = [k \in Keys |-> <<>>],
          !.aggr.paramHistory = <<>>, !.wf.pc = "metrics"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:397-398; weighted_aggregation_helper.py:272-286
WeightedGetMetricResult ==
    /\ SJAlive /\ S.wf.pc = "metrics"
    /\ wfSJ_f' = [wfSJ_f EXCEPT
          !.scratch.metrics = IF S.aggr.allMetrics THEN S.aggr.metricApplied ELSE <<>>,
          !.scratch.metricStats = IF S.aggr.allMetrics THEN S.aggr.metricStats ELSE <<>>,
          !.scratch.metricHistory = IF S.aggr.allMetrics THEN S.aggr.metricHistory ELSE <<>>,
          !.scratch.allMetrics = S.aggr.allMetrics,
          !.aggr.metricApplied = IF S.aggr.allMetrics THEN <<>> ELSE @,
          !.aggr.metricStats = IF S.aggr.allMetrics THEN <<>> ELSE @,
          !.aggr.metricHistory = IF S.aggr.allMetrics THEN <<>> ELSE @, !.wf.pc = "build"]
    /\ UNCHANGED <<pWfSJ, net>>

\* nvflare/app_common/workflows/fedavg.py:400-410
FedAvgBuildAggregateResult ==
    /\ SJAlive /\ S.wf.pc = "build"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.scratch.count = S.aggr.receivedCount,
          !.scratch.counted = S.aggr.counted, !.wf.pc = "update"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:266-270; base_fedavg.py:302-322; fl_model_utils.py:234-240.
\* The published aggregate is the set of materialized values of the used ids.
BaseFedAvgUpdateModel ==
    /\ SJAlive /\ S.wf.pc = "update"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.used[S.wf.round] = S.scratch, !.committed = @ \cup {S.wf.round},
          !.wf.sourceVersion = S.wf.round, !.wf.pc = "save"]
    /\ pWfSJ' = [pWfSJ EXCEPT !.aggregate =
          {S.value[id[1]][id[2]] : id \in SeqSet(S.scratch.params[1])}]
    /\ UNCHANGED net

\* fedavg.py:289-291,534-549; base_model_controller.py:452-459
FedAvgSaveModel ==
    /\ SJAlive /\ S.wf.pc = "save"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.saved = @ \cup {S.wf.round}, !.wf.pc = "advance"]
    \* control_flow has nothing observable left after the last save: the
    \* WORKFLOW_RETURNED signal is posted here (FedAvgAdvanceRound is local).
    /\ pWfSJ' = [pWfSJ EXCEPT !.saved = TRUE,
                              !.returned = IF S.wf.round = Rounds THEN "normal" ELSE @]
    /\ UNCHANGED net

\* fedavg.py:194,293-298; server_runner.py:152-184
FedAvgAdvanceRound ==
    /\ SJAlive /\ S.wf.pc = "advance"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = IF S.wf.round < Rounds THEN "start" ELSE "returned",
                               !.wf.outcome = IF S.wf.round = Rounds THEN "normal" ELSE @]
    /\ UNCHANGED <<pWfSJ, net>>

\* ---------------------------------------------------------------- callback body
\* wf_comm_server.py:632-661: the application callback runs on the submission
\* thread while CommSJ holds the runner and communicator locks (APP_CALL).
AppCallEntry ==
    /\ SJAlive /\ A.pc = "idle" /\ pCommSJ.call /= None
    /\ <<pCommSJ.call.round, pCommSJ.call.site>> \notin S.calls
    /\ LET b == pCommSJ.call IN
       wfSJ_f' = [wfSJ_f EXCEPT
          !.app = [EmptyApp EXCEPT !.pc = IF b.kind = "live" THEN "prelim" ELSE "unknown",
                                   !.id = <<b.round, b.site>>, !.call = b],
          !.calls = @ \cup {<<b.round, b.site>>},
          !.value[b.round][b.site] = b.value]
    /\ UNCHANGED <<pWfSJ, net>>

\* base_model_controller.py:262-284,342-378; error_handling_utils.py:51-61
BaseAcceptTrainResult ==
    /\ SJAlive /\ A.pc = "prelim"
    /\ LET bad == Body.rc /= "OK" IN
       /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = IF bad THEN "decision" ELSE "convert",
             !.aggr.failedClients = IF bad /\ ErrorMode = "dynamic"
                                    THEN @ \cup {CurId[2]} ELSE @]
       /\ pWfSJ' = [pWfSJ EXCEPT !.panic = @ \/ (bad /\ ErrorMode /= "resilient")]
    /\ UNCHANGED net

\* base_model_controller.py:283-295
BaseConvertResult ==
    /\ SJAlive /\ A.pc = "convert"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = "consumer",
                               !.invocations[CurId[1]][CurId[2]] = @+1]
    /\ UNCHANGED <<pWfSJ, net>>

\* base_model_controller.py:283-289 (fault cbFail)
BaseConvertResultFailure ==
    /\ "cbFail" \in Faults /\ SJAlive /\ A.pc = "convert"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = "decision"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:225-233
FedAvgCheckRoundGuard ==
    /\ SJAlive /\ A.pc = "consumer" /\ ~S.aggr.locked
    /\ wfSJ_f' = [wfSJ_f EXCEPT
          !.app.pc = IF S.aggr.failed \/ S.aggr.closed THEN "decision" ELSE "aggregateEntry",
          !.aggr.locked = ~(S.aggr.failed \/ S.aggr.closed)]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:301-325 (AllowEmpty FALSE: result kind is always params)
FedAvgAggregateOneResult ==
    /\ SJAlive /\ A.pc = "aggregateEntry" /\ S.aggr.locked
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = "validate", !.app.key = 1]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:326-339; weighted_aggregation_helper.py:157-188
FedAvgValidateShapes ==
    /\ SJAlive /\ A.pc = "validate" /\ S.aggr.locked
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = "paramStats"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:229-233,329-332 (fault cbFail; metric kind of the envelope)
FedAvgMetricPreparationFailure ==
    /\ "cbFail" \in Faults /\ SJAlive /\ A.pc = "validate"
    /\ S.aggr.allMetrics /\ Body.metricKind = "present"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = "decision", !.aggr.failed = TRUE, !.aggr.locked = FALSE]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:207-221
WeightedAddParamStats ==
    /\ SJAlive /\ A.pc = "paramStats" /\ A.key \in Keys
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.stats[A.key] = Append(@, CurId), !.app.pc = "paramValue"]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:219-262
WeightedAddParamValue ==
    /\ SJAlive /\ A.pc = "paramValue"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.applied[A.key] = Append(@, CurId),
          !.app.key = @+1, !.app.pc = IF A.key = NumKeys THEN "paramHistory" ELSE "paramStats"]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:218-261; fedavg.py:229-233 (fault cbFail):
\* earlier key mutations and stats are kept, the round is failed.
WeightedParamFailure ==
    /\ "cbFail" \in Faults /\ SJAlive /\ A.pc = "paramValue"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = "decision", !.aggr.failed = TRUE, !.aggr.locked = FALSE]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:264-270; fedavg.py:339-356
WeightedAddParamHistory ==
    /\ SJAlive /\ A.pc = "paramHistory"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.paramHistory = Append(@, CurId), !.app.pc = "metrics"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:345-351
FedAvgProcessMetrics ==
    /\ SJAlive /\ A.pc = "metrics"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc =
          IF S.aggr.allMetrics /\ Body.metricKind = "present" THEN "metricStats" ELSE "coverage"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:358; weighted_aggregation_helper.py:207-221
WeightedAddMetricStats ==
    /\ SJAlive /\ A.pc = "metricStats"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.metricStats = Append(@, CurId), !.app.pc = "metricValue"]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:223-262
WeightedAddMetricValue ==
    /\ SJAlive /\ A.pc = "metricValue"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.metricApplied = Append(@, CurId), !.app.pc = "metricHistory"]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:218-261 (fault cbFail)
WeightedMetricFailure ==
    /\ "cbFail" \in Faults /\ SJAlive /\ A.pc = "metricValue"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app.pc = "decision", !.aggr.failed = TRUE, !.aggr.locked = FALSE]
    /\ UNCHANGED <<pWfSJ, net>>

\* weighted_aggregation_helper.py:265-270; fedavg.py:345-368
WeightedAddMetricHistory ==
    /\ SJAlive /\ A.pc = "metricHistory"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.metricHistory = Append(@, CurId), !.app.pc = "coverage"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:353-368
FedAvgCommitMetricCoverage ==
    /\ SJAlive /\ A.pc = "coverage"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.allMetrics = @ /\ Body.metricKind /= "none",
                               !.app.pc = "count"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:370-375
FedAvgIncrementReceived ==
    /\ SJAlive /\ A.pc = "count"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.receivedCount = @+1, !.aggr.counted = Append(@, CurId),
                               !.app.accepted = TRUE, !.app.pc = "consumerDone"]
    /\ UNCHANGED <<pWfSJ, net>>

\* fedavg.py:225-233
FedAvgReleaseRoundGuard ==
    /\ SJAlive /\ A.pc = "consumerDone" /\ S.aggr.locked
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.aggr.locked = FALSE, !.app.pc = "decision"]
    /\ UNCHANGED <<pWfSJ, net>>

\* base_model_controller.py:278-302
BasePublishAcceptance ==
    /\ SJAlive /\ A.pc = "decision"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.decision[CurId[1]][CurId[2]] =
                    IF A.accepted THEN "accepted" ELSE "rejected", !.app.pc = "cleanup"]
    \* APP_RETURN is posted with the decision: the remaining finally-block
    \* (BaseClearTrainingResult) touches only callback-local state.
    /\ pWfSJ' = [pWfSJ EXCEPT !.accepted = IF A.accepted THEN @ \cup {CurId[2]} ELSE @,
                              !.ret = [site |-> CurId[2], round |-> CurId[1]]]
    /\ UNCHANGED net

\* base_model_controller.py:303-305: finally clears result refs (callback-local).
BaseClearTrainingResult ==
    /\ SJAlive /\ A.pc = "cleanup"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.app = EmptyApp]
    /\ UNCHANGED <<pWfSJ, net>>

\* wf_comm_server.py:643-651; base_model_controller.py:309-378: unknown-result
\* hook only (no callback, count, history or acceptance event); APP_RETURN.
BaseProcessUnknownResult ==
    /\ SJAlive /\ A.pc = "unknown"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.unknownSeen = @ \cup {CurId}, !.app = EmptyApp]
    /\ pWfSJ' = [pWfSJ EXCEPT !.ret = [site |-> CurId[2], round |-> CurId[1]]]
    /\ UNCHANGED net

\* ---------------------------------------------------------------- run end
\* server_runner.py:205-223: after the workflow loop (current_wf unset and
\* communicator.finalize_run done by CommSJ), status := "done" under wf_lock and
\* END_RUN to all clients as ONE fire-and-forget aux broadcast (targets=None,
\* timeout 0).
ServerRunnerEndRun ==
    /\ SJAlive /\ S.wf.pc = "returned" /\ pCommSJ.finalized /\ ~pWfSJ.done
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.wf.pc = "finalized"]
    /\ pWfSJ' = [pWfSJ EXCEPT !.done = TRUE]
    /\ net' = SendAll(net, {Msg("END_RUN", SJ, CJ(c), <<JobId, c>>, None) : c \in Sites})

\* server_runner.py:225-231: persist_components, check_end_run_readiness, END_RUN event.
ServerRunnerEndRunReadiness ==
    /\ SJAlive /\ pWfSJ.done /\ S.teardown = "none"
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.teardown = "ready"]
    /\ UNCHANGED <<pWfSJ, net>>

\* server_runner.py:233-235: ReliableMessage / streamer / DownloadService shutdown.
ServerRunnerDownloadShutdown ==
    /\ SJAlive /\ S.teardown = "ready" /\ ~pWfSJ.dsShutdown
    /\ wfSJ_f' = [wfSJ_f EXCEPT !.teardown = "shutdown"]
    /\ pWfSJ' = [pWfSJ EXCEPT !.dsShutdown = TRUE]
    /\ UNCHANGED net

ServerJobExit ==
    /\ SJAlive /\ pWfSJ.dsShutdown /\ pWfSJ.sj = "running"
    /\ PayRcvShutDone    \* DownloadService.shutdown() returned (call-return handshake)
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "exited"]
    /\ UNCHANGED <<wfSJ_f, net>>

ServerJobCrash ==
    /\ "sjCrash" \in Faults /\ SJAlive /\ pWfSJ.sj = "running"
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "crashed"]
    /\ UNCHANGED <<wfSJ_f, net>>

\* ---------------------------------------------------------------- invariants
\* (seed base.tla:1157-1206, group-local; checked in mixes with WfSJ = F)
AtMostOneConsumer == \A t \in Tasks, c \in Sites : S.invocations[t][c] <= 1
\* FencedReceiptAtMostOnce (hazards S23): application callback and unknown-result
\* hook together run at most once per fenced attempt.
FencedReceiptAtMostOnce == \A t \in Tasks, c \in Sites :
    (IF S.decision[t][c] /= "pending" THEN 1 ELSE 0) + (IF <<t, c>> \in S.unknownSeen THEN 1 ELSE 0) <= 1
SavedWasCommitted == S.saved \subseteq S.committed
CountMatchesSuccessfulReturns == S.aggr.receivedCount = Len(S.aggr.counted)
\* No publication from a failed round (seed Update!NoFailedRoundPublished).
NoFailedRoundPublished == S.aggr.failed => S.aggr.task \notin S.committed
\* Published contributions were accepted (seed CommittedValuesAccepted).
CommittedValuesAccepted == \A t \in S.committed :
    \A id \in SeqSet(S.used[t].params[1]) : S.decision[id[1]][id[2]] = "accepted"
WfSafety == AtMostOneConsumer /\ FencedReceiptAtMostOnce /\ SavedWasCommitted
            /\ CountMatchesSuccessfulReturns /\ NoFailedRoundPublished

Next ==
    \/ WorkflowOpened \/ FedAvgRoundStarted \/ FedAvgResetAggregation \/ BaseResetFailedClients
    \/ WFCommScheduleTaskCall \/ WFCommScheduleTaskReturn \/ FedAvgPollStanding
    \/ FedAvgPollFailed \/ FedAvgCancelFailedTasks \/ FedAvgCancelFailedTasksReturn
    \/ FedAvgPollAbort \/ FedAvgCloseRound \/ FedAvgRejectEmptyRound
    \/ BaseModelControllerRunException \/ FedAvgGetAggregationStats \/ WeightedGetParamResult
    \/ WeightedGetMetricResult \/ FedAvgBuildAggregateResult \/ BaseFedAvgUpdateModel
    \/ FedAvgSaveModel \/ FedAvgAdvanceRound
    \/ AppCallEntry \/ BaseAcceptTrainResult \/ BaseConvertResult \/ BaseConvertResultFailure
    \/ FedAvgCheckRoundGuard \/ FedAvgAggregateOneResult \/ FedAvgValidateShapes
    \/ FedAvgMetricPreparationFailure \/ WeightedAddParamStats \/ WeightedAddParamValue
    \/ WeightedParamFailure \/ WeightedAddParamHistory \/ FedAvgProcessMetrics
    \/ WeightedAddMetricStats \/ WeightedAddMetricValue \/ WeightedMetricFailure
    \/ WeightedAddMetricHistory \/ FedAvgCommitMetricCoverage \/ FedAvgIncrementReceived
    \/ FedAvgReleaseRoundGuard \/ BasePublishAcceptance \/ BaseClearTrainingResult
    \/ BaseProcessUnknownResult
    \/ ServerRunnerEndRun \/ ServerRunnerEndRunReadiness \/ ServerRunnerDownloadShutdown
    \/ ServerJobExit \/ ServerJobCrash
=============================================================================
