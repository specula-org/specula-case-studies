------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
VARIABLE l
traceVars == <<s,l>>
JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON ELSE "../traces/trace.ndjson"
TraceLog == SelectSeq(ndJsonDeserialize(JsonFile),
                     LAMBDA e: IF "tag" \in DOMAIN e THEN e.tag = "trace" ELSE FALSE)
logline == TraceLog[l]
TraceConfig == TraceLog[1].config

\* JSON arrays encode sets and sequences distinctly by the schema, never by guessing.
DecodeAI(j) == [j EXCEPT !.mask = ToSet(@)]
DecodeWF(j) == [j EXCEPT !.ai = [a \in Activities |-> DecodeAI(j.ai[a])],
   !.scheduled = ToSet(@), !.seen = ToSet(@), !.consumed = ToSet(@)]
DecodeReply(j) == [j EXCEPT !.outcome = ToSet(@)]
DecodeWrite(j) == [j EXCEPT !.wf = DecodeWF(@), !.tasks = ToSet(@)]
DecodeState(j) == [j EXCEPT
   !.cache = DecodeWF(@), !.db = DecodeWF(@),
   !.tx.reply = DecodeReply(@),
   !.appended = ToSet(@), !.tasks = ToSet(@), !.claimed = ToSet(@), !.ackable = ToSet(@),
   !.copies = ToSet(@), !.matching = ToSet(@), !.dispatchReturns = ToSet(@),
   !.startCalls = ToSet(@), !.startMsgs = ToSet(@), !.polls = ToSet(@), !.lostStarts = ToSet(@),
   !.tokens = ToSet(@), !.requests = ToSet(@), !.issuedRequests = ToSet(@),
   !.replies = {DecodeReply(j.replies[i]): i \in 1..Len(j.replies)},
   !.pollReplies = {DecodeReply(j.pollReplies[i]): i \in 1..Len(j.pollReplies)},
   !.observed = {DecodeReply(j.observed[i]): i \in 1..Len(j.observed)},
   !.acknowledged = ToSet(@), !.cancelObserved = ToSet(@),
   !.writes = {DecodeWrite(j.writes[i]): i \in 1..Len(j.writes)},
   !.receipts = ToSet(@), !.historyAppends = ToSet(@), !.committedOutcomes = ToSet(@),
   !.notifyPending = ToSet(@), !.notified = ToSet(@),
   !.lastCheck.beforeAI = DecodeAI(@), !.lastCheck.afterAI = DecodeAI(@),
   !.lastCheck.beforeTerms = ToSet(@), !.lastCheck.afterTerms = ToSet(@),
   !.readback.outcomes = ToSet(@)]
EnvelopeFields == {"tag","schemaVersion","seq","event","args","state","evidence"}
\* This validates declared provenance and completeness. It cannot prove that a
\* recorder told the truth; raw hooks/readbacks/ordering evidence must be audited.
IndependentEvidence(e) ==
  /\ EnvelopeFields \subseteq DOMAIN e
  /\ e.schemaVersion = 1 /\ e.tag = "trace"
  /\ {"sourceRevision","basis","complete","ordering","artifact"} \subseteq DOMAIN e.evidence
  /\ e.evidence.sourceRevision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
  /\ e.evidence.basis = "implementation" /\ e.evidence.complete = TRUE
  /\ e.evidence.ordering = "lease-and-transaction"
  /\ e.evidence.artifact \in STRING /\ e.evidence.artifact # ""
CompleteTraceUsesIndependentEvidence == \A i \in 1..Len(TraceLog): IndependentEvidence(TraceLog[i])
IsEvent(name) == l <= Len(TraceLog) /\ logline.event = name
ValidatePostState ==
  /\ IndependentEvidence(logline) /\ logline.seq = l
  /\ DOMAIN logline.state = DOMAIN s
  /\ s' = DecodeState(logline.state)
  /\ IF l = Len(TraceLog) THEN logline.event = "FinishTrace" ELSE TRUE

TraceInit ==
  /\ Len(TraceLog) >= 2 /\ TraceLog[1].event = "Bootstrap" /\ TraceLog[1].seq = 1
  /\ CompleteTraceUsesIndependentEvidence
  /\ TraceConfig.sourceRevision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
  /\ TraceConfig.backend = "sqlite" /\ TraceConfig.journalMode = "wal"
  /\ TraceConfig.synchronous = "normal" /\ TraceConfig.eagerRequest = FALSE
  /\ TraceConfig.workerControlCancellation = FALSE /\ TraceConfig.administrativeExtensions = FALSE
  /\ Init /\ s = DecodeState(TraceLog[1].state) /\ l = 2

TraceActivityCount == TraceConfig.ActivityCount
TraceNamespaceVersion == TraceConfig.NamespaceVersion
TraceIncrementRetryStamp == TraceConfig.IncrementRetryStamp
TraceHasRetryPolicy == TraceConfig.HasRetryPolicy
TraceMaximumAttempts == TraceConfig.MaximumAttempts
TraceInitialInterval == TraceConfig.InitialInterval
TraceBackoffCoefficient == TraceConfig.BackoffCoefficient
TraceMaximumInterval == TraceConfig.MaximumInterval
TraceScheduleToStart == TraceConfig.ScheduleToStart
TraceStartToClose == TraceConfig.StartToClose
TraceScheduleToClose == TraceConfig.ScheduleToClose
TraceHeartbeat == TraceConfig.Heartbeat
TraceWorkflowExpiration == TraceConfig.WorkflowExpiration
TraceKeepInitialWFT == TraceConfig.KeepInitialWFT
TraceInitialDBVersion == TraceConfig.InitialDBVersion
TraceWorkers == ToSet(TraceConfig.Workers)

\* workflow/mutable_state_impl.go:4306-4401; api/respondworkflowtaskcompleted/api.go:558
TraceAddActivityTaskScheduledEvent ==
  /\ IsEvent("AddActivityTaskScheduledEvent")
  /\ LET e == logline IN DOMAIN e.args = {} /\ AddActivityTaskScheduledEvent
  /\ ValidatePostState /\ l' = l+1

\* transfer_queue_active_task_executor.go:256-284
TraceProcessActivityTask ==
  /\ IsEvent("ProcessActivityTask")
  /\ LET e == logline IN DOMAIN e.args = {"task"} /\ ProcessActivityTask(e.args.task)
  /\ ValidatePostState /\ l' = l+1

\* timer_queue_active_task_executor.go:563-621
TraceExecuteActivityRetryTimerTask ==
  /\ IsEvent("ExecuteActivityRetryTimerTask")
  /\ LET e == logline IN DOMAIN e.args = {"task"} /\ ExecuteActivityRetryTimerTask(e.args.task)
  /\ ValidatePostState /\ l' = l+1

\* transfer_queue_active_task_executor.go:256-274; timer_queue_active_task_executor.go:565-597
TraceDiscardObsoleteActivityTask ==
  /\ IsEvent("DiscardObsoleteActivityTask")
  /\ LET e == logline IN DOMAIN e.args = {"task"} /\ DiscardObsoleteActivityTask(e.args.task)
  /\ ValidatePostState /\ l' = l+1

\* service/matching/matching_engine.go:646-693; service/matching/task_queue_partition_manager.go:607-673
TraceAddActivityTask ==
  /\ IsEvent("AddActivityTask")
  /\ LET e == logline IN DOMAIN e.args = {"delivery","created"} /\ AddActivityTaskAt(e.args.delivery,e.args.created)
  /\ ValidatePostState /\ l' = l+1

\* timer_queue_active_task_executor.go:623-639; transfer_queue_task_executor_base.go:95-144
TraceDeliverAddActivityTaskResponse ==
  /\ IsEvent("DeliverAddActivityTaskResponse")
  /\ LET e == logline IN DOMAIN e.args = {"id"} /\ DeliverAddActivityTaskResponse(e.args.id)
  /\ ValidatePostState /\ l' = l+1

\* timer_queue_active_task_executor.go:623-639
TraceLoseAddActivityTaskResponse ==
  /\ IsEvent("LoseAddActivityTaskResponse")
  /\ LET e == logline IN DOMAIN e.args = {"id"} /\ LoseAddActivityTaskResponse(e.args.id)
  /\ ValidatePostState /\ l' = l+1

\* service/matching/matching_engine.go:3587-3606
TracePollActivityTaskQueue ==
  /\ IsEvent("PollActivityTaskQueue")
  /\ LET e == logline IN DOMAIN e.args = {"delivery","worker"} /\ PollActivityTaskQueue(e.args.delivery,e.args.worker)
  /\ ValidatePostState /\ l' = l+1

\* client/history/retryable_client_gen.go:674-686
TraceRetryRecordActivityTaskStarted ==
  /\ IsEvent("RetryRecordActivityTaskStarted")
  /\ LET e == logline IN DOMAIN e.args = {"call"} /\ RetryRecordActivityTaskStarted(e.args.call)
  /\ ValidatePostState /\ l' = l+1

\* api/recordactivitytaskstarted/api.go:118-184,294-310; workflow/mutable_state_impl.go:4502-4565
TraceRecordActivityTaskStarted ==
  /\ IsEvent("RecordActivityTaskStarted")
  /\ LET e == logline IN DOMAIN e.args = {"call"} /\ RecordActivityTaskStarted(e.args.call)
  /\ ValidatePostState /\ l' = l+1

\* api/recordactivitytaskstarted/api.go:150-165,71-77
TraceRecordActivityTaskStartedDuplicate ==
  /\ IsEvent("RecordActivityTaskStartedDuplicate")
  /\ LET e == logline IN DOMAIN e.args = {"call"} /\ RecordActivityTaskStartedDuplicate(e.args.call)
  /\ ValidatePostState /\ l' = l+1

\* api/recordactivitytaskstarted/api.go:124-136,168-184
TraceRecordActivityTaskStartedRejected ==
  /\ IsEvent("RecordActivityTaskStartedRejected")
  /\ LET e == logline IN DOMAIN e.args = {"call"} /\ RecordActivityTaskStartedRejected(e.args.call)
  /\ ValidatePostState /\ l' = l+1

\* service/frontend/workflow_handler.go:1453-1463,1650-1659,1856-1865,2083-2092
TraceSendActivityRequest ==
  /\ IsEvent("SendActivityRequest")
  /\ LET e == logline IN DOMAIN e.args = {"token","kind","details"} /\ SendActivityRequest(e.args.token,e.args.kind,e.args.details)
  /\ ValidatePostState /\ l' = l+1

\* api/respondactivitytaskcompleted/api.go:74-126
TraceRespondActivityTaskCompleted ==
  /\ IsEvent("RespondActivityTaskCompleted")
  /\ LET e == logline IN DOMAIN e.args = {"request"} /\ RespondActivityTaskCompleted(e.args.request)
  /\ ValidatePostState /\ l' = l+1

\* api/respondactivitytaskfailed/api.go:88-125; workflow/mutable_state_impl.go:6880-6975
TraceRespondActivityTaskFailed ==
  /\ IsEvent("RespondActivityTaskFailed")
  /\ LET e == logline IN DOMAIN e.args = {"request"} /\ RespondActivityTaskFailed(e.args.request)
  /\ ValidatePostState /\ l' = l+1

\* api/respondactivitytaskcanceled/api.go:82-108
TraceRespondActivityTaskCanceled ==
  /\ IsEvent("RespondActivityTaskCanceled")
  /\ LET e == logline IN DOMAIN e.args = {"request"} /\ RespondActivityTaskCanceled(e.args.request)
  /\ ValidatePostState /\ l' = l+1

\* api/recordactivitytaskheartbeat/api.go:73-101; workflow/mutable_state_impl.go:2117-2127
TraceRecordActivityTaskHeartbeat ==
  /\ IsEvent("RecordActivityTaskHeartbeat")
  /\ LET e == logline IN DOMAIN e.args = {"request"} /\ RecordActivityTaskHeartbeat(e.args.request)
  /\ ValidatePostState /\ l' = l+1

\* api/activity_util.go:58-79; api/respondactivitytaskcanceled/api.go:82-89
TraceRejectActivityRequest ==
  /\ IsEvent("RejectActivityRequest")
  /\ LET e == logline IN DOMAIN e.args = {"request"} /\ RejectActivityRequest(e.args.request)
  /\ ValidatePostState /\ l' = l+1

\* timer_queue_active_task_executor.go:230-280,299-378
TraceExecuteActivityTimeoutTask ==
  /\ IsEvent("ExecuteActivityTimeoutTask")
  /\ LET e == logline IN DOMAIN e.args = {"task"} /\ ExecuteActivityTimeoutTask(e.args.task)
  /\ ValidatePostState /\ l' = l+1

\* timer_queue_active_task_executor.go:221-227
TraceDiscardClosedWorkflowTimer ==
  /\ IsEvent("DiscardClosedWorkflowTimer")
  /\ LET e == logline IN DOMAIN e.args = {"task"} /\ DiscardClosedWorkflowTimer(e.args.task)
  /\ ValidatePostState /\ l' = l+1

\* workflow/workflow_task_state_machine.go:453-479
TraceRecordWorkflowTaskStarted ==
  /\ IsEvent("RecordWorkflowTaskStarted")
  /\ LET e == logline IN DOMAIN e.args = {} /\ RecordWorkflowTaskStarted
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/api.go:384,557-566; historybuilder/event_store.go:178-199
TraceRespondWorkflowTaskCompleted ==
  /\ IsEvent("RespondWorkflowTaskCompleted")
  /\ LET e == logline IN DOMAIN e.args = {} /\ RespondWorkflowTaskCompleted
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:692-717; workflow/mutable_state_impl.go:4741-4783,4865-4892
TraceHandleCommandRequestCancelActivity ==
  /\ IsEvent("HandleCommandRequestCancelActivity")
  /\ LET e == logline IN DOMAIN e.args = {"activity"} /\ HandleCommandRequestCancelActivity(e.args.activity)
  /\ ValidatePostState /\ l' = l+1

\* workflow/mutable_state_impl.go:4751-4763; api/respondworkflowtaskcompleted/api.go:384,557-566
TraceHandleCommandCancelBufferedActivity ==
  /\ IsEvent("HandleCommandCancelBufferedActivity")
  /\ LET e == logline IN DOMAIN e.args = {"activity"} /\ HandleCommandCancelBufferedActivity(e.args.activity)
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:804-805
TraceHandleCommandCompleteWorkflow ==
  /\ IsEvent("HandleCommandCompleteWorkflow")
  /\ LET e == logline IN DOMAIN e.args = {} /\ HandleCommandCompleteWorkflow
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:692-717,804-805; historybuilder/event_store.go:168-175
TraceHandleCommandCancelAndCompleteWorkflow ==
  /\ IsEvent("HandleCommandCancelAndCompleteWorkflow")
  /\ LET e == logline IN DOMAIN e.args = {"activity"} /\ HandleCommandCancelAndCompleteWorkflow(e.args.activity)
  /\ ValidatePostState /\ l' = l+1

\* timer_queue_active_task_executor.go:658-818; workflow/util.go:72-92,28-49
TraceExecuteWorkflowRunTimeoutTask ==
  /\ IsEvent("ExecuteWorkflowRunTimeoutTask")
  /\ LET e == logline IN DOMAIN e.args = {} /\ ExecuteWorkflowRunTimeoutTask
  /\ ValidatePostState /\ l' = l+1

\* workflow/context.go:973-1001; workflow/mutable_state_impl.go:7616-7643,9055-9066; workflow/timer_sequence.go:118-164
TraceCloseTransactionAsMutation ==
  /\ IsEvent("CloseTransactionAsMutation")
  /\ LET e == logline IN DOMAIN e.args = {} /\ CloseTransactionAsMutation
  /\ ValidatePostState /\ l' = l+1

\* shard/context_impl.go:623-649
TraceSetAndTrackTaskKeys ==
  /\ IsEvent("SetAndTrackTaskKeys")
  /\ LET e == logline IN DOMAIN e.args = {"minimum"} /\ SetAndTrackTaskKeysAt(e.args.minimum)
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/sql/execution.go:334-357
TraceAppendHistoryNodes ==
  /\ IsEvent("AppendHistoryNodes")
  /\ LET e == logline IN DOMAIN e.args = {"write"} /\ AppendHistoryNodesFor(DecodeWrite(e.args.write))
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/sql/execution_util.go:23-190,629-695; common/persistence/sql/shard.go:152-176; common/persistence/sql/common.go:77-80
TraceApplyWorkflowMutationTx ==
  /\ IsEvent("ApplyWorkflowMutationTx")
  /\ LET e == logline IN DOMAIN e.args = {"write"} /\ ApplyWorkflowMutationTx(DecodeWrite(e.args.write))
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/sql/execution_util.go:645-661; common/persistence/sql/shard.go:158-169
TraceRejectWorkflowMutationTx ==
  /\ IsEvent("RejectWorkflowMutationTx")
  /\ LET e == logline IN DOMAIN e.args = {"write"} /\ RejectWorkflowMutationTx(DecodeWrite(e.args.write))
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/sql/common.go:57-74; common/persistence/faultinjection/fault.go:48-53
TraceRejectPersistenceWrite ==
  /\ IsEvent("RejectPersistenceWrite")
  /\ LET e == logline IN DOMAIN e.args = {"write"} /\ RejectPersistenceWrite(DecodeWrite(e.args.write))
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/faultinjection/fault.go:40-47,61-71
TracePersistenceTimeoutBeforeWrite ==
  /\ IsEvent("PersistenceTimeoutBeforeWrite")
  /\ LET e == logline IN DOMAIN e.args = {} /\ PersistenceTimeoutBeforeWrite
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/faultinjection/fault.go:42-47,61-71; shard/context_impl.go:1540-1548
TracePersistenceResponseTimeout ==
  /\ IsEvent("PersistenceResponseTimeout")
  /\ LET e == logline IN DOMAIN e.args = {} /\ PersistenceResponseTimeout
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/persistence_retryable_clients.go:252-264; common/persistence/sql/common.go:77-78
TraceRetryPersistenceAfterUnavailable ==
  /\ IsEvent("RetryPersistenceAfterUnavailable")
  /\ LET e == logline IN DOMAIN e.args = {} /\ RetryPersistenceAfterUnavailable
  /\ ValidatePostState /\ l' = l+1

\* workflow/transaction_impl.go:184-214
TraceReturnPersistenceResult ==
  /\ IsEvent("ReturnPersistenceResult")
  /\ LET e == logline IN DOMAIN e.args = {} /\ ReturnPersistenceResult
  /\ ValidatePostState /\ l' = l+1

\* workflow/context.go:888-909; workflow/cache/cache.go:373-409; workflow/transaction_impl.go:201-214
TraceFinishUpdateWorkflowExecution ==
  /\ IsEvent("FinishUpdateWorkflowExecution")
  /\ LET e == logline IN DOMAIN e.args = {} /\ FinishUpdateWorkflowExecution
  /\ ValidatePostState /\ l' = l+1

\* workflow/context.go:174-185
TraceClearWorkflowCache ==
  /\ IsEvent("ClearWorkflowCache")
  /\ LET e == logline IN DOMAIN e.args = {} /\ ClearWorkflowCache
  /\ ValidatePostState /\ l' = l+1

\* shard/context_impl.go:1534-1548
TraceLoseShardContext ==
  /\ IsEvent("LoseShardContext")
  /\ LET e == logline IN DOMAIN e.args = {} /\ LoseShardContext
  /\ ValidatePostState /\ l' = l+1

\* shard/context_impl.go:1541-1547; common/persistence/sql/shard.go:152-176
TraceReacquireShard ==
  /\ IsEvent("ReacquireShard")
  /\ LET e == logline IN DOMAIN e.args = {} /\ ReacquireShard
  /\ ValidatePostState /\ l' = l+1

\* workflow/context.go:416-435,474-497; workflow/mutable_state_impl.go:471-477
TraceLoadMutableState ==
  /\ IsEvent("LoadMutableState")
  /\ LET e == logline IN DOMAIN e.args = {} /\ LoadMutableState
  /\ ValidatePostState /\ l' = l+1

\* common/persistence/sql/execution.go:210-330; api/describemutablestate/api.go:52-65
TraceReadWorkflowExecution ==
  /\ IsEvent("ReadWorkflowExecution")
  /\ LET e == logline IN DOMAIN e.args = {} /\ ReadWorkflowExecution
  /\ ValidatePostState /\ l' = l+1

\* workflow/transaction_impl.go:201-214
TraceNotifyOnExecutionMutation ==
  /\ IsEvent("NotifyOnExecutionMutation")
  /\ LET e == logline IN DOMAIN e.args = {"id"} /\ NotifyOnExecutionMutation(e.args.id)
  /\ ValidatePostState /\ l' = l+1

\* queues/queue_base.go:373-394; common/persistence/sql/execution_tasks.go:66-97
TraceRangeCompleteHistoryTasks ==
  /\ IsEvent("RangeCompleteHistoryTasks")
  /\ LET e == logline IN DOMAIN e.args = {"tasks"} /\ RangeCompleteHistoryTasks(ToSet(e.args.tasks))
  /\ ValidatePostState /\ l' = l+1

\* queues/executable.go:742-770; timer_queue_active_task_executor.go:235-239
TraceRedeliverTask ==
  /\ IsEvent("RedeliverTask")
  /\ LET e == logline IN DOMAIN e.args = {"task"} /\ RedeliverTask(e.args.task)
  /\ ValidatePostState /\ l' = l+1

\* service/matching/matching_engine.go:1117-1130; service/matching/backlog_manager.go:230-270
TraceReceiveRecordActivityTaskStartedResponse ==
  /\ IsEvent("ReceiveRecordActivityTaskStartedResponse")
  /\ LET e == logline IN DOMAIN e.args = {"response"} /\ ReceiveRecordActivityTaskStartedResponse(DecodeReply(e.args.response))
  /\ ValidatePostState /\ l' = l+1

\* service/matching/matching_engine.go:3587-3624,1117-1126; service/matching/backlog_manager.go:230-259
TraceExpireRecordActivityTaskStarted ==
  /\ IsEvent("ExpireRecordActivityTaskStarted")
  /\ LET e == logline IN DOMAIN e.args = {"call"} /\ ExpireRecordActivityTaskStarted(e.args.call)
  /\ ValidatePostState /\ l' = l+1

\* service/matching/matching_engine.go:3435-3478
TraceDeliverPollActivityTaskQueueResponse ==
  /\ IsEvent("DeliverPollActivityTaskQueueResponse")
  /\ LET e == logline IN DOMAIN e.args = {"response"} /\ DeliverPollActivityTaskQueueResponse(DecodeReply(e.args.response))
  /\ ValidatePostState /\ l' = l+1

\* api/recordactivitytaskheartbeat/api.go:93-101; api/respondactivitytaskcompleted/api.go:131-133
TraceDeliverActivityResponse ==
  /\ IsEvent("DeliverActivityResponse")
  /\ LET e == logline IN DOMAIN e.args = {"response"} /\ DeliverActivityResponse(DecodeReply(e.args.response))
  /\ ValidatePostState /\ l' = l+1

\* service/matching/matching_engine.go:1128-1130; api/recordactivitytaskheartbeat/api.go:93-101
TraceLoseAPIResponse ==
  /\ IsEvent("LoseAPIResponse")
  /\ LET e == logline IN DOMAIN e.args = {"response"} /\ LoseAPIResponse(DecodeReply(e.args.response))
  /\ ValidatePostState /\ l' = l+1

\* queues/queue_scheduled.go:286-300; workflow/mutable_state_impl.go:2122-2123,4534,6949
TraceAdvanceTime ==
  /\ IsEvent("AdvanceTime")
  /\ LET e == logline IN DOMAIN e.args = {"time"} /\ AdvanceTime(e.args.time)
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/api.go:384,557-566; common/persistence/sql/execution.go:210-330
TraceFinishTrace ==
  /\ IsEvent("FinishTrace")
  /\ LET e == logline IN DOMAIN e.args = {} /\ FinishTrace
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:804-805; api/respondworkflowtaskcompleted/api.go:490-529,1133-1134
TraceHandleCommandCompleteWorkflowRejected ==
  /\ IsEvent("HandleCommandCompleteWorkflowRejected")
  /\ LET e == logline IN DOMAIN e.args = {} /\ HandleCommandCompleteWorkflowRejected
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/api.go:1136-1141; workflow/mutable_state_impl.go:471-477
TraceReloadAfterRejectedWorkflowClose ==
  /\ IsEvent("ReloadAfterRejectedWorkflowClose")
  /\ LET e == logline IN DOMAIN e.args = {} /\ ReloadAfterRejectedWorkflowClose
  /\ ValidatePostState /\ l' = l+1

\* api/respondworkflowtaskcompleted/api.go:1141-1154,529,557-566; historybuilder/event_store.go:178-199
TraceFailWorkflowTaskAfterRejectedClose ==
  /\ IsEvent("FailWorkflowTaskAfterRejectedClose")
  /\ LET e == logline IN DOMAIN e.args = {} /\ FailWorkflowTaskAfterRejectedClose
  /\ ValidatePostState /\ l' = l+1

TraceSubmitWorkflowMutation ==
  /\ IsEvent("SubmitWorkflowMutation")
  /\ DOMAIN logline.args = {} /\ SubmitWorkflowMutation
  /\ ValidatePostState /\ l' = l+1

TraceShardReady ==
  /\ IsEvent("ShardReady")
  /\ DOMAIN logline.args = {} /\ ShardReady
  /\ ValidatePostState /\ l' = l+1

TraceRetryMatchingActivityTask ==
  /\ IsEvent("RetryMatchingActivityTask")
  /\ DOMAIN logline.args = {"call"} /\ RetryMatchingActivityTask(logline.args.call)
  /\ ValidatePostState /\ l' = l+1

TraceRetryActivityRequest ==
  /\ IsEvent("RetryActivityRequest")
  /\ DOMAIN logline.args = {"request"} /\ RetryActivityRequest(logline.args.request)
  /\ ValidatePostState /\ l' = l+1

TraceDropExpiredMatchingTask ==
  /\ IsEvent("DropExpiredMatchingTask")
  /\ DOMAIN logline.args = {"delivery"} /\ DropExpiredMatchingTask(logline.args.delivery)
  /\ ValidatePostState /\ l' = l+1

TraceStep ==
  \/ TraceDropExpiredMatchingTask
  \/ TraceRetryActivityRequest
  \/ TraceRetryMatchingActivityTask
  \/ TraceShardReady
  \/ TraceSubmitWorkflowMutation
  \/ TraceAddActivityTaskScheduledEvent
  \/ TraceProcessActivityTask
  \/ TraceExecuteActivityRetryTimerTask
  \/ TraceDiscardObsoleteActivityTask
  \/ TraceAddActivityTask
  \/ TraceDeliverAddActivityTaskResponse
  \/ TraceLoseAddActivityTaskResponse
  \/ TracePollActivityTaskQueue
  \/ TraceRetryRecordActivityTaskStarted
  \/ TraceRecordActivityTaskStarted
  \/ TraceRecordActivityTaskStartedDuplicate
  \/ TraceRecordActivityTaskStartedRejected
  \/ TraceSendActivityRequest
  \/ TraceRespondActivityTaskCompleted
  \/ TraceRespondActivityTaskFailed
  \/ TraceRespondActivityTaskCanceled
  \/ TraceRecordActivityTaskHeartbeat
  \/ TraceRejectActivityRequest
  \/ TraceExecuteActivityTimeoutTask
  \/ TraceDiscardClosedWorkflowTimer
  \/ TraceRecordWorkflowTaskStarted
  \/ TraceRespondWorkflowTaskCompleted
  \/ TraceHandleCommandRequestCancelActivity
  \/ TraceHandleCommandCancelBufferedActivity
  \/ TraceHandleCommandCompleteWorkflow
  \/ TraceHandleCommandCancelAndCompleteWorkflow
  \/ TraceExecuteWorkflowRunTimeoutTask
  \/ TraceCloseTransactionAsMutation
  \/ TraceSetAndTrackTaskKeys
  \/ TraceAppendHistoryNodes
  \/ TraceApplyWorkflowMutationTx
  \/ TraceRejectWorkflowMutationTx
  \/ TraceRejectPersistenceWrite
  \/ TracePersistenceTimeoutBeforeWrite
  \/ TracePersistenceResponseTimeout
  \/ TraceRetryPersistenceAfterUnavailable
  \/ TraceReturnPersistenceResult
  \/ TraceFinishUpdateWorkflowExecution
  \/ TraceClearWorkflowCache
  \/ TraceLoseShardContext
  \/ TraceReacquireShard
  \/ TraceLoadMutableState
  \/ TraceReadWorkflowExecution
  \/ TraceNotifyOnExecutionMutation
  \/ TraceRangeCompleteHistoryTasks
  \/ TraceRedeliverTask
  \/ TraceReceiveRecordActivityTaskStartedResponse
  \/ TraceExpireRecordActivityTaskStarted
  \/ TraceDeliverPollActivityTaskQueueResponse
  \/ TraceDeliverActivityResponse
  \/ TraceLoseAPIResponse
  \/ TraceAdvanceTime
  \/ TraceFinishTrace
  \/ TraceHandleCommandCompleteWorkflowRejected
  \/ TraceReloadAfterRejectedWorkflowClose
  \/ TraceFailWorkflowTaskAfterRejectedClose

\* No silent actions: each modeled boundary has a mandatory observation hook.
TraceNext == TraceStep \/ (l > Len(TraceLog) /\ UNCHANGED traceVars)
\* Fairness eliminates arbitrary stuttering before an enabled trace event. If
\* an event cannot match, the terminal stutter violates TraceMatched.
TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceStep)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
