------------------------------- MODULE MC -------------------------------
EXTENDS base
B == INSTANCE base

\* Scenario-derived ordinary failures/retries only. Never revert existing guards.
CONSTANTS FaultLimits, MaxMessages, FilterAfterContribution, CancelAfterContribution
VARIABLE faults
mcvars == <<s, faults>>
FaultNames == {"before", "snapshot", "filter", "delivery", "resultError", "conversion", "param", "metricPrep", "metric", "ackLoss", "cancel", "dead"}
ASSUME /\ FaultLimits \in [FaultNames -> Nat]
       /\ MaxMessages \in Nat \ {0}
       /\ FilterAfterContribution \in BOOLEAN /\ CancelAfterContribution \in BOOLEAN
MCInit == /\ B!Init /\ faults = [k \in FaultNames |-> 0]

\* nvflare/apis/impl/wf_comm_server.py:281-314; Scenario mechanism budget, never a reactive-step budget.
MCBasePrepareTaskDataFailure ==
    /\ faults.before < FaultLimits.before
    /\ (~CancelAfterContribution \/ s.aggr.receivedCount > 0)
    /\ B!BasePrepareTaskDataFailure
    /\ faults' = [faults EXCEPT !.before = @+1]

\* nvflare/apis/impl/wf_comm_server.py:313-324; Scenario mechanism budget, never a reactive-step budget.
MCWFCommProtectBroadcastFailure ==
    /\ faults.snapshot < FaultLimits.snapshot
    /\ B!WFCommProtectBroadcastFailure
    /\ faults' = [faults EXCEPT !.snapshot = @+1]

\* nvflare/private/fed/server/server_runner.py:333-350; Scenario mechanism budget, never a reactive-step budget.
MCServerRunnerFilterFailure(id) ==
    /\ faults.filter < FaultLimits.filter
    /\ (~FilterAfterContribution \/ s.aggr.receivedCount > 0)
    /\ B!ServerRunnerFilterFailure(id)
    /\ faults' = [faults EXCEPT !.filter = @+1]

\* nvflare/private/fed/server/server_runner.py:371; nvflare/private/fed/client/client_runner.py:225-248; Scenario mechanism budget, never a reactive-step budget.
MCTaskDeliveryFailure(id) ==
    /\ faults.delivery < FaultLimits.delivery
    /\ B!TaskDeliveryFailure(id)
    /\ faults' = [faults EXCEPT !.delivery = @+1]

\* nvflare/private/fed/client/client_runner.py:225-248; Scenario mechanism budget, never a reactive-step budget.
MCClientExecutionError(id) ==
    /\ faults.resultError < FaultLimits.resultError
    /\ B!ClientExecutionError(id)
    /\ faults' = [faults EXCEPT !.resultError = @+1]

\* nvflare/app_common/workflows/base_model_controller.py:272-278; Scenario mechanism budget, never a reactive-step budget.
MCBaseConvertResultFailure ==
    /\ faults.conversion < FaultLimits.conversion
    /\ B!BaseConvertResultFailure
    /\ faults' = [faults EXCEPT !.conversion = @+1]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:173-216; nvflare/app_opt/pt/lazy_tensor_dict.py:77-80; nvflare/app_common/workflows/base_model_controller.py:281-286; Scenario mechanism budget, never a reactive-step budget.
MCWeightedParamFailure ==
    /\ faults.param < FaultLimits.param
    /\ B!WeightedParamFailure
    /\ faults' = [faults EXCEPT !.param = @+1]

\* nvflare/app_common/workflows/fedavg.py:312-320; nvflare/app_common/workflows/base_model_controller.py:281-286; Scenario mechanism budget, never a reactive-step budget.
MCFedAvgMetricPreparationFailure ==
    /\ faults.metricPrep < FaultLimits.metricPrep
    /\ B!FedAvgMetricPreparationFailure
    /\ faults' = [faults EXCEPT !.metricPrep = @+1]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:177-216; nvflare/app_common/workflows/base_model_controller.py:281-286; Scenario mechanism budget, never a reactive-step budget.
MCWeightedMetricFailure ==
    /\ faults.metric < FaultLimits.metric
    /\ B!WeightedMetricFailure
    /\ faults' = [faults EXCEPT !.metric = @+1]

\* nvflare/private/fed/client/client_runner.py:628-637; nvflare/private/fed/server/server_command_agent.py:96-110; Scenario mechanism budget, never a reactive-step budget.
MCClientLoseDispatchAck(id, n) ==
    /\ faults.ackLoss < FaultLimits.ackLoss
    /\ B!ClientLoseDispatchAck(id, n)
    /\ faults' = [faults EXCEPT !.ackLoss = @+1]

\* nvflare/apis/impl/wf_comm_server.py:794-827; Scenario mechanism budget, never a reactive-step budget.
MCWFCommCancelTask(t) ==
    /\ faults.cancel < FaultLimits.cancel
    /\ (~CancelAfterContribution \/ s.aggr.receivedCount > 0)
    /\ B!WFCommCancelTask(t)
    /\ faults' = [faults EXCEPT !.cancel = @+1]

\* nvflare/apis/impl/wf_comm_server.py:175-186,79-82; Scenario mechanism budget, never a reactive-step budget.
MCWFCommReportDeadClient(c) ==
    /\ faults.dead < FaultLimits.dead
    /\ B!WFCommReportDeadClient(c)
    /\ faults' = [faults EXCEPT !.dead = @+1]

\* Every normal implementation/environment reaction passes through in full.
NormalNext ==
    \/ B!FedAvgRoundStarted
    \/ B!FedAvgResetAggregation
    \/ B!WFCommScheduleTask
    \/ \E c \in Clients : B!WFCommProcessTaskRequest(c)
    \/ \E id \in Ids : B!WFCommResendTask(id)
    \/ B!BasePrepareTaskData
    \/ B!WFCommProtectBroadcast
    \/ B!WFCommCheckCanSend
    \/ B!WFCommPublishClientTask
    \/ B!WFCommTaskTryAgain
    \/ \E id \in Ids : B!ServerRunnerFilterTask(id)
    \/ \E id \in Ids : B!WFCommHandleException(id)
    \/ \E id \in Ids : B!ClientReceiveTask(id)
    \/ \E id \in Ids : \E kind \in {"params","empty"} : \E mk \in MetricKinds : B!ClientProcessTask(id, kind, mk)
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : B!ClientCheckTask(id, n)
    \/ \E id \in Ids : B!ClientRetryResult(id)
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : B!ServerRunnerProcessSubmission(id, n)
    \/ B!WFCommDispatchSubmission
    \/ B!BaseAcceptTrainResult
    \/ B!BaseConvertResult
    \/ B!FedAvgAggregateOneResult
    \/ B!WeightedAddParamStats
    \/ B!WeightedAddParamValue
    \/ B!WeightedAddParamHistory
    \/ B!FedAvgProcessMetrics
    \/ B!WeightedAddMetricStats
    \/ B!WeightedAddMetricValue
    \/ B!WeightedAddMetricHistory
    \/ B!FedAvgIncrementReceived
    \/ B!BasePublishAcceptance
    \/ B!BaseClearTrainingResult
    \/ B!WFCommStampReceipt
    \/ B!BaseProcessUnknownResult
    \/ B!WFCommDropSubmission
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : B!ServerCommandDispatchAck(id, n)
    \/ \E c \in Clients : B!WFCommClientIsActive(c)
    \/ B!ClockAdvance
    \/ B!WFCommMonitorBegin
    \/ \E c \in Clients : B!WFCommCheckDeadClient(c)
    \/ B!WFCommDeadCheckDone
    \/ \E c \in Clients : B!WFCommReadPolicyClient(c)
    \/ B!WFCommJobPolicyDecision
    \/ B!WFCommMonitorAcquire
    \/ \E t \in Tasks : B!WFCommMonitorSelect(t)
    \/ \E c \in Clients : B!WFCommReadTaskDeadClient(c)
    \/ B!WFCommTaskDeadCheckDone
    \/ B!WFCommMonitorMarkTerminal
    \/ B!WFCommMonitorRemove
    \/ B!WFCommMonitorCleanup
    \/ B!WFCommMonitorNoTask
    \/ B!FedAvgPollStanding
    \/ B!FedAvgPollAbort
    \/ B!FedAvgGetAggregationStats
    \/ B!WeightedGetParamResult
    \/ B!WeightedGetMetricResult
    \/ B!FedAvgBuildAggregateResult
    \/ B!BaseFedAvgUpdateModel
    \/ B!FedAvgSaveModel
    \/ B!FedAvgAdvanceRound
    \/ B!ServerRunnerCloseWorkflow
    \/ B!WFCommFinalizeRun
    \/ \E c \in Clients : B!ServerRunnerTaskRequestActive(c)
    \/ \E c \in Clients : B!ServerRunnerAcquireTaskRequest(c)
    \/ B!WFCommTaskUnavailable
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : B!ServerRunnerCheckTaskActive(id, n)
    \/ B!ServerRunnerSubmissionActive
    \/ B!WFCommAcquireSubmission
    \/ B!ServerRunnerDropClosedSubmission

MCNext ==
    \/ /\ NormalNext
       /\ UNCHANGED faults
    \/ MCBasePrepareTaskDataFailure
    \/ MCWFCommProtectBroadcastFailure
    \/ \E id \in Ids : MCServerRunnerFilterFailure(id)
    \/ \E id \in Ids : MCTaskDeliveryFailure(id)
    \/ \E id \in Ids : MCClientExecutionError(id)
    \/ MCBaseConvertResultFailure
    \/ MCWeightedParamFailure
    \/ MCFedAvgMetricPreparationFailure
    \/ MCWeightedMetricFailure
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : MCClientLoseDispatchAck(id, n)
    \/ \E t \in Tasks : MCWFCommCancelTask(t)
    \/ \E c \in Clients : MCWFCommReportDeadClient(c)

MCSpec == MCInit /\ [][MCNext]_mcvars

\* Finite queue constraint; ACK/lost/gone entries are historical observations.
\* Bounds in configs fit all initial responses plus permitted retries.
BufferedMessages == UNION {
    {<<id,n>> : n \in {j \in 1..Len(s.net[id[1]][id[2]]) :
                         s.net[id[1]][id[2]][j] \in {"queued","handled"}}} : id \in Ids}
MessageBufferBound == Cardinality(BufferedMessages) <= MaxMessages

\* Symmetry must preserve selection and required-sites policy. Model-value
\* clients in MC configs; Trace derives actual string client IDs instead.
ClientSymmetry == {p \in Permutations(Clients) :
    /\ {p[c] : c \in Selected} = Selected
    /\ {p[c] : c \in RequiredSites} = RequiredSites}
MCView == s
\* Counter-free view is available for diagnostics, but not applied as TLC VIEW:
\* merging different remaining fault budgets needs a dominance argument first.
MCTypeOK == TypeOK /\ faults \in [FaultNames -> Nat]
                     /\ \A k \in FaultNames : faults[k] <= FaultLimits[k]
DynamicErrorSignalsAbort == ErrorMode = "dynamic" /\ s.aggr.failedClients /= {} => s.wf.abort

\* Only internal request/callback completion and monitor/round scheduling are
\* fair. No fairness promises a permanently missing client's result or delivery.
\* Strong fairness on communicator acquisition supplies fair monitor admission
\* under contention; other internal stages use weak fairness.
ProgressFairness ==
    /\ SF_mcvars(B!WFCommMonitorAcquire /\ UNCHANGED faults)
    /\ WF_mcvars(B!ClockAdvance /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgRoundStarted /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgResetAggregation /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommScheduleTask /\ UNCHANGED faults)
    /\ WF_mcvars(B!BasePrepareTaskData /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommProtectBroadcast /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommCheckCanSend /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommPublishClientTask /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommTaskTryAgain /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommDispatchSubmission /\ UNCHANGED faults)
    /\ WF_mcvars(B!BaseAcceptTrainResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!BaseConvertResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgAggregateOneResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedAddParamStats /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedAddParamValue /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedAddParamHistory /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgProcessMetrics /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedAddMetricStats /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedAddMetricValue /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedAddMetricHistory /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgIncrementReceived /\ UNCHANGED faults)
    /\ WF_mcvars(B!BasePublishAcceptance /\ UNCHANGED faults)
    /\ WF_mcvars(B!BaseClearTrainingResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommStampReceipt /\ UNCHANGED faults)
    /\ WF_mcvars(B!BaseProcessUnknownResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommDropSubmission /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommMonitorBegin /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommDeadCheckDone /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommJobPolicyDecision /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommTaskDeadCheckDone /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommMonitorMarkTerminal /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommMonitorRemove /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommMonitorCleanup /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommMonitorNoTask /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgPollStanding /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgPollAbort /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgGetAggregationStats /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedGetParamResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!WeightedGetMetricResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgBuildAggregateResult /\ UNCHANGED faults)
    /\ WF_mcvars(B!BaseFedAvgUpdateModel /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgSaveModel /\ UNCHANGED faults)
    /\ WF_mcvars(B!FedAvgAdvanceRound /\ UNCHANGED faults)
    /\ WF_mcvars(B!ServerRunnerCloseWorkflow /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommFinalizeRun /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommTaskUnavailable /\ UNCHANGED faults)
    /\ WF_mcvars(B!ServerRunnerSubmissionActive /\ UNCHANGED faults)
    /\ WF_mcvars(B!WFCommAcquireSubmission /\ UNCHANGED faults)
    /\ WF_mcvars(B!ServerRunnerDropClosedSubmission /\ UNCHANGED faults)
    /\ \A c \in Clients : SF_mcvars(B!WFCommCheckDeadClient(c) /\ UNCHANGED faults)
    /\ \A c \in Clients : SF_mcvars(B!WFCommReadPolicyClient(c) /\ UNCHANGED faults)
    /\ \A c \in Clients : SF_mcvars(B!WFCommReadTaskDeadClient(c) /\ UNCHANGED faults)
    /\ \A t \in Tasks : SF_mcvars(B!WFCommMonitorSelect(t) /\ UNCHANGED faults)
    /\ \A c \in Clients : SF_mcvars(B!WFCommProcessTaskRequest(c) /\ UNCHANGED faults)
    /\ \A id \in Ids : SF_mcvars(B!WFCommResendTask(id) /\ UNCHANGED faults)

MCLiveSpec == MCSpec /\ ProgressFairness /\ CallbacksTerminate

Limits_standard == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 1, resultError |-> 1, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 1, cancel |-> 1, dead |-> 1]

Limits_s1_protected_input == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 0]

Limits_s2_identity_history == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 1, cancel |-> 0, dead |-> 0]

Limits_s3_partial_parameters == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 1, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 0]

Limits_s3_metric_failure == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 0, metricPrep |-> 1, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 0]

Limits_s3_conversion_control == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 1, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 0]

Limits_s4_filter_retirement == [before |-> 0, snapshot |-> 0, filter |-> 1, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 0]

Limits_s4_cancel_overlap == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 1, dead |-> 0]

Limits_s4_prepare_error == [before |-> 1, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 0]

Limits_s5_dead_policy == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 0, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 1]

Limits_s5_progress == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 1, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 1, dead |-> 1]

Limits_s5_resilient == [before |-> 0, snapshot |-> 0, filter |-> 0, delivery |-> 0, resultError |-> 1, conversion |-> 0, param |-> 0, metricPrep |-> 0, metric |-> 0, ackLoss |-> 0, cancel |-> 0, dead |-> 0]
\* Diagnostic conjunct of CommittedAcceptanceConsistency: isolate retained values
\* from earlier statistics-only failures, without restricting any transition.
CommittedValuesAccepted == \A t \in s.committed : UsedIds(s.used[t]) \subseteq AcceptedIds(t)
=============================================================================
