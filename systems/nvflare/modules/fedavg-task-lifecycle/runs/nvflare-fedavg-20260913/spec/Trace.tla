------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category A: totally ordered lifecycle trace, using real boundary hooks.
\* Instrument each internal step; no unconstrained or hidden silent actions.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
RawTrace == TLCEval(ndJsonDeserialize(JsonFile))
MetaLines == SelectSeq(RawTrace, LAMBDA x :
    IF "tag" \in DOMAIN x THEN x.tag = "specula-meta" ELSE FALSE)
ASSUME Len(MetaLines) = 1
Meta == MetaLines[1]
ASSUME /\ Meta.schema = 1
       /\ Meta.sourceHead = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
       /\ Meta.origin \in {"implementation", "synthetic-test"}
TraceLog == TLCEval(SelectSeq(RawTrace, LAMBDA x :
    IF "tag" \in DOMAIN x THEN x.tag = "trace" ELSE FALSE))
ASSUME Len(TraceLog) > 0
\* Only explicit trace records are replayed. Unknown/malformed trace event names
\* remain in TraceLog and fail; they are not filtered out as harmless noise.
TraceClients == SeqSet(Meta.config.Clients)
TraceSelected == SeqSet(Meta.config.Selected)
TraceNumRounds == Meta.config.NumRounds
TraceNumKeys == Meta.config.NumKeys
TraceHistoryLimit == Meta.config.HistoryLimit
TraceErrorMode == Meta.config.ErrorMode
TraceOutboundFilter == Meta.config.OutboundFilter
TraceLazyOffload == Meta.config.LazyOffload
TraceAllocationFailure == Meta.config.AllocationFailure
TraceConversionFailure == Meta.config.ConversionFailure
TraceBeforeSendFailure == Meta.config.BeforeSendFailure
TraceAllowEmpty == Meta.config.AllowEmpty
TraceMetricKinds == SeqSet(Meta.config.MetricKinds)
TraceMinSites == Meta.config.MinSites
TraceRequiredSites == SeqSet(Meta.config.RequiredSites)
TraceAllowPartialCompletion == Meta.config.AllowPartialCompletion

ASSUME /\ IsFiniteSet(TraceClients) /\ TraceClients /= {}
       /\ "server" \notin TraceClients /\ "clock" \notin TraceClients
       /\ "transport" \notin TraceClients

VARIABLE l
tracevars == <<s,l>>
logline == TraceLog[l].event
Unique(q) == Len(q) = Cardinality(SeqSet(q))

\* JSON arrays encode sequences, including task-indexed functions. Set-valued
\* observation fields use arrays without duplicates; normalize only those.
TraceStateShape(r) ==
    /\ Len(r.task) = NumRounds /\ Len(r.ct) = NumRounds /\ Len(r.net) = NumRounds
    /\ Len(r.used) = NumRounds
    /\ Unique(r.wf.started) /\ Unique(r.requested) /\ Unique(r.committed)
    /\ Unique(r.saved) /\ Unique(r.unknownSeen) /\ Unique(r.aggr.failedClients)
    /\ Unique(r.comm.pending) /\ Unique(r.comm.deadView)
    /\ Unique(r.mon.pending) /\ Unique(r.mon.deadView)
    /\ \A t \in Tasks : Unique(r.task[t].retiredOutstanding)
DecodeState(r) == [r EXCEPT
    !.wf.started = SeqSet(@), !.requested = SeqSet(@),
    !.task = [t \in Tasks |-> [r.task[t] EXCEPT !.retiredOutstanding = SeqSet(@)]],
    !.aggr.failedClients = SeqSet(@),
    !.comm.pending = SeqSet(@), !.comm.deadView = SeqSet(@),
    !.mon.pending = SeqSet(@), !.mon.deadView = SeqSet(@),
    !.committed = SeqSet(@), !.saved = SeqSet(@), !.unknownSeen = SeqSet(@)]

\* Mandatory strong post-state check: every event supplies the complete state.
\* Equality checks changed AND unchanged fields, actual stats and ghost PCs.
\* Missing fields cause a failed replay; no optional/vacuous field guards.
ValidatePostState == /\ TraceStateShape(logline.state)
                     /\ s' = DecodeState(logline.state)
EventIs(name, node, argc) ==
    /\ l <= Len(TraceLog)
    /\ DOMAIN logline = {"name","nid","args","state","seq"}
    /\ logline.name = name /\ logline.nid = node /\ logline.seq = l
    /\ Len(logline.args) = argc
TraceInit == /\ Init /\ l = 1
             /\ TraceStateShape(Meta.initial)
             /\ s = DecodeState(Meta.initial)

\* nvflare/app_common/workflows/fedavg.py:186-195
Trace_FedAvgRoundStarted ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgRoundStarted"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgRoundStarted", "server", 0)
    /\ FedAvgRoundStarted
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:197-212
Trace_FedAvgResetAggregation ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgResetAggregation"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgResetAggregation", "server", 0)
    /\ FedAvgResetAggregation
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/base_model_controller.py:142-158,188-221; nvflare/apis/impl/wf_comm_server.py:531-575
Trace_WFCommScheduleTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommScheduleTask"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommScheduleTask", "server", 0)
    /\ WFCommScheduleTask
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:385-421; nvflare/apis/impl/wf_comm_server.py:209-283; nvflare/apis/impl/task_manager.py:61-70
Trace_WFCommProcessTaskRequest ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommProcessTaskRequest"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("WFCommProcessTaskRequest", "server", 1)
    /\ WFCommProcessTaskRequest(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:230-241,277-370
Trace_WFCommResendTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommResendTask"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("WFCommResendTask", "server", 1)
    /\ WFCommResendTask(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/base_model_controller.py:225-228; nvflare/apis/impl/wf_comm_server.py:281-298
Trace_BasePrepareTaskData ==
    /\ l <= Len(TraceLog) /\ logline.name = "BasePrepareTaskData"
    /\ Len(logline.args) = 0
    /\ EventIs("BasePrepareTaskData", "server", 0)
    /\ BasePrepareTaskData
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:281-314
Trace_BasePrepareTaskDataFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "BasePrepareTaskDataFailure"
    /\ Len(logline.args) = 0
    /\ EventIs("BasePrepareTaskDataFailure", "server", 0)
    /\ BasePrepareTaskDataFailure
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:305-324
Trace_WFCommProtectBroadcast ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommProtectBroadcast"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommProtectBroadcast", "server", 0)
    /\ WFCommProtectBroadcast
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:313-324
Trace_WFCommProtectBroadcastFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommProtectBroadcastFailure"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommProtectBroadcastFailure", "server", 0)
    /\ WFCommProtectBroadcastFailure
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:327-345; nvflare/app_common/workflows/base_model_controller.py:213-221
Trace_WFCommCheckCanSend ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommCheckCanSend"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommCheckCanSend", "server", 0)
    /\ WFCommCheckCanSend
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:349-370; nvflare/apis/shareable.py:157-173; nvflare/private/fed/server/server_runner.py:411-421,325-331
Trace_WFCommPublishClientTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommPublishClientTask"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommPublishClientTask", "server", 0)
    /\ WFCommPublishClientTask
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:340-345
Trace_WFCommTaskTryAgain ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommTaskTryAgain"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommTaskTryAgain", "server", 0)
    /\ WFCommTaskTryAgain
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:329-371
Trace_ServerRunnerFilterTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerFilterTask"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("ServerRunnerFilterTask", "server", 1)
    /\ ServerRunnerFilterTask(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:333-350
Trace_ServerRunnerFilterFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerFilterFailure"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("ServerRunnerFilterFailure", "server", 1)
    /\ ServerRunnerFilterFailure(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:350-356; nvflare/apis/impl/wf_comm_server.py:372-390,794-812
Trace_WFCommHandleException ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommHandleException"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("WFCommHandleException", "server", 1)
    /\ WFCommHandleException(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/client/client_runner.py:225-248; nvflare/private/fed/server/server_runner.py:371
Trace_ClientReceiveTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "ClientReceiveTask"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("ClientReceiveTask", logline.args[1][2], 1)
    /\ ClientReceiveTask(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:371; nvflare/private/fed/client/client_runner.py:225-248
Trace_TaskDeliveryFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "TaskDeliveryFailure"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("TaskDeliveryFailure", "transport", 1)
    /\ TaskDeliveryFailure(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/client/client_runner.py:225-248; nvflare/app_common/workflows/fedavg.py:268-273,306-326
Trace_ClientProcessTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "ClientProcessTask"
    /\ Len(logline.args) = 3
    /\ logline.args[1] \in Ids
    /\ logline.args[2] \in {"params","empty"}
    /\ logline.args[3] \in MetricKinds
    /\ EventIs("ClientProcessTask", logline.args[1][2], 3)
    /\ ClientProcessTask(logline.args[1], logline.args[2], logline.args[3])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/client/client_runner.py:225-248
Trace_ClientExecutionError ==
    /\ l <= Len(TraceLog) /\ logline.name = "ClientExecutionError"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("ClientExecutionError", logline.args[1][2], 1)
    /\ ClientExecutionError(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/client/client_runner.py:615-630; nvflare/private/fed/server/server_runner.py:585-605
Trace_ClientCheckTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "ClientCheckTask"
    /\ Len(logline.args) = 2
    /\ logline.args[1] \in Ids
    /\ logline.args[2] \in 1..Len(s.net[logline.args[1][1]][logline.args[1][2]])
    /\ EventIs("ClientCheckTask", "server", 2)
    /\ ClientCheckTask(logline.args[1], logline.args[2])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/client/client_runner.py:590-637
Trace_ClientRetryResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "ClientRetryResult"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Ids
    /\ EventIs("ClientRetryResult", logline.args[1][2], 1)
    /\ ClientRetryResult(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:460-475
Trace_ServerRunnerProcessSubmission ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerProcessSubmission"
    /\ Len(logline.args) = 2
    /\ logline.args[1] \in Ids
    /\ logline.args[2] \in 1..Len(s.net[logline.args[1][1]][logline.args[1][2]])
    /\ EventIs("ServerRunnerProcessSubmission", "server", 2)
    /\ ServerRunnerProcessSubmission(logline.args[1], logline.args[2])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:448-499
Trace_WFCommDispatchSubmission ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommDispatchSubmission"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommDispatchSubmission", "server", 0)
    /\ WFCommDispatchSubmission
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/base_model_controller.py:251-273,329-365; nvflare/app_common/utils/error_handling_utils.py:51-61; nvflare/private/fed/server/server_runner.py:252-256,607-611
Trace_BaseAcceptTrainResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "BaseAcceptTrainResult"
    /\ Len(logline.args) = 0
    /\ EventIs("BaseAcceptTrainResult", "server", 0)
    /\ BaseAcceptTrainResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/base_model_controller.py:272-284
Trace_BaseConvertResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "BaseConvertResult"
    /\ Len(logline.args) = 0
    /\ EventIs("BaseConvertResult", "server", 0)
    /\ BaseConvertResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/base_model_controller.py:272-278
Trace_BaseConvertResultFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "BaseConvertResultFailure"
    /\ Len(logline.args) = 0
    /\ EventIs("BaseConvertResultFailure", "server", 0)
    /\ BaseConvertResultFailure
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:268-304
Trace_FedAvgAggregateOneResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgAggregateOneResult"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgAggregateOneResult", "server", 0)
    /\ FedAvgAggregateOneResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:162-175
Trace_WeightedAddParamStats ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedAddParamStats"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedAddParamStats", "server", 0)
    /\ WeightedAddParamStats
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:173-216
Trace_WeightedAddParamValue ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedAddParamValue"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedAddParamValue", "server", 0)
    /\ WeightedAddParamValue
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:173-216; nvflare/app_opt/pt/lazy_tensor_dict.py:77-80; nvflare/app_common/workflows/base_model_controller.py:281-286
Trace_WeightedParamFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedParamFailure"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedParamFailure", "server", 0)
    /\ WeightedParamFailure
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:218-224; nvflare/app_common/workflows/fedavg.py:299-310
Trace_WeightedAddParamHistory ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedAddParamHistory"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedAddParamHistory", "server", 0)
    /\ WeightedAddParamHistory
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:306-326
Trace_FedAvgProcessMetrics ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgProcessMetrics"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgProcessMetrics", "server", 0)
    /\ FedAvgProcessMetrics
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:312-320; nvflare/app_common/workflows/base_model_controller.py:281-286
Trace_FedAvgMetricPreparationFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgMetricPreparationFailure"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgMetricPreparationFailure", "server", 0)
    /\ FedAvgMetricPreparationFailure
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:321-326; nvflare/app_common/aggregators/weighted_aggregation_helper.py:162-175
Trace_WeightedAddMetricStats ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedAddMetricStats"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedAddMetricStats", "server", 0)
    /\ WeightedAddMetricStats
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:177-216
Trace_WeightedAddMetricValue ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedAddMetricValue"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedAddMetricValue", "server", 0)
    /\ WeightedAddMetricValue
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:177-216; nvflare/app_common/workflows/base_model_controller.py:281-286
Trace_WeightedMetricFailure ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedMetricFailure"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedMetricFailure", "server", 0)
    /\ WeightedMetricFailure
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:218-224; nvflare/app_common/workflows/fedavg.py:328-330
Trace_WeightedAddMetricHistory ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedAddMetricHistory"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedAddMetricHistory", "server", 0)
    /\ WeightedAddMetricHistory
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:328-330; nvflare/app_common/workflows/base_model_controller.py:281-284
Trace_FedAvgIncrementReceived ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgIncrementReceived"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgIncrementReceived", "server", 0)
    /\ FedAvgIncrementReceived
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/base_model_controller.py:267-291
Trace_BasePublishAcceptance ==
    /\ l <= Len(TraceLog) /\ logline.name = "BasePublishAcceptance"
    /\ Len(logline.args) = 0
    /\ EventIs("BasePublishAcceptance", "server", 0)
    /\ BasePublishAcceptance
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/base_model_controller.py:292-294
Trace_BaseClearTrainingResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "BaseClearTrainingResult"
    /\ Len(logline.args) = 0
    /\ EventIs("BaseClearTrainingResult", "server", 0)
    /\ BaseClearTrainingResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:504-521; nvflare/private/fed/server/server_runner.py:559-565
Trace_WFCommStampReceipt ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommStampReceipt"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommStampReceipt", "server", 0)
    /\ WFCommStampReceipt
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:454-473; nvflare/app_common/workflows/base_model_controller.py:298-365
Trace_BaseProcessUnknownResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "BaseProcessUnknownResult"
    /\ Len(logline.args) = 0
    /\ EventIs("BaseProcessUnknownResult", "server", 0)
    /\ BaseProcessUnknownResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:454-495; nvflare/private/fed/server/server_runner.py:516-518; nvflare/private/fed/server/server_commands.py:242-246
Trace_WFCommDropSubmission ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommDropSubmission"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommDropSubmission", "server", 0)
    /\ WFCommDropSubmission
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_command_agent.py:96-110; nvflare/private/fed/client/client_runner.py:628-637
Trace_ServerCommandDispatchAck ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerCommandDispatchAck"
    /\ Len(logline.args) = 2
    /\ logline.args[1] \in Ids
    /\ logline.args[2] \in 1..Len(s.net[logline.args[1][1]][logline.args[1][2]])
    /\ EventIs("ServerCommandDispatchAck", logline.args[1][2], 2)
    /\ ServerCommandDispatchAck(logline.args[1], logline.args[2])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/client/client_runner.py:628-637; nvflare/private/fed/server/server_command_agent.py:96-110
Trace_ClientLoseDispatchAck ==
    /\ l <= Len(TraceLog) /\ logline.name = "ClientLoseDispatchAck"
    /\ Len(logline.args) = 2
    /\ logline.args[1] \in Ids
    /\ logline.args[2] \in 1..Len(s.net[logline.args[1][1]][logline.args[1][2]])
    /\ EventIs("ClientLoseDispatchAck", logline.args[1][2], 2)
    /\ ClientLoseDispatchAck(logline.args[1], logline.args[2])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:794-827
Trace_WFCommCancelTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommCancelTask"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Tasks
    /\ EventIs("WFCommCancelTask", "server", 1)
    /\ WFCommCancelTask(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:175-186,79-82
Trace_WFCommReportDeadClient ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommReportDeadClient"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("WFCommReportDeadClient", "server", 1)
    /\ WFCommReportDeadClient(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:572-587; nvflare/apis/impl/wf_comm_server.py:1250-1259
Trace_WFCommClientIsActive ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommClientIsActive"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("WFCommClientIsActive", "server", 1)
    /\ WFCommClientIsActive(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1035-1040,1161-1168
Trace_ClockAdvance ==
    /\ l <= Len(TraceLog) /\ logline.name = "ClockAdvance"
    /\ Len(logline.args) = 0
    /\ EventIs("ClockAdvance", "clock", 0)
    /\ ClockAdvance
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1046-1049,1024-1030
Trace_WFCommMonitorBegin ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommMonitorBegin"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommMonitorBegin", "server", 0)
    /\ WFCommMonitorBegin
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1029-1044
Trace_WFCommCheckDeadClient ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommCheckDeadClient"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("WFCommCheckDeadClient", "server", 1)
    /\ WFCommCheckDeadClient(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1049-1051,1218-1227
Trace_WFCommDeadCheckDone ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommDeadCheckDone"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommDeadCheckDone", "server", 0)
    /\ WFCommDeadCheckDone
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1218-1227
Trace_WFCommReadPolicyClient ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommReadPolicyClient"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("WFCommReadPolicyClient", "server", 1)
    /\ WFCommReadPolicyClient(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1229-1248,1051-1057; nvflare/private/fed/server/server_runner.py:252-256,607-611
Trace_WFCommJobPolicyDecision ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommJobPolicyDecision"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommJobPolicyDecision", "server", 0)
    /\ WFCommJobPolicyDecision
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1060-1068
Trace_WFCommMonitorAcquire ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommMonitorAcquire"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommMonitorAcquire", "server", 0)
    /\ WFCommMonitorAcquire
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1067-1097; nvflare/apis/impl/bcast_manager.py:52-75
Trace_WFCommMonitorSelect ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommMonitorSelect"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Tasks
    /\ EventIs("WFCommMonitorSelect", "server", 1)
    /\ WFCommMonitorSelect(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1170-1185
Trace_WFCommReadTaskDeadClient ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommReadTaskDeadClient"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("WFCommReadTaskDeadClient", "server", 1)
    /\ WFCommReadTaskDeadClient(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1092-1098,1170-1187
Trace_WFCommTaskDeadCheckDone ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommTaskDeadCheckDone"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommTaskDeadCheckDone", "server", 0)
    /\ WFCommTaskDeadCheckDone
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1079-1084,1092-1097
Trace_WFCommMonitorMarkTerminal ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommMonitorMarkTerminal"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommMonitorMarkTerminal", "server", 0)
    /\ WFCommMonitorMarkTerminal
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1100-1109,397-406
Trace_WFCommMonitorRemove ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommMonitorRemove"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommMonitorRemove", "server", 0)
    /\ WFCommMonitorRemove
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1116-1155
Trace_WFCommMonitorCleanup ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommMonitorCleanup"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommMonitorCleanup", "server", 0)
    /\ WFCommMonitorCleanup
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:1067-1070,1113-1114
Trace_WFCommMonitorNoTask ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommMonitorNoTask"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommMonitorNoTask", "server", 0)
    /\ WFCommMonitorNoTask
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:223-230; nvflare/apis/impl/wf_comm_server.py:786-792
Trace_FedAvgPollStanding ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgPollStanding"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgPollStanding", "server", 0)
    /\ FedAvgPollStanding
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:224-228
Trace_FedAvgPollAbort ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgPollAbort"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgPollAbort", "server", 0)
    /\ FedAvgPollAbort
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:230-233,345-351; nvflare/app_common/aggregators/weighted_aggregation_helper.py:242-265
Trace_FedAvgGetAggregationStats ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgGetAggregationStats"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgGetAggregationStats", "server", 0)
    /\ FedAvgGetAggregationStats
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:226-240; nvflare/app_common/workflows/fedavg.py:351
Trace_WeightedGetParamResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedGetParamResult"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedGetParamResult", "server", 0)
    /\ WeightedGetParamResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:352-353; nvflare/app_common/aggregators/weighted_aggregation_helper.py:226-240
Trace_WeightedGetMetricResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "WeightedGetMetricResult"
    /\ Len(logline.args) = 0
    /\ EventIs("WeightedGetMetricResult", "server", 0)
    /\ WeightedGetMetricResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:355-365
Trace_FedAvgBuildAggregateResult ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgBuildAggregateResult"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgBuildAggregateResult", "server", 0)
    /\ FedAvgBuildAggregateResult
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:234-238; nvflare/app_common/workflows/base_fedavg.py:302-322; nvflare/app_common/utils/fl_model_utils.py:233-239
Trace_BaseFedAvgUpdateModel ==
    /\ l <= Len(TraceLog) /\ logline.name = "BaseFedAvgUpdateModel"
    /\ Len(logline.args) = 0
    /\ EventIs("BaseFedAvgUpdateModel", "server", 0)
    /\ BaseFedAvgUpdateModel
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:257-259,489-504; nvflare/app_common/workflows/base_model_controller.py:439-446
Trace_FedAvgSaveModel ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgSaveModel"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgSaveModel", "server", 0)
    /\ FedAvgSaveModel
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/app_common/workflows/fedavg.py:186,261-266; nvflare/private/fed/server/server_runner.py:151-183
Trace_FedAvgAdvanceRound ==
    /\ l <= Len(TraceLog) /\ logline.name = "FedAvgAdvanceRound"
    /\ Len(logline.args) = 0
    /\ EventIs("FedAvgAdvanceRound", "server", 0)
    /\ FedAvgAdvanceRound
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:157-171
Trace_ServerRunnerCloseWorkflow ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerCloseWorkflow"
    /\ Len(logline.args) = 0
    /\ EventIs("ServerRunnerCloseWorkflow", "server", 0)
    /\ ServerRunnerCloseWorkflow
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/apis/impl/wf_comm_server.py:829-895; nvflare/private/fed/server/server_runner.py:170-178
Trace_WFCommFinalizeRun ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommFinalizeRun"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommFinalizeRun", "server", 0)
    /\ WFCommFinalizeRun
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:289-298,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259; nvflare/private/fed/client/client_runner.py:548-588
Trace_ServerRunnerTaskRequestActive ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerTaskRequestActive"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("ServerRunnerTaskRequestActive", "server", 1)
    /\ ServerRunnerTaskRequestActive(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:385-395
Trace_ServerRunnerAcquireTaskRequest ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerAcquireTaskRequest"
    /\ Len(logline.args) = 1
    /\ logline.args[1] \in Clients
    /\ EventIs("ServerRunnerAcquireTaskRequest", "server", 1)
    /\ ServerRunnerAcquireTaskRequest(logline.args[1])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:386-395; nvflare/apis/impl/wf_comm_server.py:220-272; nvflare/apis/impl/task_manager.py:61-70
Trace_WFCommTaskUnavailable ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommTaskUnavailable"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommTaskUnavailable", "server", 0)
    /\ WFCommTaskUnavailable
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:585-605,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259
Trace_ServerRunnerCheckTaskActive ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerCheckTaskActive"
    /\ Len(logline.args) = 2
    /\ logline.args[1] \in Ids
    /\ logline.args[2] \in 1..Len(s.net[logline.args[1][1]][logline.args[1][2]])
    /\ EventIs("ServerRunnerCheckTaskActive", "server", 2)
    /\ ServerRunnerCheckTaskActive(logline.args[1], logline.args[2])
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:463-475,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259
Trace_ServerRunnerSubmissionActive ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerSubmissionActive"
    /\ Len(logline.args) = 0
    /\ EventIs("ServerRunnerSubmissionActive", "server", 0)
    /\ ServerRunnerSubmissionActive
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:559-565; nvflare/apis/impl/wf_comm_server.py:434-451
Trace_WFCommAcquireSubmission ==
    /\ l <= Len(TraceLog) /\ logline.name = "WFCommAcquireSubmission"
    /\ Len(logline.args) = 0
    /\ EventIs("WFCommAcquireSubmission", "server", 0)
    /\ WFCommAcquireSubmission
    /\ ValidatePostState
    /\ l' = l+1

\* nvflare/private/fed/server/server_runner.py:463-470; nvflare/private/fed/server/server_commands.py:242-246
Trace_ServerRunnerDropClosedSubmission ==
    /\ l <= Len(TraceLog) /\ logline.name = "ServerRunnerDropClosedSubmission"
    /\ Len(logline.args) = 0
    /\ EventIs("ServerRunnerDropClosedSubmission", "server", 0)
    /\ ServerRunnerDropClosedSubmission
    /\ ValidatePostState
    /\ l' = l+1

MatchedAction ==
    \/ Trace_FedAvgRoundStarted
    \/ Trace_FedAvgResetAggregation
    \/ Trace_WFCommScheduleTask
    \/ Trace_WFCommProcessTaskRequest
    \/ Trace_WFCommResendTask
    \/ Trace_BasePrepareTaskData
    \/ Trace_BasePrepareTaskDataFailure
    \/ Trace_WFCommProtectBroadcast
    \/ Trace_WFCommProtectBroadcastFailure
    \/ Trace_WFCommCheckCanSend
    \/ Trace_WFCommPublishClientTask
    \/ Trace_WFCommTaskTryAgain
    \/ Trace_ServerRunnerFilterTask
    \/ Trace_ServerRunnerFilterFailure
    \/ Trace_WFCommHandleException
    \/ Trace_ClientReceiveTask
    \/ Trace_TaskDeliveryFailure
    \/ Trace_ClientProcessTask
    \/ Trace_ClientExecutionError
    \/ Trace_ClientCheckTask
    \/ Trace_ClientRetryResult
    \/ Trace_ServerRunnerProcessSubmission
    \/ Trace_WFCommDispatchSubmission
    \/ Trace_BaseAcceptTrainResult
    \/ Trace_BaseConvertResult
    \/ Trace_BaseConvertResultFailure
    \/ Trace_FedAvgAggregateOneResult
    \/ Trace_WeightedAddParamStats
    \/ Trace_WeightedAddParamValue
    \/ Trace_WeightedParamFailure
    \/ Trace_WeightedAddParamHistory
    \/ Trace_FedAvgProcessMetrics
    \/ Trace_FedAvgMetricPreparationFailure
    \/ Trace_WeightedAddMetricStats
    \/ Trace_WeightedAddMetricValue
    \/ Trace_WeightedMetricFailure
    \/ Trace_WeightedAddMetricHistory
    \/ Trace_FedAvgIncrementReceived
    \/ Trace_BasePublishAcceptance
    \/ Trace_BaseClearTrainingResult
    \/ Trace_WFCommStampReceipt
    \/ Trace_BaseProcessUnknownResult
    \/ Trace_WFCommDropSubmission
    \/ Trace_ServerCommandDispatchAck
    \/ Trace_ClientLoseDispatchAck
    \/ Trace_WFCommCancelTask
    \/ Trace_WFCommReportDeadClient
    \/ Trace_WFCommClientIsActive
    \/ Trace_ClockAdvance
    \/ Trace_WFCommMonitorBegin
    \/ Trace_WFCommCheckDeadClient
    \/ Trace_WFCommDeadCheckDone
    \/ Trace_WFCommReadPolicyClient
    \/ Trace_WFCommJobPolicyDecision
    \/ Trace_WFCommMonitorAcquire
    \/ Trace_WFCommMonitorSelect
    \/ Trace_WFCommReadTaskDeadClient
    \/ Trace_WFCommTaskDeadCheckDone
    \/ Trace_WFCommMonitorMarkTerminal
    \/ Trace_WFCommMonitorRemove
    \/ Trace_WFCommMonitorCleanup
    \/ Trace_WFCommMonitorNoTask
    \/ Trace_FedAvgPollStanding
    \/ Trace_FedAvgPollAbort
    \/ Trace_FedAvgGetAggregationStats
    \/ Trace_WeightedGetParamResult
    \/ Trace_WeightedGetMetricResult
    \/ Trace_FedAvgBuildAggregateResult
    \/ Trace_BaseFedAvgUpdateModel
    \/ Trace_FedAvgSaveModel
    \/ Trace_FedAvgAdvanceRound
    \/ Trace_ServerRunnerCloseWorkflow
    \/ Trace_WFCommFinalizeRun
    \/ Trace_ServerRunnerTaskRequestActive
    \/ Trace_ServerRunnerAcquireTaskRequest
    \/ Trace_WFCommTaskUnavailable
    \/ Trace_ServerRunnerCheckTaskActive
    \/ Trace_ServerRunnerSubmissionActive
    \/ Trace_WFCommAcquireSubmission
    \/ Trace_ServerRunnerDropClosedSubmission

TraceNext ==
    \/ /\ l <= Len(TraceLog) /\ MatchedAction
    \/ /\ l > Len(TraceLog) /\ UNCHANGED tracevars

\* Fair cursor progression rules out arbitrary stuttering at a matchable event.
\* An unmatchable event has no enabled progression and cannot satisfy this goal.
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
TraceCursorType == l \in 1..(Len(TraceLog)+1)
=============================================================================
